// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// csc_422 — RGB to YCbCr conversion with filtered 4:2:2 chroma
//
// Function
//   Converts 8-bit R'G'B' to full-range BT.601 YCbCr in Q16 fixed point
//   (coefficients x65536, +32768 rounding, arithmetic shift, +128 chroma
//   offset, clamp to 0..255), then resamples chroma 4:4:4 -> 4:2:2 with a
//   [1,3,3,1]/8 low-pass whose taps span 2k-1..2k+2 — symmetric about each
//   pixel pair's midpoint, the JFIF chroma siting — with mirror reflection
//   at line edges (index -1 -> 1, IMG_WIDTH -> IMG_WIDTH-2). Output words
//   are the encoder's YUYV form: {chroma[15:8], Y[7:0]}, Cb on even
//   pixels, Cr on odd. Bit-exact contract:
//   verify/isp_rgb_model.py::csc_422_frame.
//
// Interface
//   Valid-only RGB stream in, raster order, s_sof framing; IMG_WIDTH must
//   be even (the encoder requires a multiple of 16). Valid-only YUYV16
//   stream out, one word per input pixel, m_sof on each frame's first.
//
// Contract
//   Sustains one pixel per clock. Words emerge through a four-entry queue:
//   pairs complete on the arrival of pixel 2k+2 (the filter's last tap),
//   and each line's final pair completes at its last pixel using the
//   mirrored tap, so the queue briefly holds four words at a line
//   boundary — the source must idle at least 2 cycles between lines, which
//   any blanked sensor source does.
//
// Position
//   RGB-domain ISP: gamma_lut → [csc_422] → encoder video input
// -----------------------------------------------------------------------------

