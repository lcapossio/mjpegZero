// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// dct_1d — 8-point forward DCT, Loeffler-factored, two time-shared multipliers
//
// Function
//   Computes the orthonormal 8-point forward DCT of each row of 8 samples:
//   X(k) = alpha(k) * sum x(n) cos((2n+1) k pi / 16), alpha(0) = 1/sqrt(8),
//   alpha(k>0) = 1/2 — the normalization the JPEG quantizer tables assume.
//   The Loeffler/LLM factorization reduces the 64 constant multiplications
//   of the direct form to 14, computed on two physical multipliers over the
//   8-cycle row period. All constants are the orthonormal values in Q12;
//   every output is rounded exactly once (+2^11, arithmetic shift by 12),
//   matching streamline/verify/dct_model.py::dct1d_loeffler bit for bit.
//
// Interface
//   Fixed-latency, valid-only stream: one sample per clock in (12-bit
//   signed), rows of 8; one coefficient per clock out (16-bit signed),
//   out_last on each row's final coefficient. Rows may arrive back-to-back
//   or with gaps. First coefficient emerges 6 clocks after a row's last
//   sample; a new row is accepted every 8 clocks with no stalls.
//
// Contract
//   Output cannot overflow 16 bits: |x| <= 2048 gives |X| <= sqrt(8)*2048
//   (+/-1 rounding) <= 5794. Intermediate widths below carry the proof at
//   each stage.
// -----------------------------------------------------------------------------

