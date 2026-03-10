// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// Zigzag Reorder
// ============================================================================
// Reorders 64 quantized DCT coefficients from raster scan order to
// JPEG zigzag order using a dual-port RAM and address remapping.
//
// Input:  64 coefficients per block in raster order, 1/clock
// Output: 64 coefficients per block in zigzag order, 1/clock
//
// Uses double-buffering: write one block while reading the previous one.
// Latency: 1 block (64 clocks)
// ============================================================================

module zigzag_reorder (
    input  wire        clk,
    input  wire        rst_n,

    // Input
    input  wire        in_valid,
    input  wire signed [15:0] in_data,
    input  wire        in_sob,     // Start of block

    // Output
    output reg         out_valid,
    output reg  signed [15:0] out_data,
    output reg         out_sob
);

    // ========================================================================
    // Zigzag order lookup table (raster index -> zigzag position)
    // ========================================================================
    // zigzag_pos[raster_idx] = position in zigzag output
    reg [5:0] zigzag_pos [0:63];

    initial begin
        // Standard JPEG zigzag order: maps raster position to zigzag position
        // This is the INVERSE mapping: for each raster index, where does it go in zigzag?
        zigzag_pos[ 0] = 6'd0;  zigzag_pos[ 1] = 6'd1;  zigzag_pos[ 2] = 6'd5;  zigzag_pos[ 3] = 6'd6;
        zigzag_pos[ 4] = 6'd14; zigzag_pos[ 5] = 6'd15; zigzag_pos[ 6] = 6'd27; zigzag_pos[ 7] = 6'd28;
        zigzag_pos[ 8] = 6'd2;  zigzag_pos[ 9] = 6'd4;  zigzag_pos[10] = 6'd7;  zigzag_pos[11] = 6'd13;
        zigzag_pos[12] = 6'd16; zigzag_pos[13] = 6'd26; zigzag_pos[14] = 6'd29; zigzag_pos[15] = 6'd42;
        zigzag_pos[16] = 6'd3;  zigzag_pos[17] = 6'd8;  zigzag_pos[18] = 6'd12; zigzag_pos[19] = 6'd17;
        zigzag_pos[20] = 6'd25; zigzag_pos[21] = 6'd30; zigzag_pos[22] = 6'd41; zigzag_pos[23] = 6'd43;
        zigzag_pos[24] = 6'd9;  zigzag_pos[25] = 6'd11; zigzag_pos[26] = 6'd18; zigzag_pos[27] = 6'd24;
        zigzag_pos[28] = 6'd31; zigzag_pos[29] = 6'd40; zigzag_pos[30] = 6'd44; zigzag_pos[31] = 6'd53;
        zigzag_pos[32] = 6'd10; zigzag_pos[33] = 6'd19; zigzag_pos[34] = 6'd23; zigzag_pos[35] = 6'd32;
        zigzag_pos[36] = 6'd39; zigzag_pos[37] = 6'd45; zigzag_pos[38] = 6'd52; zigzag_pos[39] = 6'd54;
        zigzag_pos[40] = 6'd20; zigzag_pos[41] = 6'd22; zigzag_pos[42] = 6'd33; zigzag_pos[43] = 6'd38;
        zigzag_pos[44] = 6'd46; zigzag_pos[45] = 6'd51; zigzag_pos[46] = 6'd55; zigzag_pos[47] = 6'd60;
        zigzag_pos[48] = 6'd21; zigzag_pos[49] = 6'd34; zigzag_pos[50] = 6'd37; zigzag_pos[51] = 6'd47;
        zigzag_pos[52] = 6'd50; zigzag_pos[53] = 6'd56; zigzag_pos[54] = 6'd59; zigzag_pos[55] = 6'd61;
        zigzag_pos[56] = 6'd35; zigzag_pos[57] = 6'd36; zigzag_pos[58] = 6'd48; zigzag_pos[59] = 6'd49;
        zigzag_pos[60] = 6'd57; zigzag_pos[61] = 6'd58; zigzag_pos[62] = 6'd62; zigzag_pos[63] = 6'd63;
    end

    // ========================================================================
    // Double-buffered storage
    // ========================================================================
    reg signed [15:0] buf0 [0:63];
    reg signed [15:0] buf1 [0:63];
    reg        buf_sel;          // 0 = write buf0/read buf1, 1 = write buf1/read buf0

    // Write side
    reg [5:0]  wr_cnt;
    reg        wr_block_done;

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_cnt <= 6'd0;
            wr_block_done <= 1'b0;
            buf_sel <= 1'b0;
        end else begin
            wr_block_done <= 1'b0;
            if (in_valid) begin
                // Write to zigzag-reordered position
                if (!buf_sel)
                    buf0[zigzag_pos[wr_cnt]] <= in_data;
                else
                    buf1[zigzag_pos[wr_cnt]] <= in_data;

                if (wr_cnt == 6'd63) begin
                    wr_cnt <= 6'd0;
                    wr_block_done <= 1'b1;
                    buf_sel <= ~buf_sel;
                end else begin
                    wr_cnt <= wr_cnt + 6'd1;
                end

                if (in_sob)
                    wr_cnt <= 6'd1;  // Reset counter (first sample written to pos 0)
            end
        end
    end

    // Read side - sequential readout of zigzag-ordered block
    reg [5:0]  rd_cnt;
    reg        rd_active;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_cnt <= 6'd0;
            rd_active <= 1'b0;
            out_valid <= 1'b0;
            out_sob <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            out_sob <= 1'b0;

            // Read side: output zigzag-ordered coefficients
            // (placed BEFORE wr_block_done so that wr_block_done's
            //  NBA to rd_active takes priority on collision cycles)
            if (rd_active) begin
                out_valid <= 1'b1;
                out_sob <= (rd_cnt == 6'd0);

                // Read from the buffer that's NOT being written to
                if (buf_sel)
                    out_data <= buf0[rd_cnt];
                else
                    out_data <= buf1[rd_cnt];

                if (rd_cnt == 6'd63) begin
                    rd_active <= 1'b0;
                end
                rd_cnt <= rd_cnt + 6'd1;
            end

            // Start reading when a block write completes.
            // MUST come after rd_active block so its NBA (rd_active=1)
            // wins over end-of-read NBA (rd_active=0) on collision.
            if (wr_block_done) begin
                rd_active <= 1'b1;
                rd_cnt <= 6'd0;
            end
        end
    end

endmodule