module csc_422 #(
    parameter IMG_WIDTH = 1920
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        s_valid,
    input  wire [7:0]  s_r,
    input  wire [7:0]  s_g,
    input  wire [7:0]  s_b,
    input  wire        s_sof,

    output reg         m_valid,
    output reg  [15:0] m_data,
    output reg         m_sof
);

    localparam XW = $clog2(IMG_WIDTH);

    // ========================================================================
    // Stage 1: coefficient products (Q16), rounding half included. Signed
    // products widen by sign-extension into the sum width — lossless.
    // ========================================================================
    /* verilator lint_off WIDTHEXPAND */
    reg               p1_valid, p1_sof;
    reg signed [25:0] p1_y, p1_cb, p1_cr;

    always @(posedge clk) begin
        if (!rst_n) begin
            p1_valid <= 1'b0;
            p1_sof   <= 1'b0;
        end else begin
            p1_valid <= s_valid;
            p1_sof   <= s_valid && s_sof;
            p1_y  <= $signed({1'b0, 17'd19595}) * $signed({1'b0, s_r}) +
                     $signed({1'b0, 17'd38470}) * $signed({1'b0, s_g}) +
                     $signed({1'b0, 17'd7471})  * $signed({1'b0, s_b}) +
                     $signed(26'd32768);
            p1_cb <= -$signed({1'b0, 17'd11056}) * $signed({1'b0, s_r}) +
                     -$signed({1'b0, 17'd21712}) * $signed({1'b0, s_g}) +
                      $signed({1'b0, 17'd32768}) * $signed({1'b0, s_b}) +
                      $signed(26'd32768);
            p1_cr <=  $signed({1'b0, 17'd32768}) * $signed({1'b0, s_r}) +
                     -$signed({1'b0, 17'd27440}) * $signed({1'b0, s_g}) +
                     -$signed({1'b0, 17'd5328})  * $signed({1'b0, s_b}) +
                      $signed(26'd32768);
        end
    end

    /* verilator lint_on WIDTHEXPAND */

    // ========================================================================
    // Stage 2: shift, offset, clamp to 8 bits; per-line pixel position.
    // ========================================================================
    function [7:0] clamp8;
        input signed [9:0] v;
        clamp8 = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
    endfunction

    // Bits [15:0] of each raw sum are the discarded Q16 fraction.
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [25:0] w_y  = p1_y;
    wire signed [25:0] w_cb = p1_cb;
    wire signed [25:0] w_cr = p1_cr;
    /* verilator lint_on UNUSEDSIGNAL */

    reg              p2_valid, p2_sof;
    reg [7:0]        p2_y8, p2_cb8, p2_cr8;
    reg [XW-1:0]     p2_x;
    reg [XW-1:0]     x_cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            p2_valid <= 1'b0;
            p2_sof   <= 1'b0;
            x_cnt    <= {XW{1'b0}};
        end else begin
            p2_valid <= p1_valid;
            p2_sof   <= p1_sof;
            p2_y8    <= clamp8(w_y[25:16]);
            p2_cb8   <= clamp8(w_cb[25:16] + 10'sd128);
            p2_cr8   <= clamp8(w_cr[25:16] + 10'sd128);
            if (p1_valid) begin
                p2_x  <= p1_sof ? {XW{1'b0}} : x_cnt;
                x_cnt <= p1_sof ? {{XW-1{1'b0}}, 1'b1} :
                         (x_cnt == IMG_WIDTH - 1) ? {XW{1'b0}} : x_cnt + 1'b1;
            end
        end
    end

    // ========================================================================
    // 4:2:2 assembler: chroma history across the pair, [1,3,3,1]/8 with
    // mirrored edge taps, two words queued per completed pair.
    // ========================================================================
    reg [7:0] cb_m1, cb_0, cb_1, cr_m1, cr_0, cr_1;
    reg [7:0] y_0, y_1;
    reg       first_pair;              // pair k = 0: left tap mirrors to 2k+1
    reg       sof_pend;

    // Filter: (a + 3b + 3c + d + 4) >> 3. The low three accumulator bits
    // are the discarded /8 fraction.
    function [7:0] chroma_filt;
        input [7:0] a, b, c, d;
        /* verilator lint_off UNUSEDSIGNAL */
        reg [10:0] acc;
        /* verilator lint_on UNUSEDSIGNAL */
        begin
            acc = {3'd0, a} + {3'd0, d}
                + ({3'd0, b} << 1) + {3'd0, b}
                + ({3'd0, c} << 1) + {3'd0, c} + 11'd4;
            chroma_filt = acc[10:3];
        end
    endfunction

    wire pair_interior = p2_valid && (p2_x[0] == 1'b0) && (p2_x != 0);
    wire pair_last     = p2_valid && (p2_x == IMG_WIDTH - 1);

    wire [7:0] tapA_cb = first_pair ? cb_1 : cb_m1;
    wire [7:0] tapA_cr = first_pair ? cr_1 : cr_m1;

    // Interior pair: last tap is the arriving even pixel. Final pair: last
    // tap mirrors (index W -> W-2 = the pair's own even pixel).
    wire [7:0] w0_cb = pair_last
        ? chroma_filt(tapA_cb, cb_0, p2_cb8, cb_0)
        : chroma_filt(tapA_cb, cb_0, cb_1, p2_cb8);
    wire [7:0] w0_cr = pair_last
        ? chroma_filt(tapA_cr, cr_0, p2_cr8, cr_0)
        : chroma_filt(tapA_cr, cr_0, cr_1, p2_cr8);
    wire [7:0] w1_y = pair_last ? p2_y8 : y_1;

    // Word queue: up to 4 pending (two pairs collide only at a line end).
    reg [15:0] q [0:3];
    reg [2:0]  q_cnt;
    reg        q_sof [0:3];
    integer qi;

    wire push2 = pair_interior || pair_last;
    wire [2:0] tail = q_cnt - {2'd0, (q_cnt != 3'd0)};

    always @(posedge clk) begin
        if (!rst_n) begin
            q_cnt      <= 3'd0;
            m_valid    <= 1'b0;
            m_sof      <= 1'b0;
            first_pair <= 1'b0;
            sof_pend   <= 1'b0;
        end else begin
            // chroma/luma history
            if (p2_valid) begin
                if (p2_sof)
                    sof_pend <= 1'b1;
                if (p2_x == 0) begin
                    cb_0 <= p2_cb8; cr_0 <= p2_cr8; y_0 <= p2_y8;
                    first_pair <= 1'b1;
                end else if (p2_x[0]) begin
                    cb_1 <= p2_cb8; cr_1 <= p2_cr8; y_1 <= p2_y8;
                end else begin
                    cb_m1 <= cb_1; cr_m1 <= cr_1;
                    cb_0  <= p2_cb8; cr_0 <= p2_cr8; y_0 <= p2_y8;
                    first_pair <= 1'b0;
                end
            end

            // emit one word per cycle from the queue; enqueue completed pairs
            if (q_cnt != 0) begin
                m_valid <= 1'b1;
                m_data  <= q[0];
                m_sof   <= q_sof[0];
                for (qi = 0; qi < 3; qi = qi + 1) begin
                    q[qi]     <= q[qi+1];
                    q_sof[qi] <= q_sof[qi+1];
                end
            end else begin
                m_valid <= 1'b0;
                m_sof   <= 1'b0;
            end

            // Tail position after this cycle's emission; pushes land there
            // (these assignments follow the shift, so they win overlaps).
            if (push2) begin
                q[tail[1:0]]       <= {w0_cb, y_0};
                q_sof[tail[1:0]]   <= sof_pend;
                q[tail[1:0]+2'd1]     <= {w0_cr, w1_y};
                q_sof[tail[1:0]+2'd1] <= 1'b0;
                q_cnt <= tail + 3'd2;
                if (sof_pend)
                    sof_pend <= 1'b0;
            end else if (q_cnt != 0) begin
                q_cnt <= q_cnt - 3'd1;
            end
        end
    end

endmodule
