// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// blc — Bayer-domain black-level correction with shadow footroom
//
// Function
//   Subtracts a per-channel black offset and adds the pedestal, clamping
//   to the sample range: out = clamp(in - black[channel] + pedestal).
//   Downstream RAW/RGB stages carry values in this pedestal-offset domain
//   until the CCM removes it, so sensor noise below the black level
//   survives the debayer's spatial averaging instead of being rectified
//   upward — with pedestal 0 the pipeline is bit-identical to a plain
//   floor-at-zero correction. The channel (R, Gr, Gb, B) is the pixel's
//   Bayer position, from column/row parity and the frame's Bayer phase.
//   Bit-exact contract: verify/isp_model.py::blc_px.
//
// Interface
//   Valid-only stream, raster order, s_sof on each frame's first sample;
//   bayer_phase {py, px} sampled at s_sof. The black offsets are
//   quasi-static CSR values, applied as sampled each cycle; firmware
//   changes them between frames.
//
// Contract
//   One sample per clock, one cycle latency, never stalls.
//
// Position
//   RAW-domain ISP: csi_rx/raw_unpack → [blc] → wb_gains → debayer → …
// -----------------------------------------------------------------------------

module blc #(
    parameter DATA_W    = 12,
    parameter IMG_WIDTH = 1920
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  bayer_phase,          // {py, px}: color at (0,0)
    input  wire [DATA_W-1:0] black_r,
    input  wire [DATA_W-1:0] black_gr,
    input  wire [DATA_W-1:0] black_gb,
    input  wire [DATA_W-1:0] black_b,
    input  wire [7:0]  pedestal,

    input  wire        s_valid,
    input  wire [DATA_W-1:0] s_data,
    input  wire        s_sof,

    output reg         m_valid,
    output reg  [DATA_W-1:0] m_data,
    output reg         m_sof
);

    localparam XW = $clog2(IMG_WIDTH);

    // Pixel parity tracking: x wraps per line, y toggles at each wrap.
    reg [XW-1:0] x_cnt;
    reg          y_par;

    wire sof_now  = s_valid && s_sof;
    wire line_end = (x_cnt == IMG_WIDTH - 1);

    reg [1:0] ph;

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

    wire       cur_py = sof_now ? bayer_phase[1] : (y_par ^ ph[1]);
    wire       cur_px = sof_now ? bayer_phase[0] : (x_cnt[0] ^ ph[0]);

    wire [DATA_W-1:0] black =
        (!cur_py && !cur_px) ? black_r  :
        (!cur_py &&  cur_px) ? black_gr :
        ( cur_py && !cur_px) ? black_gb : black_b;

    // in - black + pedestal, signed, then clamped to the sample range.
    // Implicit widening of the signed operands is sign-extension: lossless.
    /* verilator lint_off WIDTHEXPAND */
    wire signed [DATA_W+1:0] corrected =
        $signed({2'b00, s_data}) - $signed({2'b00, black})
        + $signed({{(DATA_W-6){1'b0}}, pedestal});
    /* verilator lint_on WIDTHEXPAND */

    always @(posedge clk) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_sof   <= 1'b0;
        end else begin
            m_valid <= s_valid;
            m_sof   <= sof_now;
            m_data  <= (corrected < 0) ? {DATA_W{1'b0}} :
                       (corrected > $signed({2'b00, {DATA_W{1'b1}}}))
                           ? {DATA_W{1'b1}} : corrected[DATA_W-1:0];
        end
    end

endmodule
