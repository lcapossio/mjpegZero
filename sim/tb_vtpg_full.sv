// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_vtpg_full.sv - full demo_top_vtpg_eth datapath in sim: VTPG -> encoder ->
// capture FSM -> demo_jpeg_buffer -> jpeg_rtp_tx, driven by a copy of the demo's
// control FSM (V_KICK/cap_reset/frame_kick/rtp_start). Dumps jpeg_rtp_tx output
// bytes per packet so a Python checker can verify the in-band QT + scan and look
// for the alternating-blank behaviour. Tests the capture+control FSM that the
// isolated encoder/egress sims never exercised together.

`timescale 1ns / 1ps

module tb_vtpg_full;
    localparam IMG_W = 1280, IMG_H = 720;
    localparam JPEG_WORDS = 65536;
    localparam JPEG_BYTES  = JPEG_WORDS*4;
    localparam OUT = "sim/rtp_test/full.txt";

    reg clk = 0; always #5 clk = ~clk;
    reg rst_n;

    // ---- VTPG ----
    reg         frame_kick;
    wire [15:0] vid_tdata; wire vid_tvalid, vid_tready, vid_tlast, vid_tuser;
    vtpgz_core #(
        .EN_COLORBAR(1), .EN_MOVING_BOX(1), .EN_SOLID(1),
        .EN_HGRAD(0), .EN_VGRAD(0), .EN_CHECKER(0), .EN_GRID(0), .EN_RAMP(0), .EN_NOISE(0),
        .OUTPUT_MODE(2), .YUV_SUBSAMPLE(1), .BPC(8)
    ) u_vtpg (
        .aclk(clk), .aresetn(rst_n),
        .cfg_enable(1'b1), .cfg_sw_fsync(1'b0), .cfg_ext_sync(1'b1),
        .cfg_img_width(IMG_W[15:0]), .cfg_img_height(IMG_H[15:0]),
        .cfg_pattern(4'd0), .cfg_solid_color(24'h00_80_80), .cfg_box_color(24'hEB_80_80),
        .cfg_box_width(16'd32), .cfg_box_height(16'd8), .cfg_box_dx(16'd4), .cfg_box_dy(16'd2),
        .cfg_grid_spacing(16'd0), .cfg_grid_color(24'd0), .cfg_checker_size(16'd0),
        .cfg_frame_rate_div(32'd2), .cfg_bar_width(IMG_W/8),
        .cfg_hg_step(16'd0), .cfg_vg_step(16'd0), .cfg_box_border_color(24'd0), .cfg_box_border_width(8'd0),
        .sts_busy(), .sts_frame_count(),
        .m_axis_tdata(vid_tdata), .m_axis_tvalid(vid_tvalid), .m_axis_tready(vid_tready),
        .m_axis_tlast(vid_tlast), .m_axis_tuser(vid_tuser), .frame_sync_in(frame_kick)
    );

    // ---- encoder ----
    wire [7:0] jpg_tdata; wire jpg_tvalid, jpg_tlast;
    reg  [4:0]  awaddr; reg awvalid; wire awready;
    reg  [31:0] wdata; reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp; wire bvalid; reg bready;
    mjpegzero_enc_top #(.IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H), .LITE_MODE(0), .LITE_QUALITY(75)) u_enc (
        .clk(clk), .rst_n(rst_n),
        .s_axis_vid_tdata(vid_tdata), .s_axis_vid_tvalid(vid_tvalid), .s_axis_vid_tready(vid_tready),
        .s_axis_vid_tlast(vid_tlast), .s_axis_vid_tuser(vid_tuser),
        .m_axis_jpg_tdata(jpg_tdata), .m_axis_jpg_tvalid(jpg_tvalid), .m_axis_jpg_tlast(jpg_tlast),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(5'd0), .s_axi_arvalid(1'b0), .s_axi_arready(),
        .s_axi_rdata(), .s_axi_rresp(), .s_axi_rvalid(), .s_axi_rready(1'b0)
    );

    // ---- capture FSM (verbatim from demo_top_vtpg_eth) ----
    reg [18:0] jpeg_byte_cnt; reg [1:0] jp_phase; reg [23:0] jp_accum; reg [16:0] jp_wptr;
    reg flush_pend, jpeg_overflow, cap_done, cap_reset;
    wire jpeg_word_room = (jp_wptr < JPEG_WORDS[16:0]);
    wire jpeg_byte_room = (jpeg_byte_cnt < JPEG_BYTES[18:0]);
    always @(posedge clk) begin
        if (!rst_n) begin
            jpeg_byte_cnt<=0; jp_phase<=0; jp_accum<=0; jp_wptr<=0;
            flush_pend<=0; jpeg_overflow<=0; cap_done<=0;
        end else if (cap_reset) begin
            jpeg_byte_cnt<=0; jp_phase<=0; jp_wptr<=0; flush_pend<=0; jpeg_overflow<=0; cap_done<=0;
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
                end else jpeg_overflow <= 1'b1;
                if (jpg_tlast) begin
                    cap_done <= 1'b1;
                    if (jp_phase != 2'd3 && jpeg_word_room && !jpeg_overflow) flush_pend <= 1'b1;
                end
            end
        end
    end
    wire jpeg_we = (jpg_tvalid && jp_phase==2'd3 && jpeg_word_room) || (flush_pend && jpeg_word_room);
    wire [31:0] jpeg_wdata = (jpg_tvalid && jp_phase==2'd3) ? {jpg_tdata, jp_accum} : {8'd0, jp_accum};

    wire [16:0] rtp_mem_raddr; wire [31:0] rtp_mem_rdata;
    demo_jpeg_buffer #(.JPEG_WORDS(JPEG_WORDS), .JPEG_TILE_DEPTH(4096)) u_buf (
        .clk(clk), .we(jpeg_we), .waddr(jp_wptr), .wdata(jpeg_wdata),
        .raddr(rtp_mem_raddr), .rdata(rtp_mem_rdata)
    );

    // ---- jpeg_rtp_tx ----
    reg rtp_start; wire rtp_busy, rtp_done;
    wire [7:0] tx_data; wire tx_valid, tx_last; reg tx_ready;
    reg [2:0] sc=0; always @(posedge clk) sc<=sc+1; always @* tx_ready=(sc!=0);
    jpeg_rtp_tx #(.IMG_W(IMG_W), .IMG_H(IMG_H), .SCAN_OFF(623), .EOI_BYTES(2),
                  .QT_LUMA_OFF(25), .QT_CHROMA_OFF(94), .SCAN_CHUNK(11'd1024)) u_rtp (
        .clk(clk), .rst_n(rst_n),
        .our_mac(48'h020000000001), .our_ip(32'hC0A8ED32), .src_port(16'd5004),
        .dst_mac(48'hAABBCCDDEEFF), .dst_ip(32'hC0A8ED01), .dst_port(16'd5004),
        .ssrc(32'h0A0B0C0D), .rtp_timestamp(32'd0),
        .start(rtp_start), .jpeg_size(jpeg_byte_cnt),
        .busy(rtp_busy), .done_pulse(rtp_done),
        .mem_raddr(rtp_mem_raddr), .mem_rdata(rtp_mem_rdata),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_last(tx_last), .tx_ready(tx_ready)
    );

    // ---- control FSM (verbatim from demo_top_vtpg_eth) ----
    localparam [2:0] V_IDLE=0,V_KICK=1,V_ENC=2,V_STREAM=3,V_WAIT=4,V_KWAIT=5;
    reg [2:0] vstate; reg [31:0] frame_cnt; reg loop_en, init_done_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            vstate<=V_IDLE; frame_kick<=0; cap_reset<=0; rtp_start<=0; frame_cnt<=0;
        end else begin
            frame_kick<=0; cap_reset<=0; rtp_start<=0;
            case (vstate)
                V_IDLE:   if (loop_en && init_done_r) vstate<=V_KICK;
                V_KICK: begin cap_reset<=1; frame_kick<=1; vstate<=V_KWAIT; end
                V_KWAIT:  vstate<=V_ENC;   // let cap_reset clear stale cap_done before V_ENC
                V_ENC:    if (cap_done) vstate<=V_STREAM;
                V_STREAM: begin rtp_start<=1; if (rtp_busy) vstate<=V_WAIT; end
                V_WAIT:   if (rtp_done) begin frame_cnt<=frame_cnt+1; vstate<=loop_en?V_KICK:V_IDLE; end
                default: vstate<=V_IDLE;
            endcase
        end
    end

    // ---- output capture (per packet) + frame markers ----
    integer fd;
    always @(posedge clk) begin
        if (rst_n && tx_valid && tx_ready) begin
            $fwrite(fd, "%02x ", tx_data);
            if (tx_last) $fwrite(fd, "\n");
        end
        if (rst_n && rtp_done) $fwrite(fd, "# FRAME size=%0d\n", jpeg_byte_cnt);
    end

    // ---- ROOT-CAUSE TRACE: LUMA-only per-frame DC mins (split Y vs chroma by
    // MCU block position Y0,Y1,Cb,Cr) + the Huffman coded DC for the blackest blk.
    reg signed [15:0] ddc_lmin, qdc_lmin;     // luma-only DCT/quant DC mins
    reg [1:0] d_blk, q_blk;                    // block-in-MCU counters
    reg signed [15:0] huff_dcdiff_at_min;      // Huffman DC diff when quant DC is most-neg luma
    always @(posedge clk) begin
        if (!rst_n) begin d_blk<=0; q_blk<=0; ddc_lmin<=0; qdc_lmin<=0; end
        else begin
            if (frame_kick) begin d_blk<=0; q_blk<=0; ddc_lmin<=0; qdc_lmin<=0; end
            else begin
                if (u_enc.dct_out_valid && u_enc.dct_out_sof) begin
                    if (d_blk < 2 && $signed(u_enc.dct_out_data) < ddc_lmin) ddc_lmin<=u_enc.dct_out_data;
                    d_blk <= (d_blk==3)?0:d_blk+1;
                end
                if (u_enc.quant_out_valid && u_enc.quant_out_sob) begin
                    if (q_blk < 2 && $signed(u_enc.quant_out_data) < qdc_lmin) qdc_lmin<=u_enc.quant_out_data;
                    q_blk <= (q_blk==3)?0:q_blk+1;
                end
            end
        end
    end
    // Trace the Huffman's DC diff + magnitude for the most-negative luma DC block
    // First few LUMA DC blocks of EACH frame at S_DC_FETCH (state 1): shows
    // coeff_dc (quant DC going in), prev_dc_y (carryover?), and the diff the
    // Huffman codes. Carryover bug => frame 1 starts with prev_dc_y != 0.
    reg [3:0] huf_dc_cnt;
    always @(posedge clk) begin
        if (!rst_n || frame_kick) huf_dc_cnt <= 4'd0;
        else if (u_enc.u_huffman.state==4'd1 && u_enc.u_huffman.blk_comp_id<=2'd1
                 && huf_dc_cnt < 4'd8) begin
            // First luma DC block of each frame must show prev_dc_y=0 (predictor
            // reset at start-of-scan). A non-zero value here is the wash bug.
            $display("[%0t] F%0d LUMA-DC#%0d: coeff_dc=%0d prev_dc_y=%0d diff=%0d",
                $time, frame_cnt, huf_dc_cnt,
                $signed(u_enc.u_huffman.coeff_dc), $signed(u_enc.u_huffman.prev_dc_y),
                $signed(u_enc.u_huffman.coeff_dc) - $signed(u_enc.u_huffman.prev_dc_y));
            huf_dc_cnt <= huf_dc_cnt + 4'd1;
        end
    end
    always @(posedge clk) if (rst_n && cap_done && vstate==V_ENC)
        $display("[%0t] FRAME %0d LUMA mins: dct_dc=%0d quant_dc=%0d  (correct ~ -1024 / -128)",
                 $time, frame_cnt, $signed(ddc_lmin), $signed(qdc_lmin));

    // ---- per-frame diagnostics ----
    reg [31:0] pixcnt, usercnt, jpgcnt;
    always @(posedge clk) begin
        if (!rst_n) begin pixcnt<=0; usercnt<=0; jpgcnt<=0; end
        else begin
            if (frame_kick) begin pixcnt<=0; usercnt<=0; jpgcnt<=0; end
            else begin
                if (vid_tvalid && vid_tready) pixcnt <= pixcnt + 1;
                if (vid_tvalid && vid_tready && vid_tuser) usercnt <= usercnt + 1;
                if (jpg_tvalid) jpgcnt <= jpgcnt + 1;
            end
        end
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (vstate==V_KICK) $display("[%0t] KICK frame=%0d", $time, frame_cnt);
            if (cap_done && vstate==V_ENC)
                $display("[%0t] cap_done frame=%0d pix_accepted=%0d sof=%0d jpg_bytes=%0d",
                         $time, frame_cnt, pixcnt, usercnt, jpgcnt);
        end
    end

    task axi_write(input [4:0] a, input [31:0] d);
        begin @(posedge clk); awaddr=a; awvalid=1; wdata=d; wstrb=4'hF; wvalid=1; bready=1;
            fork begin wait(awready); @(posedge clk); awvalid=0; end
                 begin wait(wready); @(posedge clk); wvalid=0; end join
            wait(bvalid); @(posedge clk); bready=0; end
    endtask

    initial begin
        fd=$fopen(OUT,"w");
        rst_n=0; frame_kick=0; loop_en=0; init_done_r=0;
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        repeat(10) @(posedge clk); rst_n=1; repeat(5) @(posedge clk);
        axi_write(5'h00, 32'h1);             // enable encoder
        axi_write(5'h0C, 32'd75);            // runtime quality
        repeat(600) @(posedge clk);          // Q-table load
        init_done_r=1; loop_en=1;            // start the autonomous loop
        // run TWO full 720p frames to test frame-dependent drift (frame0 vs frame1)
        wait(frame_cnt >= 32'd3);
        repeat(300) @(posedge clk);
        $display("DONE frames=%0d", frame_cnt);
        $fclose(fd); $finish;
    end
    initial begin #6_000_000_000; $display("WATCHDOG frames=%0d", frame_cnt); $fclose(fd); $finish; end
endmodule
