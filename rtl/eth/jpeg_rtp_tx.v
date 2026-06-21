// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// ============================================================================
// jpeg_rtp_tx.v - RTP/JPEG (RFC 2435) over UDP packetizer
// ============================================================================
// Streams one JPEG frame held in an external 32-bit word buffer (the demo
// JPEG BRAM) out as a sequence of RTP/JPEG/UDP/IPv4/Ethernet frames, ready to
// hand to an Ethernet MAC TX AXI4-Stream (e.g. emacZero eth_mac_sys, which adds
// preamble/SFD/FCS/IFG). Modeled on emacZero's udp_blast.v header-emit + 1-deep
// skid, extended to: fragment a finite payload, source the payload from BRAM,
// carry the quantization tables in-band, and set the RTP marker bit.
//
// Assumptions (true for this encoder, LITE_MODE=1, no DRI, no EXIF):
//   - JPEG header is a fixed SCAN_OFF (=623) bytes; scan data is bytes
//     [SCAN_OFF .. jpeg_size-3]; the final 2 bytes are the EOI marker (FF D9).
//   - Luma quant table (64 B, zigzag) at byte offset QT_LUMA_OFF (=25),
//     chroma at QT_CHROMA_OFF (=94).
//   - YUV 4:2:2 + restart_interval=0  -> RFC 2435 type 0, no restart markers.
//   - Q=255 -> quant tables sent in-band (quant-table header) on the first
//     packet of each frame; the receiver rebuilds the JFIF headers.
//
// The scan data is transmitted verbatim, including JPEG byte-stuffing
// (0xFF -> 0xFF 00), exactly as it sits in the buffer, excluding the EOI.
//
// BRAM read: drive mem_raddr (word index) combinationally; mem_rdata is the
// word registered one cycle later (1-cycle latency, LE byte packing). A byte is
// available this cycle iff the same word was requested last cycle (req_word_q).
//
// Verilog 2001.
// ============================================================================

