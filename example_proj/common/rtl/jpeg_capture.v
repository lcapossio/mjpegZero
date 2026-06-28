// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// ============================================================================
// jpeg_capture.v - pack the encoder's byte stream into the JPEG word buffer
// ============================================================================
// Consumes the encoder's m_axis_jpg byte stream (jpg_tvalid/tdata/tlast) and
// packs it little-endian, 4 bytes per 32-bit word, into the demo JPEG buffer
// (drive .we/.waddr/.wdata into demo_jpeg_buffer). Tracks the running byte count
// (jpeg_size, handed to jpeg_rtp_tx) and raises cap_done when the frame's EOI
// (jpg_tlast) has been captured.
//
// Notes:
//   - cap_done asserts only on jpg_tlast, never early. The demo control FSM
//     pulses cap_reset for the next frame right after streaming, so cap_done
//     must stay synced to the encoder's frame boundary (the encoder is then
//     quiescent). Asserting it early would let the next frame_kick fire while
//     the encoder is mid-frame -> a desynced capture.
//   - On overflow (a frame larger than the buffer, e.g. the noise/PRBS test
//     pattern) the excess bytes are dropped and `overflow` latches. The stream
//     is still a valid partial JPEG: jpeg_rtp_tx drops the trailing EOI_BYTES
//     and the RFC 2435 receiver reconstructs the JFIF header + a fresh EOI, so
//     the decoder always sees a clean, EOI-terminated (partial) frame.
//
// Verilog 2001.
// ============================================================================

`timescale 1ns / 1ps

module jpeg_capture #(
    parameter integer JPEG_WORDS = 65536      // 32-bit words in the JPEG buffer
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cap_reset,             // clear capture for a new frame

    // encoder byte stream (m_axis_jpg)
    input  wire        jpg_tvalid,
    input  wire [7:0]  jpg_tdata,
    input  wire        jpg_tlast,

    // JPEG buffer write port (to demo_jpeg_buffer)
    output wire        we,
    output wire [16:0] waddr,
    output wire [31:0] wdata,

    // status
    output wire [18:0] jpeg_size,             // total bytes captured (-> rtp_tx)
    output reg         cap_done,              // full JPEG (EOI) captured
    output reg         overflow               // frame exceeded the buffer
);
    localparam integer JPEG_BYTES = JPEG_WORDS * 4;

    reg [18:0] jpeg_byte_cnt;
    reg [1:0]  jp_phase;
    reg [23:0] jp_accum;
    reg [16:0] jp_wptr;
    reg        flush_pend;

    wire jpeg_word_room = (jp_wptr < JPEG_WORDS[16:0]);
    wire jpeg_byte_room = (jpeg_byte_cnt < JPEG_BYTES[18:0]);

    always @(posedge clk) begin
        if (!rst_n) begin
            jpeg_byte_cnt<=19'd0; jp_phase<=2'd0; jp_accum<=24'd0; jp_wptr<=17'd0;
            flush_pend<=1'b0; overflow<=1'b0; cap_done<=1'b0;
        end else if (cap_reset) begin
            jpeg_byte_cnt<=19'd0; jp_phase<=2'd0; jp_wptr<=17'd0;
            flush_pend<=1'b0; overflow<=1'b0; cap_done<=1'b0;
        end else begin
            flush_pend <= 1'b0;
            if (jpg_tvalid) begin
                if (jpeg_byte_room) begin
                    jpeg_byte_cnt <= jpeg_byte_cnt + 19'd1;
                    case (jp_phase)
                        2'd0: jp_accum[7:0]   <= jpg_tdata;
                        2'd1: jp_accum[15:8]  <= jpg_tdata;
                        2'd2: jp_accum[23:16] <= jpg_tdata;
                        2'd3: if (jpeg_word_room) jp_wptr <= jp_wptr + 17'd1;
                    endcase
                    jp_phase <= jp_phase + 2'd1;
                end else overflow <= 1'b1;
                if (jpg_tlast) begin
                    cap_done <= 1'b1;
                    if (jp_phase != 2'd3 && jpeg_word_room && !overflow)
                        flush_pend <= 1'b1;
                end
            end
        end
    end

    assign we    = (jpg_tvalid && jp_phase==2'd3 && jpeg_word_room) ||
                   (flush_pend && jpeg_word_room);
    assign wdata = (jpg_tvalid && jp_phase==2'd3) ? {jpg_tdata, jp_accum}
                                                  : {8'd0, jp_accum};
    assign waddr     = jp_wptr;
    assign jpeg_size = jpeg_byte_cnt;

endmodule
