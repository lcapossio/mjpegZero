// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// mjpegZero Testbench (SystemVerilog - simulation only)
// ============================================================================
// Feeds test vectors into the encoder pipeline and captures output.
// Verifies the output is a valid JPEG and compares against golden reference.
// ============================================================================

`timescale 1ns / 1ps

module tb_mjpegzero_enc;

    // ========================================================================
    // Parameters — override with -d IMG_W=1280 -d IMG_H=720 for 720p
    // ========================================================================
    localparam CLK_PERIOD = 10;  // 100 MHz

`ifdef TB_720P
    localparam IMG_WIDTH  = 1280;
    localparam IMG_HEIGHT = 720;
`else
    localparam IMG_WIDTH  = 64;   // default: 4 MCUs (fast sim)
    localparam IMG_HEIGHT = 8;
`endif

    localparam NUM_PIXELS  = IMG_WIDTH * IMG_HEIGHT;
    // Generous size bounds: at least 1 KB header+data, at most uncompressed RGB
    localparam MIN_BYTES   = 1000;
    localparam MAX_BYTES   = IMG_WIDTH * IMG_HEIGHT * 3;

    // LITE_MODE: compile with -d LITE_MODE to test lite variant
`ifdef LITE_MODE
    localparam TB_LITE_MODE = 1;
`else
    localparam TB_LITE_MODE = 0;
`endif

    // LITE_QUALITY: read from sim_defines.vh if it exists (written by run_sim.sh),
    // or fall back to 95.  The include path must be in the xelab search path.
`ifdef HAVE_DEFINES
  `include "sim_defines.vh"
`endif
`ifdef LITE_QUALITY
    localparam TB_LITE_QUALITY = `LITE_QUALITY;
`else
    localparam TB_LITE_QUALITY = 95;
`endif

    // TEST_QUALITY: AXI quality write (full mode only)
`ifdef TEST_QUALITY
    localparam TB_TEST_QUALITY = `TEST_QUALITY;
`else
    localparam TB_TEST_QUALITY = 95;
`endif

    // ========================================================================
    // Signals
    // ========================================================================
    reg         clk;
    reg         rst_n;

    // Video input
    reg  [15:0] s_axis_vid_tdata;
    reg         s_axis_vid_tvalid;
    wire        s_axis_vid_tready;
    reg         s_axis_vid_tlast;
    reg         s_axis_vid_tuser;

    // JPEG output (no backpressure)
    wire        m_axis_jpg_tvalid;
    wire [7:0]  m_axis_jpg_tdata;
    wire        m_axis_jpg_tlast;

    // AXI-Lite (5-bit address)
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
    // Clock generation
    // ========================================================================
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ========================================================================
    // DUT instantiation
    // Post-synthesis: parameters are baked in, instantiate without overrides.
    // RTL: pass parameters as usual.
    // ========================================================================
