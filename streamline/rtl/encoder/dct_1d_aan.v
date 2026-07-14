// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// dct_1d (AAN) — 8-point scaled forward DCT, one time-shared multiplier
//
// Function
//   Computes the Arai-Agui-Nakajima scaled 8-point forward DCT: each output
//   equals the orthonormal DCT coefficient multiplied by a fixed
//   per-coefficient gain (2.8284, 3.9230, 3.6959, 3.3256, 2.8284, 2.2218,
//   1.5311, 0.7809 for k = 0..7). The paired quantizer removes the gains by
//   folding them into its reciprocal tables, so the transform needs only
//   five constant multiplications: products are kept at full Q13 precision
//   through the additions and each output is rounded exactly once, to
//   GUARD fraction bits (the row pass keeps one: its rounding error then
//   costs half an output LSB, which matters at the positions whose AAN
//   gain is below one). Bit-exact contract:
//   streamline/verify/dct_aan_model.py::aan1d_int(x, guard=GUARD).
//
// Interface
//   Same stream contract as the orthonormal dct_1d: one sample per clock
//   in (IN_W-bit signed), rows of 8, back-to-back or gapped; one
//   coefficient per clock out, out_last on each row's final coefficient.
//   First coefficient emerges 6 clocks after a row's last sample.
//
// Contract
//   This module and quantizer_aan form a matched set (with dct_2d_aan
//   between them): its outputs are scaled, not orthonormal. The 16-bit
//   output is lossless for the encoder's input domain (|x| <= 255 gives
//   |X| <= 8*255*3.93 < 2^13 after both passes' gains at this stage's
//   input widths); the IN_W parameter sizes the second-pass instance for
//   the 16-bit inter-pass values.
// -----------------------------------------------------------------------------

