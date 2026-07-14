// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// huffman_encoder — entropy-codes quantized, zigzag-ordered coefficients
//
// Function
//   Baseline sequential Huffman coding per ITU-T T.81 §F.1.2 with the Annex
//   K.3.3 typical tables. Per block: the DC difference against the
//   component's predictor is coded as (size category, amplitude bits); each
//   nonzero AC coefficient as (run of preceding zeros, size category) plus
//   amplitude bits, with runs of 16+ zeros split off as ZRL symbols (run 15,
//   size 0) and a trailing all-zero tail closed by EOB (run 0, size 0).
//   Three DC predictors (Y, Cb, Cr) reset on restart, per §F.1.1.5.1.
//
// Interface
//   Input: valid-only coefficient stream, 64 per block, in_sob framing,
//   comp_id sampled at in_sob (0,1 = luma tables, 2,3 = chroma). Blocks land
//   in a HUFF_BANKS-deep ring; the producer must keep at most HUFF_BANKS
//   blocks in flight (the top level's credit counter enforces this), since
//   the ring accepts unconditionally. restart is a single-cycle request,
//   applied when the next block starts. Output: one code word per symbol,
//   MSB-aligned in out_bits with length out_len, out_sob on each block's DC
//   word, out_eob on its final word, valid/ready handshake.
//
// Contract
//   One symbol per accepted output word per clock: a dense 64-coefficient
//   block completes in at most 68 clocks with the output unstalled, and zero
//   coefficients cost no cycles (the scanner steps directly between nonzero
//   coefficients using a per-block occupancy mask). A block's first word is
//   never offered earlier than two clocks after the previous block's final
//   word is accepted, which keeps restart requests — which arrive relative
//   to accepted final words — ordered ahead of the next block's coding.
//
// Position
//   Encoder coefficient path:
//   input_buffer → dct_2d → quantizer → zigzag_reorder →
//   [huffman_encoder] → bitstream_packer → jfif_writer
// -----------------------------------------------------------------------------

