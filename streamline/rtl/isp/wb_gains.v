// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// wb_gains — Bayer-domain white-balance gains
//
// Function
//   Multiplies each RAW sample by a per-channel gain in U4.8 fixed point,
//   applied around the shadow pedestal so the pedestal itself is not
//   scaled: out = clamp((((in - pedestal) * gain + 128) >>> 8) + pedestal).
//   The product is signed — samples below the pedestal (noise under the
//   black level) are scaled correctly instead of being rectified. Channel
//   selection (R, Gr, Gb, B) is by pixel parity against the frame's Bayer
//   phase. Gain 256 = unity. Bit-exact contract:
//   verify/isp_model.py::wb_px.
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
    input  wire [7:0]  pedestal,

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

    // Stage 1: signed multiply of (sample - pedestal) by the gain.
    wire signed [DATA_W:0] centered =
        $signed({1'b0, s_data})
        - $signed({{(DATA_W-7){1'b0}}, pedestal});

    reg                       p1_valid, p1_sof;
    reg signed [DATA_W+13:0]  p1_prod;

    always @(posedge clk) begin
        if (!rst_n) begin
            p1_valid <= 1'b0;
            p1_sof   <= 1'b0;
        end else begin
            p1_valid <= s_valid;
            p1_sof   <= sof_now;
            p1_prod  <= centered * $signed({1'b0, gain});
        end
    end

    // Stage 2: round (arithmetic shift floors, matching the model),
    // restore the pedestal, saturate. The low eight bits are the
    // discarded Q8 fraction.
    localparam signed [DATA_W+13:0] HALF = 128;
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [DATA_W+13:0] rounded = p1_prod + HALF;
    /* verilator lint_on UNUSEDSIGNAL */
    wire signed [DATA_W+5:0]  shifted =
        $signed(rounded[DATA_W+13:8])
        + $signed({{(DATA_W-2){1'b0}}, pedestal});

    always @(posedge clk) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_sof   <= 1'b0;
        end else begin
            m_valid <= p1_valid;
            m_sof   <= p1_sof;
            m_data  <= (shifted < 0) ? {DATA_W{1'b0}} :
                       (shifted > $signed({6'd0, {DATA_W{1'b1}}}))
                           ? {DATA_W{1'b1}} : shifted[DATA_W-1:0];
        end
    end

endmodule
