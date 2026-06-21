// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// ============================================================================
// jpeg_rtp_trigger.v - Capture an RTP stream destination from a UDP trigger
// ============================================================================
// Watches the UDP payload stream from net_rx. When a datagram arrives on
// TRIGGER_PORT (and the packetizer is idle), it latches the sender's MAC and
// IP as the RTP destination and pulses `start`. The RTP destination/source
// UDP ports are fixed parameters (so the host just runs `ffplay stream.sdp`
// listening on RTP_DST_PORT, then sends any small UDP packet to TRIGGER_PORT).
//
// The trigger datagram must carry at least one payload byte (net_rx only
// asserts udp_valid for payload bytes, and the match is evaluated at udp_last).
//
// Verilog 2001.
// ============================================================================

`timescale 1ns / 1ps

module jpeg_rtp_trigger #(
    parameter [15:0] TRIGGER_PORT = 16'd9999,
    parameter [15:0] RTP_DST_PORT = 16'd5004,
    parameter [15:0] RTP_SRC_PORT = 16'd5004
)(
    input  wire        clk,
    input  wire        rst_n,

    // From net_rx (UDP payload stream + parsed metadata)
    input  wire        udp_valid,
    input  wire        udp_last,
    input  wire [15:0] udp_dst_port,
    input  wire [47:0] udp_rx_src_mac,
    input  wire [31:0] udp_rx_src_ip,

    // Gate: ignore triggers while the packetizer is streaming
    input  wire        busy,

    // To jpeg_rtp_tx
    output reg         start,
    output reg  [47:0] dst_mac,
    output reg  [31:0] dst_ip,
    output reg  [15:0] dst_port,
    output reg  [15:0] src_port
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start    <= 1'b0;
            dst_mac  <= 48'd0;
            dst_ip   <= 32'd0;
            dst_port <= RTP_DST_PORT;
            src_port <= RTP_SRC_PORT;
        end else begin
            start <= 1'b0;
            if (udp_valid && udp_last &&
                (udp_dst_port == TRIGGER_PORT) && !busy) begin
                start    <= 1'b1;
                dst_mac  <= udp_rx_src_mac;
                dst_ip   <= udp_rx_src_ip;
                dst_port <= RTP_DST_PORT;
                src_port <= RTP_SRC_PORT;
            end
        end
    end

endmodule
