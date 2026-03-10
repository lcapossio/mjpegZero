// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// mjpegZero Top-Level
// ============================================================================
// Top-level module integrating the full JPEG encoding pipeline.
//
// Interfaces:
//   - AXI4-Stream Slave: 16-bit YUYV input video
//   - AXI4-Stream Master: 8-bit JPEG compressed output
//   - AXI4-Lite Slave: Control/status registers
//
// Pipeline:
//   Input Buffer -> 2D DCT -> Quantizer -> Zigzag -> Huffman -> Bitstream -> JFIF
//
// Improvements over v1:
//   - FIFO-based comp_id tracking through pipeline
//   - Backpressure propagation from bitstream packer to Huffman
//   - Runtime quality factor via AXI4-Lite
//   - Restart marker support
//   - Frame byte count reporting
//   - Dynamic JFIF headers (Q-tables read from quantizer)
// ============================================================================

module mjpegzero_enc_top #(
    parameter LITE_MODE    = 1,                           // 0 = full (1080p30, 150 MHz), 1 = lite (720p60)
    parameter LITE_QUALITY = 95,                          // Quality 1-100, used when LITE_MODE=1
    parameter IMG_WIDTH    = LITE_MODE ? 1280 : 1920,     // 720p lite, 1080p full
    parameter IMG_HEIGHT   = LITE_MODE ? 720  : 1080
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Stream Slave - Video Input (16-bit YUYV)
    input  wire [15:0] s_axis_vid_tdata,
    input  wire        s_axis_vid_tvalid,
    output wire        s_axis_vid_tready,
    input  wire        s_axis_vid_tlast,
    input  wire        s_axis_vid_tuser,

    // AXI4-Stream Master - JPEG Output (8-bit, no backpressure)
    output wire        m_axis_jpg_tvalid,
    output wire [7:0]  m_axis_jpg_tdata,
    output wire        m_axis_jpg_tlast,

    // AXI4-Lite Slave - Register Interface (5-bit address)
    input  wire [4:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [4:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready
);

    // ========================================================================
    // Control/Status
    // ========================================================================
    wire        ctrl_enable;
    wire        ctrl_soft_reset;
    wire [6:0]  ctrl_quality;
    wire [15:0] ctrl_restart_interval;
    wire        sts_busy;
    wire        sts_frame_done_pulse;
    reg  [31:0] frame_cnt;

    // Internal reset (combined)
    wire rst_int_n = rst_n & ~ctrl_soft_reset;

    // ========================================================================
    // Forward declarations for all pipeline wires
    // (Verilog 2001 requires declarations before use)
    // ========================================================================

    // Input buffer -> DCT
    wire        ibuf_blk_valid;
    wire [7:0]  ibuf_blk_data;
    wire        ibuf_blk_sof;
    wire        ibuf_blk_sob;
    wire [1:0]  ibuf_blk_comp;
    wire        ibuf_blk_ready;
    wire        ibuf_lines_done;   // Pulse when 8 lines buffered

    // DCT input conversion (level shift: unsigned 0-255 -> signed -128..127)
    wire signed [11:0] dct_in_data = $signed({4'b0, ibuf_blk_data}) - 12'sd128;
    wire        dct_in_valid = ibuf_blk_valid;
    wire        dct_in_sof   = ibuf_blk_sob; // DCT uses sof as block start

    // DCT -> Quantizer
    wire        dct_out_valid;
    wire signed [15:0] dct_out_data;
    wire        dct_out_sof;  // Start of output block

    // Quantizer -> Zigzag
    wire        quant_out_valid;
    wire signed [15:0] quant_out_data;
    wire        quant_out_sob;

    // Zigzag -> Huffman
    wire        zz_out_valid;
    wire signed [15:0] zz_out_data;
    wire        zz_out_sob;

    // Huffman -> Bitstream packer
    wire        huff_out_valid;
    wire [31:0] huff_out_bits;
    wire [5:0]  huff_out_len;
    wire        huff_out_eob;
    wire        huff_bp_ready;  // Backpressure from bitstream packer

    // Bitstream packer -> JFIF writer
    wire        bs_out_valid;
    wire [7:0]  bs_out_data;
    wire        bs_out_last;
    wire        bs_out_ready;
    wire [31:0] bs_byte_count;

    // Q-table read port (quantizer -> JFIF writer)
    wire [5:0]  qt_rd_addr;
    wire        qt_rd_is_chroma;
    wire [7:0]  qt_rd_data;

    // JFIF writer status
    wire        jfif_headers_done;

    // ========================================================================
    // Component ID tracking through pipeline
    // ========================================================================
    // The input buffer tells us which component each block belongs to
    // (0=Y0, 1=Y1, 2=Cb, 3=Cr). We need to delay this to match the
    // DCT + quantizer + zigzag pipeline latency.
    //
    // Instead of a fragile fixed delay, use a small FIFO:
    //   Push: when ibuf_blk_sob (start of block from input buffer)
    //   Pop for quantizer: when dct_out_sof (start of block from DCT output)
    //   Pop for huffman: when zz_out_sob (start of block from zigzag output)
    //
    // We need two separate tracking paths:
    //   1. ibuf -> (DCT latency) -> quantizer comp_id
    //   2. ibuf -> (DCT + quant + zigzag latency) -> huffman comp_id
    //
    // Simple shift-register FIFO (max 4 blocks in flight)

    // --- Comp ID FIFO for quantizer (through DCT) ---
    reg [1:0] comp_fifo_q [0:3];
    reg [2:0] comp_fifo_q_wr, comp_fifo_q_rd;

    always @(posedge clk) begin
        if (!rst_int_n) begin
            comp_fifo_q_wr <= 3'd0;
            comp_fifo_q_rd <= 3'd0;
        end else begin
            if (ibuf_blk_valid && ibuf_blk_sob) begin
                comp_fifo_q[comp_fifo_q_wr[1:0]] <= ibuf_blk_comp;
                comp_fifo_q_wr <= comp_fifo_q_wr + 3'd1;
            end
            if (dct_out_valid && dct_out_sof) begin
                comp_fifo_q_rd <= comp_fifo_q_rd + 3'd1;
            end
        end
    end

    wire [1:0] quant_comp_id = comp_fifo_q[comp_fifo_q_rd[1:0]];

    // --- Comp ID FIFO for Huffman (through DCT + quant + zigzag) ---
    reg [1:0] comp_fifo_h [0:7];
    reg [3:0] comp_fifo_h_wr, comp_fifo_h_rd;

    always @(posedge clk) begin
        if (!rst_int_n) begin
            comp_fifo_h_wr <= 4'd0;
            comp_fifo_h_rd <= 4'd0;
        end else begin
            if (ibuf_blk_valid && ibuf_blk_sob) begin
                comp_fifo_h[comp_fifo_h_wr[2:0]] <= ibuf_blk_comp;
                comp_fifo_h_wr <= comp_fifo_h_wr + 4'd1;
            end
            if (zz_out_valid && zz_out_sob) begin
                comp_fifo_h_rd <= comp_fifo_h_rd + 4'd1;
            end
        end
    end

    wire [1:0] huff_comp_id = comp_fifo_h[comp_fifo_h_rd[2:0]];

    // ========================================================================
    // Frame control
    // ========================================================================
    reg         frame_active;
    reg         frame_start_pulse;
    reg         frame_done_pulse;
    reg [16:0]  mcu_count;    // Count MCUs (actually blocks) in current frame
    localparam  TOTAL_BLOCKS = (IMG_WIDTH / 16) * (IMG_HEIGHT / 8) * 4;  // 4 blocks per MCU

    // Restart marker tracking
    reg [15:0]  mcu_in_segment;    // MCU count within current restart segment
    reg         restart_trigger;   // Pulse to insert restart marker

    // Frame start: triggered by first lines_done (8 lines buffered)
    // This starts JFIF header output BEFORE blocks enter the pipeline
    reg         frame_hdr_started;  // Headers started for current frame

    always @(posedge clk) begin
        if (!rst_int_n) begin
            frame_active      <= 1'b0;
            frame_start_pulse <= 1'b0;
            frame_done_pulse  <= 1'b0;
            frame_cnt         <= 32'd0;
            mcu_count         <= 17'd0;
            mcu_in_segment    <= 16'd0;
            restart_trigger   <= 1'b0;
            frame_hdr_started <= 1'b0;
        end else begin
            frame_start_pulse <= 1'b0;
            frame_done_pulse  <= 1'b0;
            restart_trigger   <= 1'b0;

            // Trigger JFIF headers when first 8 lines are buffered
            // (before any blocks enter the pipeline)
            if (ibuf_lines_done && !frame_hdr_started) begin
                frame_start_pulse <= 1'b1;
                frame_hdr_started <= 1'b1;
            end

            // Start of frame tracking (when first block actually enters pipeline)
            if (ibuf_blk_sof && ibuf_blk_valid) begin
                frame_active   <= 1'b1;
                mcu_count      <= 17'd0;
                mcu_in_segment <= 16'd0;
            end

            // Count completed blocks via Huffman EOB
            // CRITICAL: Must check huff_bp_ready too! The Huffman encoder
            // holds out_valid=1, out_eob=1 for multiple cycles while waiting
            // for the bitstream packer to drain. Without bp_ready, mcu_count
            // increments every cycle, causing frame_done_pulse to fire early
            // and the packer to flush before all blocks are encoded.
            if (huff_out_eob && huff_out_valid && huff_bp_ready) begin
                mcu_count <= mcu_count + 17'd1;

                // Every 4 blocks = 1 MCU completion
                if (mcu_count[1:0] == 2'd3) begin
                    // Check restart interval — skip on last MCU to avoid
                    // restart_trigger colliding with frame_done_pulse (both
                    // asserted same cycle causes packer to emit RST instead of EOI)
                    if (ctrl_restart_interval != 16'd0 &&
                            mcu_count != TOTAL_BLOCKS[16:0] - 17'd1) begin
                        if (mcu_in_segment + 16'd1 >= ctrl_restart_interval) begin
                            restart_trigger <= 1'b1;
                            mcu_in_segment  <= 16'd0;
                        end else begin
                            mcu_in_segment <= mcu_in_segment + 16'd1;
                        end
                    end
                end

                // Frame complete
                if (mcu_count == TOTAL_BLOCKS[16:0] - 17'd1) begin
                    frame_active     <= 1'b0;
                    frame_done_pulse <= 1'b1;
                    frame_cnt        <= frame_cnt + 32'd1;
                    frame_hdr_started <= 1'b0; // Ready for next frame
                end
            end
        end
    end

    assign sts_busy = frame_active;
    assign sts_frame_done_pulse = frame_done_pulse;

    // ========================================================================
    // Pipeline flow control
    // Gate block output: only allow blocks to flow when:
    //   1. Encoder is enabled
    //   2. JFIF headers have been written
    //   3. Pipeline is not full (at most 2 blocks in flight)
    // The Huffman encoder has a double-buffer (2 banks). We limit blocks
    // in flight to prevent buffer overflow when the Huffman takes many
    // cycles to process complex blocks.
    // ========================================================================
    reg [2:0] pipeline_depth;

    always @(posedge clk) begin
        if (!rst_int_n) begin
            pipeline_depth <= 3'd0;
        end else begin
            case ({ibuf_blk_valid && ibuf_blk_sob && ibuf_blk_ready,
                   huff_out_eob && huff_out_valid && huff_bp_ready})
                2'b10: pipeline_depth <= pipeline_depth + 3'd1;
                2'b01: pipeline_depth <= pipeline_depth - 3'd1;
                default: ; // no change or balanced
            endcase
        end
    end

    assign ibuf_blk_ready = ctrl_enable && jfif_headers_done && (pipeline_depth < 3'd2);

    // ========================================================================
    // Module instantiations
    // ========================================================================

    // --- AXI4-Lite Register Interface ---
    axi4_lite_regs #(
        .LITE_MODE  (LITE_MODE)
    ) u_regs (
        .clk                  (clk),
        .rst_n                (rst_n),
        .s_axi_awaddr         (s_axi_awaddr),
        .s_axi_awvalid        (s_axi_awvalid),
        .s_axi_awready        (s_axi_awready),
        .s_axi_wdata          (s_axi_wdata),
        .s_axi_wstrb          (s_axi_wstrb),
        .s_axi_wvalid         (s_axi_wvalid),
        .s_axi_wready         (s_axi_wready),
        .s_axi_bresp          (s_axi_bresp),
        .s_axi_bvalid         (s_axi_bvalid),
        .s_axi_bready         (s_axi_bready),
        .s_axi_araddr         (s_axi_araddr),
        .s_axi_arvalid        (s_axi_arvalid),
        .s_axi_arready        (s_axi_arready),
        .s_axi_rdata          (s_axi_rdata),
        .s_axi_rresp          (s_axi_rresp),
        .s_axi_rvalid         (s_axi_rvalid),
        .s_axi_rready         (s_axi_rready),
        .ctrl_enable          (ctrl_enable),
        .ctrl_soft_reset      (ctrl_soft_reset),
        .ctrl_quality         (ctrl_quality),
        .ctrl_restart_interval(ctrl_restart_interval),
        .sts_busy             (sts_busy),
        .sts_frame_done_pulse (sts_frame_done_pulse),
        .sts_frame_cnt        (frame_cnt),
        .sts_frame_size       (bs_byte_count)
    );

    // --- Input Buffer ---
    input_buffer #(
        .IMG_WIDTH  (IMG_WIDTH)
    ) u_input_buffer (
        .clk           (clk),
        .rst_n         (rst_int_n),
        .s_axis_tdata  (s_axis_vid_tdata),
        .s_axis_tvalid (s_axis_vid_tvalid & ctrl_enable),
        .s_axis_tready (s_axis_vid_tready),
        .s_axis_tlast  (s_axis_vid_tlast),
        .s_axis_tuser  (s_axis_vid_tuser),
        .blk_valid     (ibuf_blk_valid),
        .blk_data      (ibuf_blk_data),
        .blk_sof       (ibuf_blk_sof),
        .blk_sob       (ibuf_blk_sob),
        .blk_comp      (ibuf_blk_comp),
        .blk_ready     (ibuf_blk_ready),
        .lines_done    (ibuf_lines_done)
    );

    // --- 2D DCT ---
    dct_2d u_dct (
        .clk       (clk),
        .rst_n     (rst_int_n),
        .in_valid  (dct_in_valid),
        .in_data   (dct_in_data),
        .in_sof    (dct_in_sof),
        .out_valid (dct_out_valid),
        .out_data  (dct_out_data),
        .out_sof   (dct_out_sof)
    );

    // --- Quantizer ---
    quantizer #(
        .LITE_MODE    (LITE_MODE),
        .LITE_QUALITY (LITE_QUALITY)
    ) u_quantizer (
        .clk            (clk),
        .rst_n          (rst_int_n),
        .comp_id        (quant_comp_id),
        .quality        (ctrl_quality),
        .in_valid       (dct_out_valid),
        .in_data        (dct_out_data),
        .in_sof         (dct_out_sof),
        .in_sob         (dct_out_sof),
        .out_valid      (quant_out_valid),
        .out_data       (quant_out_data),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_sof        (),
        /* verilator lint_on PINCONNECTEMPTY */
        .out_sob        (quant_out_sob),
        .qt_rd_addr     (qt_rd_addr),
        .qt_rd_is_chroma(qt_rd_is_chroma),
        .qt_rd_data     (qt_rd_data)
    );

    // --- Zigzag Reorder ---
    zigzag_reorder u_zigzag (
        .clk       (clk),
        .rst_n     (rst_int_n),
        .in_valid  (quant_out_valid),
        .in_data   (quant_out_data),
        .in_sob    (quant_out_sob),
        .out_valid (zz_out_valid),
        .out_data  (zz_out_data),
        .out_sob   (zz_out_sob)
    );

    // --- Huffman Encoder ---
    huffman_encoder #(
        .LITE_MODE  (LITE_MODE)
    ) u_huffman (
        .clk       (clk),
        .rst_n     (rst_int_n),
        .comp_id   (huff_comp_id),
        .restart   (restart_trigger),
        .in_valid  (zz_out_valid),
        .in_data   (zz_out_data),
        .in_sob    (zz_out_sob),
        .out_valid (huff_out_valid),
        .out_bits  (huff_out_bits),
        .out_len   (huff_out_len),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_sob   (),
        /* verilator lint_on PINCONNECTEMPTY */
        .out_eob   (huff_out_eob),
        .out_ready (huff_bp_ready)
    );

    // --- Bitstream Packer ---
    bitstream_packer u_bitpacker (
        .clk        (clk),
        .rst_n      (rst_int_n),
        .in_valid   (huff_out_valid),
        .in_bits    (huff_out_bits),
        .in_len     (huff_out_len),
        .in_flush   (frame_done_pulse),
        .in_restart (restart_trigger),
        .bp_ready   (huff_bp_ready),
        .out_valid  (bs_out_valid),
        .out_data   (bs_out_data),
        .out_last   (bs_out_last),
        .out_ready  (bs_out_ready),
        .byte_count (bs_byte_count)
    );

    // --- JFIF Writer ---
    jfif_writer #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .LITE_MODE    (LITE_MODE),
        .LITE_QUALITY (LITE_QUALITY)
    ) u_jfif (
        .clk              (clk),
        .rst_n            (rst_int_n),
        .frame_start      (frame_start_pulse),
        .frame_done       (frame_done_pulse),
        .restart_interval (ctrl_restart_interval),
        .qt_rd_addr       (qt_rd_addr),
        .qt_rd_is_chroma  (qt_rd_is_chroma),
        .qt_rd_data       (qt_rd_data),
        .scan_valid       (bs_out_valid),
        .scan_data        (bs_out_data),
        .scan_last        (bs_out_last),
        .scan_ready       (bs_out_ready),
        .m_axis_tvalid    (m_axis_jpg_tvalid),
        .m_axis_tdata     (m_axis_jpg_tdata),
        .m_axis_tlast     (m_axis_jpg_tlast),
        .headers_done     (jfif_headers_done)
    );

endmodule