module dct_1d (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    input  wire signed [11:0] in_data,
    // Row boundaries are tracked by the internal sample counter; the port
    // exists for interface compatibility.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        in_last,
    /* verilator lint_on UNUSEDSIGNAL */

    output reg         out_valid,
    output reg  signed [15:0] out_data,
    output reg         out_last
);

    // Orthonormal constants in Q12 (= the direct-form cosine table values
    // and their exact sums/differences: 1108 = 1892-784, 2676 = 1892+784).
    localparam signed [13:0] C_A  = 14'sd1448;   // alpha(0): X0, X4
    localparam signed [13:0] C_R1 = 14'sd784;    // even rotation, shared term
    localparam signed [13:0] C_R2 = 14'sd1108;   // even rotation, X2 term
    localparam signed [13:0] C_R3 = 14'sd2676;   // even rotation, X6 term
    localparam signed [13:0] C_T4 = 14'sd432;    // odd: t3 -> X7
    localparam signed [13:0] C_T5 = 14'sd2973;   // odd: t2 -> X5
    localparam signed [13:0] C_T6 = 14'sd4450;   // odd: t1 -> X3
    localparam signed [13:0] C_T7 = 14'sd2174;   // odd: t0 -> X1
    localparam signed [13:0] C_Z1 = -14'sd1303;  // odd: z1 = t3+t0
    localparam signed [13:0] C_Z2 = -14'sd3711;  // odd: z2 = t2+t1
    localparam signed [13:0] C_Z3 = -14'sd2841;  // odd: z3 = t3+t1
    localparam signed [13:0] C_Z4 = -14'sd565;   // odd: z4 = t2+t0
    localparam signed [13:0] C_Z5 = 14'sd1703;   // odd: z5 = C_Z5*(z3+z4)

    // ========================================================================
    // Sample gather: 8 samples per row, row_start pulses the cycle after the
    // eighth sample lands.
    // ========================================================================
    reg signed [11:0] x [0:7];
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
                in_cnt    <= in_cnt + 3'd1;   // wraps 7 -> 0
                row_start <= (in_cnt == 3'd7);
            end
        end
    end

    // ========================================================================
    // Butterfly stage, registered in the row_start cycle. Reading x[] here
    // is safe against a back-to-back row's first sample: both updates land
    // on the same edge, and this stage reads the pre-edge values.
    //
    // Widths (|x| <= 2048): s,t <= 4096 -> 13b+carry; e, z <= 8192 -> 14b;
    // the paired sums (dc_sum, dc_dif, rot_sum, z_sum) <= 16384 -> all fit
    // 15-bit signed.
    // ========================================================================
    reg signed [14:0] bf_dc_sum;   // (s0+s3)+(s1+s2)          -> X0
    reg signed [14:0] bf_dc_dif;   // (s0+s3)-(s1+s2)          -> X4
    reg signed [14:0] bf_rot_sum;  // e2+e3                    -> shared rot
    reg signed [14:0] bf_e2;       // (s1-s2)                  -> X6 term
    reg signed [14:0] bf_e3;       // (s0-s3)                  -> X2 term
    reg signed [14:0] bf_z_sum;    // z3+z4 = (t3+t1)+(t2+t0)  -> z5
    reg signed [14:0] bf_z1, bf_z2, bf_z3, bf_z4;
    reg signed [14:0] bf_t0, bf_t1, bf_t2, bf_t3;

    // All arithmetic below is signed; implicit widening to the destination
    // width is sign-extension and cannot lose information.
    /* verilator lint_off WIDTHEXPAND */
    wire signed [12:0] s0 = x[0] + x[7];
    wire signed [12:0] s1 = x[1] + x[6];
    wire signed [12:0] s2 = x[2] + x[5];
    wire signed [12:0] s3 = x[3] + x[4];
    wire signed [12:0] t0 = x[0] - x[7];
    wire signed [12:0] t1 = x[1] - x[6];
    wire signed [12:0] t2 = x[2] - x[5];
    wire signed [12:0] t3 = x[3] - x[4];

    always @(posedge clk) begin
        if (row_start) begin
            bf_dc_sum  <= (s0 + s3) + (s1 + s2);
            bf_dc_dif  <= (s0 + s3) - (s1 + s2);
            bf_rot_sum <= (s1 - s2) + (s0 - s3);
            bf_e2      <= s1 - s2;
            bf_e3      <= s0 - s3;
            bf_z_sum   <= (t3 + t1) + (t2 + t0);
            bf_z1      <= t3 + t0;
            bf_z2      <= t2 + t1;
            bf_z3      <= t3 + t1;
            bf_z4      <= t2 + t0;
            bf_t0      <= t0;
            bf_t1      <= t1;
            bf_t2      <= t2;
            bf_t3      <= t3;
        end
    end

    // ========================================================================
    // Row phase pipe: bit c is high c cycles after row_start. Multiplies
    // occupy phases 1..7 and phase 3 opens the emission window; rows arrive
    // at most every 8 cycles, so each bit carries at most one row at a time.
    // ========================================================================
    reg [7:0] phase;
    always @(posedge clk) begin
        if (!rst_n)
            phase <= 8'd0;
        else
            phase <= {phase[6:0], row_start};
    end

    // ========================================================================
    // Two time-shared multipliers on a static 7-cycle schedule. Each product
    // is scheduled no later than one cycle before its first consumer and no
    // earlier than eight cycles before its last (so a back-to-back row's
    // rewrite of the same register cannot precede the final read):
    //
    //   phase | mult A            | mult B
    //     1   | C_A  * bf_dc_sum  | C_R2 * bf_e3
    //     2   | C_R1 * bf_rot_sum | C_T6 * bf_t1
    //     3   | C_Z5 * bf_z_sum   | C_T7 * bf_t0
    //     4   | C_Z1 * bf_z1      | C_Z4 * bf_z4
    //     5   | C_Z2 * bf_z2      | C_Z3 * bf_z3
    //     6   | C_A  * bf_dc_dif  | C_R3 * bf_e2
    //     7   | C_T4 * bf_t3      | C_T5 * bf_t2
    //
    // Products: 15b x 14b -> at most 16384*4450 < 2^27, held in 28 bits.
    // ========================================================================
    reg signed [13:0] mula_c, mulb_c;
    reg signed [14:0] mula_d, mulb_d;
    always @(*) begin
        case (1'b1)
            phase[1]: begin mula_c = C_A;  mula_d = bf_dc_sum;
                            mulb_c = C_R2; mulb_d = bf_e3;     end
            phase[2]: begin mula_c = C_R1; mula_d = bf_rot_sum;
                            mulb_c = C_T6; mulb_d = bf_t1;     end
            phase[3]: begin mula_c = C_Z5; mula_d = bf_z_sum;
                            mulb_c = C_T7; mulb_d = bf_t0;     end
            phase[4]: begin mula_c = C_Z1; mula_d = bf_z1;
                            mulb_c = C_Z4; mulb_d = bf_z4;     end
            phase[5]: begin mula_c = C_Z2; mula_d = bf_z2;
                            mulb_c = C_Z3; mulb_d = bf_z3;     end
            phase[6]: begin mula_c = C_A;  mula_d = bf_dc_dif;
                            mulb_c = C_R3; mulb_d = bf_e2;     end
            default:  begin mula_c = C_T4; mula_d = bf_t3;
                            mulb_c = C_T5; mulb_d = bf_t2;     end
        endcase
    end

    wire signed [27:0] mula_p = mula_c * mula_d;
    wire signed [27:0] mulb_p = mulb_c * mulb_d;

    reg signed [27:0] p_x0, p_x4;          // C_A products
    reg signed [27:0] p_zr, p_e3, p_e2;    // even rotation
    reg signed [27:0] p_z5, p_z1, p_z2, p_z3, p_z4;
    reg signed [27:0] p_t0, p_t1, p_t2, p_t3;

    always @(posedge clk) begin
        if (phase[1]) begin p_x0 <= mula_p; p_e3 <= mulb_p; end
        if (phase[2]) begin p_zr <= mula_p; p_t1 <= mulb_p; end
        if (phase[3]) begin p_z5 <= mula_p; p_t0 <= mulb_p; end
        if (phase[4]) begin p_z1 <= mula_p; p_z4 <= mulb_p; end
        if (phase[5]) begin p_z2 <= mula_p; p_z3 <= mulb_p; end
        if (phase[6]) begin p_x4 <= mula_p; p_e2 <= mulb_p; end
        if (phase[7]) begin p_t3 <= mula_p; p_t2 <= mulb_p; end
    end

    // ========================================================================
    // Emission: coefficient k leaves during phase 4+k. Four-term sums stay
    // under 4 * 2^27 + rounding < 2^30 (held in 31 bits); after the single
    // +2048 >>> 12 rounding the result is the orthonormal DCT, bounded by
    // 5794 (see Contract), so the 16-bit slice below is lossless.
    // ========================================================================
    reg       emit_active;
    reg [2:0] emit_k;

    reg signed [30:0] emit_sum;
    always @(*) begin
        case (emit_k)
            3'd0: emit_sum = {{3{p_x0[27]}}, p_x0};
            3'd1: emit_sum = p_t0 + p_z1 + p_z4 + p_z5;
            3'd2: emit_sum = {{3{p_zr[27]}}, p_zr} + {{3{p_e3[27]}}, p_e3};
            3'd3: emit_sum = p_t1 + p_z2 + p_z3 + p_z5;
            3'd4: emit_sum = {{3{p_x4[27]}}, p_x4};
            3'd5: emit_sum = p_t2 + p_z2 + p_z4 + p_z5;
            3'd6: emit_sum = {{3{p_zr[27]}}, p_zr} - {{3{p_e2[27]}}, p_e2};
            default: emit_sum = p_t3 + p_z1 + p_z3 + p_z5;
        endcase
    end

    // Bits [30:16] of the rounded value duplicate the sign (|X| <= 5794,
    // see Contract), so the 16-bit slice is lossless.
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [30:0] emit_rnd = (emit_sum + 31'sd2048) >>> 12;
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on WIDTHEXPAND */

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
            // A new row's window opens exactly as a back-to-back row's
            // closes; this assignment is last so the open wins.
            if (phase[3]) begin
                emit_active <= 1'b1;
                emit_k      <= 3'd0;
            end
        end
    end

endmodule
