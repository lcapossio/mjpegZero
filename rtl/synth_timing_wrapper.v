// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// Synthesis Timing Wrapper
// ============================================================================
// Wraps the mjpegZero core with registered inputs and outputs for
// accurate timing analysis. Only the internal timing of the core matters.
// ============================================================================

module synth_timing_wrapper #(
    parameter LITE_MODE    = 1,
    parameter LITE_QUALITY = 95,
    parameter IMG_WIDTH    = LITE_MODE ? 1280 : 1920,
    parameter IMG_HEIGHT   = LITE_MODE ? 720  : 1080
) (
    input  wire        clk,
    input  wire        rst_n,

    // Video input (registered)
    input  wire [15:0] vid_tdata,
    input  wire        vid_tvalid,
    output wire        vid_tready,
    input  wire        vid_tlast,
    input  wire        vid_tuser,

    // JPEG output (registered, no backpressure)
    output wire        jpg_tvalid,
    output wire [7:0]  jpg_tdata,
    output wire        jpg_tlast,

    // AXI-Lite (registered)
    input  wire [4:0]  axi_awaddr,
    input  wire        axi_awvalid,
    output wire        axi_awready,
    input  wire [31:0] axi_wdata,
    input  wire [3:0]  axi_wstrb,
    input  wire        axi_wvalid,
    output wire        axi_wready,
    output wire [1:0]  axi_bresp,
    output wire        axi_bvalid,
    input  wire        axi_bready,
    input  wire [4:0]  axi_araddr,
    input  wire        axi_arvalid,
    output wire        axi_arready,
    output wire [31:0] axi_rdata,
    output wire [1:0]  axi_rresp,
    output wire        axi_rvalid,
    input  wire        axi_rready
);

    // ========================================================================
    // Input registers
    // ========================================================================
    reg [15:0] vid_tdata_r;
    reg        vid_tvalid_r;
    reg        vid_tlast_r;
    reg        vid_tuser_r;

    reg [4:0]  axi_awaddr_r;
    reg        axi_awvalid_r;
    reg [31:0] axi_wdata_r;
    reg [3:0]  axi_wstrb_r;
    reg        axi_wvalid_r;
    reg        axi_bready_r;
    reg [4:0]  axi_araddr_r;
    reg        axi_arvalid_r;
    reg        axi_rready_r;

    always @(posedge clk) begin
        vid_tdata_r   <= vid_tdata;
        vid_tvalid_r  <= vid_tvalid;
        vid_tlast_r   <= vid_tlast;
        vid_tuser_r   <= vid_tuser;

        axi_awaddr_r  <= axi_awaddr;
        axi_awvalid_r <= axi_awvalid;
        axi_wdata_r   <= axi_wdata;
        axi_wstrb_r   <= axi_wstrb;
        axi_wvalid_r  <= axi_wvalid;
        axi_bready_r  <= axi_bready;
        axi_araddr_r  <= axi_araddr;
        axi_arvalid_r <= axi_arvalid;
        axi_rready_r  <= axi_rready;
    end

    // ========================================================================
    // Core output wires
    // ========================================================================
    wire        vid_tready_w;
    wire        jpg_tvalid_w;
    wire [7:0]  jpg_tdata_w;
    wire        jpg_tlast_w;
    wire        axi_awready_w;
    wire        axi_wready_w;
    wire [1:0]  axi_bresp_w;
    wire        axi_bvalid_w;
    wire        axi_arready_w;
    wire [31:0] axi_rdata_w;
    wire [1:0]  axi_rresp_w;
    wire        axi_rvalid_w;

    // ========================================================================
    // Output registers
    // ========================================================================
    reg        vid_tready_rr;
    reg        jpg_tvalid_rr;
    reg [7:0]  jpg_tdata_rr;
    reg        jpg_tlast_rr;
    reg        axi_awready_rr;
    reg        axi_wready_rr;
    reg [1:0]  axi_bresp_rr;
    reg        axi_bvalid_rr;
    reg        axi_arready_rr;
    reg [31:0] axi_rdata_rr;
    reg [1:0]  axi_rresp_rr;
    reg        axi_rvalid_rr;

    always @(posedge clk) begin
        vid_tready_rr  <= vid_tready_w;
        jpg_tvalid_rr  <= jpg_tvalid_w;
        jpg_tdata_rr   <= jpg_tdata_w;
        jpg_tlast_rr   <= jpg_tlast_w;
        axi_awready_rr <= axi_awready_w;
        axi_wready_rr  <= axi_wready_w;
        axi_bresp_rr   <= axi_bresp_w;
        axi_bvalid_rr  <= axi_bvalid_w;
        axi_arready_rr <= axi_arready_w;
        axi_rdata_rr   <= axi_rdata_w;
        axi_rresp_rr   <= axi_rresp_w;
        axi_rvalid_rr  <= axi_rvalid_w;
    end

    assign vid_tready  = vid_tready_rr;
    assign jpg_tvalid  = jpg_tvalid_rr;
    assign jpg_tdata   = jpg_tdata_rr;
    assign jpg_tlast   = jpg_tlast_rr;
    assign axi_awready = axi_awready_rr;
    assign axi_wready  = axi_wready_rr;
    assign axi_bresp   = axi_bresp_rr;
    assign axi_bvalid  = axi_bvalid_rr;
    assign axi_arready = axi_arready_rr;
    assign axi_rdata   = axi_rdata_rr;
    assign axi_rresp   = axi_rresp_rr;
    assign axi_rvalid  = axi_rvalid_rr;

    // ========================================================================
    // DUT
    // ========================================================================
    mjpegzero_enc_top #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .LITE_MODE    (LITE_MODE),
        .LITE_QUALITY (LITE_QUALITY)
    ) u_dut (
        .clk               (clk),
        .rst_n             (rst_n),

        .s_axis_vid_tdata  (vid_tdata_r),
        .s_axis_vid_tvalid (vid_tvalid_r),
        .s_axis_vid_tready (vid_tready_w),
        .s_axis_vid_tlast  (vid_tlast_r),
        .s_axis_vid_tuser  (vid_tuser_r),

        .m_axis_jpg_tvalid (jpg_tvalid_w),
        .m_axis_jpg_tdata  (jpg_tdata_w),
        .m_axis_jpg_tlast  (jpg_tlast_w),

        .s_axi_awaddr      (axi_awaddr_r),
        .s_axi_awvalid     (axi_awvalid_r),
        .s_axi_awready     (axi_awready_w),
        .s_axi_wdata       (axi_wdata_r),
        .s_axi_wstrb       (axi_wstrb_r),
        .s_axi_wvalid      (axi_wvalid_r),
        .s_axi_wready      (axi_wready_w),
        .s_axi_bresp       (axi_bresp_w),
        .s_axi_bvalid      (axi_bvalid_w),
        .s_axi_bready      (axi_bready_r),
        .s_axi_araddr      (axi_araddr_r),
        .s_axi_arvalid     (axi_arvalid_r),
        .s_axi_arready     (axi_arready_w),
        .s_axi_rdata       (axi_rdata_w),
        .s_axi_rresp       (axi_rresp_w),
        .s_axi_rvalid      (axi_rvalid_w),
        .s_axi_rready      (axi_rready_r)
    );

endmodule