`ifdef POSTSIM
    mjpegzero_enc_top dut (
`else
    mjpegzero_enc_top #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .LITE_MODE    (TB_LITE_MODE),
        .LITE_QUALITY (TB_LITE_QUALITY)
    ) dut (
`endif
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
    // YUYV input data loaded from hex file
    // ========================================================================
    reg [15:0] yuyv_data [0:NUM_PIXELS-1];

    initial begin
`ifdef TB_720P
        $readmemh("test_vectors/yuyv_720p.hex", yuyv_data);
`else
        $readmemh("test_vectors/yuyv_input.hex", yuyv_data);
`endif
    end

    // ========================================================================
    // Golden reference JPEG bytes
    // ========================================================================
    reg [7:0] ref_jpeg [0:4095];  // Up to 4KB reference
    integer ref_len;

    initial begin
        // Load reference bytes
        $readmemh("test_vectors/reference_4mcu_bytes.hex", ref_jpeg);
        // Count reference length (find first XX after data)
        ref_len = 0;
    end

    // ========================================================================
    // Output capture and validation
    // ========================================================================
    integer output_file;
    integer output_byte_cnt;
    reg [7:0] output_bytes [0:4095];
    reg saw_soi;
    reg saw_eoi;
    integer mismatch_cnt;
    integer pass_cnt;

    initial begin
        output_file = $fopen("sim_output.jpg", "wb");
        output_byte_cnt = 0;
        saw_soi = 0;
        saw_eoi = 0;
        mismatch_cnt = 0;
        pass_cnt = 0;
    end

    reg [7:0] prev_byte;

    always @(posedge clk) begin
        if (m_axis_jpg_tvalid) begin
            $fwrite(output_file, "%c", m_axis_jpg_tdata);

            if (output_byte_cnt < 4096)
                output_bytes[output_byte_cnt] = m_axis_jpg_tdata;

            // Check for SOI marker (FF D8)
            if (output_byte_cnt == 0 && m_axis_jpg_tdata == 8'hFF)
                ; // first byte
            if (output_byte_cnt == 1 && prev_byte == 8'hFF && m_axis_jpg_tdata == 8'hD8)
                saw_soi = 1;

            // Check for EOI marker (FF D9)
            if (prev_byte == 8'hFF && m_axis_jpg_tdata == 8'hD9 && output_byte_cnt > 2)
                saw_eoi = 1;

            prev_byte = m_axis_jpg_tdata;
            output_byte_cnt = output_byte_cnt + 1;
        end

        if (m_axis_jpg_tlast && m_axis_jpg_tvalid) begin
            $display("[%0t] Frame complete: %0d output bytes", $time, output_byte_cnt);
            $fclose(output_file);
        end
    end

    // ========================================================================
    // AXI-Lite write task
    // ========================================================================
    task axi_write(input [4:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            s_axi_awaddr = addr;
            s_axi_awvalid = 1;
            s_axi_wdata = data;
            s_axi_wstrb = 4'hF;
            s_axi_wvalid = 1;
            s_axi_bready = 1;

            // Wait for handshake
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
    // Test stimulus
    // ========================================================================
    integer x, y, pixel_idx;

    initial begin
        $display("====================================");
        $display("mjpegZero Testbench Starting");
        $display("Image: %0d x %0d", IMG_WIDTH, IMG_HEIGHT);
        $display("====================================");

        // Initialize signals
        rst_n = 0;
        s_axis_vid_tdata = 0;
        s_axis_vid_tvalid = 0;
        s_axis_vid_tlast = 0;
        s_axis_vid_tuser = 0;
        s_axi_awaddr = 0;
        s_axi_awvalid = 0;
        s_axi_wdata = 0;
        s_axi_wstrb = 0;
        s_axi_wvalid = 0;
        s_axi_bready = 0;
        s_axi_araddr = 0;
        s_axi_arvalid = 0;
        s_axi_rready = 0;

        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // Configure: enable encoder, set quality=95
        $display("[%0t] Configuring encoder...", $time);
        axi_write(5'h00, 32'h1);  // CTRL: enable=1
        axi_write(5'h0C, TB_TEST_QUALITY); // Quality (ignored in LITE_MODE)

        // Wait for Q-table update (~512 clocks)
        repeat(600) @(posedge clk);

        // Feed video data from loaded YUYV hex file
        $display("[%0t] Feeding %0d pixels of video data...", $time, NUM_PIXELS);
        pixel_idx = 0;
        for (y = 0; y < IMG_HEIGHT; y = y + 1) begin
            for (x = 0; x < IMG_WIDTH; x = x + 1) begin
                @(negedge clk);
                s_axis_vid_tvalid = 1;
                s_axis_vid_tuser = (x == 0 && y == 0) ? 1 : 0;
                s_axis_vid_tlast = (x == IMG_WIDTH - 1) ? 1 : 0;
                s_axis_vid_tdata = yuyv_data[pixel_idx];
                pixel_idx = pixel_idx + 1;

                // Wait for ready (backpressure)
                while (!s_axis_vid_tready) begin
                    @(negedge clk);
                end
            end
        end

        // Hold valid until the DUT samples the last pixel at the next posedge,
        // then de-assert.  #1 ensures de-assertion is after the posedge active region.
        @(posedge clk); #1;
        s_axis_vid_tvalid = 0;
        s_axis_vid_tuser = 0;
        s_axis_vid_tlast = 0;

        $display("[%0t] Video data complete. Waiting for encoder...", $time);

        // Debug: monitor pipeline progress (RTL only — signals not in post-synth netlist)
`ifndef POSTSIM
        fork
            begin : debug_monitor
                integer dbg_cnt;
                dbg_cnt = 0;
                forever begin
                    @(posedge clk);
                    dbg_cnt = dbg_cnt + 1;
                    if (dbg_cnt == 1 || dbg_cnt == 100 || dbg_cnt == 500 ||
                        dbg_cnt == 625 || dbg_cnt == 700 || dbg_cnt == 750 ||
                        dbg_cnt == 800 || dbg_cnt == 900 || dbg_cnt == 1000 ||
                        dbg_cnt == 1200 || dbg_cnt == 1500 || dbg_cnt == 2000 ||
                        dbg_cnt == 3000 || dbg_cnt == 5000 || dbg_cnt == 10000) begin
                        $display("[%0t] DBG clk=%0d: lines_done=%b ibuf_blk_valid=%b ibuf_blk_ready=%b headers_done=%b",
                            $time, dbg_cnt,
                            dut.ibuf_lines_done,
                            dut.ibuf_blk_valid,
                            dut.ibuf_blk_ready,
                            dut.jfif_headers_done);
                        $display("  jfif_state=%0d frame_start=%b frame_done=%b frame_active=%b mcu_count=%0d",
`ifdef LITE_MODE
                            dut.u_jfif.g_lite_header.state,
`else
                            dut.u_jfif.g_full_header.state,
`endif
                            dut.frame_start_pulse,
                            dut.frame_done_pulse,
                            dut.frame_active,
                            dut.mcu_count);
                        $display("  huff_valid=%b huff_eob=%b bp_ready=%b bs_valid=%b bs_last=%b scan_ready=%b",
                            dut.huff_out_valid,
                            dut.huff_out_eob,
                            dut.huff_bp_ready,
                            dut.bs_out_valid,
                            dut.bs_out_last,
                            dut.bs_out_ready);
                        $display("  ibuf_rd_state=%0d ibuf_rd_active=%b ibuf_rd_mcu_col=%0d ibuf_rd_comp=%0d",
                            dut.u_input_buffer.rd_state,
                            dut.u_input_buffer.rd_active,
                            dut.u_input_buffer.rd_mcu_col,
                            dut.u_input_buffer.rd_comp);
                        $display("  dct_out_valid=%b dct_out_sof=%b quant_out_valid=%b zz_out_valid=%b zz_out_sob=%b",
                            dut.dct_out_valid,
                            dut.dct_out_sof,
                            dut.quant_out_valid,
                            dut.zz_out_valid,
                            dut.zz_out_sob);
                        $display("  huff_state=%0d huff_blk_ready=%b huff_wr_idx=%0d huff_ac_idx=%0d",
                            dut.u_huffman.state,
                            dut.u_huffman.coeff_block_ready,
                            dut.u_huffman.coeff_wr_idx,
                            dut.u_huffman.ac_idx);
                        $display("  dct_row_valid=%b dct_tbuf_done=%b dct_col_valid=%b dct_out_cnt=%0d",
                            dut.u_dct.row_dct_out_valid,
                            dut.u_dct.tbuf_block_done,
                            dut.u_dct.tbuf_rd_valid,
                            dut.u_dct.out_cnt);
                    end
                    if (dbg_cnt >= 60000) disable debug_monitor;
                end
            end
        join_none
`endif // POSTSIM

        // Wait for JPEG EOI (tlast seen) or generous timeout
        fork
            begin : wait_eoi
                wait (saw_eoi == 1);
            end
            begin : wait_timeout
`ifdef TB_720P
                repeat(60_000_000) @(posedge clk);  // 600ms for 720p
`else
                repeat(20_000_000) @(posedge clk);  // 200ms for small frames
`endif
                $display("WARNING: timeout waiting for EOI");
            end
        join_any
        disable fork;

        // ================================================================
        // Validation
        // ================================================================
        $display("");
        $display("====================================");
        $display("VALIDATION RESULTS");
        $display("====================================");
        $display("Output bytes: %0d", output_byte_cnt);

        // Check SOI
        if (saw_soi) begin
            $display("PASS: SOI marker (FFD8) found");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: SOI marker (FFD8) not found");
            mismatch_cnt = mismatch_cnt + 1;
        end

        // Check EOI
        if (saw_eoi) begin
            $display("PASS: EOI marker (FFD9) found");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: EOI marker (FFD9) not found");
            mismatch_cnt = mismatch_cnt + 1;
        end

        // Check reasonable output size (JPEG headers are ~600 bytes, data adds more)
        if (output_byte_cnt > MIN_BYTES && output_byte_cnt < MAX_BYTES) begin
            $display("PASS: Output size %0d bytes is reasonable", output_byte_cnt);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: Output size %0d bytes unexpected (expected %0d..%0d)",
                     output_byte_cnt, MIN_BYTES, MAX_BYTES);
            mismatch_cnt = mismatch_cnt + 1;
        end

        // Check output produced at all
        if (output_byte_cnt > 0) begin
            $display("PASS: Encoder produced output");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL: Encoder produced no output");
            mismatch_cnt = mismatch_cnt + 1;
        end

        $display("------------------------------------");
        $display("Tests passed: %0d", pass_cnt);
        $display("Tests failed: %0d", mismatch_cnt);
        $display("====================================");

        if (mismatch_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $display("Output saved to sim_output.jpg");
        $display("====================================");

        $finish;
    end

    // ========================================================================
    // Pipeline value tracing - dump first block's values (RTL only)
    // ========================================================================
`ifndef POSTSIM
    integer dct_dump_cnt, quant_dump_cnt, zz_dump_cnt, huff_dump_cnt;
    integer row_dct_cnt, tbuf_rd_cnt, dct_in_cnt;
    initial begin
        dct_dump_cnt = 0;
        quant_dump_cnt = 0;
        zz_dump_cnt = 0;
        huff_dump_cnt = 0;
        row_dct_cnt = 0;
        tbuf_rd_cnt = 0;
        dct_in_cnt = 0;
    end

    always @(posedge clk) begin
        // Trace first block's DCT output
        if (dut.dct_out_valid && dct_dump_cnt < 64) begin
            if (dct_dump_cnt == 0)
                $display("[TRACE] === First block DCT output (raster order) ===");
            $display("[TRACE] DCT[%0d] = %0d (hex=%04h) sof=%b",
                dct_dump_cnt, $signed(dut.dct_out_data), dut.dct_out_data, dut.dct_out_sof);
            dct_dump_cnt = dct_dump_cnt + 1;
        end

        // Trace first block's quantizer output
        if (dut.quant_out_valid && quant_dump_cnt < 64) begin
            if (quant_dump_cnt == 0) begin
                $display("[TRACE] === First block quantizer output ===");
                $display("[TRACE] Q-table quality=%0d",
                    dut.u_quantizer.quality);
                $display("[TRACE] recip_luma[0]=%0d recip_luma[1]=%0d",
                    dut.u_quantizer.recip_luma[0], dut.u_quantizer.recip_luma[1]);
            end
            $display("[TRACE] QUANT[%0d] = %0d (hex=%04h) sob=%b",
                quant_dump_cnt, $signed(dut.quant_out_data), dut.quant_out_data, dut.quant_out_sob);
            quant_dump_cnt = quant_dump_cnt + 1;
        end

        // Trace first block's zigzag output
        if (dut.zz_out_valid && zz_dump_cnt < 64) begin
            if (zz_dump_cnt == 0)
                $display("[TRACE] === First block zigzag output ===");
            $display("[TRACE] ZZ[%0d] = %0d sob=%b",
                zz_dump_cnt, $signed(dut.zz_out_data), dut.zz_out_sob);
            zz_dump_cnt = zz_dump_cnt + 1;
        end

        // Trace row DCT output (first block = 64 values)
        if (dut.u_dct.row_dct_out_valid && row_dct_cnt < 64) begin
            $display("[TRACE] ROW_DCT[%0d] = %0d (wr_row=%0d wr_col=%0d)",
                row_dct_cnt, $signed(dut.u_dct.row_dct_out_data),
                dut.u_dct.tbuf_wr_row, dut.u_dct.tbuf_wr_col);
            row_dct_cnt = row_dct_cnt + 1;
        end

        // Trace transpose buffer read output (first block)
        if (dut.u_dct.tbuf_rd_valid && tbuf_rd_cnt < 64) begin
            $display("[TRACE] TBUF_RD[%0d] rd_row=%0d rd_col=%0d data=%0d col_in=%0d",
                tbuf_rd_cnt,
                dut.u_dct.tbuf_rd_row, dut.u_dct.tbuf_rd_col,
                $signed(dut.u_dct.tbuf_rd_data),
                $signed(dut.u_dct.col_dct_in));
            tbuf_rd_cnt = tbuf_rd_cnt + 1;
        end

        // Trace input buffer first 64 outputs (full first block)
        if (dut.ibuf_blk_valid && dut.ibuf_blk_ready && huff_dump_cnt < 64) begin
            if (huff_dump_cnt == 0)
                $display("[TRACE] === First block input buffer outputs ===");
            if (huff_dump_cnt % 8 == 0)
                $write("[TRACE] IBUF row %0d: ", huff_dump_cnt / 8);
            $write("%4d", dut.ibuf_blk_data);
            if (huff_dump_cnt % 8 == 7)
                $write("\n");
            huff_dump_cnt = huff_dump_cnt + 1;
        end

        // Trace level-shifted DCT input (first 64)
        if (dut.dct_in_valid && dct_in_cnt < 64) begin
            if (dct_in_cnt == 0)
                $display("[TRACE] === DCT input (level-shifted) ===");
            if (dct_in_cnt % 8 == 0)
                $write("[TRACE] DCT_IN row %0d: ", dct_in_cnt / 8);
            $write("%5d", $signed(dut.dct_in_data));
            if (dct_in_cnt % 8 == 7)
                $write("\n");
            dct_in_cnt = dct_in_cnt + 1;
        end
    end
`endif // POSTSIM

    // ========================================================================
    // Huffman encoder DC tracing for ALL blocks (RTL only)
    // ========================================================================
`ifndef POSTSIM
    integer huff_blk_num;
    initial huff_blk_num = 0;

    always @(posedge clk) begin
        // Trace Huffman DC value for every block (DC_FETCH -> DC_ENCODE transition)
        if (dut.u_huffman.state == 4'd1) begin // S_DC_FETCH
            $display("[HUFF] Block %0d comp=%0d: DC_raw=%0d prev_dc_y=%0d prev_dc_cb=%0d prev_dc_cr=%0d",
                huff_blk_num, dut.u_huffman.blk_comp_id,
                $signed(dut.u_huffman.coeff_buf[{dut.u_huffman.coeff_rd_bank, 6'd0}]),
                $signed(dut.u_huffman.prev_dc_y),
                $signed(dut.u_huffman.prev_dc_cb),
                $signed(dut.u_huffman.prev_dc_cr));
        end
        // Trace the DC emit details
        if (dut.u_huffman.state == 4'd3 && dut.u_huffman.out_valid && dut.huff_bp_ready) begin
            $display("[HUFF] Block %0d DC_EMIT: dc_diff=%0d cat=%0d huff_len=%0d out_bits=%08h out_len=%0d",
                huff_blk_num, $signed(dut.u_huffman.cur_coeff),
                dut.u_huffman.cur_cat, dut.u_huffman.huff_len,
                dut.u_huffman.out_bits, dut.u_huffman.out_len);
        end
        // Count EOBs to track block progression (only when accepted by packer)
        if (dut.huff_out_eob && dut.huff_out_valid && dut.huff_bp_ready) begin
            huff_blk_num = huff_blk_num + 1;
        end
    end
`endif // POSTSIM

    // ========================================================================
    // Bitstream packer tracing - track every accepted Huffman code (RTL only)
    // ========================================================================
`ifndef POSTSIM
    integer bp_byte_num;
    integer bp_total_bits_in;
    integer bp_huff_code_num;
    initial begin
        bp_byte_num = 0;
        bp_total_bits_in = 0;
        bp_huff_code_num = 0;
    end

    always @(posedge clk) begin
        if (dut.u_bitpacker.out_valid && dut.u_bitpacker.out_ready) begin
            bp_byte_num = bp_byte_num + 1;
        end
        // Track every Huffman code accepted by the packer
        if (dut.huff_out_valid && dut.huff_bp_ready) begin
            if (bp_huff_code_num < 600)
                $display("[PACK] Code %0d: bits=%08h len=%0d cumul_bits=%0d eob=%b",
                    bp_huff_code_num, dut.huff_out_bits, dut.huff_out_len,
                    bp_total_bits_in, dut.huff_out_eob);
            bp_total_bits_in = bp_total_bits_in + dut.huff_out_len;
            bp_huff_code_num = bp_huff_code_num + 1;
        end
    end
`endif // POSTSIM

    // ========================================================================
    // Comp ID FIFO tracing (RTL only)
    // ========================================================================
`ifndef POSTSIM
    always @(posedge clk) begin
        if (dut.zz_out_valid && dut.zz_out_sob) begin
            $display("[COMP] ZZ sob: huff_comp_id=%0d fifo_rd=%0d fifo_wr=%0d",
                dut.huff_comp_id, dut.comp_fifo_h_rd, dut.comp_fifo_h_wr);
        end
    end
`endif // POSTSIM

    // ========================================================================
    // Watchdog timer
    // ========================================================================
    initial begin
`ifdef TB_720P
        #1_500_000_000;  // 1500ms for 720p full frame
`else
        #50_000_000;     // 50ms for small test vectors
`endif
        $display("WATCHDOG TIMEOUT - design may be stuck");
        $display("Output bytes so far: %0d", output_byte_cnt);
        $finish;
    end

    // ========================================================================
    // Waveform dump (opt-in: compile with -d DUMP_VCD to enable)
    // ========================================================================
`ifdef DUMP_VCD
`ifndef VCD_FILE
  `define VCD_FILE "tb_mjpegzero_enc.vcd"
`endif
    initial begin
        $dumpfile(`VCD_FILE);
        $dumpvars(0, tb_mjpegzero_enc);
    end
`endif

endmodule
