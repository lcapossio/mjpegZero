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
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [3:0]  s_axi_wstrb,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [4:0]  s_axi_araddr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
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
    /* verilator lint_off UNUSEDSIGNAL */
    reg [4:0]  wr_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    reg        aw_received, w_received;

    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_received   <= 1'b0;
            w_received    <= 1'b0;
            reg_ctrl      <= 32'd0;
            reg_status    <= 32'd0;
            reg_quality   <= 32'd95;
            reg_restart   <= 32'd0;
        end else begin
            // Accept write address
            if (s_axi_awvalid && !aw_received && !s_axi_bvalid) begin
                s_axi_awready <= 1'b1;
                wr_addr <= s_axi_awaddr;
                aw_received <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            // Accept write data
            if (s_axi_wvalid && !w_received && !s_axi_bvalid) begin
                s_axi_wready <= 1'b1;
                w_received <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end

            // Perform write when both address and data received
            if (aw_received && w_received) begin
                case (wr_addr[4:2])
                    3'd0: reg_ctrl    <= s_axi_wdata;
                    3'd1: reg_status  <= reg_status & ~s_axi_wdata;
                    3'd3: if (LITE_MODE == 0) reg_quality <= s_axi_wdata;
                    3'd4: reg_restart <= s_axi_wdata;
                    default: ;
                endcase
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= 2'b00;
                aw_received <= 1'b0;
                w_received <= 1'b0;
            end

            // Write response handshake
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            // Update status from hardware
            reg_status[0] <= sts_busy;
            if (sts_frame_done_pulse)
                reg_status[1] <= 1'b1;
        end
    end

    // ========================================================================
    // Read channel
    // ========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
        end else begin
            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
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
            end else begin
                s_axi_arready <= 1'b0;
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

endmodule