// The module keeps the canonical name so the encoder top instantiates it
// unchanged; the _aan filename distinguishes the matched-set variant.
/* verilator lint_off DECLFILENAME */
module dct_1d #(
    parameter IN_W  = 12,
    parameter GUARD = 0   // fraction bits kept in the outputs (0 or 1):
                          // outputs are scaled by a further 2^GUARD, folded
                          // out by the paired quantizer's tables
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    input  wire signed [IN_W-1:0] in_data,
    // Row boundaries are tracked by the internal sample counter; the port
    // exists for interface compatibility.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        in_last,
    /* verilator lint_on UNUSEDSIGNAL */

    output reg         out_valid,
    output reg  signed [15:0] out_data,
    output reg         out_last
);

    localparam Q = 13;
    // AAN constants in Q13; C_A4 exceeds 1.0, so the constants carry
    // 15 signed bits.
    localparam signed [14:0] C_A1 = 15'sd5793;   // sqrt(2)/2
    localparam signed [14:0] C_A2 = 15'sd4433;   // 0.541196100
    localparam signed [14:0] C_A3 = 15'sd5793;   // sqrt(2)/2
    localparam signed [14:0] C_A4 = 15'sd10703;  // 1.306562965
    localparam signed [14:0] C_A5 = 15'sd3135;   // 0.382683433

    // Widths: butterflies grow 3 bits over IN_W; multiplier operands one
    // more; Q13 accumulators carry 13 fraction bits above that.
    localparam BW_ = IN_W + 3;            // butterfly terms
    localparam MW  = BW_ + 15;            // product: (BW_) x 15-bit constant
    localparam AW  = MW + 3;              // sums of up to four Q13 terms

    // ========================================================================
    // Sample gather
    // ========================================================================
    reg signed [IN_W-1:0] x [0:7];
    reg [2:0] in_cnt;
    reg       row_start;

    always @(posedge clk) begin
        if (!rst_n) begin
            in_cnt    <= 3'd0;
            row_start <= 1'b0;
        end else begin
            row_start <= 1'b0;
            if (in_valid) begin
                x[in_cnt] <= in_data;
                in_cnt    <= in_cnt + 3'd1;
                row_start <= (in_cnt == 3'd7);
            end
        end
    end

    // ========================================================================
    // Butterflies, registered in the row_start cycle (reads the pre-edge
    // x[] values, safe against a back-to-back row's first sample). The
    // terms consumed after the next row's butterflies land (phase 8) are
    // banked by row parity.
    // ========================================================================
    /* verilator lint_off WIDTHEXPAND */
    wire signed [IN_W:0]  t0 = x[0] + x[7];
    wire signed [IN_W:0]  t1 = x[1] + x[6];
    wire signed [IN_W:0]  t2 = x[2] + x[5];
    wire signed [IN_W:0]  t3 = x[3] + x[4];
    wire signed [IN_W:0]  s7 = x[0] - x[7];
    wire signed [IN_W:0]  s6 = x[1] - x[6];
    wire signed [IN_W:0]  s5 = x[2] - x[5];
    wire signed [IN_W:0]  s4 = x[3] - x[4];

    reg        bank;                       // toggles per row
    reg signed [BW_-1:0] bf_u2u3, bf_v0, bf_v1, bf_v2;   // multiplier feeds
    reg signed [BW_-1:0] b_x0 [0:1];       // banked: u0+u1 (exact X0)
    reg signed [BW_-1:0] b_x4 [0:1];       // banked: u0-u1 (exact X4)
    reg signed [BW_-1:0] b_u3 [0:1];       // banked: X2/X6 integer term
    reg signed [BW_-1:0] b_t7 [0:1];       // banked: odd-half integer term

    always @(posedge clk) begin
        if (row_start) begin
            b_x0[bank] <= (t0 + t3) + (t1 + t2);
            b_x4[bank] <= (t0 + t3) - (t1 + t2);
            b_u3[bank] <= t0 - t3;
            b_t7[bank] <= s7;
            bf_u2u3    <= (t1 - t2) + (t0 - t3);
            bf_v0      <= s4 + s5;
            bf_v1      <= s5 + s6;
            bf_v2      <= s6 + s7;
        end
    end
    /* verilator lint_on WIDTHEXPAND */

    always @(posedge clk) begin
        if (!rst_n)
            bank <= 1'b0;
        else if (row_start)
            bank <= ~bank;
    end
    wire wbank = ~bank;                    // bank being filled this row

    // ========================================================================
    // Phase pipe and the five-product schedule on one multiplier:
    //   phase 1: C_A5 * (v0 - v2)   (z5)
    //   phase 2: C_A3 * v1          (z3)
    //   phase 3: C_A4 * v2          (z4 part)
    //   phase 4: C_A1 * (u2 + u3)   (even rotation)
    //   phase 5: C_A2 * v0          (z2 part)
    // Products are banked with their row, so a back-to-back row's schedule
    // (starting 8 cycles later) can never overwrite a term before the
    // emission window (phases 4..11) has read it.
    // ========================================================================
    reg [5:0] phase;
    always @(posedge clk) begin
        if (!rst_n)
            phase <= 6'd0;
        else
            phase <= {phase[4:0], row_start};
    end

    reg signed [BW_:0]  mul_d;
    reg signed [14:0]   mul_c;
    always @(*) begin
        case (1'b1)
            phase[1]: begin mul_c = C_A5; mul_d = bf_v0 - bf_v2; end
            phase[2]: begin mul_c = C_A3; mul_d = {bf_v1[BW_-1], bf_v1}; end
            phase[3]: begin mul_c = C_A4; mul_d = {bf_v2[BW_-1], bf_v2}; end
            phase[4]: begin mul_c = C_A1; mul_d = {bf_u2u3[BW_-1], bf_u2u3}; end
            default:  begin mul_c = C_A2; mul_d = {bf_v0[BW_-1], bf_v0}; end
        endcase
    end

    wire signed [MW:0] mul_p = mul_c * mul_d;

    reg signed [MW:0] p_z5 [0:1];
    reg signed [MW:0] p_z3 [0:1];
    reg signed [MW:0] p_c4 [0:1];
    reg signed [MW:0] p_c1 [0:1];
    reg signed [MW:0] p_c2 [0:1];

    always @(posedge clk) begin
        if (phase[1]) p_z5[wbank] <= mul_p;
        if (phase[2]) p_z3[wbank] <= mul_p;
        if (phase[3]) p_c4[wbank] <= mul_p;
        if (phase[4]) p_c1[wbank] <= mul_p;
        if (phase[5]) p_c2[wbank] <= mul_p;
    end

    // ========================================================================
    // Emission: coefficient k during phase 4+k, from the emitting row's
    // bank. X0/X4 are exact integers; the rest sum Q13 terms and round
    // once.
    // ========================================================================
    reg       emit_active;
    reg [2:0] emit_k;
    reg       eb;                          // emitting row's bank

    /* verilator lint_off WIDTHEXPAND */
    reg signed [AW-1:0] emit_sum;
    always @(*) begin
        case (emit_k)
            3'd0: emit_sum = $signed(b_x0[eb]) <<< Q;
            3'd1: emit_sum = ($signed(b_t7[eb]) <<< Q)
                             + p_z3[eb] + p_c4[eb] + p_z5[eb];
            3'd2: emit_sum = ($signed(b_u3[eb]) <<< Q) + p_c1[eb];
            3'd3: emit_sum = ($signed(b_t7[eb]) <<< Q)
                             - p_z3[eb] - p_c2[eb] - p_z5[eb];
            3'd4: emit_sum = $signed(b_x4[eb]) <<< Q;
            3'd5: emit_sum = ($signed(b_t7[eb]) <<< Q)
                             - p_z3[eb] + p_c2[eb] + p_z5[eb];
            3'd6: emit_sum = ($signed(b_u3[eb]) <<< Q) - p_c1[eb];
            default: emit_sum = ($signed(b_t7[eb]) <<< Q)
                                + p_z3[eb] - p_c4[eb] - p_z5[eb];
        endcase
    end
    /* verilator lint_on WIDTHEXPAND */

    // Bits above 16 duplicate the sign for in-contract inputs (see
    // Contract); the low 13 bits are the discarded fraction.
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [AW-1:0] emit_rnd =
        (emit_sum + $signed({{(AW-14){1'b0}}, 14'd4096} >> GUARD))
        >>> (Q - GUARD);
    /* verilator lint_on UNUSEDSIGNAL */

    always @(posedge clk) begin
        if (!rst_n) begin
            emit_active <= 1'b0;
            emit_k      <= 3'd0;
            out_valid   <= 1'b0;
            out_last    <= 1'b0;
            out_data    <= 16'sd0;
        end else begin
            out_valid <= emit_active;
            out_last  <= emit_active && (emit_k == 3'd7);
            if (emit_active) begin
                out_data <= emit_rnd[15:0];
                emit_k   <= emit_k + 3'd1;
                if (emit_k == 3'd7)
                    emit_active <= 1'b0;
            end
            if (phase[3]) begin
                emit_active <= 1'b1;
                emit_k      <= 3'd0;
                eb          <= wbank;
            end
        end
    end

endmodule
