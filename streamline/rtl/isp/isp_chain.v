// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// isp_chain — the assembled ISP: Bayer RAW in, encoder-ready YUYV out
//
// Function
//   Composes the six ISP stages in processing order:
//     blc → wb_gains → debayer → ccm → gamma_lut → csc_422
//   Black-level correction adds the shadow pedestal, white balance scales
//   around it, the MHC demosaic reconstructs RGB (the pedestal rides
//   through its unity-DC kernels), the color matrix removes the pedestal,
//   the tone LUT maps to 8-bit display values, and the color-space
//   converter emits filtered 4:2:2 YUYV words in the encoder's format.
//
// Interface
//   Valid-only streams throughout; every control input (Bayer phase,
//   blacks, pedestal, gains, matrix, LUT write port) is a quasi-static CSR
//   forwarded to its stage. Input framing: one Bayer sample per clock,
//   raster order, s_sof on each frame's first sample, with the debayer's
//   line/frame spacing requirements (its header states them; any blanked
//   sensor source meets them).
//
// Contract
//   One pixel per clock end to end; total latency two lines plus the six
//   stages' small pipelines. Output words are bit-exact to the composed
//   golden models (verify/isp_model.py, debayer_model.py,
//   isp_rgb_model.py applied in the same order).
//
// Position
//   Camera datapath: csi_rx/raw_unpack → [isp_chain] → mjpegzero encoder.
// -----------------------------------------------------------------------------

module isp_chain #(
    parameter DATA_W     = 12,
    parameter IMG_WIDTH  = 1920,
    parameter IMG_HEIGHT = 1080
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  bayer_phase,
    input  wire [DATA_W-1:0] black_r,
    input  wire [DATA_W-1:0] black_gr,
    input  wire [DATA_W-1:0] black_gb,
    input  wire [DATA_W-1:0] black_b,
    input  wire [7:0]  pedestal,
    input  wire [11:0] gain_r,
    input  wire [11:0] gain_gr,
    input  wire [11:0] gain_gb,
    input  wire [11:0] gain_b,
    input  wire signed [12:0] m00, input wire signed [12:0] m01, input wire signed [12:0] m02,
    input  wire signed [12:0] m10, input wire signed [12:0] m11, input wire signed [12:0] m12,
    input  wire signed [12:0] m20, input wire signed [12:0] m21, input wire signed [12:0] m22,
    input  wire        lut_we,
    input  wire [DATA_W-1:0] lut_addr,
    input  wire [7:0]  lut_wdata,

    input  wire        s_valid,
    input  wire [DATA_W-1:0] s_data,
    input  wire        s_sof,

    output wire        m_valid,
    output wire [15:0] m_data,
    output wire        m_sof
);

    wire              blc_v, blc_f;
    wire [DATA_W-1:0] blc_d;

    blc #(.DATA_W(DATA_W), .IMG_WIDTH(IMG_WIDTH)) u_blc (
        .clk(clk), .rst_n(rst_n),
        .bayer_phase(bayer_phase),
        .black_r(black_r), .black_gr(black_gr),
        .black_gb(black_gb), .black_b(black_b),
        .pedestal(pedestal),
        .s_valid(s_valid), .s_data(s_data), .s_sof(s_sof),
        .m_valid(blc_v), .m_data(blc_d), .m_sof(blc_f)
    );

    wire              wb_v, wb_f;
    wire [DATA_W-1:0] wb_d;

    wb_gains #(.DATA_W(DATA_W), .IMG_WIDTH(IMG_WIDTH)) u_wb (
        .clk(clk), .rst_n(rst_n),
        .bayer_phase(bayer_phase),
        .gain_r(gain_r), .gain_gr(gain_gr),
        .gain_gb(gain_gb), .gain_b(gain_b),
        .pedestal(pedestal),
        .s_valid(blc_v), .s_data(blc_d), .s_sof(blc_f),
        .m_valid(wb_v), .m_data(wb_d), .m_sof(wb_f)
    );

    wire              db_v, db_f;
    wire [DATA_W-1:0] db_r, db_g, db_b;

    debayer #(.DATA_W(DATA_W), .IMG_WIDTH(IMG_WIDTH),
              .IMG_HEIGHT(IMG_HEIGHT)) u_debayer (
        .clk(clk), .rst_n(rst_n),
        .bayer_phase(bayer_phase),
        .s_valid(wb_v), .s_data(wb_d), .s_sof(wb_f),
        .m_valid(db_v), .m_r(db_r), .m_g(db_g), .m_b(db_b), .m_sof(db_f)
    );

    wire              ccm_v, ccm_f;
    wire [DATA_W-1:0] ccm_r, ccm_g, ccm_b;

    ccm #(.DATA_W(DATA_W)) u_ccm (
        .clk(clk), .rst_n(rst_n),
        .m00(m00), .m01(m01), .m02(m02),
        .m10(m10), .m11(m11), .m12(m12),
        .m20(m20), .m21(m21), .m22(m22),
        .pedestal(pedestal),
        .s_valid(db_v), .s_r(db_r), .s_g(db_g), .s_b(db_b), .s_sof(db_f),
        .m_valid(ccm_v), .m_r(ccm_r), .m_g(ccm_g), .m_b(ccm_b), .m_sof(ccm_f)
    );

    wire       gm_v, gm_f;
    wire [7:0] gm_r, gm_g, gm_b;

    gamma_lut #(.DATA_W(DATA_W)) u_gamma (
        .clk(clk), .rst_n(rst_n),
        .lut_we(lut_we), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
        .s_valid(ccm_v), .s_r(ccm_r), .s_g(ccm_g), .s_b(ccm_b), .s_sof(ccm_f),
        .m_valid(gm_v), .m_r(gm_r), .m_g(gm_g), .m_b(gm_b), .m_sof(gm_f)
    );

    csc_422 #(.IMG_WIDTH(IMG_WIDTH)) u_csc (
        .clk(clk), .rst_n(rst_n),
        .s_valid(gm_v), .s_r(gm_r), .s_g(gm_g), .s_b(gm_b), .s_sof(gm_f),
        .m_valid(m_valid), .m_data(m_data), .m_sof(m_sof)
    );

endmodule
