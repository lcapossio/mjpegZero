// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// bitstream_packer — packs variable-length codes into the JPEG byte stream
//
// Function
//   Concatenates MSB-first variable-length code words (up to 32 bits) into
//   bytes, applying the entropy-stream rules of ITU-T T.81:
//     - byte stuffing: every 0xFF data byte is followed by 0x00 (§B.1.1.5)
//     - restart markers: pad the segment tail with 1-bits to a byte
//       boundary, then emit 0xFF, 0xD0+m with m cycling 0..7 (§B.2.1.2)
//     - end of frame: pad with 1-bits to a byte boundary, drain, then emit
//       one zero byte carrying out_last to close the AXI-Stream packet
//   byte_count counts every emitted stream byte (stuffing and markers
//   included; the out_last closing byte excluded) for the frame-size CSR.
//
// Interface
//   Input: in_valid/bp_ready handshake, code in in_bits[31:0] MSB-aligned
//   with length in_len. in_restart / in_flush are single-cycle requests that
//   take effect after any code accepted in the same cycle; the sender must
//   not offer a code of the following segment in or before the cycle a
//   restart or flush arrives (the encoder's inter-block spacing provides
//   this). Output: 8-bit AXI-Stream with out_last on the closing byte.
//
// Contract
//   The 64-bit accumulator accepts a new code whenever at most 32 bits are
//   pending, so acceptance and byte drain proceed concurrently: worst case
//   32 pending + 32 accepted = 64 bits, which the buffer holds exactly.
//   Sustained throughput is therefore limited only by the 8 bits/clock
//   output rate, not by accept/drain alternation: code words whose long-run
//   average length is at most 8 bits stream at one code per clock.
//
// Position
//   Encoder coefficient path:
//   input_buffer → dct_2d → quantizer → zigzag_reorder →
//   huffman_encoder → [bitstream_packer] → jfif_writer
// -----------------------------------------------------------------------------

