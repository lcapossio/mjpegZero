// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// dct_2d (AAN) — 8x8 scaled forward DCT by row-column decomposition
//
// Function
//   Two AAN dct_1d passes with a transpose between them, producing the 2-D
//   DCT scaled per coefficient by g_u * g_v (the AAN per-pass gains); the
//   paired quantizer removes the scale inside its folded reciprocal
//   tables. Ten constant multiplications per block-row pair (five per
//   pass) versus 28 for the orthonormal pair. The row pass keeps one
//   guard fraction bit (outputs x2, folded out by the quantizer): the
//   transform's rounding error at the positions whose AAN gain is below
//   one then stays under one orthonormal unit, which decoded quality at
//   high quality settings requires. The inter-pass value is carried at
//   its full 16-bit width with no saturation and no precision discard.
//   Bit-exact contract: streamline/verify/dct_aan_model.py::dct2d_aan
//   (interpass_shift 0, 16-bit).
//
// Interface
//   Identical ports to the orthonormal dct_2d: 12-bit samples in, raster
//   order with in_sof; 16-bit coefficients out, raster order with out_sof.
//
// Contract
//   One block per 64 clocks, never stalls, back-to-back safe (latched
//   read-side buffer halves). Matched set: dct_2d_aan + quantizer_aan
//   replace dct_2d + quantizer together, never separately. Valid input
//   domain is the encoder's level-shifted pixel range -128..127; over
//   that domain the doubled scaled output is bounded by
//   2 * (max_u g_u * a_u * sum_i |cos_u,i|)^2 * 128 = 25.9K < 2^15
//   (the u = 1 axis maximizes at 10.05), so the 16-bit output cannot
//   overflow; |inter-pass| < 2^12.
// -----------------------------------------------------------------------------

// The module keeps the canonical name so the encoder top instantiates it
// unchanged; the _aan filename distinguishes the matched-set variant.
/* verilator lint_off DECLFILENAME */
module dct_2d (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    input  wire signed [11:0] in_data,
    input  wire        in_sof,

    output reg         out_valid,
    output reg  signed [15:0] out_data,
    output wire        out_sof
);

    // ========================================================================
    // Row pass (12-bit input domain)
    // ========================================================================
    reg [5:0] in_cnt;
    always @(posedge clk) begin
        if (!rst_n)
            in_cnt <= 6'd0;
        else if (in_valid)
            in_cnt <= in_sof ? 6'd1 : in_cnt + 6'd1;
    end

    wire        row_valid;
    wire signed [15:0] row_data;

    dct_1d #(.IN_W(12), .GUARD(1)) u_row_dct (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_data  (in_data),
        .in_last  (in_valid && (in_sof ? 1'b0 : in_cnt[2:0] == 3'd7)),
        .out_valid(row_valid),
        .out_data (row_data),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_last ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ========================================================================
    // Transpose buffer, full 16-bit inter-pass width.
    // ========================================================================
    reg signed [15:0] tbuf [0:127];

    reg [5:0] t_wr_cnt;
    reg       t_wr_half;
    reg       t_done;

    always @(posedge clk) begin
        if (!rst_n) begin
            t_wr_cnt  <= 6'd0;
            t_wr_half <= 1'b0;
            t_done    <= 1'b0;
        end else begin
            t_done <= 1'b0;
            if (row_valid) begin
                tbuf[{t_wr_half, t_wr_cnt}] <= row_data;
                t_wr_cnt <= t_wr_cnt + 6'd1;
                if (t_wr_cnt == 6'd63) begin
                    t_wr_half <= ~t_wr_half;
                    t_done    <= 1'b1;
                end
            end
        end
    end

    reg [5:0] t_rd_cnt;
    reg       t_rd_half;
    reg       t_rd_active;
    reg       t_rd_valid;
    reg signed [15:0] t_rd_data;
    reg       t_rd_elem_last;

    always @(posedge clk) begin
        if (!rst_n) begin
            t_rd_cnt       <= 6'd0;
            t_rd_half      <= 1'b0;
            t_rd_active    <= 1'b0;
            t_rd_valid     <= 1'b0;
            t_rd_elem_last <= 1'b0;
        end else begin
            t_rd_valid     <= 1'b0;
            t_rd_elem_last <= 1'b0;

            if (t_rd_active) begin
                t_rd_valid     <= 1'b1;
                t_rd_data      <= tbuf[{t_rd_half, t_rd_cnt[2:0], t_rd_cnt[5:3]}];
                t_rd_elem_last <= (t_rd_cnt[2:0] == 3'd7);
                t_rd_cnt       <= t_rd_cnt + 6'd1;
                if (t_rd_cnt == 6'd63)
                    t_rd_active <= 1'b0;
            end

            // Last so a back-to-back restart wins over the end-of-read
            // clear; t_wr_half has already swapped away from the block.
            if (t_done) begin
                t_rd_active <= 1'b1;
                t_rd_cnt    <= 6'd0;
                t_rd_half   <= ~t_wr_half;
            end
        end
    end

    // ========================================================================
    // Column pass on the full-width intermediate.
    // ========================================================================
    wire        col_valid;
    wire signed [15:0] col_data;

    dct_1d #(.IN_W(16), .GUARD(0)) u_col_dct (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (t_rd_valid),
        .in_data  (t_rd_data),
        .in_last  (t_rd_elem_last),
        .out_valid(col_valid),
        .out_data (col_data),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_last ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ========================================================================
    // Output reorder buffer (column-major to raster), as in dct_2d.
    // ========================================================================
    reg signed [15:0] obuf [0:127];

    reg [5:0] o_wr_cnt;
    reg       o_wr_half;
    reg       o_done;

    always @(posedge clk) begin
        if (!rst_n) begin
            o_wr_cnt  <= 6'd0;
            o_wr_half <= 1'b0;
            o_done    <= 1'b0;
        end else begin
            o_done <= 1'b0;
            if (col_valid) begin
                obuf[{o_wr_half, o_wr_cnt}] <= col_data;
                o_wr_cnt <= o_wr_cnt + 6'd1;
                if (o_wr_cnt == 6'd63) begin
                    o_wr_half <= ~o_wr_half;
                    o_done    <= 1'b1;
                end
            end
        end
    end

    reg [5:0] o_rd_cnt;
    reg       o_rd_half;
    reg       o_rd_active;

    always @(posedge clk) begin
        if (!rst_n) begin
            o_rd_cnt    <= 6'd0;
            o_rd_half   <= 1'b0;
            o_rd_active <= 1'b0;
            out_valid   <= 1'b0;
            out_data    <= 16'sd0;
        end else begin
            out_valid <= 1'b0;

            if (o_rd_active) begin
                out_valid <= 1'b1;
                out_data  <= obuf[{o_rd_half, o_rd_cnt[2:0], o_rd_cnt[5:3]}];
                o_rd_cnt  <= o_rd_cnt + 6'd1;
                if (o_rd_cnt == 6'd63)
                    o_rd_active <= 1'b0;
            end

            if (o_done) begin
                o_rd_active <= 1'b1;
                o_rd_cnt    <= 6'd0;
                o_rd_half   <= ~o_wr_half;
            end
        end
    end

    // ========================================================================
    // Output block framing
    // ========================================================================
    reg [5:0] out_cnt;
    always @(posedge clk) begin
        if (!rst_n)
            out_cnt <= 6'd0;
        else if (out_valid)
            out_cnt <= out_cnt + 6'd1;
    end
    assign out_sof = out_valid && (out_cnt == 6'd0);

endmodule
