// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// gamma_lut — programmable tone curve and bit-depth conversion
//
// Function
//   Maps each linear DATA_W-bit channel through a lookup table to 8-bit
//   display-referred values: one curve, applied identically to R, G, B via
//   three copies of the table so all three channels convert in the same
//   cycle. Power-up contents are the identity truncation
//   (v >> (DATA_W - 8)); firmware loads the product curve (sRGB or tuned)
//   through the write port. Contract: verify/isp_rgb_model.py::gamma_px.
//
// Interface
//   Valid-only RGB stream with s_sof framing. Write port: one entry per
//   cycle when lut_we is high (all three copies take the write). Writing
//   during active video affects in-flight pixels of that frame; firmware
//   loads curves in vertical blanking.
//
// Contract
//   One pixel per clock, one cycle latency, never stalls. Three
//   2^DATA_W x 8 memories.
//
// Position
//   RGB-domain ISP: ccm → [gamma_lut] → csc_422 → encoder
// -----------------------------------------------------------------------------

module gamma_lut #(
    parameter DATA_W = 12
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        lut_we,
    input  wire [DATA_W-1:0] lut_addr,
    input  wire [7:0]  lut_wdata,

    input  wire        s_valid,
    input  wire [DATA_W-1:0] s_r,
    input  wire [DATA_W-1:0] s_g,
    input  wire [DATA_W-1:0] s_b,
    input  wire        s_sof,

    output reg         m_valid,
    output reg  [7:0]  m_r,
    output reg  [7:0]  m_g,
    output reg  [7:0]  m_b,
    output reg         m_sof
);

    reg [7:0] lut_r [0:(1<<DATA_W)-1];
    reg [7:0] lut_g [0:(1<<DATA_W)-1];
    reg [7:0] lut_b [0:(1<<DATA_W)-1];

    // Power-up identity: straight truncation to 8 bits.
    integer k;
    initial begin
        for (k = 0; k < (1 << DATA_W); k = k + 1) begin
            lut_r[k] = k[DATA_W-1:DATA_W-8];
            lut_g[k] = k[DATA_W-1:DATA_W-8];
            lut_b[k] = k[DATA_W-1:DATA_W-8];
        end
    end

    always @(posedge clk) begin
        if (lut_we) begin
            lut_r[lut_addr] <= lut_wdata;
            lut_g[lut_addr] <= lut_wdata;
            lut_b[lut_addr] <= lut_wdata;
        end
        m_r <= lut_r[s_r];
        m_g <= lut_g[s_g];
        m_b <= lut_b[s_b];
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_sof   <= 1'b0;
        end else begin
            m_valid <= s_valid;
            m_sof   <= s_valid && s_sof;
        end
    end

endmodule
