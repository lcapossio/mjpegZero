// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// Huffman Encoder (Pipelined, Multi-cycle FSM)
// ============================================================================
// Encodes quantized, zigzag-ordered DCT coefficients using JPEG Huffman coding.
//
// Fixes and improvements over initial version:
//   - Three separate DC predictors (Y, Cb, Cr) instead of two
//   - Early EOB detection (skip trailing zeros)
//   - Restart marker support (reset DC predictors)
//   - Backpressure via out_ready handshake
//   - Double-buffered input to prevent corruption
//
// Input:  64 coefficients per block in zigzag order, 1/clock
// Output: variable-length Huffman code words with lengths
// ============================================================================

/* verilator lint_off WIDTHTRUNC */
module huffman_encoder #(
    parameter HUFF_BANKS = 4     // coefficient input-ring depth; MUST equal the top
                                 // in-flight cap (pipeline_depth < HUFF_BANKS) so the
                                 // ring can never overflow (no backpressure into zigzag)
) (
    /* verilator coverage_off */
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
    /* verilator coverage_on */
);

    // ========================================================================
    // DC Huffman table functions
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

    // ========================================================================
    // Category computation
    // ========================================================================
    function [3:0] compute_category;
        input [10:0] abs_val;
        begin
            if (abs_val[10])     compute_category = 4'd11;
            else if (abs_val[9]) compute_category = 4'd10;
            else if (abs_val[8]) compute_category = 4'd9;
            else if (abs_val[7]) compute_category = 4'd8;
            else if (abs_val[6]) compute_category = 4'd7;
            else if (abs_val[5]) compute_category = 4'd6;
            else if (abs_val[4]) compute_category = 4'd5;
            else if (abs_val[3]) compute_category = 4'd4;
            else if (abs_val[2]) compute_category = 4'd3;
            else if (abs_val[1]) compute_category = 4'd2;
            else if (abs_val[0]) compute_category = 4'd1;
            else                 compute_category = 4'd0;
        end
    endfunction
    /* verilator coverage_on */


    // Binary index of a one-hot vector (an OR tree, no priority chain).
    function [5:0] onehot_idx;
        input [63:0] oh;
        integer i;
        begin
            onehot_idx = 6'd0;
            for (i = 0; i < 64; i = i + 1)
                onehot_idx = onehot_idx | ({6{oh[i]}} & i[5:0]);
        end
    endfunction

    // Inclusive prefix OR (bit i = |x[i:0]) as a log-depth shift-OR network,
    // so the lowest-set-bit logic stays off the 64-bit carry chain.
    function [63:0] prefix_or;
        input [63:0] x;
        begin
            prefix_or = x;
            prefix_or = prefix_or | (prefix_or << 1);
            prefix_or = prefix_or | (prefix_or << 2);
            prefix_or = prefix_or | (prefix_or << 4);
            prefix_or = prefix_or | (prefix_or << 8);
            prefix_or = prefix_or | (prefix_or << 16);
            prefix_or = prefix_or | (prefix_or << 32);
        end
    endfunction
    /* verilator coverage_on */

    // ========================================================================
    // Input buffering with level-based ready signal
    // ========================================================================
    // ---- NB-deep ring of 64-coefficient blocks (a FIFO of whole blocks) ----
    // Deeper buffering lets the streaming front end (DCT/zigzag, ~64 cyc/block)
    // run ahead of the Huffman pipeline. occ = wr_count - rd_count is a wire, so
    // the controller observes a pop the same cycle it issues it.
    localparam [3:0] NB = HUFF_BANKS[3:0];
    localparam BW = (NB <= 4'd2) ? 1 : (NB <= 4'd4) ? 2 : (NB <= 4'd8) ? 3 : 4;
    // NB must be 2, 4 or 8: wr_bank = wr_count[BW-1:0] is a power-of-two mask and
    // the per-bank arrays below are sized to NB, so a non-power-of-two or >8
    // value would index nonexistent banks. Reject at elaboration (mirrored in
    // mjpegzero_enc_top) rather than wrap into out-of-range banks.
    generate if (HUFF_BANKS != 2 && HUFF_BANKS != 4 && HUFF_BANKS != 8)
        begin : g_huff_banks_check
            HUFF_BANKS_must_be_2_4_or_8 illegal_huff_banks_value();
        end
    endgenerate
    (* ram_style = "distributed" *) reg signed [15:0] coeff_buf [0:NB*64-1];
    /* verilator coverage_off */
    reg [5:0]    coeff_wr_idx;
    reg [1:0]    coeff_comp_id;
    /* verilator lint_off UNUSEDSIGNAL */
    reg [63:1]   nz_acc;              // nonzero map of the block being written ([63] only feeds bank_nz)
    /* verilator lint_on UNUSEDSIGNAL */
    reg          nz_any;              // any nonzero AC so far in that block
    reg [BW:0]   wr_count;            // block write pointer (BW+1 bits)
    reg [BW:0]   rd_count;            // block read  pointer (BW+1 bits)
    reg [1:0]    bank_comp [0:NB-1];  // per-bank comp_id
    reg [63:1]   bank_nz   [0:NB-1];  // per-bank nonzero AC map (bit i = coeff i != 0)
    reg          bank_any  [0:NB-1];  // per-bank |bank_nz, kept off the read-side path
    /* verilator coverage_on */

    wire [BW-1:0] wr_bank = wr_count[BW-1:0];
    wire [BW-1:0] rd_bank = rd_count[BW-1:0];
    wire [BW:0]   occ      = wr_count - rd_count;   // 0..NB blocks queued

    wire [BW+5:0] coeff_wr_addr = {wr_bank, (in_sob ? 6'd0 : coeff_wr_idx)};

    // Write side: fill the current bank with 64 coefficients, then advance the
    // write pointer (push). The top-level cap keeps occ < NB whenever a new
    // block's first coefficient arrives, so a write never clobbers a queued bank.
    always @(posedge clk) begin
        if (!rst_n) begin
            coeff_wr_idx <= 6'd0;
            wr_count     <= {(BW+1){1'b0}};
            nz_acc       <= 63'd0;
            nz_any       <= 1'b0;
        end else begin
            if (in_valid) begin
                coeff_buf[coeff_wr_addr] <= in_data;
                if (in_sob) begin
                    coeff_wr_idx  <= 6'd1;
                    coeff_comp_id <= comp_id;
                    nz_acc        <= 63'd0;
                    nz_any        <= 1'b0;
                end else begin
                    nz_acc[coeff_wr_idx] <= (in_data != 16'd0);
                    if (in_data != 16'd0)
                        nz_any <= 1'b1;
                    if (coeff_wr_idx == 6'd63) begin
                        bank_comp[wr_bank] <= coeff_comp_id;
                        bank_nz[wr_bank]   <= {(in_data != 16'd0), nz_acc[62:1]};
                        bank_any[wr_bank]  <= nz_any || (in_data != 16'd0);
                        wr_count           <= wr_count + 1'b1;   // push (advances wr_bank)
                        coeff_wr_idx       <= 6'd0;
                    end else begin
                        coeff_wr_idx <= coeff_wr_idx + 6'd1;
                    end
                end
            end
        end
    end

    // ========================================================================
    // Code pipeline: one Huffman code per cycle
    // ========================================================================
    // A controller walks the block's nonzero map and issues one token per cycle
    // (DC, each nonzero AC, EOB) into a 5-stage pipeline; zero coefficients cost
    // nothing. Stage 2 splits runs of >15 zeros into ZRL codes, stalling the
    // controller one cycle per ZRL. The whole pipeline advances together
    // whenever the output register is free (adv).
    //
    //   issue -> S2 fetch/DC diff/run -> S3 abs+category -> S4 table lookup
    //         -> out register (code+value bits combined)
    //
    // Blocks never overlap: the next block is issued only from C_IDLE, entered
    // the cycle after the block's EOB-flagged code is accepted. That keeps the
    // top's restart/frame_done (registered off that handshake) in step: the DC
    // predictors reset in C_IDLE before the next DC reaches S2, and the next
    // code reaches the packer >= 2 cycles after the EOB, after it saw in_restart.
    localparam C_IDLE = 2'd0,
               C_AC   = 2'd1,
               C_EOB  = 2'd2,
               C_WAIT = 2'd3;

    localparam K_DC  = 2'd0,
               K_AC  = 2'd1,
               K_ZRL = 2'd2,
               K_EOB = 2'd3;

    /* verilator coverage_off */
    reg [1:0]  ctl;
    reg [63:1] rem;                  // nonzero ACs not yet issued
    reg [1:0]  blk_comp_id;
    reg [BW-1:0] coeff_rd_bank;
    reg        restart_pending;
    reg signed [15:0] prev_dc_y;
    reg signed [15:0] prev_dc_cb;
    reg signed [15:0] prev_dc_cr;

    // S2: token as issued
    reg        s2_valid;
    reg [1:0]  s2_kind;
    reg [5:0]  s2_pos;               // coefficient index (0 for DC)
    reg        s2_eob;
    reg [5:0]  last_pos;             // index of the previous coded coefficient
    // S3: value + run
    reg        s3_valid;
    reg [1:0]  s3_kind;
    reg        s3_eob;
    /* verilator lint_off UNUSEDSIGNAL */
    reg signed [15:0] s3_val;        // only [15] and [10:0] used (|value| < 2048)
    /* verilator lint_on UNUSEDSIGNAL */
    reg [3:0]  s3_run;
    // S4: sign/abs/category
    reg        s4_valid;
    reg [1:0]  s4_kind;
    reg        s4_eob;
    reg [10:0] s4_raw;               // value[10:0]
    reg        s4_sign;
    reg [3:0]  s4_cat;
    reg [3:0]  s4_run;
    // S5: code + value bits, ready to combine
    reg        s5_valid;
    reg        s5_dc;
    reg        s5_eob;
    reg [15:0] s5_code;
    reg [4:0]  s5_len;
    reg [3:0]  s5_cat;
    reg [10:0] s5_vbits;
    /* verilator coverage_on */

    wire blk_is_luma = (blk_comp_id <= 2'd1);
    wire adv = !out_valid || out_ready;

    // S2 run of zeros before this AC; > 15 needs a ZRL first.
    wire [5:0] s2_run   = s2_pos - last_pos - 6'd1;
    wire       zrl_emit = s2_valid && (s2_kind == K_AC) && (s2_run[5:4] != 2'd0);
    wire       issue_en = adv && !zrl_emit;

    // Controller: next nonzero AC in the block
    // rem_below[i] = any set bit below i. The lowest set bit is the one with
    // none below it; clearing it keeps the rest (== x & (x-1), no carry chain).
    wire [63:0] rem64     = {rem, 1'b0};
    wire [63:0] rem_below = prefix_or(rem64) << 1;
    wire [5:0]  rem_pos   = onehot_idx(rem64 & ~rem_below);
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0] rem_clr   = rem64 & rem_below;   // [0] is always 0 (rem64[0] = 0)
    /* verilator lint_on UNUSEDSIGNAL */
    wire [63:1] rem_next  = rem_clr[63:1];

    wire signed [15:0] s2_coeff = coeff_buf[{coeff_rd_bank, s2_pos}];
    wire signed [15:0] s2_prev_dc = (blk_comp_id <= 2'd1) ? prev_dc_y :
                                    (blk_comp_id == 2'd2) ? prev_dc_cb : prev_dc_cr;

    wire [10:0] s3_abs = s3_val[15] ? (-s3_val[10:0]) : s3_val[10:0];

    /* verilator coverage_off */
    reg [19:0] dc_lookup_tmp;
    reg [20:0] ac_lookup_tmp;
    reg [5:0]  vshift;
    /* verilator coverage_on */

    always @(posedge clk) begin
        if (!rst_n) begin
            ctl             <= C_IDLE;
            rem             <= 63'd0;
            restart_pending <= 1'b0;
            coeff_rd_bank   <= {BW{1'b0}};
            rd_count        <= {(BW+1){1'b0}};
            prev_dc_y       <= 16'd0;
            prev_dc_cb      <= 16'd0;
            prev_dc_cr      <= 16'd0;
            last_pos        <= 6'd0;
            s2_valid        <= 1'b0;
            s3_valid        <= 1'b0;
            s4_valid        <= 1'b0;
            s5_valid        <= 1'b0;
            out_valid       <= 1'b0;
            out_sob         <= 1'b0;
            out_eob         <= 1'b0;
        end else begin
            // Latch restart request
            if (restart)
                restart_pending <= 1'b1;

            // ---------------- Controller / issue ----------------
            case (ctl)
                C_IDLE: begin
                    // Apply pending restart. Also honor a LIVE restart that
                    // arrives this very cycle: a mid-frame restart_trigger lands
                    // exactly as the controller enters C_IDLE (both are registered
                    // off the same EOB handshake), so waiting for the latched
                    // restart_pending (set next cycle) would miss it and the next
                    // MCU's DC would be coded against the stale predictor - a
                    // desync vs the decoder, which resets DC at the RSTn marker.
                    if (restart_pending || restart) begin
                        prev_dc_y       <= 16'd0;
                        prev_dc_cb      <= 16'd0;
                        prev_dc_cr      <= 16'd0;
                        restart_pending <= 1'b0;
                    end
                    if (issue_en) begin
                        s2_valid <= 1'b0;
                        if (occ != {(BW+1){1'b0}}) begin
                            blk_comp_id   <= bank_comp[rd_bank];
                            coeff_rd_bank <= rd_bank;
                            rem           <= bank_nz[rd_bank];
                            s2_valid      <= 1'b1;
                            s2_kind       <= K_DC;
                            s2_pos        <= 6'd0;
                            s2_eob        <= 1'b0;
                            ctl           <= bank_any[rd_bank] ? C_AC : C_EOB;
                        end
                    end
                end

                C_AC: begin
                    if (issue_en) begin
                        s2_valid <= 1'b1;
                        s2_kind  <= K_AC;
                        s2_pos   <= rem_pos;
                        s2_eob   <= (rem_next == 63'd0) && (rem_pos == 6'd63);
                        rem      <= rem_next;
                        if (rem_next == 63'd0)
                            ctl <= (rem_pos == 6'd63) ? C_WAIT : C_EOB;
                    end
                end

                C_EOB: begin
                    if (issue_en) begin
                        s2_valid <= 1'b1;
                        s2_kind  <= K_EOB;
                        s2_eob   <= 1'b1;
                        ctl      <= C_WAIT;
                    end
                end

                C_WAIT: begin
                    if (issue_en)
                        s2_valid <= 1'b0;
                    if (out_valid && out_ready && out_eob) begin
                        rd_count <= rd_count + 1'b1;   // pop completed block
                        ctl      <= C_IDLE;
                    end
                end
            endcase

            if (adv) begin
                // ---------------- S2: fetch / DC diff / zero run ----------------
                s3_valid <= s2_valid;
                s3_eob   <= s2_eob && !zrl_emit;
                if (zrl_emit) begin
                    s3_kind  <= K_ZRL;
                    s3_run   <= 4'd15;
                    s3_val   <= 16'd0;
                    last_pos <= last_pos + 6'd16;
                end else begin
                    s3_kind <= s2_kind;
                    s3_run  <= s2_run[3:0];
                    if (s2_kind == K_DC) begin
                        s3_val   <= s2_coeff - s2_prev_dc;
                        last_pos <= 6'd0;
                        if (s2_valid) begin
                            if (blk_comp_id <= 2'd1)      prev_dc_y  <= s2_coeff;
                            else if (blk_comp_id == 2'd2) prev_dc_cb <= s2_coeff;
                            else                          prev_dc_cr <= s2_coeff;
                        end
                    end else begin
                        s3_val <= s2_coeff;
                        if (s2_valid)
                            last_pos <= s2_pos;
                    end
                end

                // ---------------- S3: sign / abs / category ----------------
                s4_valid <= s3_valid;
                s4_kind  <= s3_kind;
                s4_eob   <= s3_eob;
                s4_run   <= s3_run;
                // ZRL/EOB carry no value bits: zero them so none leak into the code.
                if (s3_kind == K_DC || s3_kind == K_AC) begin
                    s4_raw  <= s3_val[10:0];
                    s4_sign <= s3_val[15];
                    s4_cat  <= compute_category(s3_abs);
                end else begin
                    s4_raw  <= 11'd0;
                    s4_sign <= 1'b0;
                    s4_cat  <= 4'd0;
                end

                // ---------------- S4: value bits + table lookup ----------------
                s5_valid <= s4_valid;
                s5_dc    <= (s4_kind == K_DC);
                s5_eob   <= s4_eob;
                s5_cat   <= s4_cat;
                if (s4_sign)
                    s5_vbits <= s4_raw + (11'd1 << s4_cat) - 11'd1;
                else
                    s5_vbits <= s4_raw;
                /* verilator lint_off BLKSEQ */
                if (s4_kind == K_DC) begin
                    dc_lookup_tmp = blk_is_luma ? dc_luma_lookup(s4_cat) : dc_chroma_lookup(s4_cat);
                    s5_code <= dc_lookup_tmp[15:0];
                    /* verilator lint_off WIDTHEXPAND */
                    s5_len  <= dc_lookup_tmp[19:16];
                    /* verilator lint_on WIDTHEXPAND */
                end else begin
                    ac_lookup_tmp = blk_is_luma ?
                        ac_luma_lookup((s4_kind == K_AC)  ? {s4_run, s4_cat} :
                                       (s4_kind == K_ZRL) ? 8'hF0 : 8'h00) :
                        ac_chroma_lookup((s4_kind == K_AC)  ? {s4_run, s4_cat} :
                                         (s4_kind == K_ZRL) ? 8'hF0 : 8'h00);
                    s5_code <= ac_lookup_tmp[15:0];
                    s5_len  <= ac_lookup_tmp[20:16];
                end
                /* verilator lint_on BLKSEQ */

                // ---------------- S5: combine into the output register ----------------
                // Huffman code MSB-aligned, value bits immediately after it.
                out_valid <= s5_valid;
                out_sob   <= s5_valid && s5_dc;
                out_eob   <= s5_valid && s5_eob;
                /* verilator lint_off BLKSEQ */
                vshift = 6'd32 - {1'b0, s5_len} - {2'd0, s5_cat};
                /* verilator lint_on BLKSEQ */
                out_bits <= {s5_code, 16'd0} | ({21'd0, s5_vbits} << vshift);
                out_len  <= {1'b0, s5_len} + {2'd0, s5_cat};
            end
        end
    end

/* verilator lint_on WIDTHTRUNC */
endmodule
