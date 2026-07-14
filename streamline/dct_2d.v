// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// dct_2d — 8x8 forward DCT by row-column decomposition
//
// Function
//   Applies the orthonormal 8-point DCT (dct_1d) to the rows of each 8x8
//   block, transposes, applies it to the columns, and restores raster
//   order, producing the 2-D DCT with the normalization the JPEG quantizer
//   tables assume. Between passes each intermediate coefficient is
//   saturated to 12 bits, the row-pass range the column DCT accepts;
//   |row-pass output| <= sqrt(8)*2048 = 5793 can exceed 2047 only for
//   blocks near full-scale in an entire row, where clipping this
//   intermediate is the accepted precision trade of the 12-bit interface.
//
// Interface
//   Fixed-latency, valid-only stream: one 12-bit sample per clock in,
//   raster order, in_sof on each block's first sample; one 16-bit
//   coefficient per clock out, raster order, out_sof on each block's first.
//
// Contract
//   One block per 64 clocks, never stalls, correct for any input gap
//   pattern including fully back-to-back blocks. Both transpose buffers
//   are double-buffered halves of one array with the read-side half
//   latched at block completion, so a write-side swap during the final
//   read cycles of a block cannot redirect an in-progress readout.
// -----------------------------------------------------------------------------

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
    // Row pass
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

    dct_1d u_row_dct (
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
    // Transpose buffer: {half, row, col} written row-major, read
    // column-major as {half, col-fast, row-slow} address swizzle.
    // ========================================================================
    reg signed [15:0] tbuf [0:127];

    reg [5:0] t_wr_cnt;              // {row, col} within the block
    reg       t_wr_half;
    reg       t_done;                // one-cycle pulse: block written

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

    reg [5:0] t_rd_cnt;              // {column, element} read order
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
                // Element i of column k lives at write address {i, k}.
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
    // Column pass, on the 12-bit saturated intermediate.
    // ========================================================================
    wire signed [11:0] col_in =
        (t_rd_data > 16'sd2047)  ? 12'sd2047  :
        (t_rd_data < -16'sd2048) ? -12'sd2048 : t_rd_data[11:0];

    wire        col_valid;
    wire signed [15:0] col_data;

    dct_1d u_col_dct (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (t_rd_valid),
        .in_data  (col_in),
        .in_last  (t_rd_elem_last),
        .out_valid(col_valid),
        .out_data (col_data),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_last ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ========================================================================
    // Output reorder buffer: the column pass emits F[u][k] with u fast
    // (column-major); writing linearly and reading with the 3-bit address
    // fields swapped restores raster order.
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