module bitstream_packer (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        in_valid,
    input  wire [31:0] in_bits,
    input  wire [5:0]  in_len,
    input  wire        in_flush,
    input  wire        in_restart,
    output wire        bp_ready,

    output reg         out_valid,
    output reg  [7:0]  out_data,
    output reg         out_last,
    input  wire        out_ready,

    output reg  [31:0] byte_count
);

    localparam S_NORMAL     = 3'd0;  // accept codes, drain bytes
    localparam S_RST_TAIL   = 3'd1;  // pad + drain the segment tail
    localparam S_RST_FF     = 3'd2;  // marker prefix 0xFF
    localparam S_RST_MARKER = 3'd3;  // marker code 0xD0 + m
    localparam S_FLUSH_TAIL = 3'd4;  // pad + drain the frame tail
    localparam S_FLUSH_LAST = 3'd5;  // closing byte with out_last

    reg [2:0]  state;
    reg [63:0] bit_buf;              // pending bits, MSB-first
    reg [6:0]  bit_cnt;
    reg        need_stuff;           // a 0xFF data byte was just emitted
    reg [2:0]  rst_counter;          // restart marker modulus m

    // Accept while at most 32 bits are pending (see Contract). Acceptance is
    // independent of the emit path: inserting bits touches only the
    // accumulator, so a pending stuff byte or an in-flight drain never
    // blocks it.
    assign bp_ready = (state == S_NORMAL) && (bit_cnt <= 7'd32);

    // The output register is free to load this cycle.
    wire slot_free = !out_valid || out_ready;

    // One byte leaves the accumulator this cycle (S_NORMAL drain).
    wire drain = (state == S_NORMAL) && slot_free && !need_stuff
                 && (bit_cnt >= 7'd8);

    // Accumulator state after the optional drain, before the optional insert.
    wire [63:0] buf_after_drain = drain ? {bit_buf[55:0], 8'd0} : bit_buf;
    wire [6:0]  cnt_after_drain = drain ? bit_cnt - 7'd8 : bit_cnt;

    wire accept = in_valid && bp_ready;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_NORMAL;
            bit_buf     <= 64'd0;
            bit_cnt     <= 7'd0;
            need_stuff  <= 1'b0;
            rst_counter <= 3'd0;
            out_valid   <= 1'b0;
            out_data    <= 8'd0;
            out_last    <= 1'b0;
            byte_count  <= 32'd0;
        end else begin
            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
                out_last  <= 1'b0;
            end

            case (state)
                // ============================================================
                // NORMAL: stuff/drain into the output register while
                // accepting new codes into the accumulator — independently
                // and, when possible, in the same cycle.
                // ============================================================
                S_NORMAL: begin
                    if (slot_free) begin
                        if (need_stuff) begin
                            out_valid  <= 1'b1;
                            out_data   <= 8'h00;
                            need_stuff <= 1'b0;
                            byte_count <= byte_count + 32'd1;
                        end else if (bit_cnt >= 7'd8) begin
                            out_valid  <= 1'b1;
                            out_data   <= bit_buf[63:56];
                            need_stuff <= (bit_buf[63:56] == 8'hFF);
                            byte_count <= byte_count + 32'd1;
                        end
                    end

                    bit_buf <= accept
                        ? (buf_after_drain | ({in_bits, 32'd0} >> cnt_after_drain))
                        : buf_after_drain;
                    bit_cnt <= accept
                        ? cnt_after_drain + {1'b0, in_len}
                        : cnt_after_drain;

                    if (in_restart)
                        state <= S_RST_TAIL;
                    else if (in_flush)
                        state <= S_FLUSH_TAIL;
                end

                // ============================================================
                // RESTART: drain whole bytes, pad a partial tail byte with
                // 1-bits (T.81 §B.2.1.2), then emit the marker.
                // ============================================================
                S_RST_TAIL: begin
                    if (slot_free) begin
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
                            need_stuff <= (bit_buf[63:56] == 8'hFF);
                            byte_count <= byte_count + 32'd1;
                        end else if (bit_cnt > 7'd0) begin
                            bit_buf[63:56] <= bit_buf[63:56] | (8'hFF >> bit_cnt[2:0]);
                            bit_cnt        <= 7'd8;
                        end else begin
                            state <= S_RST_FF;
                        end
                    end
                end

                S_RST_FF: begin
                    if (slot_free) begin
                        out_valid  <= 1'b1;
                        out_data   <= 8'hFF;
                        byte_count <= byte_count + 32'd1;
                        state      <= S_RST_MARKER;
                    end
                end

                S_RST_MARKER: begin
                    if (slot_free) begin
                        out_valid   <= 1'b1;
                        out_data    <= {5'b11010, rst_counter};
                        byte_count  <= byte_count + 32'd1;
                        rst_counter <= rst_counter + 3'd1;  // cycles 0..7
                        state       <= S_NORMAL;
                    end
                end

                // ============================================================
                // FLUSH: drain whole bytes, pad the final partial byte with
                // 1-bits, then close the stream.
                // ============================================================
                S_FLUSH_TAIL: begin
                    if (slot_free) begin
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
                            need_stuff <= (bit_buf[63:56] == 8'hFF);
                            byte_count <= byte_count + 32'd1;
                        end else if (bit_cnt > 7'd0) begin
                            out_valid  <= 1'b1;
                            out_data   <= bit_buf[63:56] | (8'hFF >> bit_cnt[2:0]);
                            byte_count <= byte_count + 32'd1;
                            bit_buf    <= 64'd0;
                            bit_cnt    <= 7'd0;
                            if ((bit_buf[63:56] | (8'hFF >> bit_cnt[2:0])) == 8'hFF)
                                need_stuff <= 1'b1;   // stuff, then close
                            else
                                state <= S_FLUSH_LAST;
                        end else begin
                            state <= S_FLUSH_LAST;
                        end
                    end
                end

                S_FLUSH_LAST: begin
                    if (slot_free) begin
                        if (need_stuff) begin
                            out_valid  <= 1'b1;
                            out_data   <= 8'h00;
                            need_stuff <= 1'b0;
                            byte_count <= byte_count + 32'd1;
                        end else begin
                            // Closing byte: carries out_last only, so it is
                            // not part of the entropy stream and not counted.
                            out_valid   <= 1'b1;
                            out_data    <= 8'h00;
                            out_last    <= 1'b1;
                            state       <= S_NORMAL;
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
