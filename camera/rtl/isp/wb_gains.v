// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// wb_gains — Bayer-domain white-balance gains
//
// Function
//   Multiplies each RAW sample by a per-channel gain in U4.8 fixed point,
//   rounding to nearest and saturating: out = min((in * gain + 128) >> 8,
//   2^DATA_W - 1). Channel selection (R, Gr, Gb, B) is by pixel parity
//   against the frame's Bayer phase. Gain 256 = unity; the U4.8 range
//   covers gains up to ~16, far beyond photographic need. Bit-exact
//   contract: verify/isp_model.py::wb_px.
//
// Interface
//   Valid-only stream, raster order, s_sof framing; bayer_phase sampled at
//   s_sof. Gains are quasi-static CSR values; firmware changes them
//   between frames (the AWB loop's cadence).
//
// Contract
//   One sample per clock, two cycles latency (multiply, then round and
//   saturate), never stalls. One DATA_W x 12 multiplier.
//
// Position
//   RAW-domain ISP: blc → [wb_gains] → debayer → ccm → …
// -----------------------------------------------------------------------------

module wb_gains #(
    parameter DATA_W    = 12,
    parameter IMG_WIDTH = 1920
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  bayer_phase,          // {py, px}: color at (0,0)
    input  wire [11:0] gain_r,               // U4.8; 256 = 1.0
    input  wire [11:0] gain_gr,
    input  wire [11:0] gain_gb,
    input  wire [11:0] gain_b,

    input  wire        s_valid,
    input  wire [DATA_W-1:0] s_data,
    input  wire        s_sof,

    output reg         m_valid,
    output reg  [DATA_W-1:0] m_data,
    output reg         m_sof
);

    localparam XW = $clog2(IMG_WIDTH);

    reg [XW-1:0] x_cnt;
    reg          y_par;
    reg [1:0]    ph;

    wire sof_now  = s_valid && s_sof;
    wire line_end = (x_cnt == IMG_WIDTH - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            x_cnt <= {XW{1'b0}};
            y_par <= 1'b0;
            ph    <= 2'd0;
        end else if (s_valid) begin
            if (sof_now) begin
                x_cnt <= 1;
                y_par <= 1'b0;
                ph    <= bayer_phase;
            end else begin
                x_cnt <= line_end ? {XW{1'b0}} : x_cnt + 1'b1;
                if (line_end)
                    y_par <= ~y_par;
            end
        end
    end

    wire cur_py = sof_now ? bayer_phase[1] : (y_par ^ ph[1]);
    wire cur_px = sof_now ? bayer_phase[0] : (x_cnt[0] ^ ph[0]);

    wire [11:0] gain =
        (!cur_py && !cur_px) ? gain_r  :
        (!cur_py &&  cur_px) ? gain_gr :
        ( cur_py && !cur_px) ? gain_gb : gain_b;

    // Stage 1: multiply. DATA_W x 12 -> DATA_W+12 bits.
    reg                  p1_valid, p1_sof;
    reg [DATA_W+11:0]    p1_prod;

    always @(posedge clk) begin
        if (!rst_n) begin
            p1_valid <= 1'b0;
            p1_sof   <= 1'b0;
        end else begin
            p1_valid <= s_valid;
            p1_sof   <= sof_now;
            p1_prod  <= s_data * gain;
        end
    end

    // Stage 2: round to nearest, saturate to the sample range. The low
    // eight bits of the rounded product are the discarded Q8 fraction.
    localparam [DATA_W+11:0] HALF = 128;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [DATA_W+11:0] rounded = p1_prod + HALF;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [DATA_W+3:0]  shifted = rounded[DATA_W+11:8];

    always @(posedge clk) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_sof   <= 1'b0;
        end else begin
            m_valid <= p1_valid;
            m_sof   <= p1_sof;
            m_data  <= (shifted > {4'd0, {DATA_W{1'b1}}})
                       ? {DATA_W{1'b1}} : shifted[DATA_W-1:0];
        end
    end

endmodule
