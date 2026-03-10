// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// tb_demo_top.sv — Behavioral testbench for demo_top_bare
// Replaces jtag_axi_0 with a simple AXI4 master.
// Resolution: 320x180 (180p) — all 16 MCU columns x 22 MCU rows (rounded up to multiple of 16 lines)
// NOTE: 180 is not a multiple of 8*2=16; encoder processes 16-line MCU strips.
//       Use 176 lines (11*16) to keep frame MCU-aligned.  Reduce to 160 if needed.
//
// Protocol mirroring demo_top AXI map:
//   0x0000_0000  PIXEL PORT (write bursts)   32-bit word = {Cr,Y1}[31:16] | {Cb,Y0}[15:0]
//   0x0200_0000  CTRL write: [1]=RESET [0]=START
//   0x0200_0000  STATUS read: [0]=enc_done
//   0x0200_0004  JPEG_SIZE read: [17:0]=byte count
//   0x0300_0000  JPEG PORT (read bursts)
//
// Simulation flow:
//   1. Assert RESET
//   2. Upload 320x176 pixels as 28160 AXI words (max burst=256 words = 1024 B)
//   3. Write START
//   4. Poll STATUS until enc_done=1
//   5. Read JPEG_SIZE
//   6. Burst-read JPEG bytes
//   7. Save raw JPEG to sim/demo_sim_output.jpg
//   8. Verify SOI (FFD8) / EOI (FFD9) markers
//
`timescale 1ns / 1ps

module tb_demo_top;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam CLK_PERIOD  = 6;           // 150 MHz (6 ns)
    localparam IMG_W       = 320;
    localparam IMG_H       = 176;         // MCU-aligned (176 = 11*16)
    localparam FRAME_PXLS  = IMG_W * IMG_H;    // 56320 pixels
    localparam FRAME_WORDS = FRAME_PXLS / 2;   // 28160 AXI 32-bit words
    localparam JPEG_WORDS_P = 16384;      // 64 KB output buffer (16 RAMB36)

    localparam AXI_PIXEL_BASE = 32'h0000_0000;
    localparam AXI_CTRL_ADDR  = 32'h0200_0000;
    localparam AXI_SIZE_ADDR  = 32'h0200_0004;
    localparam AXI_JPEG_BASE  = 32'h0300_0000;

    // Max burst length (AXI4: len=N means N+1 transfers)
    localparam BURST_LEN = 8'd255;        // 256 words per burst

    // Timeout (in clocks) for enc_done polling
    localparam POLL_TIMEOUT = 10_000_000;

    // -----------------------------------------------------------------------
    // Clock & signals
    // -----------------------------------------------------------------------
    reg  clk, rst_n;
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // AXI4 master (testbench drives)
    reg  [31:0] m_awaddr;
    reg  [7:0]  m_awlen;
    reg  [2:0]  m_awsize;
    reg  [1:0]  m_awburst;
    reg  [2:0]  m_awprot;
    reg         m_awvalid;
    wire        m_awready;

    reg  [31:0] m_wdata;
    reg  [3:0]  m_wstrb;
    reg         m_wlast;
    reg         m_wvalid;
    wire        m_wready;

    wire [1:0]  m_bresp;
    wire        m_bvalid;
    reg         m_bready;

    reg  [31:0] m_araddr;
    reg  [7:0]  m_arlen;
    reg  [2:0]  m_arsize;
    reg  [1:0]  m_arburst;
    reg  [2:0]  m_arprot;
    reg         m_arvalid;
    wire        m_arready;

    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rlast;
    wire        m_rvalid;
    reg         m_rready;

    wire led0, led1, led2, led3;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    demo_top_bare #(
        .IMG_W        (IMG_W),
        .IMG_H        (IMG_H),
        .LITE_QUALITY (75),
        .JPEG_WORDS   (JPEG_WORDS_P)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .m_awaddr (m_awaddr), .m_awlen  (m_awlen),  .m_awsize (m_awsize),
        .m_awburst(m_awburst),.m_awprot (m_awprot), .m_awvalid(m_awvalid),
        .m_awready(m_awready),
        .m_wdata  (m_wdata),  .m_wstrb  (m_wstrb),  .m_wlast  (m_wlast),
        .m_wvalid (m_wvalid), .m_wready (m_wready),
        .m_bresp  (m_bresp),  .m_bvalid (m_bvalid), .m_bready (m_bready),
        .m_araddr (m_araddr), .m_arlen  (m_arlen),  .m_arsize (m_arsize),
        .m_arburst(m_arburst),.m_arprot (m_arprot), .m_arvalid(m_arvalid),
        .m_arready(m_arready),
        .m_rdata  (m_rdata),  .m_rresp  (m_rresp),  .m_rlast  (m_rlast),
        .m_rvalid (m_rvalid), .m_rready (m_rready),
        .led0(led0), .led1(led1), .led2(led2), .led3(led3)
    );

    // -----------------------------------------------------------------------
    // Pixel test vector (YUYV 320x176)
    // Loaded from binary file written by gen_tb_pixels.py, or synthesized here.
    // Each entry: 32-bit word = {Cr,Y1}[31:16] | {Cb,Y0}[15:0]
    // -----------------------------------------------------------------------
    reg [31:0] pix_mem [0:FRAME_WORDS-1];

    // -----------------------------------------------------------------------
    // JPEG output buffer
    // -----------------------------------------------------------------------
    reg [7:0] jpeg_buf [0:JPEG_WORDS_P*4-1];  // byte-wide view
    integer   jpeg_byte_count;

    // -----------------------------------------------------------------------
    // Helper tasks
    // -----------------------------------------------------------------------

    // Wait N clock rising edges
    task wait_clk;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
        end
    endtask

    // AXI4 single-beat write (len=0)
    task axi_write_word;
        input [31:0] addr;
        input [31:0] data;
        begin
            // AW channel
            @(posedge clk);
            m_awaddr  <= addr;
            m_awlen   <= 8'd0;
            m_awsize  <= 3'b010;   // 4 bytes
            m_awburst <= 2'b01;    // INCR
            m_awprot  <= 3'b000;
            m_awvalid <= 1'b1;
            @(posedge clk);
            while (!m_awready) @(posedge clk);
            m_awvalid <= 1'b0;

            // W channel
            m_wdata  <= data;
            m_wstrb  <= 4'hF;
            m_wlast  <= 1'b1;
            m_wvalid <= 1'b1;
            @(posedge clk);
            while (!m_wready) @(posedge clk);
            m_wvalid <= 1'b0;
            m_wlast  <= 1'b0;

            // B channel: wait for bvalid first, THEN assert bready.
            // Pre-asserting bready causes a same-cycle override: DUT sets
            // m_bvalid<=1 then m_bvalid<=0 in the same always block evaluation,
            // so m_bvalid never goes high in the output register.
            @(posedge clk);
            while (!m_bvalid) @(posedge clk);
            m_bready <= 1'b1;
            @(posedge clk);
            m_bready <= 1'b0;
            @(posedge clk);
        end
    endtask

    // AXI4 burst write (len+1 beats starting at addr, data from pix_mem[base])
    task axi_write_burst;
        input [31:0] addr;
        input [31:0] base;  // pix_mem start index
        input [7:0]  len;   // AXI len (beats-1)
        integer b;
        begin
            // AW channel
            @(posedge clk);
            m_awaddr  <= addr;
            m_awlen   <= len;
            m_awsize  <= 3'b010;
            m_awburst <= 2'b01;
            m_awprot  <= 3'b000;
            m_awvalid <= 1'b1;
            @(posedge clk);
            while (!m_awready) @(posedge clk);
            m_awvalid <= 1'b0;

            // W channel — stream beats
            for (b = 0; b <= len; b = b + 1) begin
                m_wdata  <= pix_mem[base + b];
                m_wstrb  <= 4'hF;
                m_wlast  <= (b == len) ? 1'b1 : 1'b0;
                m_wvalid <= 1'b1;
                @(posedge clk);
                while (!m_wready) @(posedge clk);
            end
            m_wvalid <= 1'b0;
            m_wlast  <= 1'b0;

            // B channel: wait for bvalid before asserting bready
            @(posedge clk);
            while (!m_bvalid) @(posedge clk);
            m_bready <= 1'b1;
            @(posedge clk);
            m_bready <= 1'b0;
            @(posedge clk);
        end
    endtask

    // AXI4 single-beat read
    task axi_read_word;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk);
            m_araddr  <= addr;
            m_arlen   <= 8'd0;
            m_arsize  <= 3'b010;
            m_arburst <= 2'b01;
            m_arprot  <= 3'b000;
            m_arvalid <= 1'b1;
            @(posedge clk);
            while (!m_arready) @(posedge clk);
            m_arvalid <= 1'b0;

            m_rready <= 1'b1;
            @(posedge clk);
            while (!m_rvalid) @(posedge clk);
            data = m_rdata;
            m_rready <= 1'b0;
            @(posedge clk);
        end
    endtask

    // AXI4 burst read — fills jpeg_buf starting at buf_offset (byte offset)
    // reads (len+1) 32-bit words = (len+1)*4 bytes
    task axi_read_burst;
        input  [31:0] addr;
        input  [7:0]  len;
        input  integer buf_off;  // byte offset into jpeg_buf
        integer b;
        reg [31:0] tmp;
        begin
            @(posedge clk);
            m_araddr  <= addr;
            m_arlen   <= len;
            m_arsize  <= 3'b010;
            m_arburst <= 2'b01;
            m_arprot  <= 3'b000;
            m_arvalid <= 1'b1;
            @(posedge clk);
            while (!m_arready) @(posedge clk);
            m_arvalid <= 1'b0;

            m_rready <= 1'b1;
            b = 0;
            while (b <= len) begin
                @(posedge clk);
                if (m_rvalid) begin
                    tmp = m_rdata;
                    // LE byte order: byte0=tmp[7:0], byte1=tmp[15:8], ...
                    jpeg_buf[buf_off + b*4 + 0] = tmp[7:0];
                    jpeg_buf[buf_off + b*4 + 1] = tmp[15:8];
                    jpeg_buf[buf_off + b*4 + 2] = tmp[23:16];
                    jpeg_buf[buf_off + b*4 + 3] = tmp[31:24];
                    b = b + 1;
                end
            end
            m_rready <= 1'b0;
            @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Generate a simple YUYV test image (color bars) if no file is available.
    // Pattern: 8 vertical bars, each 40 pixels wide.
    // YUYV encoding: word = {Cr, Y1, Cb, Y0}  — but demo_top expects
    //   word[15:0]  = {Cb, Y0}   (even pixel)
    //   word[31:16] = {Cr, Y1}   (odd pixel)
    // -----------------------------------------------------------------------
    integer px, row, col;
    reg [7:0] Y0, Y1, Cb, Cr;
    // YCbCr values for 8 color bars (ITU-R BT.601 full range)
    //                  Y    Cb   Cr
    reg [7:0] bar_y  [0:7]; // luma
    reg [7:0] bar_cb [0:7]; // Cb
    reg [7:0] bar_cr [0:7]; // Cr
    integer bar_idx;

    task gen_color_bars;
        integer r, c, word_idx;
        reg [7:0] cy0, cy1, ccb, ccr;
        begin
            // White, Yellow, Cyan, Green, Magenta, Red, Blue, Black
            bar_y [0] = 8'd235; bar_cb[0] = 8'd128; bar_cr[0] = 8'd128;
            bar_y [1] = 8'd210; bar_cb[1] = 8'd16;  bar_cr[1] = 8'd146;
            bar_y [2] = 8'd170; bar_cb[2] = 8'd166; bar_cr[2] = 8'd16;
            bar_y [3] = 8'd145; bar_cb[3] = 8'd54;  bar_cr[3] = 8'd34;
            bar_y [4] = 8'd106; bar_cb[4] = 8'd202; bar_cr[4] = 8'd222;
            bar_y [5] = 8'd81;  bar_cb[5] = 8'd90;  bar_cr[5] = 8'd240;
            bar_y [6] = 8'd41;  bar_cb[6] = 8'd240; bar_cr[6] = 8'd110;
            bar_y [7] = 8'd16;  bar_cb[7] = 8'd128; bar_cr[7] = 8'd128;

            word_idx = 0;
            for (r = 0; r < IMG_H; r = r + 1) begin
                for (c = 0; c < IMG_W; c = c + 2) begin
                    bar_idx = (c * 8) / IMG_W;
                    cy0 = bar_y [bar_idx];
                    ccb = bar_cb[bar_idx];
                    bar_idx = ((c+1) * 8) / IMG_W;
                    cy1 = bar_y [bar_idx];
                    ccr = bar_cr[bar_idx];
                    // word = {Cr, Y1} << 16 | {Cb, Y0}
                    pix_mem[word_idx] = {ccr, cy1, ccb, cy0};
                    word_idx = word_idx + 1;
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    integer   i, words_remaining, burst_words, burst_base;
    integer   addr_offset;
    integer   total_words_to_read, words_read, read_len;
    reg [31:0] rdata;
    integer   fd;
    integer   clk_count;

    initial begin : tb_main
        // Default AXI idle state
        m_awaddr  = 0; m_awlen  = 0; m_awsize = 0;
        m_awburst = 0; m_awprot = 0; m_awvalid = 0;
        m_wdata   = 0; m_wstrb  = 0; m_wlast  = 0; m_wvalid = 0;
        m_bready  = 0;
        m_araddr  = 0; m_arlen  = 0; m_arsize = 0;
        m_arburst = 0; m_arprot = 0; m_arvalid = 0;
        m_rready  = 0;

        // Reset
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (10) @(posedge clk);

        // ----------------------------------------------------------------
        // Step 0: wait for axi_init to enable encoder, then RESET demo state
        // ----------------------------------------------------------------
        $display("[TB] Step 0: waiting for axi_init, then RESET");
        wait_clk(30);  // axi_init completes in ~10 cycles after rst_n
        axi_write_word(AXI_CTRL_ADDR, 32'h0000_0002);  // RESET demo state
        wait_clk(5);

        // ----------------------------------------------------------------
        // Step 1: generate test image (color bars)
        // ----------------------------------------------------------------
        $display("[TB] Step 1: generating color-bar test image %0dx%0d", IMG_W, IMG_H);
        gen_color_bars;

        // ----------------------------------------------------------------
        // Step 2: issue START *before* pixel upload so the pixel pump
        //         drains the 64-entry FIFO concurrently with uploads.
        //         Without START, the FIFO fills on the first burst and stalls.
        // ----------------------------------------------------------------
        $display("[TB] Step 2: START (before pixel upload)");
        axi_write_word(AXI_CTRL_ADDR, 32'h0000_0001);  // START
        wait_clk(5);

        // ----------------------------------------------------------------
        // Step 3: upload pixels via AXI burst writes
        //         The pixel pump drains FIFO concurrently; m_wready throttles
        //         when FIFO is full (naturally back-pressures the upload).
        // ----------------------------------------------------------------
        $display("[TB] Step 3: uploading %0d pixel words (%0d bursts of 256)...",
                 FRAME_WORDS, (FRAME_WORDS + 255) / 256);

        words_remaining = FRAME_WORDS;
        burst_base      = 0;
        addr_offset     = 0;

        while (words_remaining > 0) begin
            burst_words = (words_remaining > 256) ? 256 : words_remaining;
            axi_write_burst(
                AXI_PIXEL_BASE + addr_offset * 4,
                burst_base,
                burst_words - 1   // AXI len = beats-1
            );
            burst_base      = burst_base  + burst_words;
            addr_offset     = addr_offset + burst_words;
            words_remaining = words_remaining - burst_words;
        end
        $display("[TB] Upload complete");

        // ----------------------------------------------------------------
        // Step 4: poll STATUS until enc_done
        // (encoder may still be finishing last MCU rows)
        // ----------------------------------------------------------------
        $display("[TB] Step 4: polling enc_done...");
        clk_count = 0;
        rdata = 32'd0;
        while (rdata[0] == 1'b0) begin
            wait_clk(500);
            axi_read_word(AXI_CTRL_ADDR, rdata);
            clk_count = clk_count + 500;
            if (clk_count > POLL_TIMEOUT) begin
                $display("[TB] TIMEOUT waiting for enc_done!");
                $finish;
            end
        end
        $display("[TB] enc_done asserted after ~%0d clocks", clk_count);

        // ----------------------------------------------------------------
        // Step 5: read JPEG_SIZE
        // ----------------------------------------------------------------
        axi_read_word(AXI_SIZE_ADDR, rdata);
        jpeg_byte_count = rdata[17:0];
        $display("[TB] JPEG size = %0d bytes", jpeg_byte_count);

        if (jpeg_byte_count == 0) begin
            $display("[TB] ERROR: zero-byte JPEG!");
            $finish;
        end

        // ----------------------------------------------------------------
        // Step 6: burst-read JPEG from 0x0300_0000
        // ----------------------------------------------------------------
        $display("[TB] Step 6: reading JPEG data...");
        total_words_to_read = (jpeg_byte_count + 3) / 4;  // round up to words
        words_read  = 0;

        while (words_read < total_words_to_read) begin
            read_len = total_words_to_read - words_read;
            if (read_len > 256) read_len = 256;
            axi_read_burst(
                AXI_JPEG_BASE + words_read * 4,
                read_len - 1,      // AXI len = beats-1
                words_read * 4     // byte offset into jpeg_buf
            );
            words_read = words_read + read_len;
        end

        // ----------------------------------------------------------------
        // Step 7: save JPEG to file
        // ----------------------------------------------------------------
        fd = $fopen("demo_sim_output.jpg", "wb");  // relative to xsim working dir (build/demo_sim/)
        if (!fd) begin
            $display("[TB] WARNING: could not open output file");
        end else begin
            for (i = 0; i < jpeg_byte_count; i = i + 1)
                $fwrite(fd, "%c", jpeg_buf[i]);
            $fclose(fd);
            $display("[TB] JPEG saved to build/demo_sim/demo_sim_output.jpg");
        end

        // ----------------------------------------------------------------
        // Step 8: verify SOI and EOI markers
        // ----------------------------------------------------------------
        $display("[TB] Step 8: verifying JPEG markers...");
        $display("[TB]   First 8 bytes: %02h %02h %02h %02h %02h %02h %02h %02h",
            jpeg_buf[0], jpeg_buf[1], jpeg_buf[2], jpeg_buf[3],
            jpeg_buf[4], jpeg_buf[5], jpeg_buf[6], jpeg_buf[7]);
        $display("[TB]   Last  4 bytes: %02h %02h %02h %02h",
            jpeg_buf[jpeg_byte_count-4], jpeg_buf[jpeg_byte_count-3],
            jpeg_buf[jpeg_byte_count-2], jpeg_buf[jpeg_byte_count-1]);

        if (jpeg_buf[0] == 8'hFF && jpeg_buf[1] == 8'hD8)
            $display("[TB]   SOI OK (FFD8)");
        else
            $display("[TB]   ERROR: SOI missing! got %02h%02h", jpeg_buf[0], jpeg_buf[1]);

        if (jpeg_buf[jpeg_byte_count-2] == 8'hFF &&
            jpeg_buf[jpeg_byte_count-1] == 8'hD9)
            $display("[TB]   EOI OK (FFD9)");
        else
            $display("[TB]   ERROR: EOI missing! got %02h%02h",
                     jpeg_buf[jpeg_byte_count-2], jpeg_buf[jpeg_byte_count-1]);

        // Print a hex dump of the first 32 bytes for inspection
        $display("[TB]   Hex dump (first 64 bytes):");
        for (i = 0; i < 64 && i < jpeg_byte_count; i = i + 1) begin
            if (i % 16 == 0) $write("[TB]     %04h: ", i);
            $write("%02h ", jpeg_buf[i]);
            if (i % 16 == 15) $write("\n");
        end
        $write("\n");

        $display("[TB] DONE.");
        $finish;
    end

    // -----------------------------------------------------------------------
    // Watchdog
    // -----------------------------------------------------------------------
    initial begin
        #(CLK_PERIOD * 30_000_000);
        $display("[TB] WATCHDOG TIMEOUT at 30M cycles");
        $finish;
    end

    // -----------------------------------------------------------------------
    // AXI4 transaction monitor (prints write/read addresses)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (m_awvalid && m_awready)
            $display("[AXI WR] addr=%08h len=%0d", m_awaddr, m_awlen+1);
        if (m_arvalid && m_arready)
            $display("[AXI RD] addr=%08h len=%0d", m_araddr, m_arlen+1);
    end

endmodule
