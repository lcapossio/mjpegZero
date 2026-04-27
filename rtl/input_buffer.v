// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// Input Buffer - YUV422 De-interleave and 8x8 Block Assembly
// ============================================================================
// Receives YUYV interleaved data via AXI4-Stream (16-bit),
// de-interleaves into Y, Cb, Cr components,
// buffers 8 lines, and outputs 8x8 blocks in MCU order.
//
// YUV422 input format (16-bit words):
//   Word 0: {Cb0, Y0}  (Cb in [15:8], Y in [7:0])
//   Word 1: {Cr0, Y1}  (Cr in [15:8], Y in [7:0])
//   Word 2: {Cb1, Y2}
//   Word 3: {Cr1, Y3}
//   ...
//
// MCU structure for YUV422 (H=2, V=1):
//   - Y block 0 (left 8x8)
//   - Y block 1 (right 8x8)
//   - Cb block (8x8, subsampled)
//   - Cr block (8x8, subsampled)
//
// Buffer sizes and addresses are fully parameterized by IMG_WIDTH.
// ============================================================================

module input_buffer #(
    parameter IMG_WIDTH  = 1280
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Stream slave input (YUYV 16-bit)
    input  wire [15:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,   // End of line
    input  wire        s_axis_tuser,   // Start of frame

    // Block output interface
    output reg         blk_valid,      // One sample per clock
    output reg  [7:0]  blk_data,       // 8-bit unsigned sample
    output reg         blk_sof,        // Start of frame (first sample of first block)
    output reg         blk_sob,        // Start of block
    output reg  [1:0]  blk_comp,       // Component: 0=Y0, 1=Y1, 2=Cb, 3=Cr
    input  wire        blk_ready,      // Downstream ready

    // Lines-done pulse (8 lines written, blocks ready to read)
    output wire        lines_done
);

    initial begin
        if (IMG_WIDTH <= 0) begin
            $display("ERROR: IMG_WIDTH must be positive");
            $finish;
        end
        if ((IMG_WIDTH % 16) != 0) begin
            $display("ERROR: IMG_WIDTH must be a multiple of 16");
            $finish;
        end
    end

    // ========================================================================
    // Derived parameters
    // ========================================================================
    localparam MCU_COLS = IMG_WIDTH / 16;

    // Buffer sizes per bank (8 lines)
    localparam Y_BANK_SIZE  = 8 * IMG_WIDTH;      // 8 lines of full-res luma
    localparam CB_BANK_SIZE = 8 * (IMG_WIDTH/2);   // 8 lines of half-res chroma
    localparam CR_BANK_SIZE = 8 * (IMG_WIDTH/2);
    localparam CHROMA_WIDTH = IMG_WIDTH / 2;

    // Address bit widths (double-buffered)
    localparam Y_ADDR_W  = $clog2(2 * Y_BANK_SIZE);
    localparam CB_ADDR_W = $clog2(2 * CB_BANK_SIZE);
    localparam CR_ADDR_W = $clog2(2 * CR_BANK_SIZE);

    // ========================================================================
    // Line buffers using BRAM (8 lines of Y, 8 lines of Cb, 8 lines of Cr)
    // Double-buffered: 2 banks
    // ========================================================================
    reg y_buf_we;
    reg [Y_ADDR_W-1:0]  y_buf_waddr;
    reg [7:0]           y_buf_wdata;
    reg [Y_ADDR_W-1:0]  y_buf_raddr;
    wire [7:0]          y_buf_rdata;   // driven by bram_sdp (2-cycle latency)

    reg cb_buf_we;
    reg [CB_ADDR_W-1:0] cb_buf_waddr;
    reg [7:0]           cb_buf_wdata;
    reg [CB_ADDR_W-1:0] cb_buf_raddr;
    wire [7:0]          cb_buf_rdata;

    reg cr_buf_we;
    reg [CR_ADDR_W-1:0] cr_buf_waddr;
    reg [7:0]           cr_buf_wdata;
    reg [CR_ADDR_W-1:0] cr_buf_raddr;
    wire [7:0]          cr_buf_rdata;

    // Explicit RAMB36E1 instances with DOB_REG=1.
    // Vivado's behavioural inference creates depth-cascaded BRAM groups with
    // an internal cascade MUX *before* the output register, blocking DOB_REG
    // absorption. This causes tile duplication (11 → 16 at 720p) regardless
    // of clock frequency. Explicit primitives guarantee DOB_REG=1 and
    // optimal tile count. Read latency = 2 cycles.
    //   Y:  ceil(20480/4096) = 5 tiles
    //   Cb: ceil(10240/4096) = 3 tiles
    //   Cr: ceil(10240/4096) = 3 tiles  →  11 total
    bram_sdp #(.DEPTH(2*Y_BANK_SIZE),  .WIDTH(8)) u_y_mem  (
        .clk(clk), .we(y_buf_we),  .waddr(y_buf_waddr),  .wdata(y_buf_wdata),
        .raddr(y_buf_raddr),  .rdata(y_buf_rdata)
    );
    bram_sdp #(.DEPTH(2*CB_BANK_SIZE), .WIDTH(8)) u_cb_mem (
        .clk(clk), .we(cb_buf_we), .waddr(cb_buf_waddr), .wdata(cb_buf_wdata),
        .raddr(cb_buf_raddr), .rdata(cb_buf_rdata)
    );
    bram_sdp #(.DEPTH(2*CR_BANK_SIZE), .WIDTH(8)) u_cr_mem (
        .clk(clk), .we(cr_buf_we), .waddr(cr_buf_waddr), .wdata(cr_buf_wdata),
        .raddr(cr_buf_raddr), .rdata(cr_buf_rdata)
    );

    reg rd_valid_pipe;

    // ========================================================================
    // Forward declarations for read-side signals used in write-side ready
    // ========================================================================
    reg rd_bank;
    reg rd_active;

    // Latch for wr_8lines_done pulses that arrive while RD_READ is active.
    // With double-buffering, write completes a row while the read side is still
    // draining the previous row.  Without the latch the one-cycle pulse is
    // missed and the read side stalls forever.
    reg lines_done_pending;
    reg rd_bank_pending;

    // ========================================================================
    // Write side state machine
    // ========================================================================
    reg wr_bank;
    reg [10:0] wr_x;          // Pixel x position (0..IMG_WIDTH-1)
    reg [2:0]  wr_line;       // Line within 8-line group (0..7)
    reg [6:0]  wr_mcu_row;    // MCU row
    reg        wr_phase;      // 0 = Y+Cb word, 1 = Y+Cr word
    reg        wr_frame_active;
    reg        wr_8lines_done;

    wire wr_accept = s_axis_tvalid && s_axis_tready;

    // Write-side ready: accept data when frame is active and the write bank
    // is not being read (double-buffer protection). Do NOT gate with blk_ready,
    // because the write side must fill 8 lines before blocks can be read out.
    assign s_axis_tready = wr_frame_active && (wr_bank != rd_bank || !rd_active);
    assign lines_done = wr_8lines_done;

    // Power-on initialisation (synthesisable on Xilinx FPGAs via INIT attrs).
    // Required for synchronous-reset style: prevents X propagation through
    // combinational paths (s_axis_tready, BRAM we) before the first posedge.
    initial begin
        // Write-side
        wr_bank         = 1'b0;
        wr_x            = 11'd0;
        wr_line         = 3'd0;
        wr_mcu_row      = 7'd0;
        wr_phase        = 1'b0;
        wr_frame_active = 1'b0;
        wr_8lines_done  = 1'b0;
        y_buf_we        = 1'b0;
        cb_buf_we       = 1'b0;
        cr_buf_we       = 1'b0;
        // Read-side
        rd_bank              = 1'b0;
        rd_active            = 1'b0;
        lines_done_pending   = 1'b0;
        rd_bank_pending      = 1'b0;
        rd_valid_pipe        = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_bank <= 1'b0;
            wr_x <= 11'd0;
            wr_line <= 3'd0;
            wr_mcu_row <= 7'd0;
            wr_phase <= 1'b0;
            wr_frame_active <= 1'b0;
            wr_8lines_done <= 1'b0;
            y_buf_we <= 1'b0;
            cb_buf_we <= 1'b0;
            cr_buf_we <= 1'b0;
        end else begin
            y_buf_we <= 1'b0;
            cb_buf_we <= 1'b0;
            cr_buf_we <= 1'b0;
            wr_8lines_done <= 1'b0;

            if (s_axis_tvalid && s_axis_tuser) begin
                wr_frame_active <= 1'b1;
                wr_x <= 11'd0;
                wr_line <= 3'd0;
                wr_mcu_row <= 7'd0;
                wr_phase <= 1'b0;
                wr_bank <= 1'b0;
            end

            if (wr_accept && wr_frame_active) begin
                // Y sample (always present)
                y_buf_we <= 1'b1;
                /* verilator lint_off WIDTHEXPAND */
                y_buf_waddr <= wr_bank * Y_BANK_SIZE[Y_ADDR_W-1:0]
                             + {1'b0, wr_line} * IMG_WIDTH[Y_ADDR_W-1:0]
                             + wr_x;
                /* verilator lint_on WIDTHEXPAND */
                y_buf_wdata <= s_axis_tdata[7:0];

                if (!wr_phase) begin
                    // Even pixel: Cb
                    cb_buf_we <= 1'b1;
                    /* verilator lint_off WIDTHEXPAND */
                    cb_buf_waddr <= wr_bank * CB_BANK_SIZE[CB_ADDR_W-1:0]
                                 + {1'b0, wr_line} * CHROMA_WIDTH[CB_ADDR_W-1:0]
                                 + wr_x[10:1];
                    /* verilator lint_on WIDTHEXPAND */
                    cb_buf_wdata <= s_axis_tdata[15:8];
                end else begin
                    // Odd pixel: Cr
                    cr_buf_we <= 1'b1;
                    /* verilator lint_off WIDTHEXPAND */
                    cr_buf_waddr <= wr_bank * CR_BANK_SIZE[CR_ADDR_W-1:0]
                                 + {1'b0, wr_line} * CHROMA_WIDTH[CR_ADDR_W-1:0]
                                 + wr_x[10:1];
                    /* verilator lint_on WIDTHEXPAND */
                    cr_buf_wdata <= s_axis_tdata[15:8];
                end

                wr_phase <= ~wr_phase;
                wr_x <= wr_x + 11'd1;

                // End of line
                if (wr_x == IMG_WIDTH[10:0] - 11'd1 || s_axis_tlast) begin
                    wr_x <= 11'd0;
                    wr_phase <= 1'b0;
                    if (wr_line == 3'd7) begin
                        wr_line <= 3'd0;
                        wr_8lines_done <= 1'b1;
                        wr_bank <= ~wr_bank;
                        wr_mcu_row <= wr_mcu_row + 7'd1;
                    end else begin
                        wr_line <= wr_line + 3'd1;
                    end
                end
            end
        end
    end

    // ========================================================================
    // Read side state machine - outputs 8x8 blocks in MCU order
    // ========================================================================
    // rd_bank and rd_active declared above (forward declarations)
    reg [6:0] rd_mcu_col;
    reg [1:0] rd_comp;
    reg [2:0] rd_row;
    reg [2:0] rd_col;
    reg       rd_started;
    reg       rd_sof_pending;

    // rd_valid_pipe declared above (forward declaration for BRAM clock enable)
    reg       rd_sob_pipe;
    reg [1:0] rd_comp_pipe;
    reg       rd_sof_pipe;

    localparam RD_IDLE = 2'd0,
               RD_READ = 2'd1;
    reg [1:0] rd_state;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_bank <= 1'b0;
            rd_mcu_col <= 7'd0;
            rd_comp <= 2'd0;
            rd_row <= 3'd0;
            rd_col <= 3'd0;
            rd_active <= 1'b0;
            rd_started <= 1'b0;
            rd_sof_pending <= 1'b0;
            rd_state <= RD_IDLE;
            rd_valid_pipe <= 1'b0;
            rd_sob_pipe <= 1'b0;
            rd_sof_pipe <= 1'b0;
            lines_done_pending <= 1'b0;
            rd_bank_pending <= 1'b0;
        end else begin
            rd_valid_pipe <= 1'b0;
            rd_sob_pipe <= 1'b0;
            rd_sof_pipe <= 1'b0;

            // Capture wr_8lines_done pulse arriving while read side is busy.
            // In simulation the pixel feed can deliver rows faster than the
            // read side drains them; without the latch the one-cycle pulse is
            // lost and the read side stalls indefinitely after the first row.
            if (wr_8lines_done && rd_state == RD_READ) begin
                lines_done_pending <= 1'b1;
                rd_bank_pending    <= ~wr_bank;
            end

            case (rd_state)
                RD_IDLE: begin
                    if (wr_8lines_done || lines_done_pending) begin
                        rd_active   <= 1'b1;
                        rd_bank     <= wr_8lines_done ? ~wr_bank : rd_bank_pending;
                        rd_mcu_col  <= 7'd0;
                        rd_comp     <= 2'd0;
                        rd_row      <= 3'd0;
                        rd_col      <= 3'd0;
                        rd_state    <= RD_READ;
                        lines_done_pending <= 1'b0;
                        if (!rd_started) begin
                            rd_sof_pending <= 1'b1;
                            rd_started     <= 1'b1;
                        end
                    end
                end

                RD_READ: begin
                    if (blk_ready) begin
                        rd_valid_pipe <= 1'b1;
                        rd_comp_pipe <= rd_comp;

                        if (rd_sof_pending && rd_row == 3'd0 && rd_col == 3'd0) begin
                            rd_sof_pipe <= 1'b1;
                            rd_sof_pending <= 1'b0;
                        end

                        if (rd_row == 3'd0 && rd_col == 3'd0)
                            rd_sob_pipe <= 1'b1;

                        // Generate read address based on component
                        case (rd_comp)
                            2'd0: begin // Y block 0 (left)
                                y_buf_raddr <= rd_bank * Y_BANK_SIZE[Y_ADDR_W-1:0]
                                             + {1'b0, rd_row} * IMG_WIDTH[Y_ADDR_W-1:0]
                                             + {1'b0, rd_mcu_col} * {{(Y_ADDR_W-5){1'b0}}, 5'd16}
                                             + {{(Y_ADDR_W-3){1'b0}}, rd_col};
                            end
                            2'd1: begin // Y block 1 (right)
                                y_buf_raddr <= rd_bank * Y_BANK_SIZE[Y_ADDR_W-1:0]
                                             + {1'b0, rd_row} * IMG_WIDTH[Y_ADDR_W-1:0]
                                             + {1'b0, rd_mcu_col} * {{(Y_ADDR_W-5){1'b0}}, 5'd16}
                                             + {{(Y_ADDR_W-4){1'b0}}, 4'd8}
                                             + {{(Y_ADDR_W-3){1'b0}}, rd_col};
                            end
                            2'd2: begin // Cb
                                cb_buf_raddr <= rd_bank * CB_BANK_SIZE[CB_ADDR_W-1:0]
                                              + {1'b0, rd_row} * CHROMA_WIDTH[CB_ADDR_W-1:0]
                                              + {1'b0, rd_mcu_col} * {{(CB_ADDR_W-4){1'b0}}, 4'd8}
                                              + {{(CB_ADDR_W-3){1'b0}}, rd_col};
                            end
                            2'd3: begin // Cr
                                cr_buf_raddr <= rd_bank * CR_BANK_SIZE[CR_ADDR_W-1:0]
                                              + {1'b0, rd_row} * CHROMA_WIDTH[CR_ADDR_W-1:0]
                                              + {1'b0, rd_mcu_col} * {{(CR_ADDR_W-4){1'b0}}, 4'd8}
                                              + {{(CR_ADDR_W-3){1'b0}}, rd_col};
                            end
                        endcase

                        // Advance position
                        rd_col <= rd_col + 3'd1;
                        if (rd_col == 3'd7) begin
                            rd_col <= 3'd0;
                            rd_row <= rd_row + 3'd1;
                            if (rd_row == 3'd7) begin
                                rd_row <= 3'd0;
                                rd_comp <= rd_comp + 2'd1;
                                if (rd_comp == 2'd3) begin
                                    rd_comp <= 2'd0;
                                    rd_mcu_col <= rd_mcu_col + 7'd1;
                                    if (rd_mcu_col == MCU_COLS[6:0] - 7'd1) begin
                                        rd_state <= RD_IDLE;
                                        rd_active <= 1'b0;
                                    end
                                end
                            end
                        end
                    end
                end

                default: rd_state <= RD_IDLE;
            endcase

            // Reset on SOF
            if (s_axis_tvalid && s_axis_tuser) begin
                rd_started         <= 1'b0;
                rd_state           <= RD_IDLE;
                lines_done_pending <= 1'b0;
                rd_active <= 1'b0;
            end
        end
    end

    // Output pipeline: matches bram_sdp 2-cycle read latency (BRAM array + DOB_REG)
    // 3-stage: addr → BRAM+DOB_REG → output mux
    reg       out_valid_d1, out_valid_d2;
    reg       out_sob_d1,   out_sob_d2;
    reg       out_sof_d1,   out_sof_d2;
    reg [1:0] out_comp_d1,  out_comp_d2;

    always @(posedge clk) begin
        if (!rst_n) begin
            blk_valid    <= 1'b0;
            blk_data     <= 8'd0;
            blk_sof      <= 1'b0;
            blk_sob      <= 1'b0;
            blk_comp     <= 2'd0;
            out_valid_d1 <= 1'b0;
            out_sob_d1   <= 1'b0;
            out_sof_d1   <= 1'b0;
            out_comp_d1  <= 2'd0;
            out_valid_d2 <= 1'b0;
            out_sob_d2   <= 1'b0;
            out_sof_d2   <= 1'b0;
            out_comp_d2  <= 2'd0;
        end else begin
            // Stage 1: 1 cycle after address (BRAM internal read in progress)
            out_valid_d1 <= rd_valid_pipe;
            out_sob_d1   <= rd_sob_pipe;
            out_sof_d1   <= rd_sof_pipe;
            out_comp_d1  <= rd_comp_pipe;

            // Stage 2: aligned with *_buf_rdata (DOB_REG output valid)
            out_valid_d2 <= out_valid_d1;
            out_sob_d2   <= out_sob_d1;
            out_sof_d2   <= out_sof_d1;
            out_comp_d2  <= out_comp_d1;

            // Stage 3: output mux selects Y/Cb/Cr based on component
            blk_valid <= out_valid_d2;
            blk_sob   <= out_sob_d2;
            blk_sof   <= out_sof_d2;
            blk_comp  <= out_comp_d2;

            if (out_comp_d2 <= 2'd1)
                blk_data <= y_buf_rdata;
            else if (out_comp_d2 == 2'd2)
                blk_data <= cb_buf_rdata;
            else
                blk_data <= cr_buf_rdata;
        end
    end

endmodule
