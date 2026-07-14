// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// ccm — 3x3 color-correction matrix
//
// Function
//   Maps sensor RGB to output RGB through a programmable 3x3 matrix in
//   S4.8 fixed point: out_i = clamp((sum_j m[i][j] * in_j + 128) >> 8) to
//   [0, 2^DATA_W - 1]. Coefficient 256 = 1.0; the S4.8 range (-16..+16)
//   covers any practical sensor matrix. Bit-exact contract:
//   verify/isp_model.py::ccm_px.
//
// Interface
//   Valid-only RGB stream with s_sof framing. The nine coefficients are
//   quasi-static CSR values, row-major m00..m22; firmware changes them
//   between frames.
//
// Contract
//   One pixel per clock, two cycles latency (multiply, then sum, round,
//   clamp), never stalls. Nine DATA_W x 13 signed multipliers — the ISP's
//   main multiplier cost; noted in the CAMERA-PLAN.md DSP budget.
//
// Position
//   RGB-domain ISP: debayer → [ccm] → gamma_lut → csc_422 → encoder
// -----------------------------------------------------------------------------

module ccm #(
    parameter DATA_W = 12
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire signed [12:0] m00, input wire signed [12:0] m01, input wire signed [12:0] m02,
    input  wire signed [12:0] m10, input wire signed [12:0] m11, input wire signed [12:0] m12,
    input  wire signed [12:0] m20, input wire signed [12:0] m21, input wire signed [12:0] m22,

    input  wire        s_valid,
    input  wire [DATA_W-1:0] s_r,
    input  wire [DATA_W-1:0] s_g,
    input  wire [DATA_W-1:0] s_b,
    input  wire        s_sof,

    output reg         m_valid,
    output reg  [DATA_W-1:0] m_r,
    output reg  [DATA_W-1:0] m_g,
    output reg  [DATA_W-1:0] m_b,
    output reg         m_sof
);

    // Products: unsigned DATA_W sample x signed S4.8 -> signed DATA_W+14.
    localparam PW = DATA_W + 14;

    function signed [PW-1:0] pmul;
        input [DATA_W-1:0] v;
        input signed [12:0] c;
        pmul = $signed({1'b0, v}) * c;
    endfunction

    reg               p1_valid, p1_sof;
    reg signed [PW-1:0] pr0, pr1, pr2, pg0, pg1, pg2, pb0, pb1, pb2;

    always @(posedge clk) begin
        if (!rst_n) begin
            p1_valid <= 1'b0;
            p1_sof   <= 1'b0;
        end else begin
            p1_valid <= s_valid;
            p1_sof   <= s_valid && s_sof;
            pr0 <= pmul(s_r, m00); pr1 <= pmul(s_g, m01); pr2 <= pmul(s_b, m02);
            pg0 <= pmul(s_r, m10); pg1 <= pmul(s_g, m11); pg2 <= pmul(s_b, m12);
            pb0 <= pmul(s_r, m20); pb1 <= pmul(s_g, m21); pb2 <= pmul(s_b, m22);
        end
    end

    // Round to nearest and clamp. Sums of three products plus the rounding
    // half stay inside PW+2 signed bits.
    function [DATA_W-1:0] rnd_clamp;
        input signed [PW+1:0] acc;
        reg signed [PW+1:0] r;
        begin
            r = acc >>> 8;
            rnd_clamp = (r < 0) ? {DATA_W{1'b0}} :
                        (r > $signed({{(PW+2-DATA_W){1'b0}}, {DATA_W{1'b1}}}))
                                ? {DATA_W{1'b1}} : r[DATA_W-1:0];
        end
    endfunction

    localparam signed [PW+1:0] HALF = 128;   // rounding half at Q8

    // Signed products widen by sign-extension into the sum width; the low
    // eight bits of each sum are the discarded Q8 fraction.
    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [PW+1:0] sum_r = pr0 + pr1 + pr2 + HALF;
    wire signed [PW+1:0] sum_g = pg0 + pg1 + pg2 + HALF;
    wire signed [PW+1:0] sum_b = pb0 + pb1 + pb2 + HALF;
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on WIDTHEXPAND */

    always @(posedge clk) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_sof   <= 1'b0;
        end else begin
            m_valid <= p1_valid;
            m_sof   <= p1_sof;
            m_r     <= rnd_clamp(sum_r);
            m_g     <= rnd_clamp(sum_g);
            m_b     <= rnd_clamp(sum_b);
        end
    end

endmodule
