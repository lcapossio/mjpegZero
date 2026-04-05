// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// tb_iverilog.sv — CI-friendly testbench for iverilog / Verilator
// ============================================================================
// Stripped-down version of tb_mjpegzero_enc.sv:
//   - No internal signal probing (no generate-block hierarchical refs)
//   - No VCD dump by default (use +define+DUMP_VCD to enable)
//   - Exit-code friendly: prints "ALL TESTS PASSED" or "SOME TESTS FAILED"
//
// Usage (iverilog + vvp):
//   iverilog -g2012 -o sim.vvp \
//     rtl/vendor/sim/bram_sdp.v rtl/dct_1d.v rtl/dct_2d.v \
//     rtl/input_buffer.v rtl/quantizer.v rtl/zigzag_reorder.v \
//     rtl/huffman_encoder.v rtl/bitstream_packer.v rtl/jfif_writer.v \
//     rtl/axi4_lite_regs.v rtl/mjpegzero_enc_top.v sim/tb_iverilog.sv
//   vvp sim.vvp
// ============================================================================

`timescale 1ns / 1ps

module tb_iverilog;

    // ========================================================================
    // Parameters
    // ========================================================================
    localparam CLK_PERIOD = 10;   // 100 MHz
    localparam IMG_WIDTH  = 64;   // 4 MCUs wide
    localparam IMG_HEIGHT = 8;    // 1 MCU row
    localparam NUM_PIXELS = IMG_WIDTH * IMG_HEIGHT;

`ifdef LITE_MODE
    localparam TB_LITE_MODE    = 1;
`else
    localparam TB_LITE_MODE    = 0;
`endif

`ifdef LITE_QUALITY
    localparam TB_LITE_QUALITY = `LITE_QUALITY;
`else
    localparam TB_LITE_QUALITY = 95;
`endif

`ifdef TEST_QUALITY
    localparam TB_TEST_QUALITY = `TEST_QUALITY;
`else
    localparam TB_TEST_QUALITY = 95;
`endif

`ifdef EXIF_ENABLE
    localparam TB_EXIF_ENABLE   = 1;
`else
    localparam TB_EXIF_ENABLE   = 0;
`endif

`ifdef EXIF_X_RES
    localparam TB_EXIF_X_RES    = `EXIF_X_RES;
`else
    localparam TB_EXIF_X_RES    = 72;
`endif

`ifdef EXIF_Y_RES
    localparam TB_EXIF_Y_RES    = `EXIF_Y_RES;
`else
    localparam TB_EXIF_Y_RES    = 72;
`endif

`ifdef EXIF_RES_UNIT
    localparam TB_EXIF_RES_UNIT = `EXIF_RES_UNIT;
`else
    localparam TB_EXIF_RES_UNIT = 2;
`endif

`ifdef NUM_FRAMES
    localparam TB_NUM_FRAMES = `NUM_FRAMES;
`else
    localparam TB_NUM_FRAMES = 1;
`endif

`ifdef RGB_INPUT
    localparam TB_RGB_INPUT  = 1;
    localparam TB_VID_DATA_W = 24;
