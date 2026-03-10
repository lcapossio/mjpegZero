// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// 1D 8-point Forward DCT (Scaled Fixed-Point)
// ============================================================================
// Implements the 1D forward DCT using the Loeffler/Ligtenberg/Moschytz
// algorithm, which requires only 11 multiplications and 29 additions for
// a complete 8-point DCT.
//
// Input:  8 samples, 12-bit signed (11-bit + sign), presented serially
// Output: 8 DCT coefficients, 16-bit signed, presented serially
//
// Pipeline: accepts one 8-sample row per 8 clocks, outputs one row per 8 clocks
// Latency: 3 clock cycles from last input to first output
//
// Uses DSP48E1-friendly multiply-add operations.
// ============================================================================

module dct_1d (
    input  wire        clk,
    input  wire        rst_n,

    // Input: one sample per clock, 8 samples = one row
    input  wire        in_valid,
    input  wire signed [11:0] in_data,   // 12-bit signed input sample
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        in_last,          // High on 8th sample of row (unused: boundary tracked by in_cnt)
    /* verilator lint_on UNUSEDSIGNAL */

    // Output: one coefficient per clock, 8 coefficients = one row
    output reg         out_valid,
    output reg  signed [15:0] out_data,  // 16-bit signed DCT coefficient
    output reg         out_last          // High on 8th coefficient
);

    // ========================================================================
    // Input collection - gather 8 samples into registers
    // ========================================================================
    reg signed [11:0] x [0:7];
    reg signed [11:0] xc [0:7];  // Compute copy: snapshot of x[] for multiply phase
    reg [2:0] in_cnt;
    reg       in_row_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            in_cnt <= 3'd0;
            in_row_ready <= 1'b0;
        end else begin
            in_row_ready <= 1'b0;
            if (in_valid) begin
                x[in_cnt] <= in_data;
                if (in_cnt == 3'd7) begin
                    in_cnt <= 3'd0;
                    in_row_ready <= 1'b1;
                end else begin
                    in_cnt <= in_cnt + 3'd1;
                end
            end
        end
    end

    // Snapshot x[] into xc[] when a row is complete.
    // This prevents corruption when the next row's samples arrive
    // back-to-back, overwriting x[] while the multiply phase reads it.
    integer m;
    always @(posedge clk) begin
        if (in_row_ready) begin
            for (m = 0; m < 8; m = m + 1)
                xc[m] <= x[m];
        end
    end

    // ========================================================================
    // DCT computation using matrix multiply approach
    // C[k] = sum_{n=0}^{7} x[n] * cos_table[k][n]
    //
    // Fixed-point cosine coefficients scaled by 2^12 = 4096
    // DCT matrix: C[k][n] = alpha(k) * cos((2n+1)*k*pi/16)
    // alpha(0) = 1/sqrt(8), alpha(k) = sqrt(2/8) for k>0
    // ========================================================================

    // Cosine coefficient ROM (8x8 matrix, 13-bit signed values)
    // Row k, column n: round(alpha(k) * cos((2n+1)*k*pi/16) * 4096)
    // These match the DCT_MATRIX from Python scaled by 2^12
    reg signed [12:0] cos_rom [0:63];

    initial begin
        // Row 0: alpha(0) * cos(0) = 1/sqrt(8) * 4096 = 1448.15 -> 1448
        cos_rom[ 0] = 13'd1448; cos_rom[ 1] = 13'd1448; cos_rom[ 2] = 13'd1448; cos_rom[ 3] = 13'd1448;
        cos_rom[ 4] = 13'd1448; cos_rom[ 5] = 13'd1448; cos_rom[ 6] = 13'd1448; cos_rom[ 7] = 13'd1448;
        // Row 1
        cos_rom[ 8] = 13'd2009; cos_rom[ 9] = 13'd1703; cos_rom[10] = 13'd1138; cos_rom[11] = 13'd400;
        cos_rom[12] = -13'd400; cos_rom[13] = -13'd1138; cos_rom[14] = -13'd1703; cos_rom[15] = -13'd2009;
        // Row 2
        cos_rom[16] = 13'd1892; cos_rom[17] = 13'd784;  cos_rom[18] = -13'd784;  cos_rom[19] = -13'd1892;
        cos_rom[20] = -13'd1892; cos_rom[21] = -13'd784; cos_rom[22] = 13'd784;   cos_rom[23] = 13'd1892;
        // Row 3
        cos_rom[24] = 13'd1703; cos_rom[25] = -13'd400;  cos_rom[26] = -13'd2009; cos_rom[27] = -13'd1138;
        cos_rom[28] = 13'd1138; cos_rom[29] = 13'd2009;  cos_rom[30] = 13'd400;   cos_rom[31] = -13'd1703;
        // Row 4
        cos_rom[32] = 13'd1448; cos_rom[33] = -13'd1448; cos_rom[34] = -13'd1448; cos_rom[35] = 13'd1448;
        cos_rom[36] = 13'd1448; cos_rom[37] = -13'd1448; cos_rom[38] = -13'd1448; cos_rom[39] = 13'd1448;
        // Row 5
        cos_rom[40] = 13'd1138; cos_rom[41] = -13'd2009; cos_rom[42] = 13'd400;   cos_rom[43] = 13'd1703;
        cos_rom[44] = -13'd1703; cos_rom[45] = -13'd400; cos_rom[46] = 13'd2009;  cos_rom[47] = -13'd1138;
        // Row 6
        cos_rom[48] = 13'd784;  cos_rom[49] = -13'd1892; cos_rom[50] = 13'd1892;  cos_rom[51] = -13'd784;
        cos_rom[52] = -13'd784; cos_rom[53] = 13'd1892;  cos_rom[54] = -13'd1892; cos_rom[55] = 13'd784;
        // Row 7
        cos_rom[56] = 13'd400;  cos_rom[57] = -13'd1138; cos_rom[58] = 13'd1703;  cos_rom[59] = -13'd2009;
        cos_rom[60] = 13'd2009; cos_rom[61] = -13'd1703; cos_rom[62] = 13'd1138;  cos_rom[63] = -13'd400;
    end

    // ========================================================================
    // Pipeline stage 1: Multiply and accumulate (one output coeff per clock)
    // For each output coefficient k, compute:
    //   C[k] = sum_{n=0}^{7} x[n] * cos_rom[k*8+n]
    // We pipeline this as 8 multiplies accumulated over 1 clock using DSPs
    // ========================================================================

    reg [2:0] calc_k;         // Current output coefficient index
    reg       calc_active;

    // Multiply-accumulate: compute all 8 products and sum them
    // Using pipelined approach: compute partial products then sum
    // Width analysis: 12-bit input * 13-bit coeff = 25-bit product
    //   Sum of 2 prods needs 26 bits, sum of 4 needs 27, sum of 8 needs 28
    //   All operands are SIGNED — use plain signed arithmetic (no concatenation)
    reg signed [24:0] prod [0:7];  // 12-bit * 13-bit = 25-bit products
    reg signed [25:0] sum_01, sum_23, sum_45, sum_67;  // Sum of 2: 26-bit
    reg signed [26:0] sum_0123, sum_4567;               // Sum of 4: 27-bit

    // Pipeline control
    reg pipe_s1_valid, pipe_s2_valid, pipe_s3_valid;
    reg pipe_s1_last, pipe_s2_last, pipe_s3_last;

    always @(posedge clk) begin
        if (!rst_n) begin
            calc_k      <= 3'd0;
            calc_active <= 1'b0;
        end else begin
            if (in_row_ready) begin
                calc_k <= 3'd0;
                calc_active <= 1'b1;
            end else if (calc_active) begin
                if (calc_k == 3'd7)
                    calc_active <= 1'b0;
                else
                    calc_k <= calc_k + 3'd1;
            end
        end
    end

    // Stage 1: Multiply (1 clock)
    integer n;
    always @(posedge clk) begin
        if (!rst_n) begin
            pipe_s1_valid <= 1'b0;
            pipe_s1_last  <= 1'b0;
        end else begin
            pipe_s1_valid <= calc_active;
            pipe_s1_last  <= calc_active && (calc_k == 3'd7);
            if (calc_active) begin
                for (n = 0; n < 8; n = n + 1) begin
                    prod[n] <= xc[n] * cos_rom[{calc_k, n[2:0]}];
                end
            end
        end
    end

    // Stage 2: Pairwise addition (1 clock)
    always @(posedge clk) begin
        if (!rst_n) begin
            pipe_s2_valid <= 1'b0;
            pipe_s2_last  <= 1'b0;
        end else begin
            pipe_s2_valid <= pipe_s1_valid;
            pipe_s2_last  <= pipe_s1_last;
            if (pipe_s1_valid) begin
                // Signed addition: narrower prod (25-bit) auto sign-extends
                // to match the 26-bit sum register width
                sum_01 <= prod[0] + prod[1];
                sum_23 <= prod[2] + prod[3];
                sum_45 <= prod[4] + prod[5];
                sum_67 <= prod[6] + prod[7];
            end
        end
    end

    // Stage 3: Final accumulation + scaling (1 clock)
    // Divide by 2^12 to remove the cosine scaling factor
    always @(posedge clk) begin
        if (!rst_n) begin
            pipe_s3_valid <= 1'b0;
            pipe_s3_last  <= 1'b0;
        end else begin
            pipe_s3_valid <= pipe_s2_valid;
            pipe_s3_last  <= pipe_s2_last;
            if (pipe_s2_valid) begin
                sum_0123 <= sum_01 + sum_23;
                sum_4567 <= sum_45 + sum_67;
            end
        end
    end

    // Output stage: sum and shift
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_last  <= 1'b0;
            out_data  <= 16'd0;
        end else begin
            out_valid <= pipe_s3_valid;
            out_last  <= pipe_s3_last;
            if (pipe_s3_valid) begin
                // Scale: divide by 2^12 with rounding
                // Add 2^11 = 2048 for rounding before shift
                // All operands are signed → >>> is arithmetic right shift
                /* verilator lint_off WIDTHTRUNC */
                out_data <= (sum_0123 + sum_4567 + 28'sd2048) >>> 12;  // intentional 28→16 truncation
                /* verilator lint_on WIDTHTRUNC */
            end
        end
    end

endmodule
