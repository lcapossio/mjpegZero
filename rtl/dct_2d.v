// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// 2D 8x8 Forward DCT
// ============================================================================
// Implements 2D DCT using row-column decomposition:
//   1. Apply 1D DCT to each row (8 rows)
//   2. Transpose the result
//   3. Apply 1D DCT to each column (now rows after transpose)
//
// Input:  8x8 block, 12-bit signed samples, streamed row by row
// Output: 8x8 block, 16-bit signed DCT coefficients, streamed row by row
//
// Uses two 1D DCT instances with a transpose buffer between them.
// Total latency: ~24 clocks from first input to first output
// Throughput: one 8x8 block every 64 input clocks
// ============================================================================

module dct_2d (
    input  wire        clk,
    input  wire        rst_n,

    // Input: one sample per clock, row-major order
    input  wire        in_valid,
    input  wire signed [11:0] in_data,
    input  wire        in_sof,     // Start of 8x8 block (first sample)

    // Output: one coefficient per clock, row-major order
    output reg         out_valid,
    output reg  signed [15:0] out_data,
    output wire        out_sof     // Start of output block
);

    // ========================================================================
    // Input sample counter
    // ========================================================================
    reg [5:0] in_sample_cnt;  // 0..63
    wire      in_last_of_row = (in_sample_cnt[2:0] == 3'd7) && in_valid;

    always @(posedge clk) begin
        if (!rst_n)
            in_sample_cnt <= 6'd0;
        else if (in_valid) begin
            if (in_sof)
                in_sample_cnt <= 6'd1;
            else
                in_sample_cnt <= in_sample_cnt + 6'd1;
        end
    end

    // ========================================================================
    // Row DCT (first pass)
    // ========================================================================
    wire        row_dct_out_valid;
    wire signed [15:0] row_dct_out_data;
    wire        row_dct_out_last;

    dct_1d u_row_dct (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .in_data  (in_data),
        .in_last  (in_last_of_row),
        .out_valid(row_dct_out_valid),
        .out_data (row_dct_out_data),
        .out_last (row_dct_out_last)
    );

    // ========================================================================
    // Transpose buffer
    // ========================================================================
    // Write row-major, read column-major
    // Double-buffered: while writing one block, reading the previous one
    reg signed [15:0] tbuf0 [0:63];
    reg signed [15:0] tbuf1 [0:63];
    reg        tbuf_sel;          // 0 = write buf0/read buf1, 1 = write buf1/read buf0

    // Write side
    reg [5:0]  tbuf_wr_cnt;
    reg [2:0]  tbuf_wr_row;
    reg [2:0]  tbuf_wr_col;
    reg        tbuf_block_done;   // Signals that a complete block was written

    always @(posedge clk) begin
        if (!rst_n) begin
            tbuf_wr_cnt    <= 6'd0;
            tbuf_wr_row    <= 3'd0;
            tbuf_wr_col    <= 3'd0;
            tbuf_block_done <= 1'b0;
            tbuf_sel       <= 1'b0;
        end else begin
            tbuf_block_done <= 1'b0;
            if (row_dct_out_valid) begin
                // Write in row-major order
                if (!tbuf_sel)
                    tbuf0[{tbuf_wr_row, tbuf_wr_col}] <= row_dct_out_data;
                else
                    tbuf1[{tbuf_wr_row, tbuf_wr_col}] <= row_dct_out_data;

                tbuf_wr_col <= tbuf_wr_col + 3'd1;
                tbuf_wr_cnt <= tbuf_wr_cnt + 6'd1;

                if (row_dct_out_last) begin
                    tbuf_wr_row <= tbuf_wr_row + 3'd1;
                    tbuf_wr_col <= 3'd0;
                end

                if (tbuf_wr_cnt == 6'd63) begin
                    tbuf_block_done <= 1'b1;
                    tbuf_wr_cnt <= 6'd0;
                    tbuf_wr_row <= 3'd0;
                    tbuf_wr_col <= 3'd0;
                    tbuf_sel <= ~tbuf_sel;
                end
            end
        end
    end

    // Read side - column-major (transpose)
    reg [2:0]  tbuf_rd_row;
    reg [2:0]  tbuf_rd_col;
    reg        tbuf_rd_active;
    reg        tbuf_rd_valid;
    reg signed [15:0] tbuf_rd_data;
    reg        tbuf_rd_sel;       // Which buffer to read from

    always @(posedge clk) begin
        if (!rst_n) begin
            tbuf_rd_row    <= 3'd0;
            tbuf_rd_col    <= 3'd0;
            tbuf_rd_active <= 1'b0;
            tbuf_rd_valid  <= 1'b0;
            tbuf_rd_sel    <= 1'b0;
        end else begin
            tbuf_rd_valid <= 1'b0;

            // Read side: output transposed data
            // (placed BEFORE tbuf_block_done so that tbuf_block_done's
            //  NBA to tbuf_rd_active takes priority on collision cycles)
            if (tbuf_rd_active) begin
                tbuf_rd_valid <= 1'b1;

                // Read column-major: address = {col, row} (transposed!)
                if (!tbuf_rd_sel)
                    tbuf_rd_data <= tbuf0[{tbuf_rd_col, tbuf_rd_row}];
                else
                    tbuf_rd_data <= tbuf1[{tbuf_rd_col, tbuf_rd_row}];

                // Advance: col increments fastest (reading down a column of
                // the stored row-DCT output), row increments to next column
                tbuf_rd_col <= tbuf_rd_col + 3'd1;
                if (tbuf_rd_col == 3'd7) begin
                    tbuf_rd_col <= 3'd0;
                    tbuf_rd_row <= tbuf_rd_row + 3'd1;
                    if (tbuf_rd_row == 3'd7) begin
                        tbuf_rd_active <= 1'b0;
                    end
                end
            end

            // Start reading when a block write completes.
            // This MUST come after the rd_active block above so that
            // its NBA to tbuf_rd_active (=1) wins over the end-of-read
            // NBA (=0) when both fire on the same clock cycle.
            if (tbuf_block_done) begin
                tbuf_rd_sel    <= ~tbuf_sel;
                tbuf_rd_active <= 1'b1;
                tbuf_rd_row    <= 3'd0;
                tbuf_rd_col    <= 3'd0;
            end
        end
    end

    // Last sample of each 8-sample group: rd_col is the fast counter,
    // so "last" fires when the output data used rd_col == 7.
    // tbuf_rd_col_d holds the rd_col value that produced the current output.
    wire tbuf_rd_row_last;
    reg [2:0] tbuf_rd_col_d;
    always @(posedge clk) tbuf_rd_col_d <= tbuf_rd_col;
    assign tbuf_rd_row_last = tbuf_rd_valid && (tbuf_rd_col_d == 3'd7);

    // ========================================================================
    // Column DCT (second pass) - reuse same dct_1d module
    // ========================================================================
    // Input is transposed data (column reads fed as rows)
    wire        col_in_last = tbuf_rd_row_last;

    // Truncate 16-bit to 12-bit for column DCT input (with saturation)
    wire signed [11:0] col_dct_in;
    assign col_dct_in = (tbuf_rd_data > 16'sd2047)  ? 12'sd2047 :
                        (tbuf_rd_data < -16'sd2048) ? -12'sd2048 :
                        tbuf_rd_data[11:0];

    wire        col_dct_out_valid;
    wire signed [15:0] col_dct_out_data;

    dct_1d u_col_dct (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (tbuf_rd_valid),
        .in_data  (col_dct_in),
        .in_last  (col_in_last),
        .out_valid(col_dct_out_valid),
        .out_data (col_dct_out_data),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_last ()           // not needed: 2D DCT output timing tracked by out_valid count
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // ========================================================================
    // Output transpose buffer (double-buffered)
    // ========================================================================
    // The column DCT outputs coefficients in column-major order:
    //   F[0][0], F[1][0], ..., F[7][0], F[0][1], F[1][1], ..., F[7][1], ...
    // The quantizer/zigzag expect row-major (raster) order:
    //   F[0][0], F[0][1], ..., F[0][7], F[1][0], F[1][1], ..., F[1][7], ...
    //
    // Write linearly (column-major): buf[cnt] where cnt[2:0]=u, cnt[5:3]=v
    // Read transposed (row-major):   buf[{cnt[2:0], cnt[5:3]}] swaps u/v
    reg signed [15:0] obuf0 [0:63];
    reg signed [15:0] obuf1 [0:63];
    reg        obuf_wr_sel;
    reg [5:0]  obuf_wr_cnt;
    reg        obuf_block_done;

    always @(posedge clk) begin
        if (!rst_n) begin
            obuf_wr_sel    <= 1'b0;
            obuf_wr_cnt    <= 6'd0;
            obuf_block_done <= 1'b0;
        end else begin
            obuf_block_done <= 1'b0;
            if (col_dct_out_valid) begin
                if (!obuf_wr_sel)
                    obuf0[obuf_wr_cnt] <= col_dct_out_data;
                else
                    obuf1[obuf_wr_cnt] <= col_dct_out_data;

                if (obuf_wr_cnt == 6'd63) begin
                    obuf_wr_cnt     <= 6'd0;
                    obuf_wr_sel     <= ~obuf_wr_sel;
                    obuf_block_done <= 1'b1;
                end else begin
                    obuf_wr_cnt <= obuf_wr_cnt + 6'd1;
                end
            end
        end
    end

    // Read side: transpose by swapping 3-bit row/col fields of address
    reg        obuf_rd_active;
    reg [5:0]  obuf_rd_cnt;
    reg        obuf_rd_sel;

    always @(posedge clk) begin
        if (!rst_n) begin
            obuf_rd_active <= 1'b0;
            obuf_rd_cnt    <= 6'd0;
            obuf_rd_sel    <= 1'b0;
            out_valid      <= 1'b0;
            out_data       <= 16'sd0;
        end else begin
            out_valid <= 1'b0;

            if (obuf_rd_active) begin
                out_valid <= 1'b1;
                // Read with transposed address: swap {v, u} to {u, v}
                if (!obuf_rd_sel)
                    out_data <= obuf0[{obuf_rd_cnt[2:0], obuf_rd_cnt[5:3]}];
                else
                    out_data <= obuf1[{obuf_rd_cnt[2:0], obuf_rd_cnt[5:3]}];

                if (obuf_rd_cnt == 6'd63)
                    obuf_rd_active <= 1'b0;
                obuf_rd_cnt <= obuf_rd_cnt + 6'd1;
            end

            // Start reading when a block write completes
            if (obuf_block_done) begin
                obuf_rd_sel    <= ~obuf_wr_sel; // Read from just-completed buffer
                obuf_rd_active <= 1'b1;
                obuf_rd_cnt    <= 6'd0;
            end
        end
    end

    // ========================================================================
    // SOF tracking for output
    // ========================================================================
    reg [5:0] out_cnt;
    always @(posedge clk) begin
        if (!rst_n)
            out_cnt <= 6'd0;
        else if (out_valid)
            out_cnt <= (out_cnt == 6'd63) ? 6'd0 : out_cnt + 6'd1;
    end
    assign out_sof = out_valid && (out_cnt == 6'd0);

endmodule