`timescale 1ns / 1ps

module jpeg_rtp_tx #(
    parameter         IMG_W         = 1280,
    parameter         IMG_H         = 720,
    parameter integer SCAN_OFF      = 623,   // first scan byte in buffer
    parameter integer EOI_BYTES     = 2,     // trailing EOI bytes to drop
    parameter integer QT_LUMA_OFF   = 25,    // luma quant table byte offset
    parameter integer QT_CHROMA_OFF = 94,    // chroma quant table byte offset
    parameter [10:0]  SCAN_CHUNK    = 11'd1024 // scan bytes per packet
)(
    input  wire        clk,
    input  wire        rst_n,

    // Identity / target (latched at frame start)
    input  wire [47:0] our_mac,
    input  wire [31:0] our_ip,
    input  wire [15:0] src_port,
    input  wire [47:0] dst_mac,
    input  wire [31:0] dst_ip,
    input  wire [15:0] dst_port,
    input  wire [31:0] ssrc,
    input  wire [31:0] rtp_timestamp,  // 90 kHz units; constant within a frame

    // Frame trigger
    input  wire        start,          // 1-cycle pulse: stream current buffer
    input  wire [18:0] jpeg_size,      // total JPEG byte count (header+scan+EOI)
    output reg         busy,
    output reg         done_pulse,     // 1-cycle pulse after last packet

    // JPEG buffer read port (32-bit words, 1-cycle registered latency)
    output wire [16:0] mem_raddr,
    input  wire [31:0] mem_rdata,

    // AXIS TX master (to MAC / arbiter)
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    output wire        tx_last,
    input  wire        tx_ready
);

    // Compact image dimensions for the RTP/JPEG header (units of 8 px).
    localparam [7:0] W8 = (IMG_W / 8);
    localparam [7:0] H8 = (IMG_H / 8);

    // Section codes
    localparam [2:0]
        S_IDLE   = 3'd0,  // not emitting
        S_ETH    = 3'd1,  // 14 bytes
        S_IP     = 3'd2,  // 20 bytes
        S_UDP    = 3'd3,  // 8 bytes
        S_RTP    = 3'd4,  // 12 bytes
        S_JHDR   = 3'd5,  // 8 bytes
        S_QT     = 3'd6,  // 4 bytes  (first packet only)
        S_QTDATA = 3'd7;  // 128 bytes (first packet only)
    // Scan section reuses a separate flag (sec==S_IDLE is free, so use a wider
    // encoding). Encode SCAN as a dedicated state via a 4th bit.
    reg        in_scan;   // 1 = currently emitting the scan payload section

    // ---- Frame-level latched state ----
    reg [18:0] scan_remaining;  // scan bytes not yet packetized
    reg [23:0] frag_off;        // scan bytes already sent (RTP fragment offset)
    reg [31:0] ts_lat;
    reg [15:0] seq;             // RTP sequence number (free-running)
    reg [15:0] ip_id;           // IP identification (free-running)

    // ---- Packet-level latched state ----
    reg [10:0] p_chunk;         // scan bytes in this packet
    reg        p_first;         // this is the first packet of the frame
    reg        p_last;          // this is the last packet of the frame
    reg [15:0] p_udp_total;     // UDP length field
    reg [15:0] p_ip_total;      // IP total length field
    reg [15:0] p_ip_csum;       // IP header checksum
    reg [15:0] p_ip_id;
    reg [23:0] p_frag;

    // ---- Emission pointers ----
    reg [2:0]  sec;
    reg [10:0] idx;             // byte index within the current section

    // ---- AXIS 1-deep skid ----
    reg [7:0]  r_data;
    reg        r_valid;
    reg        r_last;
    assign tx_data  = r_data;
    assign tx_valid = r_valid;
    assign tx_last  = r_last;
    wire       src_ready = !r_valid || tx_ready;

    // ---- Top-level FSM ----
    localparam [1:0] F_IDLE = 2'd0, F_INIT = 2'd1, F_EMIT = 2'd2, F_NEXT = 2'd3;
    reg [1:0]  fstate;

    // ========================================================================
    // IP header checksum (combinational over the fields that vary per packet).
    // Fixed bytes: 45 00 | tot | id | 40 00 | 40 11 | 0000 | our_ip | dst_ip
    // ========================================================================
    wire [31:0] ipc_sum = 32'h00004500
                        + {16'd0, p_ip_total}
                        + {16'd0, p_ip_id}
                        + 32'h00004000
                        + 32'h00004011
                        + {16'd0, our_ip[31:16]}
                        + {16'd0, our_ip[15:0]}
                        + {16'd0, dst_ip[31:16]}
                        + {16'd0, dst_ip[15:0]};
    wire [16:0] ipc_f1  = ipc_sum[15:0] + ipc_sum[31:16];
    wire [15:0] ipc_f2  = ipc_f1[15:0] + {15'd0, ipc_f1[16]};
    wire [15:0] ip_csum_calc = ~ipc_f2;

    // ========================================================================
    // BRAM byte fetch. base byte address for the current memory byte.
    // ========================================================================
    reg  [18:0] mem_base;       // byte address of idx==0 of the mem section
    wire [18:0] byte_addr = mem_base + {8'd0, idx};
    wire [16:0] need_word = byte_addr[18:2];
    wire [1:0]  need_lane = byte_addr[1:0];
    wire        mem_sec   = in_scan || (sec == S_QTDATA);

    assign mem_raddr = need_word;

    reg  [16:0] req_word_q;      // word address requested last cycle
    always @(posedge clk) req_word_q <= need_word;
    wire        mem_hit  = (req_word_q == need_word);
    wire [7:0]  mem_byte = mem_rdata[need_lane*8 +: 8];

    // ========================================================================
    // Section length (bytes) of the current section.
    // ========================================================================
    reg [10:0] sec_len;
    always @* begin
        case (sec)
            S_ETH:    sec_len = 11'd14;
            S_IP:     sec_len = 11'd20;
            S_UDP:    sec_len = 11'd8;
            S_RTP:    sec_len = 11'd12;
            S_JHDR:   sec_len = 11'd8;
            S_QT:     sec_len = 11'd4;
            S_QTDATA: sec_len = 11'd128;
            default:  sec_len = p_chunk;   // scan
        endcase
    end
    wire sec_last_byte = (idx == sec_len - 11'd1);
    wire pkt_last_byte = in_scan && sec_last_byte;

    // ========================================================================
    // Output byte mux.
    // ========================================================================
    reg [7:0] out_byte;
    always @* begin
        out_byte = 8'h00;
        if (in_scan || sec == S_QTDATA) begin
            out_byte = mem_byte;
        end else begin
            case (sec)
                S_ETH: case (idx[3:0])
                    4'd0:  out_byte = dst_mac[47:40];
                    4'd1:  out_byte = dst_mac[39:32];
                    4'd2:  out_byte = dst_mac[31:24];
                    4'd3:  out_byte = dst_mac[23:16];
                    4'd4:  out_byte = dst_mac[15:8];
                    4'd5:  out_byte = dst_mac[7:0];
                    4'd6:  out_byte = our_mac[47:40];
                    4'd7:  out_byte = our_mac[39:32];
                    4'd8:  out_byte = our_mac[31:24];
                    4'd9:  out_byte = our_mac[23:16];
                    4'd10: out_byte = our_mac[15:8];
                    4'd11: out_byte = our_mac[7:0];
                    4'd12: out_byte = 8'h08;        // ethertype 0x0800
                    default: out_byte = 8'h00;
                endcase
                S_IP: case (idx[4:0])
                    5'd0:  out_byte = 8'h45;        // ver/IHL
                    5'd1:  out_byte = 8'h00;        // DSCP/ECN
                    5'd2:  out_byte = p_ip_total[15:8];
                    5'd3:  out_byte = p_ip_total[7:0];
                    5'd4:  out_byte = p_ip_id[15:8];
                    5'd5:  out_byte = p_ip_id[7:0];
                    5'd6:  out_byte = 8'h40;        // flags=DF, frag=0
                    5'd7:  out_byte = 8'h00;
                    5'd8:  out_byte = 8'h40;        // TTL = 64
                    5'd9:  out_byte = 8'h11;        // proto = UDP
                    5'd10: out_byte = p_ip_csum[15:8];
                    5'd11: out_byte = p_ip_csum[7:0];
                    5'd12: out_byte = our_ip[31:24];
                    5'd13: out_byte = our_ip[23:16];
                    5'd14: out_byte = our_ip[15:8];
                    5'd15: out_byte = our_ip[7:0];
                    5'd16: out_byte = dst_ip[31:24];
                    5'd17: out_byte = dst_ip[23:16];
                    5'd18: out_byte = dst_ip[15:8];
                    default: out_byte = dst_ip[7:0];
                endcase
                S_UDP: case (idx[2:0])
                    3'd0: out_byte = src_port[15:8];
                    3'd1: out_byte = src_port[7:0];
                    3'd2: out_byte = dst_port[15:8];
                    3'd3: out_byte = dst_port[7:0];
                    3'd4: out_byte = p_udp_total[15:8];
                    3'd5: out_byte = p_udp_total[7:0];
                    default: out_byte = 8'h00;      // UDP csum = 0 (skipped)
                endcase
                S_RTP: case (idx[3:0])
                    4'd0:  out_byte = 8'h80;                    // V=2
                    4'd1:  out_byte = p_last ? 8'h9A : 8'h1A;   // M | PT=26
                    4'd2:  out_byte = seq[15:8];
                    4'd3:  out_byte = seq[7:0];
                    4'd4:  out_byte = ts_lat[31:24];
                    4'd5:  out_byte = ts_lat[23:16];
                    4'd6:  out_byte = ts_lat[15:8];
                    4'd7:  out_byte = ts_lat[7:0];
                    4'd8:  out_byte = ssrc[31:24];
                    4'd9:  out_byte = ssrc[23:16];
                    4'd10: out_byte = ssrc[15:8];
                    default: out_byte = ssrc[7:0];
                endcase
                S_JHDR: case (idx[2:0])
                    3'd0: out_byte = 8'h00;          // type-specific
                    3'd1: out_byte = p_frag[23:16];  // fragment offset
                    3'd2: out_byte = p_frag[15:8];
                    3'd3: out_byte = p_frag[7:0];
                    3'd4: out_byte = 8'h00;          // type 0 (4:2:2, no DRI)
                    3'd5: out_byte = 8'hFF;          // Q = 255 (tables in-band)
                    3'd6: out_byte = W8;             // width / 8
                    default: out_byte = H8;          // height / 8
                endcase
                S_QT: case (idx[1:0])
                    2'd0: out_byte = 8'h00;          // MBZ
                    2'd1: out_byte = 8'h00;          // precision (8-bit tables)
                    2'd2: out_byte = 8'h00;          // length hi (128)
                    default: out_byte = 8'h80;       // length lo = 128
                endcase
                default: out_byte = 8'h00;
            endcase
        end
    end

    // Byte is presentable this cycle: header bytes always; memory bytes on hit.
    wire emit_active = (fstate == F_EMIT);
    wire out_valid_int = emit_active && (mem_sec ? mem_hit : 1'b1);
    wire beat = src_ready && out_valid_int;   // byte latched into skid this cycle

    // mem_base for the current memory section (combinational select).
    always @* begin
        if (in_scan)
            mem_base = SCAN_OFF[18:0] + {19{1'b0}} + p_frag[18:0];
        else if (sec == S_QTDATA)
            mem_base = (idx < 11'd64) ? QT_LUMA_OFF[18:0]
                                      : (QT_CHROMA_OFF[18:0] - 19'd64);
        else
            mem_base = 19'd0;
    end

    // ========================================================================
    // Main FSM
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate         <= F_IDLE;
            busy           <= 1'b0;
            done_pulse     <= 1'b0;
            sec            <= S_IDLE;
            in_scan        <= 1'b0;
            idx            <= 11'd0;
            scan_remaining <= 19'd0;
            frag_off       <= 24'd0;
            ts_lat         <= 32'd0;
            seq            <= 16'd0;
            ip_id          <= 16'd0;
            p_chunk        <= 11'd0;
            p_first        <= 1'b0;
            p_last         <= 1'b0;
            p_udp_total    <= 16'd0;
            p_ip_total     <= 16'd0;
            p_ip_csum      <= 16'd0;
            p_ip_id        <= 16'd0;
            p_frag         <= 24'd0;
            r_data         <= 8'd0;
            r_valid        <= 1'b0;
            r_last         <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            // ---- AXIS skid update ----
            if (src_ready) begin
                r_data  <= out_byte;
                r_valid <= out_valid_int;
                r_last  <= out_valid_int && pkt_last_byte;
            end

            case (fstate)
                // ----------------------------------------------------------
                F_IDLE: begin
                    busy <= 1'b0;
                    if (start && jpeg_size > (SCAN_OFF[18:0] + EOI_BYTES[18:0])) begin
                        busy           <= 1'b1;
                        scan_remaining <= jpeg_size - SCAN_OFF[18:0] - EOI_BYTES[18:0];
                        frag_off       <= 24'd0;
                        ts_lat         <= rtp_timestamp;
                        fstate         <= F_INIT;
                    end
                end

                // ---- Compute this packet's geometry, then start emitting ----
                F_INIT: begin
                    p_first <= (frag_off == 24'd0);
                    p_frag  <= frag_off;
                    p_ip_id <= ip_id;
                    if (scan_remaining > {8'd0, SCAN_CHUNK}) begin
                        p_chunk <= SCAN_CHUNK;
                        p_last  <= 1'b0;
                    end else begin
                        p_chunk <= scan_remaining[10:0];
                        p_last  <= 1'b1;
                    end
                    sec     <= S_ETH;
                    in_scan <= 1'b0;
                    idx     <= 11'd0;
                    fstate  <= F_EMIT;
                end

                // ----------------------------------------------------------
                F_EMIT: begin
                    if (beat) begin
                        if (sec_last_byte) begin
                            idx <= 11'd0;
                            // advance to next section
                            case (sec)
                                S_ETH:  sec <= S_IP;
                                S_IP:   sec <= S_UDP;
                                S_UDP:  sec <= S_RTP;
                                S_RTP:  sec <= S_JHDR;
                                S_JHDR: begin
                                    if (p_first) sec <= S_QT;
                                    else begin sec <= S_IDLE; in_scan <= 1'b1; end
                                end
                                S_QT:     sec <= S_QTDATA;
                                S_QTDATA: begin sec <= S_IDLE; in_scan <= 1'b1; end
                                default:  sec <= S_IDLE;   // (scan handled below)
                            endcase
                            if (in_scan) begin
                                // last byte of the scan section -> packet done
                                in_scan <= 1'b0;
                                fstate  <= F_NEXT;
                            end
                        end else begin
                            idx <= idx + 11'd1;
                        end
                    end
                end

                // ---- Packet finished: bump counters, loop or finish ----
                F_NEXT: begin
                    seq      <= seq + 16'd1;
                    ip_id    <= ip_id + 16'd1;
                    frag_off <= frag_off + {13'd0, p_chunk};
                    if (scan_remaining > {8'd0, p_chunk})
                        scan_remaining <= scan_remaining - {8'd0, p_chunk};
                    else
                        scan_remaining <= 19'd0;

                    if (p_last) begin
                        busy       <= 1'b0;
                        done_pulse <= 1'b1;
                        fstate     <= F_IDLE;
                    end else begin
                        fstate <= F_INIT;
                    end
                end

                default: fstate <= F_IDLE;
            endcase
        end
    end

    // Latch per-packet length/checksum fields the cycle after F_INIT computes
    // p_chunk/p_first (combinational ipc uses p_ip_total/p_ip_id). Computed here
    // from the freshly-registered p_* values during the first F_EMIT cycle.
    always @(posedge clk) begin
        if (fstate == F_INIT) begin
            // udp data = RTP(12)+JHDR(8) + [QT(4)+128] + chunk
            p_udp_total <= 16'd8 + 16'd20
                         + ((frag_off == 24'd0) ? 16'd132 : 16'd0)
                         + ({5'd0, ((scan_remaining > {8'd0, SCAN_CHUNK})
                                    ? SCAN_CHUNK : scan_remaining[10:0])});
        end
    end

    // p_ip_total / p_ip_csum follow p_udp_total one cycle later; recompute
    // continuously so the checksum tracks p_ip_total/p_ip_id while emitting.
    always @(posedge clk) begin
        p_ip_total <= 16'd20 + p_udp_total;
        p_ip_csum  <= ip_csum_calc;
    end

endmodule