module huffman_encoder #(
    parameter HUFF_BANKS = 4    // block ring depth; must equal the top-level
                                // in-flight cap so the ring cannot overflow
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  comp_id,
    input  wire        restart,
    input  wire        in_valid,
    input  wire signed [15:0] in_data,
    input  wire        in_sob,
    output reg         out_valid,
    output reg  [31:0] out_bits,
    output reg  [5:0]  out_len,
    output reg         out_sob,
    output reg         out_eob,
    input  wire        out_ready
);

    // ========================================================================
    // Code tables — ITU-T T.81 Annex K.3.3, as constant functions
    // ({length, left-aligned code}). Function form keeps the tables pure
    // combinational data for synthesis.
    // ========================================================================
    /* verilator coverage_off */
    function [19:0] dc_luma_lookup;
        input [3:0] category;
        case (category)
            4'd0:  dc_luma_lookup = {4'd2,  16'b00_00000000000000};
            4'd1:  dc_luma_lookup = {4'd3,  16'b010_0000000000000};
            4'd2:  dc_luma_lookup = {4'd3,  16'b011_0000000000000};
            4'd3:  dc_luma_lookup = {4'd3,  16'b100_0000000000000};
            4'd4:  dc_luma_lookup = {4'd3,  16'b101_0000000000000};
            4'd5:  dc_luma_lookup = {4'd3,  16'b110_0000000000000};
            4'd6:  dc_luma_lookup = {4'd4,  16'b1110_000000000000};
            4'd7:  dc_luma_lookup = {4'd5,  16'b11110_00000000000};
            4'd8:  dc_luma_lookup = {4'd6,  16'b111110_0000000000};
            4'd9:  dc_luma_lookup = {4'd7,  16'b1111110_000000000};
            4'd10: dc_luma_lookup = {4'd8,  16'b11111110_00000000};
            4'd11: dc_luma_lookup = {4'd9,  16'b111111110_0000000};
            default: dc_luma_lookup = {4'd2, 16'b00_00000000000000};
        endcase
    endfunction

    function [19:0] dc_chroma_lookup;
        input [3:0] category;
        case (category)
            4'd0:  dc_chroma_lookup = {4'd2,  16'b00_00000000000000};
            4'd1:  dc_chroma_lookup = {4'd2,  16'b01_00000000000000};
            4'd2:  dc_chroma_lookup = {4'd2,  16'b10_00000000000000};
            4'd3:  dc_chroma_lookup = {4'd3,  16'b110_0000000000000};
            4'd4:  dc_chroma_lookup = {4'd4,  16'b1110_000000000000};
            4'd5:  dc_chroma_lookup = {4'd5,  16'b11110_00000000000};
            4'd6:  dc_chroma_lookup = {4'd6,  16'b111110_0000000000};
            4'd7:  dc_chroma_lookup = {4'd7,  16'b1111110_000000000};
            4'd8:  dc_chroma_lookup = {4'd8,  16'b11111110_00000000};
            4'd9:  dc_chroma_lookup = {4'd9,  16'b111111110_0000000};
            4'd10: dc_chroma_lookup = {4'd10, 16'b1111111110_000000};
            4'd11: dc_chroma_lookup = {4'd11, 16'b11111111110_00000};
            default: dc_chroma_lookup = {4'd2, 16'b00_00000000000000};
        endcase
    endfunction

    // ========================================================================
    // AC Huffman table functions (combinatorial — avoids Vivado initial-block
    // synthesis failures that corrupt reg-array ROM initialization)
    // ========================================================================
    function [20:0] ac_luma_lookup;
        input [7:0] sym;
        begin
            case (sym)
                8'h00: ac_luma_lookup = {5'd4,  16'b1010000000000000};
                8'h01: ac_luma_lookup = {5'd2,  16'b0000000000000000};
                8'h02: ac_luma_lookup = {5'd2,  16'b0100000000000000};
                8'h03: ac_luma_lookup = {5'd3,  16'b1000000000000000};
                8'h04: ac_luma_lookup = {5'd4,  16'b1011000000000000};
                8'h05: ac_luma_lookup = {5'd5,  16'b1101000000000000};
                8'h06: ac_luma_lookup = {5'd7,  16'b1111000000000000};
                8'h07: ac_luma_lookup = {5'd8,  16'b1111100000000000};
                8'h08: ac_luma_lookup = {5'd10, 16'b1111110110000000};
                8'h09: ac_luma_lookup = {5'd16, 16'b1111111110000010};
                8'h0A: ac_luma_lookup = {5'd16, 16'b1111111110000011};
                8'h11: ac_luma_lookup = {5'd4,  16'b1100000000000000};
                8'h12: ac_luma_lookup = {5'd5,  16'b1101100000000000};
                8'h13: ac_luma_lookup = {5'd7,  16'b1111001000000000};
                8'h14: ac_luma_lookup = {5'd9,  16'b1111101100000000};
                8'h15: ac_luma_lookup = {5'd11, 16'b1111111011000000};
                8'h16: ac_luma_lookup = {5'd16, 16'b1111111110000100};
                8'h17: ac_luma_lookup = {5'd16, 16'b1111111110000101};
                8'h18: ac_luma_lookup = {5'd16, 16'b1111111110000110};
                8'h19: ac_luma_lookup = {5'd16, 16'b1111111110000111};
                8'h1A: ac_luma_lookup = {5'd16, 16'b1111111110001000};
                8'h21: ac_luma_lookup = {5'd5,  16'b1110000000000000};
                8'h22: ac_luma_lookup = {5'd8,  16'b1111100100000000};
                8'h23: ac_luma_lookup = {5'd10, 16'b1111110111000000};
                8'h24: ac_luma_lookup = {5'd12, 16'b1111111101000000};
                8'h25: ac_luma_lookup = {5'd16, 16'b1111111110001001};
                8'h26: ac_luma_lookup = {5'd16, 16'b1111111110001010};
                8'h27: ac_luma_lookup = {5'd16, 16'b1111111110001011};
                8'h28: ac_luma_lookup = {5'd16, 16'b1111111110001100};
                8'h29: ac_luma_lookup = {5'd16, 16'b1111111110001101};
                8'h2A: ac_luma_lookup = {5'd16, 16'b1111111110001110};
                8'h31: ac_luma_lookup = {5'd6,  16'b1110100000000000};
                8'h32: ac_luma_lookup = {5'd9,  16'b1111101110000000};
                8'h33: ac_luma_lookup = {5'd12, 16'b1111111101010000};
                8'h34: ac_luma_lookup = {5'd16, 16'b1111111110001111};
                8'h35: ac_luma_lookup = {5'd16, 16'b1111111110010000};
                8'h36: ac_luma_lookup = {5'd16, 16'b1111111110010001};
                8'h37: ac_luma_lookup = {5'd16, 16'b1111111110010010};
                8'h38: ac_luma_lookup = {5'd16, 16'b1111111110010011};
                8'h39: ac_luma_lookup = {5'd16, 16'b1111111110010100};
                8'h3A: ac_luma_lookup = {5'd16, 16'b1111111110010101};
                8'h41: ac_luma_lookup = {5'd6,  16'b1110110000000000};
                8'h42: ac_luma_lookup = {5'd10, 16'b1111111000000000};
                8'h43: ac_luma_lookup = {5'd16, 16'b1111111110010110};
                8'h44: ac_luma_lookup = {5'd16, 16'b1111111110010111};
                8'h45: ac_luma_lookup = {5'd16, 16'b1111111110011000};
                8'h46: ac_luma_lookup = {5'd16, 16'b1111111110011001};
                8'h47: ac_luma_lookup = {5'd16, 16'b1111111110011010};
                8'h48: ac_luma_lookup = {5'd16, 16'b1111111110011011};
                8'h49: ac_luma_lookup = {5'd16, 16'b1111111110011100};
                8'h4A: ac_luma_lookup = {5'd16, 16'b1111111110011101};
                8'h51: ac_luma_lookup = {5'd7,  16'b1111010000000000};
                8'h52: ac_luma_lookup = {5'd11, 16'b1111111011100000};
                8'h53: ac_luma_lookup = {5'd16, 16'b1111111110011110};
                8'h54: ac_luma_lookup = {5'd16, 16'b1111111110011111};
                8'h55: ac_luma_lookup = {5'd16, 16'b1111111110100000};
                8'h56: ac_luma_lookup = {5'd16, 16'b1111111110100001};
                8'h57: ac_luma_lookup = {5'd16, 16'b1111111110100010};
                8'h58: ac_luma_lookup = {5'd16, 16'b1111111110100011};
                8'h59: ac_luma_lookup = {5'd16, 16'b1111111110100100};
                8'h5A: ac_luma_lookup = {5'd16, 16'b1111111110100101};
                8'h61: ac_luma_lookup = {5'd7,  16'b1111011000000000};
                8'h62: ac_luma_lookup = {5'd12, 16'b1111111101100000};
                8'h63: ac_luma_lookup = {5'd16, 16'b1111111110100110};
                8'h64: ac_luma_lookup = {5'd16, 16'b1111111110100111};
                8'h65: ac_luma_lookup = {5'd16, 16'b1111111110101000};
                8'h66: ac_luma_lookup = {5'd16, 16'b1111111110101001};
                8'h67: ac_luma_lookup = {5'd16, 16'b1111111110101010};
                8'h68: ac_luma_lookup = {5'd16, 16'b1111111110101011};
                8'h69: ac_luma_lookup = {5'd16, 16'b1111111110101100};
                8'h6A: ac_luma_lookup = {5'd16, 16'b1111111110101101};
                8'h71: ac_luma_lookup = {5'd8,  16'b1111101000000000};
                8'h72: ac_luma_lookup = {5'd12, 16'b1111111101110000};
                8'h73: ac_luma_lookup = {5'd16, 16'b1111111110101110};
                8'h74: ac_luma_lookup = {5'd16, 16'b1111111110101111};
                8'h75: ac_luma_lookup = {5'd16, 16'b1111111110110000};
                8'h76: ac_luma_lookup = {5'd16, 16'b1111111110110001};
                8'h77: ac_luma_lookup = {5'd16, 16'b1111111110110010};
                8'h78: ac_luma_lookup = {5'd16, 16'b1111111110110011};
                8'h79: ac_luma_lookup = {5'd16, 16'b1111111110110100};
                8'h7A: ac_luma_lookup = {5'd16, 16'b1111111110110101};
                8'h81: ac_luma_lookup = {5'd9,  16'b1111110000000000};
                8'h82: ac_luma_lookup = {5'd15, 16'b1111111110000000};
                8'h83: ac_luma_lookup = {5'd16, 16'b1111111110110110};
                8'h84: ac_luma_lookup = {5'd16, 16'b1111111110110111};
                8'h85: ac_luma_lookup = {5'd16, 16'b1111111110111000};
                8'h86: ac_luma_lookup = {5'd16, 16'b1111111110111001};
                8'h87: ac_luma_lookup = {5'd16, 16'b1111111110111010};
                8'h88: ac_luma_lookup = {5'd16, 16'b1111111110111011};
                8'h89: ac_luma_lookup = {5'd16, 16'b1111111110111100};
                8'h8A: ac_luma_lookup = {5'd16, 16'b1111111110111101};
                8'h91: ac_luma_lookup = {5'd9,  16'b1111110010000000};
                8'h92: ac_luma_lookup = {5'd16, 16'b1111111110111110};
                8'h93: ac_luma_lookup = {5'd16, 16'b1111111110111111};
                8'h94: ac_luma_lookup = {5'd16, 16'b1111111111000000};
                8'h95: ac_luma_lookup = {5'd16, 16'b1111111111000001};
                8'h96: ac_luma_lookup = {5'd16, 16'b1111111111000010};
                8'h97: ac_luma_lookup = {5'd16, 16'b1111111111000011};
                8'h98: ac_luma_lookup = {5'd16, 16'b1111111111000100};
                8'h99: ac_luma_lookup = {5'd16, 16'b1111111111000101};
                8'h9A: ac_luma_lookup = {5'd16, 16'b1111111111000110};
                8'hA1: ac_luma_lookup = {5'd9,  16'b1111110100000000};
                8'hA2: ac_luma_lookup = {5'd16, 16'b1111111111000111};
                8'hA3: ac_luma_lookup = {5'd16, 16'b1111111111001000};
                8'hA4: ac_luma_lookup = {5'd16, 16'b1111111111001001};
                8'hA5: ac_luma_lookup = {5'd16, 16'b1111111111001010};
                8'hA6: ac_luma_lookup = {5'd16, 16'b1111111111001011};
                8'hA7: ac_luma_lookup = {5'd16, 16'b1111111111001100};
                8'hA8: ac_luma_lookup = {5'd16, 16'b1111111111001101};
                8'hA9: ac_luma_lookup = {5'd16, 16'b1111111111001110};
                8'hAA: ac_luma_lookup = {5'd16, 16'b1111111111001111};
                8'hB1: ac_luma_lookup = {5'd10, 16'b1111111001000000};
                8'hB2: ac_luma_lookup = {5'd16, 16'b1111111111010000};
                8'hB3: ac_luma_lookup = {5'd16, 16'b1111111111010001};
                8'hB4: ac_luma_lookup = {5'd16, 16'b1111111111010010};
                8'hB5: ac_luma_lookup = {5'd16, 16'b1111111111010011};
                8'hB6: ac_luma_lookup = {5'd16, 16'b1111111111010100};
                8'hB7: ac_luma_lookup = {5'd16, 16'b1111111111010101};
                8'hB8: ac_luma_lookup = {5'd16, 16'b1111111111010110};
                8'hB9: ac_luma_lookup = {5'd16, 16'b1111111111010111};
                8'hBA: ac_luma_lookup = {5'd16, 16'b1111111111011000};
                8'hC1: ac_luma_lookup = {5'd10, 16'b1111111010000000};
                8'hC2: ac_luma_lookup = {5'd16, 16'b1111111111011001};
                8'hC3: ac_luma_lookup = {5'd16, 16'b1111111111011010};
                8'hC4: ac_luma_lookup = {5'd16, 16'b1111111111011011};
                8'hC5: ac_luma_lookup = {5'd16, 16'b1111111111011100};
                8'hC6: ac_luma_lookup = {5'd16, 16'b1111111111011101};
                8'hC7: ac_luma_lookup = {5'd16, 16'b1111111111011110};
                8'hC8: ac_luma_lookup = {5'd16, 16'b1111111111011111};
                8'hC9: ac_luma_lookup = {5'd16, 16'b1111111111100000};
                8'hCA: ac_luma_lookup = {5'd16, 16'b1111111111100001};
                8'hD1: ac_luma_lookup = {5'd11, 16'b1111111100000000};
                8'hD2: ac_luma_lookup = {5'd16, 16'b1111111111100010};
                8'hD3: ac_luma_lookup = {5'd16, 16'b1111111111100011};
                8'hD4: ac_luma_lookup = {5'd16, 16'b1111111111100100};
                8'hD5: ac_luma_lookup = {5'd16, 16'b1111111111100101};
                8'hD6: ac_luma_lookup = {5'd16, 16'b1111111111100110};
                8'hD7: ac_luma_lookup = {5'd16, 16'b1111111111100111};
                8'hD8: ac_luma_lookup = {5'd16, 16'b1111111111101000};
                8'hD9: ac_luma_lookup = {5'd16, 16'b1111111111101001};
                8'hDA: ac_luma_lookup = {5'd16, 16'b1111111111101010};
                8'hE1: ac_luma_lookup = {5'd16, 16'b1111111111101011};
                8'hE2: ac_luma_lookup = {5'd16, 16'b1111111111101100};
                8'hE3: ac_luma_lookup = {5'd16, 16'b1111111111101101};
                8'hE4: ac_luma_lookup = {5'd16, 16'b1111111111101110};
                8'hE5: ac_luma_lookup = {5'd16, 16'b1111111111101111};
                8'hE6: ac_luma_lookup = {5'd16, 16'b1111111111110000};
                8'hE7: ac_luma_lookup = {5'd16, 16'b1111111111110001};
                8'hE8: ac_luma_lookup = {5'd16, 16'b1111111111110010};
                8'hE9: ac_luma_lookup = {5'd16, 16'b1111111111110011};
                8'hEA: ac_luma_lookup = {5'd16, 16'b1111111111110100};
                8'hF0: ac_luma_lookup = {5'd11, 16'b1111111100100000};
                8'hF1: ac_luma_lookup = {5'd16, 16'b1111111111110101};
                8'hF2: ac_luma_lookup = {5'd16, 16'b1111111111110110};
                8'hF3: ac_luma_lookup = {5'd16, 16'b1111111111110111};
                8'hF4: ac_luma_lookup = {5'd16, 16'b1111111111111000};
                8'hF5: ac_luma_lookup = {5'd16, 16'b1111111111111001};
                8'hF6: ac_luma_lookup = {5'd16, 16'b1111111111111010};
                8'hF7: ac_luma_lookup = {5'd16, 16'b1111111111111011};
                8'hF8: ac_luma_lookup = {5'd16, 16'b1111111111111100};
                8'hF9: ac_luma_lookup = {5'd16, 16'b1111111111111101};
                8'hFA: ac_luma_lookup = {5'd16, 16'b1111111111111110};
                default: ac_luma_lookup = 21'd0;
            endcase
        end
    endfunction

    function [20:0] ac_chroma_lookup;
        input [7:0] sym;
        begin
            case (sym)
                8'h00: ac_chroma_lookup = {5'd2,  16'b0000000000000000};
                8'h01: ac_chroma_lookup = {5'd2,  16'b0100000000000000};
                8'h02: ac_chroma_lookup = {5'd3,  16'b1000000000000000};
                8'h03: ac_chroma_lookup = {5'd4,  16'b1010000000000000};
                8'h04: ac_chroma_lookup = {5'd5,  16'b1100000000000000};
                8'h05: ac_chroma_lookup = {5'd5,  16'b1100100000000000};
                8'h06: ac_chroma_lookup = {5'd6,  16'b1110000000000000};
                8'h07: ac_chroma_lookup = {5'd7,  16'b1111000000000000};
                8'h08: ac_chroma_lookup = {5'd9,  16'b1111101000000000};
                8'h09: ac_chroma_lookup = {5'd10, 16'b1111110110000000};
                8'h0A: ac_chroma_lookup = {5'd12, 16'b1111111101000000};
                8'h11: ac_chroma_lookup = {5'd4,  16'b1011000000000000};
                8'h12: ac_chroma_lookup = {5'd6,  16'b1110010000000000};
                8'h13: ac_chroma_lookup = {5'd8,  16'b1111011000000000};
                8'h14: ac_chroma_lookup = {5'd9,  16'b1111101010000000};
                8'h15: ac_chroma_lookup = {5'd11, 16'b1111111011000000};
                8'h16: ac_chroma_lookup = {5'd12, 16'b1111111101010000};
                8'h17: ac_chroma_lookup = {5'd16, 16'b1111111110001000};
                8'h18: ac_chroma_lookup = {5'd16, 16'b1111111110001001};
                8'h19: ac_chroma_lookup = {5'd16, 16'b1111111110001010};
                8'h1A: ac_chroma_lookup = {5'd16, 16'b1111111110001011};
                8'h21: ac_chroma_lookup = {5'd5,  16'b1101000000000000};
                8'h22: ac_chroma_lookup = {5'd8,  16'b1111011100000000};
                8'h23: ac_chroma_lookup = {5'd10, 16'b1111110111000000};
                8'h24: ac_chroma_lookup = {5'd12, 16'b1111111101100000};
                8'h25: ac_chroma_lookup = {5'd15, 16'b1111111110000100};
                8'h26: ac_chroma_lookup = {5'd16, 16'b1111111110001100};
                8'h27: ac_chroma_lookup = {5'd16, 16'b1111111110001101};
                8'h28: ac_chroma_lookup = {5'd16, 16'b1111111110001110};
                8'h29: ac_chroma_lookup = {5'd16, 16'b1111111110001111};
                8'h2A: ac_chroma_lookup = {5'd16, 16'b1111111110010000};
                8'h31: ac_chroma_lookup = {5'd5,  16'b1101100000000000};
                8'h32: ac_chroma_lookup = {5'd8,  16'b1111100000000000};
                8'h33: ac_chroma_lookup = {5'd10, 16'b1111111000000000};
                8'h34: ac_chroma_lookup = {5'd12, 16'b1111111101110000};
                8'h35: ac_chroma_lookup = {5'd16, 16'b1111111110010001};
                8'h36: ac_chroma_lookup = {5'd16, 16'b1111111110010010};
                8'h37: ac_chroma_lookup = {5'd16, 16'b1111111110010011};
                8'h38: ac_chroma_lookup = {5'd16, 16'b1111111110010100};
                8'h39: ac_chroma_lookup = {5'd16, 16'b1111111110010101};
                8'h3A: ac_chroma_lookup = {5'd16, 16'b1111111110010110};
                8'h41: ac_chroma_lookup = {5'd6,  16'b1110100000000000};
                8'h42: ac_chroma_lookup = {5'd9,  16'b1111101100000000};
                8'h43: ac_chroma_lookup = {5'd16, 16'b1111111110010111};
                8'h44: ac_chroma_lookup = {5'd16, 16'b1111111110011000};
                8'h45: ac_chroma_lookup = {5'd16, 16'b1111111110011001};
                8'h46: ac_chroma_lookup = {5'd16, 16'b1111111110011010};
                8'h47: ac_chroma_lookup = {5'd16, 16'b1111111110011011};
                8'h48: ac_chroma_lookup = {5'd16, 16'b1111111110011100};
                8'h49: ac_chroma_lookup = {5'd16, 16'b1111111110011101};
                8'h4A: ac_chroma_lookup = {5'd16, 16'b1111111110011110};
                8'h51: ac_chroma_lookup = {5'd6,  16'b1110110000000000};
                8'h52: ac_chroma_lookup = {5'd10, 16'b1111111001000000};
                8'h53: ac_chroma_lookup = {5'd16, 16'b1111111110011111};
                8'h54: ac_chroma_lookup = {5'd16, 16'b1111111110100000};
                8'h55: ac_chroma_lookup = {5'd16, 16'b1111111110100001};
                8'h56: ac_chroma_lookup = {5'd16, 16'b1111111110100010};
                8'h57: ac_chroma_lookup = {5'd16, 16'b1111111110100011};
                8'h58: ac_chroma_lookup = {5'd16, 16'b1111111110100100};
                8'h59: ac_chroma_lookup = {5'd16, 16'b1111111110100101};
                8'h5A: ac_chroma_lookup = {5'd16, 16'b1111111110100110};
                8'h61: ac_chroma_lookup = {5'd7,  16'b1111001000000000};
                8'h62: ac_chroma_lookup = {5'd11, 16'b1111111011100000};
                8'h63: ac_chroma_lookup = {5'd16, 16'b1111111110100111};
                8'h64: ac_chroma_lookup = {5'd16, 16'b1111111110101000};
                8'h65: ac_chroma_lookup = {5'd16, 16'b1111111110101001};
                8'h66: ac_chroma_lookup = {5'd16, 16'b1111111110101010};
                8'h67: ac_chroma_lookup = {5'd16, 16'b1111111110101011};
                8'h68: ac_chroma_lookup = {5'd16, 16'b1111111110101100};
                8'h69: ac_chroma_lookup = {5'd16, 16'b1111111110101101};
                8'h6A: ac_chroma_lookup = {5'd16, 16'b1111111110101110};
                8'h71: ac_chroma_lookup = {5'd7,  16'b1111010000000000};
                8'h72: ac_chroma_lookup = {5'd11, 16'b1111111100000000};
                8'h73: ac_chroma_lookup = {5'd16, 16'b1111111110101111};
                8'h74: ac_chroma_lookup = {5'd16, 16'b1111111110110000};
                8'h75: ac_chroma_lookup = {5'd16, 16'b1111111110110001};
                8'h76: ac_chroma_lookup = {5'd16, 16'b1111111110110010};
                8'h77: ac_chroma_lookup = {5'd16, 16'b1111111110110011};
                8'h78: ac_chroma_lookup = {5'd16, 16'b1111111110110100};
                8'h79: ac_chroma_lookup = {5'd16, 16'b1111111110110101};
                8'h7A: ac_chroma_lookup = {5'd16, 16'b1111111110110110};
                8'h81: ac_chroma_lookup = {5'd8,  16'b1111100100000000};
                8'h82: ac_chroma_lookup = {5'd16, 16'b1111111110110111};
                8'h83: ac_chroma_lookup = {5'd16, 16'b1111111110111000};
                8'h84: ac_chroma_lookup = {5'd16, 16'b1111111110111001};
                8'h85: ac_chroma_lookup = {5'd16, 16'b1111111110111010};
                8'h86: ac_chroma_lookup = {5'd16, 16'b1111111110111011};
                8'h87: ac_chroma_lookup = {5'd16, 16'b1111111110111100};
                8'h88: ac_chroma_lookup = {5'd16, 16'b1111111110111101};
                8'h89: ac_chroma_lookup = {5'd16, 16'b1111111110111110};
                8'h8A: ac_chroma_lookup = {5'd16, 16'b1111111110111111};
                8'h91: ac_chroma_lookup = {5'd9,  16'b1111101110000000};
                8'h92: ac_chroma_lookup = {5'd16, 16'b1111111111000000};
                8'h93: ac_chroma_lookup = {5'd16, 16'b1111111111000001};
                8'h94: ac_chroma_lookup = {5'd16, 16'b1111111111000010};
                8'h95: ac_chroma_lookup = {5'd16, 16'b1111111111000011};
                8'h96: ac_chroma_lookup = {5'd16, 16'b1111111111000100};
                8'h97: ac_chroma_lookup = {5'd16, 16'b1111111111000101};
                8'h98: ac_chroma_lookup = {5'd16, 16'b1111111111000110};
                8'h99: ac_chroma_lookup = {5'd16, 16'b1111111111000111};
                8'h9A: ac_chroma_lookup = {5'd16, 16'b1111111111001000};
                8'hA1: ac_chroma_lookup = {5'd9,  16'b1111110000000000};
                8'hA2: ac_chroma_lookup = {5'd16, 16'b1111111111001001};
                8'hA3: ac_chroma_lookup = {5'd16, 16'b1111111111001010};
                8'hA4: ac_chroma_lookup = {5'd16, 16'b1111111111001011};
                8'hA5: ac_chroma_lookup = {5'd16, 16'b1111111111001100};
                8'hA6: ac_chroma_lookup = {5'd16, 16'b1111111111001101};
                8'hA7: ac_chroma_lookup = {5'd16, 16'b1111111111001110};
                8'hA8: ac_chroma_lookup = {5'd16, 16'b1111111111001111};
                8'hA9: ac_chroma_lookup = {5'd16, 16'b1111111111010000};
                8'hAA: ac_chroma_lookup = {5'd16, 16'b1111111111010001};
                8'hB1: ac_chroma_lookup = {5'd9,  16'b1111110010000000};
                8'hB2: ac_chroma_lookup = {5'd16, 16'b1111111111010010};
                8'hB3: ac_chroma_lookup = {5'd16, 16'b1111111111010011};
                8'hB4: ac_chroma_lookup = {5'd16, 16'b1111111111010100};
                8'hB5: ac_chroma_lookup = {5'd16, 16'b1111111111010101};
                8'hB6: ac_chroma_lookup = {5'd16, 16'b1111111111010110};
                8'hB7: ac_chroma_lookup = {5'd16, 16'b1111111111010111};
                8'hB8: ac_chroma_lookup = {5'd16, 16'b1111111111011000};
                8'hB9: ac_chroma_lookup = {5'd16, 16'b1111111111011001};
                8'hBA: ac_chroma_lookup = {5'd16, 16'b1111111111011010};
                8'hC1: ac_chroma_lookup = {5'd9,  16'b1111110100000000};
                8'hC2: ac_chroma_lookup = {5'd16, 16'b1111111111011011};
                8'hC3: ac_chroma_lookup = {5'd16, 16'b1111111111011100};
                8'hC4: ac_chroma_lookup = {5'd16, 16'b1111111111011101};
                8'hC5: ac_chroma_lookup = {5'd16, 16'b1111111111011110};
                8'hC6: ac_chroma_lookup = {5'd16, 16'b1111111111011111};
                8'hC7: ac_chroma_lookup = {5'd16, 16'b1111111111100000};
                8'hC8: ac_chroma_lookup = {5'd16, 16'b1111111111100001};
                8'hC9: ac_chroma_lookup = {5'd16, 16'b1111111111100010};
                8'hCA: ac_chroma_lookup = {5'd16, 16'b1111111111100011};
                8'hD1: ac_chroma_lookup = {5'd11, 16'b1111111100100000};
                8'hD2: ac_chroma_lookup = {5'd16, 16'b1111111111100100};
                8'hD3: ac_chroma_lookup = {5'd16, 16'b1111111111100101};
                8'hD4: ac_chroma_lookup = {5'd16, 16'b1111111111100110};
                8'hD5: ac_chroma_lookup = {5'd16, 16'b1111111111100111};
                8'hD6: ac_chroma_lookup = {5'd16, 16'b1111111111101000};
                8'hD7: ac_chroma_lookup = {5'd16, 16'b1111111111101001};
                8'hD8: ac_chroma_lookup = {5'd16, 16'b1111111111101010};
                8'hD9: ac_chroma_lookup = {5'd16, 16'b1111111111101011};
                8'hDA: ac_chroma_lookup = {5'd16, 16'b1111111111101100};
                8'hE1: ac_chroma_lookup = {5'd14, 16'b1111111110000000};
                8'hE2: ac_chroma_lookup = {5'd16, 16'b1111111111101101};
                8'hE3: ac_chroma_lookup = {5'd16, 16'b1111111111101110};
                8'hE4: ac_chroma_lookup = {5'd16, 16'b1111111111101111};
                8'hE5: ac_chroma_lookup = {5'd16, 16'b1111111111110000};
                8'hE6: ac_chroma_lookup = {5'd16, 16'b1111111111110001};
                8'hE7: ac_chroma_lookup = {5'd16, 16'b1111111111110010};
                8'hE8: ac_chroma_lookup = {5'd16, 16'b1111111111110011};
                8'hE9: ac_chroma_lookup = {5'd16, 16'b1111111111110100};
                8'hEA: ac_chroma_lookup = {5'd16, 16'b1111111111110101};
                8'hF0: ac_chroma_lookup = {5'd10, 16'b1111111010000000};
                8'hF1: ac_chroma_lookup = {5'd15, 16'b1111111110000110};
                8'hF2: ac_chroma_lookup = {5'd16, 16'b1111111111110110};
                8'hF3: ac_chroma_lookup = {5'd16, 16'b1111111111110111};
                8'hF4: ac_chroma_lookup = {5'd16, 16'b1111111111111000};
                8'hF5: ac_chroma_lookup = {5'd16, 16'b1111111111111001};
                8'hF6: ac_chroma_lookup = {5'd16, 16'b1111111111111010};
                8'hF7: ac_chroma_lookup = {5'd16, 16'b1111111111111011};
                8'hF8: ac_chroma_lookup = {5'd16, 16'b1111111111111100};
                8'hF9: ac_chroma_lookup = {5'd16, 16'b1111111111111101};
                8'hFA: ac_chroma_lookup = {5'd16, 16'b1111111111111110};
                default: ac_chroma_lookup = 21'd0;
            endcase
        end
    endfunction
    /* verilator coverage_on */

    // category_of(m) = number of significant bits of the magnitude m: the
    // T.81 size category (SSSS), 0..11.
    function [3:0] category_of;
        input [10:0] mag;
        begin
            if      (mag[10]) category_of = 4'd11;
            else if (mag[9])  category_of = 4'd10;
            else if (mag[8])  category_of = 4'd9;
            else if (mag[7])  category_of = 4'd8;
            else if (mag[6])  category_of = 4'd7;
            else if (mag[5])  category_of = 4'd6;
            else if (mag[4])  category_of = 4'd5;
            else if (mag[3])  category_of = 4'd4;
            else if (mag[2])  category_of = 4'd3;
            else if (mag[1])  category_of = 4'd2;
            else if (mag[0])  category_of = 4'd1;
            else              category_of = 4'd0;
        end
    endfunction

    // Index of the lowest set bit (only called with v != 0).
    function [5:0] ffs64;
        input [63:0] v;
        integer i;
        begin
            ffs64 = 6'd0;
            for (i = 63; i >= 0; i = i - 1)
                if (v[i]) ffs64 = i[5:0];
        end
    endfunction

    // ========================================================================
    // Block ring: HUFF_BANKS banks of 64 coefficients, plus per-bank
    // component id and a 64-bit occupancy mask (bit i set = AC coefficient i
    // is nonzero; bit 0, the DC position, is always clear). wr_count and
    // rd_count are one bit wider than the bank index so occupancy is their
    // difference.
    // ========================================================================
    localparam [3:0] NB = HUFF_BANKS[3:0];
    localparam BW = (NB <= 4'd2) ? 1 : (NB <= 4'd4) ? 2 : 3;

    // The bank index is wr_count[BW-1:0], a power-of-two wrap, and the bank
    // arrays hold exactly NB entries: any other depth would index past them.
    // Instantiating an undefined module makes elaboration fail loudly.
    generate if (HUFF_BANKS != 2 && HUFF_BANKS != 4 && HUFF_BANKS != 8)
        begin : g_huff_banks_check
            HUFF_BANKS_must_be_2_4_or_8 illegal_huff_banks_value();
        end
    endgenerate

    (* ram_style = "distributed" *) reg signed [15:0] coeff_buf [0:NB*64-1];

    reg [5:0]    wr_idx;
    reg [1:0]    wr_comp;
    reg [62:1]   wr_mask;
    reg [BW:0]   wr_count;
    reg [BW:0]   rd_count;
    reg [1:0]    bank_comp [0:NB-1];
    reg [63:1]   bank_mask [0:NB-1];

    wire [BW-1:0] wr_bank = wr_count[BW-1:0];
    wire [BW-1:0] rd_bank = rd_count[BW-1:0];
    wire [BW:0]   occ     = wr_count - rd_count;

    wire [BW+5:0] wr_addr = {wr_bank, in_sob ? 6'd0 : wr_idx};

    always @(posedge clk) begin
        if (!rst_n) begin
            wr_idx   <= 6'd0;
            wr_count <= {(BW+1){1'b0}};
        end else if (in_valid) begin
            coeff_buf[wr_addr] <= in_data;
            if (in_sob) begin
                wr_idx  <= 6'd1;
                wr_comp <= comp_id;
                wr_mask <= 62'd0;
            end else begin
                if (wr_idx != 6'd63)
                    wr_mask[wr_idx] <= (in_data != 16'd0);
                if (wr_idx == 6'd63) begin
                    bank_comp[wr_bank] <= wr_comp;
                    bank_mask[wr_bank] <= {(in_data != 16'd0), wr_mask[62:1]};
                    wr_count           <= wr_count + 1'b1;
                    wr_idx             <= 6'd0;
                end else begin
                    wr_idx <= wr_idx + 6'd1;
                end
            end
        end
    end

    // ========================================================================
    // Symbol scanner: pops a block, produces one symbol per clock.
    // DC is produced in the pop cycle; each following cycle either codes the
    // next nonzero coefficient (clearing its mask bit), splits off a ZRL for
    // a 16+ zero gap, or closes the block with EOB. ZRL and EOB are AC
    // symbols (run 15, size 0) and (run 0, size 0), so one encode path
    // serves all four symbol kinds.
    // ========================================================================
    reg               blk_active;   // pop() .. final word accepted
    reg               scanning;     // symbols still to produce
    reg               blk_luma;
    reg [BW-1:0]      blk_bank;
    reg [63:0]        mask_rem;     // nonzero ACs not yet coded
    reg               need_eob;     // coefficient 63 is zero
    reg [5:0]         cursor;       // next uncoded coefficient position
    reg               restart_pending;

    reg signed [15:0] prev_dc_y, prev_dc_cb, prev_dc_cr;

    // Symbol register (stage S), then encode register (stage E), then the
    // output register. Each stage loads when the one after it can accept.
    reg               s_valid;
    reg               s_is_dc;
    reg [3:0]         s_run;
    reg               s_sign;
    reg [10:0]        s_low;
    reg               s_sob, s_eob, s_luma;

    reg               e_valid;
    reg [15:0]        e_code;
    reg [4:0]         e_len;
    reg [3:0]         e_cat;
    reg [10:0]        e_vbits;
    reg               e_sob, e_eob;

    wire out_take = !out_valid || out_ready;   // output register can load
    wire e_take   = !e_valid || out_take;      // stage E can load
    wire s_take   = !s_valid || e_take;        // stage S can load

    // Pop-cycle DC values, read asynchronously from the bank.
    wire signed [15:0] dc_coeff = coeff_buf[{rd_bank, 6'd0}];
    wire [1:0]  pop_comp = bank_comp[rd_bank];
    wire signed [15:0] pop_pred =
        restart_pending          ? 16'sd0     :
        (pop_comp <= 2'd1)       ? prev_dc_y  :
        (pop_comp == 2'd2)       ? prev_dc_cb : prev_dc_cr;

    // Quantized coefficients and DC differences span at most +/-2047 (T.81
    // size category <= 11), so bits 14:11 duplicate the sign bit and only
    // the sign and low 11 bits enter the encoding math.
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [15:0] dc_diff = dc_coeff - pop_pred;
    /* verilator lint_on UNUSEDSIGNAL */

    wire do_pop = !blk_active && (occ != {(BW+1){1'b0}}) && s_take;

    // Scan-cycle values.
    wire [5:0] nz_next = ffs64(mask_rem);
    wire [5:0] gap     = nz_next - cursor;
    wire       is_zrl  = (gap >= 6'd16);
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [15:0] ac_coeff = coeff_buf[{blk_bank, nz_next}];
    /* verilator lint_on UNUSEDSIGNAL */

    always @(posedge clk) begin
        if (!rst_n) begin
            blk_active      <= 1'b0;
            scanning        <= 1'b0;
            restart_pending <= 1'b0;
            rd_count        <= {(BW+1){1'b0}};
            prev_dc_y       <= 16'd0;
            prev_dc_cb      <= 16'd0;
            prev_dc_cr      <= 16'd0;
            s_valid         <= 1'b0;
        end else begin
            if (restart)
                restart_pending <= 1'b1;

            if (do_pop) begin
                // DC symbol: difference against the (possibly just reset)
                // component predictor, which then takes the new DC value.
                blk_active <= 1'b1;
                scanning   <= 1'b1;
                blk_bank   <= rd_bank;
                blk_luma   <= (pop_comp <= 2'd1);
                mask_rem   <= {bank_mask[rd_bank], 1'b0};
                need_eob   <= !bank_mask[rd_bank][63];
                cursor     <= 6'd1;
                rd_count   <= rd_count + 1'b1;

                if (restart_pending) begin
                    prev_dc_y       <= 16'd0;
                    prev_dc_cb      <= 16'd0;
                    prev_dc_cr      <= 16'd0;
                    restart_pending <= 1'b0;
                end
                if (pop_comp <= 2'd1)      prev_dc_y  <= dc_coeff;
                else if (pop_comp == 2'd2) prev_dc_cb <= dc_coeff;
                else                       prev_dc_cr <= dc_coeff;

                s_valid <= 1'b1;
                s_is_dc <= 1'b1;
                s_run   <= 4'd0;
                {s_sign, s_low} <= {dc_diff[15], dc_diff[10:0]};
                s_sob   <= 1'b1;
                s_eob   <= 1'b0;
                s_luma  <= (pop_comp <= 2'd1);
            end else if (scanning && blk_active && s_take) begin
                s_is_dc <= 1'b0;
                s_sob   <= 1'b0;
                s_luma  <= blk_luma;
                if (mask_rem != 64'd0) begin
                    s_valid <= 1'b1;
                    if (is_zrl) begin
                        s_run   <= 4'd15;              // ZRL = (15, 0)
                        {s_sign, s_low} <= 12'd0;
                        s_eob   <= 1'b0;
                        cursor  <= cursor + 6'd16;
                    end else begin
                        s_run    <= gap[3:0];
                        {s_sign, s_low} <= {ac_coeff[15], ac_coeff[10:0]};
                        s_eob    <= (nz_next == 6'd63);
                        cursor   <= nz_next + 6'd1;
                        mask_rem <= mask_rem & ~(64'd1 << nz_next);
                        if (nz_next == 6'd63 || (mask_rem & ~(64'd1 << nz_next)) == 64'd0)
                            scanning <= need_eob;      // EOB still owed, or done
                    end
                end else if (need_eob) begin
                    s_valid  <= 1'b1;
                    s_run    <= 4'd0;                  // EOB = (0, 0)
                    {s_sign, s_low} <= 12'd0;
                    s_eob    <= 1'b1;
                    need_eob <= 1'b0;
                    scanning <= 1'b0;
                end else begin
                    s_valid <= 1'b0;
                end
            end else if (s_take) begin
                s_valid <= 1'b0;
            end

            // The block is retired when its final word leaves the module;
            // only then may the next block be popped (see Contract).
            if (out_valid && out_ready && out_eob)
                blk_active <= 1'b0;
        end
    end

    // ========================================================================
    // Stage E: size category, amplitude bits, code lookup — one clock.
    // Amplitude bits per T.81 §F.1.2.1: the low SSSS bits of the value for
    // positive values, of value - 1 for negative values; the two's-
    // complement low bits of the value plus 2^SSSS - 1 equal the latter.
    // ========================================================================
    wire [10:0] s_mag = s_sign ? (-s_low) : s_low;
    wire [3:0]  s_cat = category_of(s_mag);
    wire [7:0]  s_sym = {s_run, s_cat};
    wire [19:0] s_dc_entry = s_luma ? dc_luma_lookup(s_cat)
                                    : dc_chroma_lookup(s_cat);
    wire [20:0] s_ac_entry = s_luma ? ac_luma_lookup(s_sym)
                                    : ac_chroma_lookup(s_sym);

    always @(posedge clk) begin
        if (!rst_n) begin
            e_valid <= 1'b0;
        end else if (e_take) begin
            e_valid <= s_valid;
            e_sob   <= s_sob;
            e_eob   <= s_eob;
            e_cat   <= s_cat;
            e_vbits <= s_sign
                       ? s_low + ((11'd1 << s_cat) - 11'd1)
                       : s_low;
            if (s_is_dc) begin
                e_code <= s_dc_entry[15:0];
                e_len  <= {1'b0, s_dc_entry[19:16]};
            end else begin
                e_code <= s_ac_entry[15:0];
                e_len  <= s_ac_entry[20:16];
            end
        end
    end

    // ========================================================================
    // Output register: code word MSB-aligned, amplitude bits directly after.
    // ========================================================================
    wire [5:0] e_shift = 6'd32 - {1'b0, e_len} - {2'd0, e_cat};

    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_sob   <= 1'b0;
            out_eob   <= 1'b0;
        end else if (out_take) begin
            out_valid <= e_valid;
            out_sob   <= e_valid && e_sob;
            out_eob   <= e_valid && e_eob;
            out_bits  <= {e_code, 16'd0} | ({21'd0, e_vbits} << e_shift);
            out_len   <= {1'b0, e_len} + {2'd0, e_cat};
        end
    end

endmodule
