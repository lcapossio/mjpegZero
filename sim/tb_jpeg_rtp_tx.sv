// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_jpeg_rtp_tx.sv - standalone testbench for the RTP/JPEG packetizer (M1).
//
// Loads a real JPEG (as 32-bit LE words via $readmemh) into a 1-cycle-latency
// memory model that mimics demo_jpeg_buffer, triggers one frame, and captures
// the emitted Ethernet/IP/UDP/RTP/JPEG byte stream to a text file: one packet
// per line, space-separated hex bytes. The Python verifier depacketizes and
// checks byte-exactness against the source JPEG.
//
// Run via scripts/run_rtp_sim.py (passes +JPEG_BYTES). Files are read/written
// at fixed paths relative to the repo root (the compile/run cwd).

`timescale 1ns / 1ps

`ifndef TB_IMG_W
 `define TB_IMG_W 1280
`endif
`ifndef TB_IMG_H
 `define TB_IMG_H 720
`endif

module tb_jpeg_rtp_tx #(
    parameter IMG_W = `TB_IMG_W,   // overridden via -DTB_IMG_W=... by the runner
    parameter IMG_H = `TB_IMG_H
);

    localparam HEX_PATH = "sim/rtp_test/jpeg_words.hex";
    localparam OUT_PATH = "sim/rtp_test/captured.txt";

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;   // 100 MHz

    // --- frame parameters ---
    integer jpeg_bytes;
    initial begin
        if (!$value$plusargs("JPEG_BYTES=%d", jpeg_bytes))
            jpeg_bytes = 0;
    end

    // --- identity / target (arbitrary; the verifier parses them back) ---
    localparam [47:0] OUR_MAC = 48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP  = 32'hC0_A8_01_32;   // 192.168.1.50
    localparam [15:0] SRC_PORT = 16'd5004;
    localparam [47:0] DST_MAC = 48'hAA_BB_CC_DD_EE_FF;
    localparam [31:0] DST_IP  = 32'hC0_A8_01_0A;   // 192.168.1.10
    localparam [15:0] DST_PORT = 16'd5004;
    localparam [31:0] SSRC    = 32'h0A_0B_0C_0D;
    localparam [31:0] RTP_TS  = 32'd12345678;

    // --- DUT <-> JPEG buffer model ---
    wire [16:0] mem_raddr;
    reg  [31:0] mem_rdata;
    reg  [31:0] jmem [0:65535];
    always @(posedge clk) mem_rdata <= jmem[mem_raddr[15:0]];  // 1-cycle latency

    // --- control / status ---
    reg         start;
    wire        busy;
    wire        done_pulse;

    // --- AXIS TX ---
    wire [7:0]  tx_data;
    wire        tx_valid;
    wire        tx_last;
    reg         tx_ready;

    // backpressure pattern: ready 7 of every 8 cycles (exercises the skid)
    reg [2:0] sc = 3'd0;
    always @(posedge clk) sc <= sc + 3'd1;
    always @* tx_ready = (sc != 3'd0);

    jpeg_rtp_tx #(
        .IMG_W      (IMG_W),
        .IMG_H      (IMG_H),
        .SCAN_OFF   (623),
        .EOI_BYTES  (2),
        .QT_LUMA_OFF(25),
        .QT_CHROMA_OFF(94),
        .SCAN_CHUNK (11'd1024)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .our_mac(OUR_MAC), .our_ip(OUR_IP), .src_port(SRC_PORT),
        .dst_mac(DST_MAC), .dst_ip(DST_IP), .dst_port(DST_PORT),
        .ssrc(SSRC), .rtp_timestamp(RTP_TS),
        .start(start), .jpeg_size(jpeg_bytes[18:0]),
        .busy(busy), .done_pulse(done_pulse),
        .mem_raddr(mem_raddr), .mem_rdata(mem_rdata),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_last(tx_last),
        .tx_ready(tx_ready)
    );

    // --- capture ---
    integer fd;
    integer byte_cnt = 0;
    integer pkt_cnt  = 0;
    always @(posedge clk) begin
        if (rst_n && tx_valid && tx_ready) begin
            $fwrite(fd, "%02x ", tx_data);
            byte_cnt = byte_cnt + 1;
            if (tx_last) begin
                $fwrite(fd, "\n");
                pkt_cnt = pkt_cnt + 1;
            end
        end
    end

    // --- stimulus ---
    integer drain;
    initial begin
        $readmemh(HEX_PATH, jmem);
        fd = $fopen(OUT_PATH, "w");
        start = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;

        // wait for completion
        wait (done_pulse === 1'b1);
        // drain the last skid byte(s)
        drain = 0;
        while (drain < 32) begin @(posedge clk); drain = drain + 1; end

        $fclose(fd);
        $display("[tb] done: %0d packets, %0d bytes captured (jpeg_bytes=%0d)",
                 pkt_cnt, byte_cnt, jpeg_bytes);
        $finish;
    end

    // --- safety timeout ---
    initial begin
        #50_000_000;  // 50 ms
        $display("[tb] TIMEOUT");
        $fclose(fd);
        $finish;
    end

endmodule
