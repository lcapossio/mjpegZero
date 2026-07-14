// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// zigzag_reorder — reorders each block from raster order to zigzag order
//
// Function
//   Writes each incoming raster-order coefficient to its zigzag position
//   (ITU-T T.81 Figure A.6) in one half of a double buffer, then reads the
//   completed block out sequentially while the other half fills.
//
// Interface
//   Fixed-latency, valid-only stream: 64 coefficients per block in, in_sob
//   framing; 64 out in zigzag order, one block (64 cycles + 2) behind.
//
// Contract
//   One coefficient per clock, never stalls, and correct for any input gap
//   pattern including fully back-to-back blocks: the read-side buffer
//   selector is latched when a block completes, so the write side's buffer
//   swap — which can occur during the final read cycles of the previous
//   block — cannot redirect an in-progress readout.
//
// Position
//   Encoder coefficient path:
//   input_buffer → dct_2d → quantizer → [zigzag_reorder] →
//   huffman_encoder → bitstream_packer → jfif_writer
//   May fuse into dct_2d's output stage (ZIGZAG_OUT) once the streamline
//   top exists; this standalone module covers until then.
// -----------------------------------------------------------------------------

module zigzag_reorder (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    input  wire signed [15:0] in_data,
    input  wire        in_sob,

    output reg         out_valid,
    output reg  signed [15:0] out_data,
    output reg         out_sob
);

    // zigzag_pos(r) = zigzag position of raster index r (T.81 Figure A.6).
    function [5:0] zigzag_pos;
        input [5:0] r;
        case (r)
            6'd0 : zigzag_pos = 6'd0;  6'd1 : zigzag_pos = 6'd1;  6'd2 : zigzag_pos = 6'd5;  6'd3 : zigzag_pos = 6'd6;
            6'd4 : zigzag_pos = 6'd14; 6'd5 : zigzag_pos = 6'd15; 6'd6 : zigzag_pos = 6'd27; 6'd7 : zigzag_pos = 6'd28;
            6'd8 : zigzag_pos = 6'd2;  6'd9 : zigzag_pos = 6'd4;  6'd10: zigzag_pos = 6'd7;  6'd11: zigzag_pos = 6'd13;
            6'd12: zigzag_pos = 6'd16; 6'd13: zigzag_pos = 6'd26; 6'd14: zigzag_pos = 6'd29; 6'd15: zigzag_pos = 6'd42;
            6'd16: zigzag_pos = 6'd3;  6'd17: zigzag_pos = 6'd8;  6'd18: zigzag_pos = 6'd12; 6'd19: zigzag_pos = 6'd17;
            6'd20: zigzag_pos = 6'd25; 6'd21: zigzag_pos = 6'd30; 6'd22: zigzag_pos = 6'd41; 6'd23: zigzag_pos = 6'd43;
            6'd24: zigzag_pos = 6'd9;  6'd25: zigzag_pos = 6'd11; 6'd26: zigzag_pos = 6'd18; 6'd27: zigzag_pos = 6'd24;
            6'd28: zigzag_pos = 6'd31; 6'd29: zigzag_pos = 6'd40; 6'd30: zigzag_pos = 6'd44; 6'd31: zigzag_pos = 6'd53;
            6'd32: zigzag_pos = 6'd10; 6'd33: zigzag_pos = 6'd19; 6'd34: zigzag_pos = 6'd23; 6'd35: zigzag_pos = 6'd32;
            6'd36: zigzag_pos = 6'd39; 6'd37: zigzag_pos = 6'd45; 6'd38: zigzag_pos = 6'd52; 6'd39: zigzag_pos = 6'd54;
            6'd40: zigzag_pos = 6'd20; 6'd41: zigzag_pos = 6'd22; 6'd42: zigzag_pos = 6'd33; 6'd43: zigzag_pos = 6'd38;
            6'd44: zigzag_pos = 6'd46; 6'd45: zigzag_pos = 6'd51; 6'd46: zigzag_pos = 6'd55; 6'd47: zigzag_pos = 6'd60;
            6'd48: zigzag_pos = 6'd21; 6'd49: zigzag_pos = 6'd34; 6'd50: zigzag_pos = 6'd37; 6'd51: zigzag_pos = 6'd47;
            6'd52: zigzag_pos = 6'd50; 6'd53: zigzag_pos = 6'd56; 6'd54: zigzag_pos = 6'd59; 6'd55: zigzag_pos = 6'd61;
            6'd56: zigzag_pos = 6'd35; 6'd57: zigzag_pos = 6'd36; 6'd58: zigzag_pos = 6'd48; 6'd59: zigzag_pos = 6'd49;
            6'd60: zigzag_pos = 6'd57; 6'd61: zigzag_pos = 6'd58; 6'd62: zigzag_pos = 6'd62; 6'd63: zigzag_pos = 6'd63;
        endcase
    endfunction

    // Double buffer as one array: {half, zigzag position}.
    reg signed [15:0] blk_buf [0:127];

    // Write side: fill half wr_half in zigzag positions, swap on completion.
    reg [5:0] wr_cnt;
    reg       wr_half;
    reg       wr_done;      // one-cycle pulse: a block just completed

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_cnt  <= 6'd0;
            wr_half <= 1'b0;
            wr_done <= 1'b0;
        end else begin
            wr_done <= 1'b0;
            if (in_valid) begin
                blk_buf[{wr_half, zigzag_pos(in_sob ? 6'd0 : wr_cnt)}] <= in_data;
                if (in_sob) begin
                    wr_cnt <= 6'd1;
                end else if (wr_cnt == 6'd63) begin
                    wr_cnt  <= 6'd0;
                    wr_half <= ~wr_half;
                    wr_done <= 1'b1;
                end else begin
                    wr_cnt <= wr_cnt + 6'd1;
                end
            end
        end
    end

    // Read side: 64 sequential reads from the half latched at wr_done. The
    // latch makes the readout immune to the write side swapping halves
    // during the final read cycles of a back-to-back block sequence.
    reg [5:0] rd_cnt;
    reg       rd_half;
    reg       rd_active;

    always @(posedge clk) begin
        if (!rst_n) begin
            rd_cnt    <= 6'd0;
            rd_half   <= 1'b0;
            rd_active <= 1'b0;
            out_valid <= 1'b0;
            out_sob   <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            out_sob   <= 1'b0;

            if (rd_active) begin
                out_valid <= 1'b1;
                out_sob   <= (rd_cnt == 6'd0);
                out_data  <= blk_buf[{rd_half, rd_cnt}];
                rd_cnt    <= rd_cnt + 6'd1;
                if (rd_cnt == 6'd63)
                    rd_active <= 1'b0;
            end

            // A completed block starts (or, back-to-back, restarts) the
            // readout; this assignment is last so it wins the collision with
            // the end-of-read clear above. wr_half has already swapped away
            // from the completed block's half.
            if (wr_done) begin
                rd_active <= 1'b1;
                rd_cnt    <= 6'd0;
                rd_half   <= ~wr_half;
            end
        end
    end

endmodule
