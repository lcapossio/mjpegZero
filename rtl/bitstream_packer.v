// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// Bitstream Packer
// ============================================================================
// Accumulates variable-length Huffman codes into a byte-aligned output stream.
// Handles JPEG byte stuffing (0xFF -> 0xFF 0x00).
//
// Features:
//   - 64-bit accumulator for variable-length codes (up to 32 bits)
//   - JPEG byte stuffing (0xFF -> 0xFF 0x00)
//   - Backpressure to Huffman encoder (bp_ready output)
//   - Restart marker insertion (pad + 0xFF + 0xD0-0xD7)
//   - Frame byte counting (reported via byte_count output)
//   - Flush at end of frame (pad with 1-bits to byte boundary)
//
// Input:  Variable-length code words (up to 32 bits) with length
// Output: 8-bit byte stream via AXI4-Stream
// ============================================================================

module bitstream_packer (
    input  wire        clk,
    input  wire        rst_n,

    // Input from Huffman encoder
    input  wire        in_valid,
    input  wire [31:0] in_bits,    // Code bits (MSB-aligned)
    input  wire [5:0]  in_len,     // Number of valid bits (1-32)
    input  wire        in_flush,   // Flush remaining bits (end of frame)

    // Restart marker insertion
    input  wire        in_restart, // Insert restart marker (pad + RST)

    // Backpressure to Huffman encoder
    output wire        bp_ready,   // 1 = can accept data

    // Output AXI4-Stream (byte stream)
    output reg         out_valid,
    output reg  [7:0]  out_data,
    output reg         out_last,   // End of frame
    input  wire        out_ready,

    // Frame byte count (updated continuously)
    output reg  [31:0] byte_count
);

    // ========================================================================
    // Bit accumulator
    // ========================================================================
    reg [63:0] bit_buf;
    reg [6:0]  bit_cnt;       // Number of valid bits in bit_buf (0..64)

    // Byte stuffing state
    reg        need_stuff;    // Previous output byte was 0xFF

    // ========================================================================
    // State machine for restart marker and flush
    // ========================================================================
    localparam S_NORMAL     = 3'd0;  // Normal: accumulate bits, output bytes
    localparam S_RST_PAD    = 3'd1;  // Pad bits to byte boundary with 1s
    localparam S_RST_DRAIN  = 3'd2;  // Drain remaining bytes from accumulator
    localparam S_RST_FF     = 3'd3;  // Emit 0xFF
    localparam S_RST_MARKER = 3'd4;  // Emit 0xD0 + counter
    localparam S_FLUSH_PAD  = 3'd5;  // End of frame: pad and drain
    localparam S_FLUSH_LAST = 3'd6;  // Emit last byte with tlast

    reg [2:0] state;
    reg [2:0] rst_counter;   // RST0-RST7 counter (wraps at 8)

    // Backpressure: ready ONLY when Priority 3 (accept input) will actually fire.
    // Must ensure bit_cnt < 8 so Priority 2 (byte drain) won't take precedence
    // in the else-if chain.  Old condition (bit_cnt <= 32) allowed the Huffman
    // encoder to see acceptance while the packer was actually draining bytes.
    assign bp_ready = (state == S_NORMAL) && (bit_cnt < 7'd8) && !need_stuff;

    // ========================================================================
    // Main logic
    // ========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            bit_buf     <= 64'd0;
            bit_cnt     <= 7'd0;
            out_valid   <= 1'b0;
            out_data    <= 8'd0;
            out_last    <= 1'b0;
            need_stuff  <= 1'b0;
            state       <= S_NORMAL;
            rst_counter <= 3'd0;
            byte_count  <= 32'd0;
        end else begin
            // Default: deassert valid when downstream accepts
            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
                out_last  <= 1'b0;
            end

            case (state)
                // ==============================================================
                // NORMAL: Accept input, output bytes
                // ==============================================================
                S_NORMAL: begin
                    // Priority 1: Byte stuffing
                    if (need_stuff && (!out_valid || out_ready)) begin
                        out_valid  <= 1'b1;
                        out_data   <= 8'h00;
                        need_stuff <= 1'b0;
                        byte_count <= byte_count + 32'd1;
                    end
                    // Priority 2: Output bytes when >=8 bits available
                    else if (bit_cnt >= 7'd8 && !need_stuff && (!out_valid || out_ready)) begin
                        out_valid <= 1'b1;
                        out_data  <= bit_buf[63:56];
                        bit_buf   <= {bit_buf[55:0], 8'd0};
                        bit_cnt   <= bit_cnt - 7'd8;
                        byte_count <= byte_count + 32'd1;
                        // Check for byte stuffing
                        if (bit_buf[63:56] == 8'hFF)
                            need_stuff <= 1'b1;
                    end
                    // Priority 3: Accept new input when buffer has room
                    else if (in_valid && bp_ready && (!out_valid || out_ready)) begin
                        bit_buf <= bit_buf | ({in_bits, 32'd0} >> bit_cnt);
                        bit_cnt <= bit_cnt + {1'b0, in_len};
                    end

                    // Restart request
                    if (in_restart) begin
                        state <= S_RST_PAD;
                    end
                    // Flush request
                    else if (in_flush) begin
                        state <= S_FLUSH_PAD;
                    end
                end

                // ==============================================================
                // RESTART: Pad bits to byte boundary
                // ==============================================================
                S_RST_PAD: begin
                    if (!out_valid || out_ready) begin
                        if (need_stuff) begin
                            // Emit the stuff byte first
                            out_valid  <= 1'b1;
                            out_data   <= 8'h00;
                            need_stuff <= 1'b0;
                            byte_count <= byte_count + 32'd1;
                        end else if (bit_cnt > 7'd0) begin
                            // Pad partial byte with 1s
                            if (bit_cnt < 7'd8) begin
                                bit_buf[63:56] <= bit_buf[63:56] | (8'hFF >> bit_cnt[2:0]);
                                bit_cnt <= 7'd8;
                            end
                            state <= S_RST_DRAIN;
                        end else begin
                            state <= S_RST_FF;
                        end
                    end
                end

                // ==============================================================
                // RESTART: Drain remaining bytes
                // ==============================================================
                S_RST_DRAIN: begin
                    if (!out_valid || out_ready) begin
                        if (need_stuff) begin
                            out_valid  <= 1'b1;
                            out_data   <= 8'h00;
                            need_stuff <= 1'b0;
                            byte_count <= byte_count + 32'd1;
                        end else if (bit_cnt >= 7'd8) begin
                            out_valid  <= 1'b1;
                            out_data   <= bit_buf[63:56];
                            bit_buf    <= {bit_buf[55:0], 8'd0};
                            bit_cnt    <= bit_cnt - 7'd8;
                            byte_count <= byte_count + 32'd1;
                            if (bit_buf[63:56] == 8'hFF)
                                need_stuff <= 1'b1;
                        end else begin
                            state <= S_RST_FF;
                        end
                    end
                end

                // ==============================================================
                // RESTART: Emit 0xFF marker prefix
                // ==============================================================
                S_RST_FF: begin
                    if (!out_valid || out_ready) begin
                        out_valid  <= 1'b1;
                        out_data   <= 8'hFF;
                        need_stuff <= 1'b0; // Next byte is marker, not stuffing
                        byte_count <= byte_count + 32'd1;
                        state      <= S_RST_MARKER;
                    end
                end

                // ==============================================================
                // RESTART: Emit RST marker (0xD0 + counter)
                // ==============================================================
                S_RST_MARKER: begin
                    if (!out_valid || out_ready) begin
                        out_valid   <= 1'b1;
                        out_data    <= {5'b11010, rst_counter};
                        byte_count  <= byte_count + 32'd1;
                        rst_counter <= rst_counter + 3'd1; // Wraps 0-7 automatically
                        state       <= S_NORMAL;
                        // Reset bit accumulator for new segment
                        bit_buf <= 64'd0;
                        bit_cnt <= 7'd0;
                    end
                end

                // ==============================================================
                // FLUSH: Pad and drain (end of frame)
                // ==============================================================
                S_FLUSH_PAD: begin
                    if (!out_valid || out_ready) begin
                        if (need_stuff) begin
                            out_valid  <= 1'b1;
                            out_data   <= 8'h00;
                            need_stuff <= 1'b0;
                            byte_count <= byte_count + 32'd1;
                        end else if (bit_cnt >= 7'd8) begin
                            // Drain full bytes
                            out_valid  <= 1'b1;
                            out_data   <= bit_buf[63:56];
                            bit_buf    <= {bit_buf[55:0], 8'd0};
                            bit_cnt    <= bit_cnt - 7'd8;
                            byte_count <= byte_count + 32'd1;
                            if (bit_buf[63:56] == 8'hFF)
                                need_stuff <= 1'b1;
                        end else if (bit_cnt > 7'd0) begin
                            // Pad partial byte with 1s and output
                            out_valid  <= 1'b1;
                            out_data   <= bit_buf[63:56] | (8'hFF >> bit_cnt[2:0]);
                            byte_count <= byte_count + 32'd1;
                            bit_buf    <= 64'd0;
                            bit_cnt    <= 7'd0;
                            // Check for 0xFF
                            if ((bit_buf[63:56] | (8'hFF >> bit_cnt[2:0])) == 8'hFF)
                                need_stuff <= 1'b1;
                            else
                                state <= S_FLUSH_LAST;
                        end else begin
                            // No bits left, go to last
                            state <= S_FLUSH_LAST;
                        end
                    end
                end

                // ==============================================================
                // FLUSH: Signal end of frame
                // ==============================================================
                S_FLUSH_LAST: begin
                    if (!out_valid || out_ready) begin
                        if (need_stuff) begin
                            out_valid  <= 1'b1;
                            out_data   <= 8'h00;
                            need_stuff <= 1'b0;
                            byte_count <= byte_count + 32'd1;
                        end else begin
                            out_last <= 1'b1;
                            out_valid <= 1'b1;
                            out_data <= 8'h00; // Dummy byte with tlast
                            state <= S_NORMAL;
                            // Reset for next frame
                            bit_buf     <= 64'd0;
                            bit_cnt     <= 7'd0;
                            rst_counter <= 3'd0;
                        end
                    end
                end

                default: state <= S_NORMAL;
            endcase
        end
    end

endmodule
