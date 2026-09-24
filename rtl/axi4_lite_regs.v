// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// AXI4-Lite Register Interface
// ============================================================================
// Register map (5-bit address, 6 registers):
//   0x00: CTRL       [0]=enable, [1]=soft_reset
//   0x04: STATUS     [0]=busy, [1]=frame_done (W1C)
//   0x08: FRAME_CNT  (RO) completed frame count
//   0x0C: QUALITY    [6:0]=quality factor (1-100, default 95)
//   0x10: RESTART    [15:0]=restart interval in MCUs (0=disabled)
//   0x14: FRAME_SIZE (RO) byte count of last completed frame
// ============================================================================

module axi4_lite_regs #(
    parameter LITE_MODE = 0     // 1 = quality fixed at 95, writes ignored
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Lite Slave
    input  wire [4:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [4:0]  s_axi_araddr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // Control outputs
    output wire        ctrl_enable,
    output wire        ctrl_soft_reset,
    output wire [6:0]  ctrl_quality,
    output wire [15:0] ctrl_restart_interval,

    // Status inputs
    input  wire        sts_busy,
    input  wire        sts_frame_done_pulse,
    input  wire [31:0] sts_frame_cnt,
    input  wire [31:0] sts_frame_size
);

    // ========================================================================
    // Registers
    // ========================================================================
    reg [31:0] reg_ctrl;
    reg [31:0] reg_status;
    reg [31:0] reg_quality;
    reg [31:0] reg_restart;

    assign ctrl_enable           = reg_ctrl[0];
    assign ctrl_soft_reset       = reg_ctrl[1];
    assign ctrl_quality          = reg_quality[6:0];
    assign ctrl_restart_interval = reg_restart[15:0];

    // ========================================================================
    // Write channel
    // ========================================================================
    // AW and W are accepted independently (each captured at its own
    // handshake), the register is written once both are held, then B is
    // returned. A new AW/W is not accepted until B completes.
    /* verilator lint_off UNUSEDSIGNAL */
    reg [4:0]  wr_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [31:0] wr_data;
    reg [3:0]  wr_strb;
    reg        aw_received, w_received;

    assign s_axi_awready = !aw_received && !s_axi_bvalid;
    assign s_axi_wready  = !w_received  && !s_axi_bvalid;

    // Byte-lane merge honoring WSTRB
    wire [31:0] strb_mask = {{8{wr_strb[3]}}, {8{wr_strb[2]}},
                             {8{wr_strb[1]}}, {8{wr_strb[0]}}};
    function [31:0] merge;
        input [31:0] old_val;
        input [31:0] new_val;
        input [31:0] mask;
        begin
            merge = (old_val & ~mask) | (new_val & mask);
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_received   <= 1'b0;
            w_received    <= 1'b0;
            wr_addr       <= 5'd0;
            wr_data       <= 32'd0;
            wr_strb       <= 4'd0;
            reg_ctrl      <= 32'd0;
            reg_status    <= 32'd0;
            reg_quality   <= 32'd95;
            reg_restart   <= 32'd0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                wr_addr     <= s_axi_awaddr;
                aw_received <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wr_data    <= s_axi_wdata;
                wr_strb    <= s_axi_wstrb;
                w_received <= 1'b1;
            end

            // Update status from hardware
            reg_status[0] <= sts_busy;
            if (sts_frame_done_pulse)
                reg_status[1] <= 1'b1;

            // Perform the write once both address and data are held
            if (aw_received && w_received) begin
                case (wr_addr[4:2])
                    3'd0: reg_ctrl    <= merge(reg_ctrl, wr_data, strb_mask);
                    3'd1: begin
                        // W1C on frame_done; a same-cycle new frame_done wins
                        if (wr_data[1] && wr_strb[0] && !sts_frame_done_pulse)
                            reg_status[1] <= 1'b0;
                    end
                    3'd3: if (LITE_MODE == 0)
                              reg_quality <= merge(reg_quality, wr_data, strb_mask);
                    3'd4: reg_restart <= merge(reg_restart, wr_data, strb_mask);
                    default: ;
                endcase
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
                aw_received  <= 1'b0;
                w_received   <= 1'b0;
            end

            // Write response handshake
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end

    // ========================================================================
    // Read channel
    // ========================================================================
    // ARREADY is high while no response is outstanding; RVALID follows the
    // AR handshake by one cycle and is held until RREADY.
    assign s_axi_arready = !s_axi_rvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;
                case (s_axi_araddr[4:2])
                    3'd0: s_axi_rdata <= reg_ctrl;
                    3'd1: s_axi_rdata <= reg_status;
                    3'd2: s_axi_rdata <= sts_frame_cnt;
                    3'd3: s_axi_rdata <= reg_quality;
                    3'd4: s_axi_rdata <= reg_restart;
                    3'd5: s_axi_rdata <= sts_frame_size;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
