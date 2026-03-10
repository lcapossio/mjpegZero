// SPDX-License-Identifier: MIT
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
    parameter LITE_MODE = 0     // 1 = single-buffered input (reduced LUTs)
) (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire [1:0]  comp_id,        // 0,1=Y, 2=Cb, 3=Cr
    input  wire        restart,        // Reset DC predictors (restart boundary)

    // Input (zigzag-ordered coefficients)
    input  wire        in_valid,
    input  wire signed [15:0] in_data,
    input  wire        in_sob,         // Start of block

    // Output (Huffman coded bits)
    output reg         out_valid,
    output reg  [31:0] out_bits,       // Huffman code bits (MSB-aligned)
    output reg  [5:0]  out_len,        // Number of valid bits (1-32)
    output reg         out_sob,        // Start of block
    output reg         out_eob,        // End of block
    input  wire        out_ready       // Downstream backpressure
);

    // ========================================================================
    // DC Huffman table functions
    // ========================================================================
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

    // ========================================================================
    // Input buffering with level-based ready signal
    // LITE_MODE=0: Double-buffered (2x64), allows overlap of write and FSM read
    // LITE_MODE=1: Single-buffered (1x64), saves ~64x16 = 1024 bits of registers
    // ========================================================================
    reg signed [15:0] coeff_buf [0:(LITE_MODE ? 63 : 127)];
    reg [5:0]  coeff_wr_idx;
    reg        coeff_block_ready;  // Level: stays high until FSM acknowledges
    reg [1:0]  coeff_comp_id;
    reg [5:0]  last_nonzero_idx;

    // Latched metadata: captured when block completes writing so FSM can
    // read correct values even if a new block starts writing immediately.
    reg [1:0]  ready_comp_id;
    reg [5:0]  ready_last_nonzero;

    // Bank tracking (only used in full mode, optimized away in lite)
    reg        coeff_wr_bank;
    reg        ready_rd_bank;

    // Acknowledgment from FSM (driven in FSM always block)
    reg        fsm_ack;

    always @(posedge clk) begin
        if (!rst_n) begin
            coeff_wr_idx <= 6'd0;
            coeff_wr_bank <= 1'b0;
            coeff_block_ready <= 1'b0;
            last_nonzero_idx <= 6'd0;
        end else begin
            // Clear ready when FSM acknowledges (BEFORE set, so set wins on collision)
            if (fsm_ack)
                coeff_block_ready <= 1'b0;

            if (in_valid) begin
                if (LITE_MODE) begin
                    /* verilator lint_off WIDTHEXPAND */
                    coeff_buf[coeff_wr_idx] <= in_data;
                    /* verilator lint_on WIDTHEXPAND */
                    if (in_sob) begin
                        coeff_wr_idx <= 6'd1;
                        coeff_buf[0] <= in_data;
                        coeff_comp_id <= comp_id;
                        last_nonzero_idx <= 6'd0;
                    end else begin
                        if (in_data != 16'd0)
                            last_nonzero_idx <= coeff_wr_idx;
                        if (coeff_wr_idx == 6'd63) begin
                            coeff_block_ready <= 1'b1;
                            ready_comp_id <= coeff_comp_id;
                            ready_last_nonzero <= (in_data != 16'd0) ? 6'd63 : last_nonzero_idx;
                            coeff_wr_idx <= 6'd0;
                        end else begin
                            coeff_wr_idx <= coeff_wr_idx + 6'd1;
                        end
                    end
                end else begin
                    coeff_buf[{coeff_wr_bank, coeff_wr_idx}] <= in_data;
                    if (in_sob) begin
                        coeff_wr_idx <= 6'd1;
                        coeff_buf[{coeff_wr_bank, 6'd0}] <= in_data;
                        coeff_comp_id <= comp_id;
                        last_nonzero_idx <= 6'd0;
                    end else begin
                        if (in_data != 16'd0)
                            last_nonzero_idx <= coeff_wr_idx;
                        if (coeff_wr_idx == 6'd63) begin
                            coeff_block_ready <= 1'b1;
                            ready_comp_id <= coeff_comp_id;
                            ready_last_nonzero <= (in_data != 16'd0) ? 6'd63 : last_nonzero_idx;
                            ready_rd_bank <= coeff_wr_bank;
                            coeff_wr_idx <= 6'd0;
                            coeff_wr_bank <= ~coeff_wr_bank;
                        end else begin
                            coeff_wr_idx <= coeff_wr_idx + 6'd1;
                        end
                    end
                end
            end
        end
    end

    // ========================================================================
    // Multi-cycle processing state machine
    // ========================================================================
    localparam S_IDLE      = 4'd0,
               S_DC_FETCH  = 4'd1,
               S_DC_ENCODE = 4'd2,
               S_DC_EMIT   = 4'd3,
               S_AC_FETCH  = 4'd4,
               S_AC_SCAN   = 4'd5,
               S_AC_ENCODE = 4'd6,
               S_AC_EMIT   = 4'd7,
               S_ZRL_EMIT  = 4'd8,
               S_EOB_EMIT  = 4'd9,
               S_DC_CALC   = 4'd10;

    reg [3:0]  state;
    reg [5:0]  ac_idx;
    reg [3:0]  zero_run;
    reg [1:0]  blk_comp_id;
    wire       blk_is_luma = (blk_comp_id <= 2'd1);
    reg        coeff_rd_bank;
    reg [5:0]  blk_last_nonzero;  // Latched for FSM use

    // Three DC predictors (FIX: was only 2)
    reg signed [15:0] prev_dc_y;
    reg signed [15:0] prev_dc_cb;
    reg signed [15:0] prev_dc_cr;

    // Pipeline registers
    reg signed [15:0] cur_coeff;
    reg [10:0] cur_abs;
    reg        cur_sign;
    reg [3:0]  cur_cat;
    reg [10:0] cur_vbits;
    reg [15:0] huff_code;
    reg [4:0]  huff_len;

    // Restart pending
    reg restart_pending;

    // Temporary computation variables (Verilog 2001: blocking in sequential)
    reg [19:0] dc_lookup_tmp;
    reg [20:0] ac_lookup_tmp;
    reg [3:0]  temp_cat;
    reg [7:0]  ac_sym_tmp;
    reg [5:0]  vshift;       // Shift amount for value bits positioning

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            out_valid <= 1'b0;
            out_sob <= 1'b0;
            out_eob <= 1'b0;
            prev_dc_y  <= 16'd0;
            prev_dc_cb <= 16'd0;
            prev_dc_cr <= 16'd0;
            ac_idx <= 6'd1;
            zero_run <= 4'd0;
            restart_pending <= 1'b0;
            coeff_rd_bank <= 1'b0;
            fsm_ack <= 1'b0;
        end else begin
            fsm_ack <= 1'b0;  // Default: 1-cycle pulse

            // Latch restart request
            if (restart)
                restart_pending <= 1'b1;

            case (state)
                // ============================================================
                S_IDLE: begin
                    out_valid <= 1'b0;
                    out_sob <= 1'b0;
                    out_eob <= 1'b0;

                    // Apply pending restart
                    if (restart_pending) begin
                        prev_dc_y  <= 16'd0;
                        prev_dc_cb <= 16'd0;
                        prev_dc_cr <= 16'd0;
                        restart_pending <= 1'b0;
                    end

                    if (coeff_block_ready) begin
                        fsm_ack <= 1'b1;  // Acknowledge: clear coeff_block_ready
                        blk_comp_id <= ready_comp_id;
                        blk_last_nonzero <= ready_last_nonzero;
                        if (!LITE_MODE) coeff_rd_bank <= ready_rd_bank;
                        state <= S_DC_FETCH;
                    end
                end

                // ============================================================
                // DC coefficient processing
                // ============================================================
                S_DC_FETCH: begin
                    out_valid <= 1'b0;
                    // Compute DC differential based on component
                    // LITE_MODE: single buffer, direct 6-bit index
                    // Full mode: double buffer, {bank, index} 7-bit address
                    if (blk_comp_id <= 2'd1) begin
                        cur_coeff <= coeff_buf[LITE_MODE ? {1'b0, 6'd0} : {coeff_rd_bank, 6'd0}] - prev_dc_y;
                        prev_dc_y <= coeff_buf[LITE_MODE ? {1'b0, 6'd0} : {coeff_rd_bank, 6'd0}];
                    end else if (blk_comp_id == 2'd2) begin
                        cur_coeff <= coeff_buf[LITE_MODE ? {1'b0, 6'd0} : {coeff_rd_bank, 6'd0}] - prev_dc_cb;
                        prev_dc_cb <= coeff_buf[LITE_MODE ? {1'b0, 6'd0} : {coeff_rd_bank, 6'd0}];
                    end else begin
                        cur_coeff <= coeff_buf[LITE_MODE ? {1'b0, 6'd0} : {coeff_rd_bank, 6'd0}] - prev_dc_cr;
                        prev_dc_cr <= coeff_buf[LITE_MODE ? {1'b0, 6'd0} : {coeff_rd_bank, 6'd0}];
                    end
                    state <= S_DC_ENCODE;
                end

                S_DC_ENCODE: begin
                    // Cycle 1: abs + category (split to reduce 7-level critical path)
                    out_valid <= 1'b0;
                    cur_sign <= cur_coeff[15];
                    cur_abs <= cur_coeff[15] ? (-cur_coeff[10:0]) : cur_coeff[10:0];
                    /* verilator lint_off BLKSEQ */
                    temp_cat = compute_category(cur_coeff[15] ? (-cur_coeff[10:0]) : cur_coeff[10:0]);
                    /* verilator lint_on BLKSEQ */
                    cur_cat <= temp_cat;
                    state <= S_DC_CALC;
                end

                S_DC_CALC: begin
                    // Cycle 2: vbits + Huffman lookup from registered category
                    out_valid <= 1'b0;
                    if (cur_sign)
                        cur_vbits <= cur_coeff[10:0] + (11'd1 << cur_cat) - 11'd1;
                    else
                        cur_vbits <= cur_coeff[10:0];

                    /* verilator lint_off BLKSEQ */
                    dc_lookup_tmp = blk_is_luma ? dc_luma_lookup(cur_cat) : dc_chroma_lookup(cur_cat);
                    /* verilator lint_on BLKSEQ */
                    huff_code <= dc_lookup_tmp[15:0];
                    /* verilator lint_off WIDTHEXPAND */
                    huff_len  <= dc_lookup_tmp[19:16];
                    /* verilator lint_on WIDTHEXPAND */

                    state <= S_DC_EMIT;
                end

                S_DC_EMIT: begin
                    out_valid <= 1'b1;
                    out_sob <= 1'b1;
                    out_eob <= 1'b0;
                    // Combine Huffman code (MSB-aligned) with value bits
                    // Value bits placed immediately after the Huffman code
                    /* verilator lint_off BLKSEQ */
                    vshift = 6'd32 - {1'b0, huff_len} - {2'd0, cur_cat};
                    /* verilator lint_on BLKSEQ */
                    out_bits <= {huff_code, 16'd0} |
                               ({21'd0, cur_vbits} << vshift);
                    out_len <= {1'b0, huff_len} + {2'd0, cur_cat};

                    // Wait for out_valid to be registered (1 cycle) before
                    // checking out_ready. Prevents last-NBA-wins override.
                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        out_sob <= 1'b0;
                        // Early EOB: skip AC processing if all ACs are zero
                        if (blk_last_nonzero == 6'd0) begin
                            state <= S_EOB_EMIT;
                        end else begin
                            ac_idx <= 6'd1;
                            zero_run <= 4'd0;
                            state <= S_AC_FETCH;
                        end
                    end
                end

                // ============================================================
                // AC coefficient processing
                // ============================================================
                S_AC_FETCH: begin
                    out_valid <= 1'b0;
                    out_sob <= 1'b0;
                    out_eob <= 1'b0;
                    cur_coeff <= coeff_buf[LITE_MODE ? {1'b0, ac_idx} : {coeff_rd_bank, ac_idx}];
                    state <= S_AC_SCAN;
                end

                S_AC_SCAN: begin
                    out_valid <= 1'b0;
                    if (cur_coeff == 16'd0) begin
                        // Early EOB: all remaining ACs are zero
                        if (ac_idx > blk_last_nonzero) begin
                            state <= S_EOB_EMIT;
                        end else if (zero_run == 4'd15) begin
                            state <= S_ZRL_EMIT;
                        end else begin
                            zero_run <= zero_run + 4'd1;
                            ac_idx <= ac_idx + 6'd1;
                            state <= S_AC_FETCH;
                        end
                    end else begin
                        cur_sign <= cur_coeff[15];
                        cur_abs <= cur_coeff[15] ? (-cur_coeff[10:0]) : cur_coeff[10:0];
                        state <= S_AC_ENCODE;
                    end
                end

                S_AC_ENCODE: begin
                    out_valid <= 1'b0;
                    /* verilator lint_off BLKSEQ */
                    temp_cat = compute_category(cur_abs);
                    /* verilator lint_on BLKSEQ */
                    cur_cat <= temp_cat;

                    if (cur_sign)
                        cur_vbits <= cur_coeff[10:0] + (11'd1 << temp_cat) - 11'd1;
                    else
                        cur_vbits <= cur_coeff[10:0];

                    /* verilator lint_off BLKSEQ */
                    ac_sym_tmp = {zero_run, temp_cat};
                    ac_lookup_tmp = blk_is_luma ? ac_luma_lookup(ac_sym_tmp) : ac_chroma_lookup(ac_sym_tmp);
                    /* verilator lint_on BLKSEQ */
                    huff_code <= ac_lookup_tmp[15:0];
                    huff_len  <= ac_lookup_tmp[20:16];

                    state <= S_AC_EMIT;
                end

                S_AC_EMIT: begin
                    out_valid <= 1'b1;
                    out_sob <= 1'b0;
                    // Signal block completion on last AC coefficient
                    out_eob <= (ac_idx == 6'd63) ? 1'b1 : 1'b0;
                    // Combine Huffman code (MSB-aligned) with value bits
                    /* verilator lint_off BLKSEQ */
                    vshift = 6'd32 - {1'b0, huff_len} - {2'd0, cur_cat};
                    /* verilator lint_on BLKSEQ */
                    out_bits <= {huff_code, 16'd0} |
                               ({21'd0, cur_vbits} << vshift);
                    out_len <= {1'b0, huff_len} + {2'd0, cur_cat};

                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        zero_run <= 4'd0;
                        if (ac_idx == 6'd63) begin
                            state <= S_IDLE;
                        end else begin
                            ac_idx <= ac_idx + 6'd1;
                            state <= S_AC_FETCH;
                        end
                    end
                end

                S_ZRL_EMIT: begin
                    out_valid <= 1'b1;
                    out_sob <= 1'b0;
                    out_eob <= 1'b0;
                    /* verilator lint_off BLKSEQ */
                    ac_lookup_tmp = blk_is_luma ? ac_luma_lookup(8'hF0) : ac_chroma_lookup(8'hF0);
                    /* verilator lint_on BLKSEQ */
                    out_bits <= {ac_lookup_tmp[15:0], 16'd0};
                    out_len <= {1'b0, ac_lookup_tmp[20:16]};

                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        zero_run <= 4'd0;
                        ac_idx <= ac_idx + 6'd1;
                        state <= S_AC_FETCH;
                    end
                end

                S_EOB_EMIT: begin
                    out_valid <= 1'b1;
                    out_sob <= 1'b0;
                    out_eob <= 1'b1;
                    /* verilator lint_off BLKSEQ */
                    ac_lookup_tmp = blk_is_luma ? ac_luma_lookup(8'h00) : ac_chroma_lookup(8'h00);
                    /* verilator lint_on BLKSEQ */
                    out_bits <= {ac_lookup_tmp[15:0], 16'd0};
                    out_len <= {1'b0, ac_lookup_tmp[20:16]};

                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        out_eob <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

/* verilator lint_on WIDTHTRUNC */
endmodule
