// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_jpeg_path.v - cocotb wrapper for the demo JPEG output path:
//   jpeg_capture -> demo_jpeg_buffer -> jpeg_rtp_tx
//
// Exposes the encoder-side byte stream, the RTP trigger, and the MAC-side AXIS
// so the cocotb test can push a synthetic JPEG in and check the RTP/JPEG bytes
// that come out (catching capture<->RTP contract bugs: cap_done sync, byte
// packing, and the RFC 2435 EOI handling).

`timescale 1ns / 1ps

module tb_jpeg_path #(
    parameter integer JPEG_WORDS = 512
)(
    input  wire        clk,
    input  wire        rst_n,
    // encoder byte stream in
    input  wire        cap_reset,
    input  wire        jpg_tvalid,
    input  wire [7:0]  jpg_tdata,
    input  wire        jpg_tlast,
    // RTP trigger + AXIS sink handshake
    input  wire        start,
    input  wire        tx_ready,
    // capture status
    output wire        cap_done,
    output wire        overflow,
    output wire [18:0] jpeg_size,
    // RTP/MAC AXIS out
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    output wire        busy,
    output wire        done_pulse
);
    wire        jpeg_we;
    wire [16:0] jp_wptr;
    wire [31:0] jpeg_wdata;
    wire [16:0] rtp_raddr;
    wire [31:0] rtp_rdata;

    jpeg_capture #(.JPEG_WORDS(JPEG_WORDS)) u_cap (
        .clk(clk), .rst_n(rst_n), .cap_reset(cap_reset),
        .jpg_tvalid(jpg_tvalid), .jpg_tdata(jpg_tdata), .jpg_tlast(jpg_tlast),
        .we(jpeg_we), .waddr(jp_wptr), .wdata(jpeg_wdata),
        .jpeg_size(jpeg_size), .cap_done(cap_done), .overflow(overflow)
    );

    demo_jpeg_buffer #(.JPEG_WORDS(JPEG_WORDS), .JPEG_TILE_DEPTH(256)) u_buf (
        .clk(clk), .we(jpeg_we), .waddr(jp_wptr), .wdata(jpeg_wdata),
        .raddr(rtp_raddr), .rdata(rtp_rdata)
    );

    jpeg_rtp_tx #(.IMG_W(1280), .IMG_H(720)) u_rtp (
        .clk(clk), .rst_n(rst_n),
        .our_mac(48'h00_11_22_33_44_55), .our_ip(32'hC0A8_ED32),
        .src_port(16'd5004), .dst_mac(48'hAA_BB_CC_DD_EE_FF),
        .dst_ip(32'hC0A8_ED01), .dst_port(16'd5004),
        .ssrc(32'h1234_5678), .rtp_timestamp(32'd0),
        .start(start), .jpeg_size(jpeg_size),
        .busy(busy), .done_pulse(done_pulse),
        .mem_raddr(rtp_raddr), .mem_rdata(rtp_rdata),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_last(tx_last),
        .tx_ready(tx_ready)
    );
endmodule
