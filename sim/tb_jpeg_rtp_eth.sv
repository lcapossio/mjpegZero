// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_jpeg_rtp_eth.sv - M2 integration TB for the Ethernet egress chain.
//
// Exercises the real wiring used by demo_top_eth, minus the MAC/MII:
//   trigger frame -> net_rx -> jpeg_rtp_trigger -> jpeg_rtp_tx -> arty_tx_arbiter
// A crafted UDP trigger datagram is streamed into net_rx's RX AXIS; the captured
// sender address must drive the emitted RTP/JPEG stream, which is captured off
// the arbiter's output and depacketized by python/rtp_jpeg_verify.py.
//
// net_rx ignores IP/UDP checksums, so the trigger frame uses csum=0.
// Shared identity/port constants below MUST match scripts/run_rtp_eth_sim.py
// (which passes the expected destination to the verifier as gate G5).
//
// Run via scripts/run_rtp_eth_sim.py.

`timescale 1ns / 1ps

`ifndef TB_IMG_W
 `define TB_IMG_W 1280
`endif
`ifndef TB_IMG_H
 `define TB_IMG_H 720
`endif

module tb_jpeg_rtp_eth #(
    parameter IMG_W = `TB_IMG_W,
    parameter IMG_H = `TB_IMG_H
);

    localparam OUT_PATH = "sim/rtp_test/captured.txt";
    localparam HEX_PATH = "sim/rtp_test/jpeg_words.hex";

    // ---- shared identity / ports (keep in sync with the runner) ----
    localparam [47:0] FPGA_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] FPGA_IP  = 32'hC0_A8_01_32;   // 192.168.1.50
    localparam [47:0] HOST_MAC = 48'hAA_BB_CC_DD_EE_FF;
    localparam [31:0] HOST_IP  = 32'hC0_A8_01_4D;   // 192.168.1.77
    localparam [15:0] HOST_PORT    = 16'hAA_55;
    localparam [15:0] TRIGGER_PORT = 16'd9999;
    localparam [15:0] RTP_DST_PORT = 16'd5004;
    localparam [15:0] RTP_SRC_PORT = 16'd5004;
    localparam [31:0] SSRC   = 32'h0A_0B_0C_0D;
    localparam [31:0] RTP_TS = 32'd12345678;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    integer jpeg_bytes;
    initial if (!$value$plusargs("JPEG_BYTES=%d", jpeg_bytes)) jpeg_bytes = 0;

    // ====================================================================
    // JPEG buffer model (32-bit words, 1-cycle latency)
    // ====================================================================
    wire [16:0] mem_raddr;
    reg  [31:0] mem_rdata;
    reg  [31:0] jmem [0:65535];
    always @(posedge clk) mem_rdata <= jmem[mem_raddr[15:0]];

    // ====================================================================
    // net_rx RX AXIS (driven by the trigger-frame injector)
    // ====================================================================
    reg  [7:0] rx_tdata;
    reg        rx_tvalid;
    reg        rx_tlast;
    reg        rx_tsof;

    wire [7:0]  ud_data;  wire ud_valid, ud_last;
    wire [31:0] ud_src_ip;
    wire [15:0] ud_src_port, ud_dst_port, ud_length;
    wire [47:0] rx_src_mac;

    net_rx u_net_rx (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(rx_tdata), .s_axis_tvalid(rx_tvalid),
        .s_axis_tlast(rx_tlast), .s_axis_tsof(rx_tsof), .s_axis_terror(1'b0),
        .arp_data(), .arp_valid(), .arp_last(),
        .icmp_data(), .icmp_valid(), .icmp_last(), .icmp_src_ip(),
        .udp_data(ud_data), .udp_valid(ud_valid), .udp_last(ud_last),
        .udp_src_ip(ud_src_ip), .udp_src_port(ud_src_port),
        .udp_dst_port(ud_dst_port), .udp_length(ud_length),
        .rx_src_mac(rx_src_mac),
        .our_ip(FPGA_IP)
    );

    // ====================================================================
    // Trigger capture
    // ====================================================================
    wire        trg_start;
    wire [47:0] trg_dst_mac;
    wire [31:0] trg_dst_ip;
    wire [15:0] trg_dst_port, trg_src_port;
    wire        busy;

    jpeg_rtp_trigger #(
        .TRIGGER_PORT(TRIGGER_PORT),
        .RTP_DST_PORT(RTP_DST_PORT),
        .RTP_SRC_PORT(RTP_SRC_PORT)
    ) u_trig (
        .clk(clk), .rst_n(rst_n),
        .udp_valid(ud_valid), .udp_last(ud_last), .udp_dst_port(ud_dst_port),
        .udp_rx_src_mac(rx_src_mac), .udp_rx_src_ip(ud_src_ip),
        .busy(busy),
        .start(trg_start), .dst_mac(trg_dst_mac), .dst_ip(trg_dst_ip),
        .dst_port(trg_dst_port), .src_port(trg_src_port)
    );

    // ====================================================================
    // Packetizer
    // ====================================================================
    wire [7:0] tx_data;  wire tx_valid, tx_last, tx_ready;
    wire       done_pulse;

    jpeg_rtp_tx #(
        .IMG_W(IMG_W), .IMG_H(IMG_H),
        .SCAN_OFF(623), .EOI_BYTES(2),
        .QT_LUMA_OFF(25), .QT_CHROMA_OFF(94),
        .SCAN_CHUNK(11'd1024)
    ) u_tx (
        .clk(clk), .rst_n(rst_n),
        .our_mac(FPGA_MAC), .our_ip(FPGA_IP), .src_port(trg_src_port),
        .dst_mac(trg_dst_mac), .dst_ip(trg_dst_ip), .dst_port(trg_dst_port),
        .ssrc(SSRC), .rtp_timestamp(RTP_TS),
        .start(trg_start), .jpeg_size(jpeg_bytes[18:0]),
        .busy(busy), .done_pulse(done_pulse),
        .mem_raddr(mem_raddr), .mem_rdata(mem_rdata),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_last(tx_last),
        .tx_ready(tx_ready)
    );

    // ====================================================================
    // Per-frame store-and-forward buffer (absorbs jpeg_rtp_tx mid-frame
    // bubbles so the cut-through MAC sees gap-free frames) then TX arbiter.
    // ====================================================================
    wire [7:0] fb_data;  wire fb_valid, fb_last, fb_ready;

    axis_frame_buffer #(.AW(11)) u_fb (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(tx_data), .s_tvalid(tx_valid), .s_tlast(tx_last), .s_tready(tx_ready),
        .m_tdata(fb_data), .m_tvalid(fb_valid), .m_tlast(fb_last), .m_tready(fb_ready)
    );

    wire [7:0] m_tdata;  wire m_tvalid, m_tlast;
    reg        m_tready;

    arty_tx_arbiter u_arb (
        .clk(clk), .rst_n(rst_n), .arp_tx_active(1'b0),
        .seq_tdata(8'd0),   .seq_tvalid(1'b0),   .seq_tready(),   .seq_tlast(1'b0),
        .arp_tdata(8'd0),   .arp_tvalid(1'b0),   .arp_tready(),   .arp_tlast(1'b0),
        .icmp_tdata(8'd0),  .icmp_tvalid(1'b0),  .icmp_tready(),  .icmp_tlast(1'b0),
        .stats_tdata(8'd0), .stats_tvalid(1'b0), .stats_tready(), .stats_tlast(1'b0),
        .udp_tdata(fb_data), .udp_tvalid(fb_valid), .udp_tready(fb_ready), .udp_tlast(fb_last),
        .blast_tdata(8'd0), .blast_tvalid(1'b0), .blast_tready(), .blast_tlast(1'b0),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast)
    );

    // gap-free monitor on the frame-buffer output: once a frame starts,
    // m_tvalid must stay high until tlast (else the cut-through MAC underruns).
    reg fb_inframe = 1'b0;
    integer fb_gap_errors = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (fb_inframe && !fb_valid) fb_gap_errors = fb_gap_errors + 1;
            if (fb_valid && fb_ready) fb_inframe <= !fb_last;
        end
    end

    // downstream "MAC" backpressure: ready 7 of every 8 cycles
    reg [2:0] sc = 3'd0;
    always @(posedge clk) sc <= sc + 3'd1;
    always @* m_tready = (sc != 3'd0);

    // ====================================================================
    // Capture arbiter output
    // ====================================================================
    integer fd;
    integer byte_cnt = 0;
    integer pkt_cnt  = 0;
    always @(posedge clk) begin
        if (rst_n && m_tvalid && m_tready) begin
            $fwrite(fd, "%02x ", m_tdata);
            byte_cnt = byte_cnt + 1;
            if (m_tlast) begin
                $fwrite(fd, "\n");
                pkt_cnt = pkt_cnt + 1;
            end
        end
    end

    // ====================================================================
    // Trigger frame (Eth/IPv4/UDP to TRIGGER_PORT, 4-byte payload, csum=0)
    // ====================================================================
    localparam FRAME_LEN = 46;
    reg [7:0] trig [0:FRAME_LEN-1];
    initial begin
        // Ethernet
        trig[0]=FPGA_MAC[47:40]; trig[1]=FPGA_MAC[39:32]; trig[2]=FPGA_MAC[31:24];
        trig[3]=FPGA_MAC[23:16]; trig[4]=FPGA_MAC[15:8];  trig[5]=FPGA_MAC[7:0];
        trig[6]=HOST_MAC[47:40]; trig[7]=HOST_MAC[39:32]; trig[8]=HOST_MAC[31:24];
        trig[9]=HOST_MAC[23:16]; trig[10]=HOST_MAC[15:8]; trig[11]=HOST_MAC[7:0];
        trig[12]=8'h08; trig[13]=8'h00;
        // IPv4 (total len 32, id 0, proto UDP, csum 0)
        trig[14]=8'h45; trig[15]=8'h00; trig[16]=8'h00; trig[17]=8'h20;
        trig[18]=8'h00; trig[19]=8'h00; trig[20]=8'h40; trig[21]=8'h00;
        trig[22]=8'h40; trig[23]=8'h11; trig[24]=8'h00; trig[25]=8'h00;
        trig[26]=HOST_IP[31:24]; trig[27]=HOST_IP[23:16];
        trig[28]=HOST_IP[15:8];  trig[29]=HOST_IP[7:0];
        trig[30]=FPGA_IP[31:24]; trig[31]=FPGA_IP[23:16];
        trig[32]=FPGA_IP[15:8];  trig[33]=FPGA_IP[7:0];
        // UDP (len 12, csum 0)
        trig[34]=HOST_PORT[15:8];    trig[35]=HOST_PORT[7:0];
        trig[36]=TRIGGER_PORT[15:8]; trig[37]=TRIGGER_PORT[7:0];
        trig[38]=8'h00; trig[39]=8'h0C; trig[40]=8'h00; trig[41]=8'h00;
        // payload
        trig[42]=8'h01; trig[43]=8'h02; trig[44]=8'h03; trig[45]=8'h04;
    end

    // ====================================================================
    // Stimulus
    // ====================================================================
    integer i, drain;
    initial begin
        $readmemh(HEX_PATH, jmem);
        fd = $fopen(OUT_PATH, "w");
        rx_tvalid = 1'b0; rx_tdata = 8'd0; rx_tlast = 1'b0; rx_tsof = 1'b0;

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // inject the trigger frame, one byte per cycle
        @(negedge clk);
        for (i = 0; i < FRAME_LEN; i = i + 1) begin
            rx_tvalid = 1'b1;
            rx_tdata  = trig[i];
            rx_tsof   = (i == 0);
            rx_tlast  = (i == FRAME_LEN - 1);
            @(negedge clk);
        end
        rx_tvalid = 1'b0; rx_tsof = 1'b0; rx_tlast = 1'b0;

        wait (done_pulse === 1'b1);
        // The frame buffer still has the last frame to emit after jpeg_rtp_tx
        // finishes feeding it; wait until the arbiter output is idle.
        drain = 0;
        while (drain < 64) begin
            @(posedge clk);
            if (m_tvalid) drain = 0; else drain = drain + 1;
        end

        $fclose(fd);
        $display("[tb] done: %0d packets, %0d bytes (jpeg_bytes=%0d), fb_gap_errors=%0d",
                 pkt_cnt, byte_cnt, jpeg_bytes, fb_gap_errors);
        $finish;
    end

    // sanity: report the captured destination
    always @(posedge clk)
        if (trg_start)
            $display("[tb] trigger fired: dst_mac=%012x dst_ip=%08x dst_port=%0d src_port=%0d",
                     trg_dst_mac, trg_dst_ip, trg_dst_port, trg_src_port);

    initial begin
        #50_000_000;
        $display("[tb] TIMEOUT");
        $fclose(fd);
        $finish;
    end

endmodule