`else
    localparam TB_RGB_INPUT  = 0;
    localparam TB_VID_DATA_W = 16;
`endif

    // ========================================================================
    // Signals
    // ========================================================================
    reg         clk;
    reg         rst_n;

    reg  [TB_VID_DATA_W-1:0] s_axis_vid_tdata;
    reg         s_axis_vid_tvalid;
    wire        s_axis_vid_tready;
    reg         s_axis_vid_tlast;
    reg         s_axis_vid_tuser;

    wire        m_axis_jpg_tvalid;
    wire [7:0]  m_axis_jpg_tdata;
    wire        m_axis_jpg_tlast;

    reg  [4:0]  s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    reg  [4:0]  s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    // ========================================================================
    // Clock
    // ========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ========================================================================
    // DUT
    // ========================================================================
    mjpegzero_enc_top #(
        .IMG_WIDTH     (IMG_WIDTH),
        .IMG_HEIGHT    (IMG_HEIGHT),
        .LITE_MODE     (TB_LITE_MODE),
        .LITE_QUALITY  (TB_LITE_QUALITY),
        .EXIF_ENABLE   (TB_EXIF_ENABLE),
        .EXIF_X_RES    (TB_EXIF_X_RES),
        .EXIF_Y_RES    (TB_EXIF_Y_RES),
        .EXIF_RES_UNIT (TB_EXIF_RES_UNIT),
        .RGB_INPUT     (TB_RGB_INPUT)
    ) dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .s_axis_vid_tdata  (s_axis_vid_tdata),
        .s_axis_vid_tvalid (s_axis_vid_tvalid),
        .s_axis_vid_tready (s_axis_vid_tready),
        .s_axis_vid_tlast  (s_axis_vid_tlast),
        .s_axis_vid_tuser  (s_axis_vid_tuser),
        .m_axis_jpg_tvalid (m_axis_jpg_tvalid),
        .m_axis_jpg_tdata  (m_axis_jpg_tdata),
        .m_axis_jpg_tlast  (m_axis_jpg_tlast),
        .s_axi_awaddr      (s_axi_awaddr),
        .s_axi_awvalid     (s_axi_awvalid),
        .s_axi_awready     (s_axi_awready),
        .s_axi_wdata       (s_axi_wdata),
        .s_axi_wstrb       (s_axi_wstrb),
        .s_axi_wvalid      (s_axi_wvalid),
        .s_axi_wready      (s_axi_wready),
        .s_axi_bresp       (s_axi_bresp),
        .s_axi_bvalid      (s_axi_bvalid),
        .s_axi_bready      (s_axi_bready),
        .s_axi_araddr      (s_axi_araddr),
        .s_axi_arvalid     (s_axi_arvalid),
        .s_axi_arready     (s_axi_arready),
        .s_axi_rdata       (s_axi_rdata),
        .s_axi_rresp       (s_axi_rresp),
        .s_axi_rvalid      (s_axi_rvalid),
        .s_axi_rready      (s_axi_rready)
    );

    // ========================================================================
    // Test vector storage
    // ========================================================================
    reg [TB_VID_DATA_W-1:0] vid_data [0:NUM_PIXELS-1];

    initial begin
        if (TB_RGB_INPUT)
            $readmemh("test_vectors/rgb_input.hex", vid_data);
        else
            $readmemh("test_vectors/yuyv_input.hex", vid_data);
    end

    // ========================================================================
    // Output capture
    // ========================================================================
    integer output_file;
    integer output_byte_cnt;
    integer frames_completed;
    reg     saw_soi;
    reg     saw_eoi;
    reg [7:0] prev_byte;

    initial begin
        output_file      = $fopen("sim_output.jpg", "wb");
        output_byte_cnt  = 0;
        frames_completed = 0;
        saw_soi          = 0;
        saw_eoi          = 0;
        prev_byte        = 0;
    end

    always @(posedge clk) begin
        if (m_axis_jpg_tvalid) begin
            $fwrite(output_file, "%c", m_axis_jpg_tdata);

            if (output_byte_cnt == 1 && prev_byte == 8'hFF && m_axis_jpg_tdata == 8'hD8)
                saw_soi = 1;
            if (output_byte_cnt > 2 && prev_byte == 8'hFF && m_axis_jpg_tdata == 8'hD9)
                saw_eoi = 1;

            prev_byte       = m_axis_jpg_tdata;
            output_byte_cnt = output_byte_cnt + 1;
        end

        if (m_axis_jpg_tlast && m_axis_jpg_tvalid) begin
            $fclose(output_file);
            $display("[%0t] Frame %0d complete: %0d bytes", $time, frames_completed, output_byte_cnt);
            frames_completed = frames_completed + 1;
            // Re-open for next frame (resets to the same filename; last frame is what remains)
            if (frames_completed < TB_NUM_FRAMES) begin
                output_file     = $fopen("sim_output.jpg", "wb");
                output_byte_cnt = 0;
                saw_soi         = 0;
                saw_eoi         = 0;
                prev_byte       = 0;
            end
        end
    end

    // ========================================================================
    // AXI-Lite write task
    // ========================================================================
    task axi_write(input [4:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1;
            s_axi_wdata   = data;
            s_axi_wstrb   = 4'hF;
            s_axi_wvalid  = 1;
            s_axi_bready  = 1;

            fork
                begin: aw_wait
                    wait(s_axi_awready);
                    @(posedge clk);
                    s_axi_awvalid = 0;
                end
                begin: w_wait
                    wait(s_axi_wready);
                    @(posedge clk);
                    s_axi_wvalid = 0;
                end
            join

            wait(s_axi_bvalid);
            @(posedge clk);
            s_axi_bready = 0;
        end
    endtask

    // ========================================================================
    // AXI-Lite read task
    // ========================================================================
    // Set signals at negedge to guarantee setup before the next posedge.
    // The reg file responds with rvalid+rdata in 1 clock cycle, so:
    //   negedge C  : set araddr/arvalid/rready
    //   posedge C+1: DUT samples arvalid=1, rvalid=0 → rvalid<=1, rdata<=reg
    //   posedge C+2: DUT samples rvalid=1, rready=1 → rvalid<=0; rdata stable
    //   after C+2  : capture s_axi_rdata, deassert
    task axi_read(input [4:0] addr, output reg [31:0] data);
        begin
            @(negedge clk);
            s_axi_araddr  = addr;
            s_axi_arvalid = 1;
            s_axi_rready  = 1;

            @(posedge clk);   // C+1: DUT captures address, sets rvalid+rdata
            @(posedge clk);   // C+2: DUT clears rvalid; rdata is stable
            data = s_axi_rdata;
            s_axi_arvalid = 0;
            s_axi_rready  = 0;
        end
    endtask

    // ========================================================================
    // Stimulus and validation
    // ========================================================================
    integer x, y, pixel_idx, frame_num;
    integer pass_cnt, fail_cnt;
    reg [31:0] reg_val;

    initial begin
        $display("====================================");
        $display("mjpegZero CI Testbench");
        $display("Image: %0d x %0d  LITE_MODE=%0d  RGB_INPUT=%0d", IMG_WIDTH, IMG_HEIGHT, TB_LITE_MODE, TB_RGB_INPUT);
        $display("====================================");

        rst_n             = 0;
        s_axis_vid_tdata  = 0;
        s_axis_vid_tvalid = 0;
        s_axis_vid_tlast  = 0;
        s_axis_vid_tuser  = 0;
        s_axi_awaddr      = 0;
        s_axi_awvalid     = 0;
        s_axi_wdata       = 0;
        s_axi_wstrb       = 0;
        s_axi_wvalid      = 0;
        s_axi_bready      = 0;
        s_axi_araddr      = 0;
        s_axi_arvalid     = 0;
        s_axi_rready      = 0;
        pass_cnt          = 0;
        fail_cnt          = 0;

        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5)  @(posedge clk);

        axi_write(5'h00, 32'h1);             // CTRL: enable=1
        axi_write(5'h0C, TB_TEST_QUALITY);  // Quality (full mode only; ignored in LITE_MODE)

        repeat(600) @(posedge clk); // Wait for Q-table update

        // Feed TB_NUM_FRAMES frames; wait for each JPEG output before next
        for (frame_num = 0; frame_num < TB_NUM_FRAMES; frame_num = frame_num + 1) begin
            $display("[%0t] Feeding frame %0d/%0d (%0d pixels)...",
                     $time, frame_num, TB_NUM_FRAMES - 1, NUM_PIXELS);
            pixel_idx = 0;
            for (y = 0; y < IMG_HEIGHT; y = y + 1) begin
                for (x = 0; x < IMG_WIDTH; x = x + 1) begin
                    @(negedge clk);
                    s_axis_vid_tvalid = 1;
                    s_axis_vid_tuser  = (x == 0 && y == 0) ? 1 : 0;
                    s_axis_vid_tlast  = (x == IMG_WIDTH - 1) ? 1 : 0;
                    s_axis_vid_tdata  = vid_data[pixel_idx];
                    pixel_idx = pixel_idx + 1;
                    while (!s_axis_vid_tready) @(negedge clk);
                end
            end

            // Hold valid/last until posedge; #1 keeps de-assert after active region
            @(posedge clk); #1;
            s_axis_vid_tvalid = 0;
            s_axis_vid_tlast  = 0;
            s_axis_vid_tuser  = 0;

            // Wait for this frame's JPEG output before sending next frame
            if (frame_num < TB_NUM_FRAMES - 1) begin
                wait(frames_completed == frame_num + 1);
                repeat(20) @(posedge clk);
            end
        end

        repeat(200000) @(posedge clk); // Wait for last frame pipeline to flush

        // ====================================================================
        // Validation
        // ====================================================================
        $display("");
        $display("====================================");
        $display("VALIDATION");
        $display("====================================");
        $display("Output bytes: %0d", output_byte_cnt);

        if (saw_soi) begin
            $display("PASS: SOI marker (FFD8) found");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: SOI marker not found");
            fail_cnt = fail_cnt + 1;
        end

        if (saw_eoi) begin
            $display("PASS: EOI marker (FFD9) found");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: EOI marker not found");
            fail_cnt = fail_cnt + 1;
        end

        if (output_byte_cnt > 100 && output_byte_cnt < 10000) begin
            $display("PASS: Output size %0d bytes is reasonable", output_byte_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: Output size %0d bytes unexpected", output_byte_cnt);
            fail_cnt = fail_cnt + 1;
        end

        if (output_byte_cnt > 0) begin
            $display("PASS: Encoder produced output");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: No output produced");
            fail_cnt = fail_cnt + 1;
        end

`ifdef VERIFY_AXI_REGS
        // ====================================================================
        // AXI Register Checks
        // ====================================================================
        $display("");
        $display("====================================");
        $display("AXI REGISTER CHECKS");
        $display("====================================");

        // QUALITY register readback
        axi_read(5'h0C, reg_val);
        if (TB_LITE_MODE == 0 && reg_val[6:0] == TB_TEST_QUALITY[6:0]) begin
            $display("PASS: QUALITY reg = %0d", reg_val[6:0]);
            pass_cnt = pass_cnt + 1;
        end else if (TB_LITE_MODE == 1 && reg_val[6:0] == 7'd95) begin
            $display("PASS: QUALITY reg = 95 (LITE_MODE; write ignored as expected)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: QUALITY reg = %0d (expected %0d)", reg_val[6:0],
                     TB_LITE_MODE ? 7'd95 : TB_TEST_QUALITY[6:0]);
            fail_cnt = fail_cnt + 1;
        end

        // FRAME_CNT register
        axi_read(5'h08, reg_val);
        if (reg_val == TB_NUM_FRAMES) begin
            $display("PASS: FRAME_CNT = %0d", reg_val);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: FRAME_CNT = %0d, expected %0d", reg_val, TB_NUM_FRAMES);
            fail_cnt = fail_cnt + 1;
        end

        // FRAME_SIZE register — running scan-data byte count (resets only on hard reset)
        axi_read(5'h14, reg_val);
        if (reg_val > 100) begin
            $display("PASS: FRAME_SIZE (scan bytes total) = %0d", reg_val);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: FRAME_SIZE = %0d (expected >100)", reg_val);
            fail_cnt = fail_cnt + 1;
        end

        // STATUS frame_done bit (W1C, should be set after encoding)
        axi_read(5'h04, reg_val);
        if (reg_val[1]) begin
            $display("PASS: STATUS[1] frame_done is set");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: STATUS[1] frame_done not set");
            fail_cnt = fail_cnt + 1;
        end

        // Clear frame_done via W1C write, then verify cleared
        axi_write(5'h04, 32'h2);
        axi_read(5'h04, reg_val);
        if (!reg_val[1]) begin
            $display("PASS: STATUS[1] frame_done W1C clear works");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: STATUS[1] frame_done not cleared after W1C");
            fail_cnt = fail_cnt + 1;
        end

        // RESTART register write/readback
        axi_write(5'h10, 32'h7);
        axi_read(5'h10, reg_val);
        if (reg_val[15:0] == 16'h7) begin
            $display("PASS: RESTART reg write/readback = 7");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: RESTART reg = %0h, expected 7", reg_val[15:0]);
            fail_cnt = fail_cnt + 1;
        end
        axi_write(5'h10, 32'h0);  // restore
`endif

        $display("------------------------------------");
        $display("Tests passed: %0d", pass_cnt);
        $display("Tests failed: %0d", fail_cnt);
        $display("====================================");

        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $display("Output saved to sim_output.jpg");
        $display("====================================");

        $finish;
    end

    // ========================================================================
    // Watchdog
    // ========================================================================
    initial begin
        #50_000_000;
        $display("WATCHDOG TIMEOUT");
        $display("Output bytes so far: %0d", output_byte_cnt);
        $finish;
    end

    // ========================================================================
    // AXI4-Lite protocol assertions
    // ========================================================================
    // These checks flag protocol violations in the DUT's AXI4-Lite slave.
    // They are always active and will print a FAIL message if triggered.

    // AR channel: arready must not be asserted unless arvalid is high
    always @(posedge clk) begin
        if (rst_n && s_axi_arready && !s_axi_arvalid) begin
            $display("ASSERT FAIL: s_axi_arready asserted without s_axi_arvalid @ %0t", $time);
        end
    end

    // AW channel: awready must not be asserted unless awvalid is high
    always @(posedge clk) begin
        if (rst_n && s_axi_awready && !s_axi_awvalid) begin
            $display("ASSERT FAIL: s_axi_awready asserted without s_axi_awvalid @ %0t", $time);
        end
    end

    // W channel: wready must not be asserted unless wvalid is high
    always @(posedge clk) begin
        if (rst_n && s_axi_wready && !s_axi_wvalid) begin
            $display("ASSERT FAIL: s_axi_wready asserted without s_axi_wvalid @ %0t", $time);
        end
    end

    // R channel: rvalid must not be asserted if no read was requested
    // (conservative: rvalid should only pulse after arvalid handshake)
    reg r_pending;
    initial r_pending = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            r_pending <= 0;
        end else begin
            if (s_axi_arvalid && s_axi_arready)
                r_pending <= 1;
            if (s_axi_rvalid && s_axi_rready)
                r_pending <= 0;
        end
    end
    always @(posedge clk) begin
        if (rst_n && s_axi_rvalid && !r_pending) begin
            $display("ASSERT FAIL: s_axi_rvalid without prior AR handshake @ %0t", $time);
        end
    end

    // B channel: bvalid must not be asserted if no write was requested
    reg b_pending;
    initial b_pending = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            b_pending <= 0;
        end else begin
            if (s_axi_awvalid && s_axi_awready)
                b_pending <= 1;
            if (s_axi_bvalid && s_axi_bready)
                b_pending <= 0;
        end
    end
    always @(posedge clk) begin
        if (rst_n && s_axi_bvalid && !b_pending) begin
            $display("ASSERT FAIL: s_axi_bvalid without prior AW handshake @ %0t", $time);
        end
    end

`ifdef DUMP_VCD
`ifndef VCD_FILE
  `define VCD_FILE "tb_iverilog.vcd"
`endif
    initial begin
        $dumpfile(`VCD_FILE);
        $dumpvars(0, tb_iverilog);
    end
`endif

endmodule
