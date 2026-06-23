// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_egress.sv - reproduce the FPGA egress path with the REAL tiled
// demo_jpeg_buffer (the one component never covered by tb_jpeg_rtp_tx, which
// uses a flat ideal memory). Loads a known-correct JFIF into the buffer via its
// write port, streams it through jpeg_rtp_tx, and dumps Ethernet bytes per
// packet. A Python checker extracts the in-band QT + scan and compares to truth.

`timescale 1ns / 1ps

module tb_egress;
    localparam HEX = "sim/rtp_test/jpeg_words.hex";
    localparam OUT = "sim/rtp_test/egress.txt";
    localparam integer NWORDS = 298;
    localparam integer JPEG_BYTES = 1191;

    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;

    reg  [31:0] words [0:65535];

    // buffer write port (TB drives), read port (jpeg_rtp_tx drives)
    reg         bwe; reg [16:0] bwaddr; reg [31:0] bwdata;
    wire [16:0] mem_raddr; wire [31:0] mem_rdata;

    demo_jpeg_buffer #(.JPEG_WORDS(65536), .JPEG_TILE_DEPTH(4096)) u_buf (
        .clk(clk), .we(bwe), .waddr(bwaddr), .wdata(bwdata),
        .raddr(mem_raddr), .rdata(mem_rdata)
    );

    localparam [47:0] OUR_MAC=48'h02_00_00_00_00_01;
    localparam [31:0] OUR_IP =32'hC0_A8_ED_32;
    localparam [47:0] DST_MAC=48'hAA_BB_CC_DD_EE_FF;
    localparam [31:0] DST_IP =32'hC0_A8_ED_01;

    reg start; wire busy, done_pulse;
    wire [7:0] tx_data; wire tx_valid, tx_last; reg tx_ready;
    reg [2:0] sc=0; always @(posedge clk) sc<=sc+1; always @* tx_ready=(sc!=0);

    jpeg_rtp_tx #(
        .IMG_W(1280), .IMG_H(16), .SCAN_OFF(623), .EOI_BYTES(2),
        .QT_LUMA_OFF(25), .QT_CHROMA_OFF(94), .SCAN_CHUNK(11'd1024)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .our_mac(OUR_MAC), .our_ip(OUR_IP), .src_port(16'd5004),
        .dst_mac(DST_MAC), .dst_ip(DST_IP), .dst_port(16'd5004),
        .ssrc(32'h0A0B0C0D), .rtp_timestamp(32'd0),
        .start(start), .jpeg_size(JPEG_BYTES[18:0]),
        .busy(busy), .done_pulse(done_pulse),
        .mem_raddr(mem_raddr), .mem_rdata(mem_rdata),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_last(tx_last), .tx_ready(tx_ready)
    );

    integer fd, i;
    always @(posedge clk) begin
        if (rst_n && tx_valid && tx_ready) begin
            $fwrite(fd, "%02x ", tx_data);
            if (tx_last) $fwrite(fd, "\n");
        end
    end

    initial begin
        $readmemh(HEX, words);
        fd = $fopen(OUT, "w");
        bwe=0; bwaddr=0; bwdata=0; start=0;
        repeat(8) @(posedge clk); rst_n=1; repeat(4) @(posedge clk);
        // write the JFIF words into the tiled buffer
        for (i=0; i<NWORDS; i=i+1) begin
            @(posedge clk); bwe<=1; bwaddr<=i[16:0]; bwdata<=words[i];
        end
        @(posedge clk); bwe<=0;
        repeat(4) @(posedge clk);
        @(posedge clk); start<=1; @(posedge clk); start<=0;
        wait(done_pulse);
        repeat(20) @(posedge clk);
        $fclose(fd);
        $display("EGRESS DONE");
        $finish;
    end
    initial begin #20_000_000; $display("TIMEOUT"); $fclose(fd); $finish; end
endmodule
