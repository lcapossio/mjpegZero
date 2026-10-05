// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_vtpg_stream.v - the demo_top_vtpg_eth streaming datapath at 1280x720,
// built from the same modules the bitstream uses (only the MAC/MII side is
// left out):
//
//   vtpg_udp_control (defaults) -> vtpgz_core -> mjpegzero_enc_top
//     -> jpeg_capture -> demo_jpeg_buffer -> jpeg_rtp_tx -> axis_frame_buffer
//   vtpg_stream_control + axi_init sequence it, exactly as on the board.
//
// Host control is replayed the way stream_view.py / eth_control.py drive it:
// start the loop, stop it while a frame is encoding (that frame must still
// stream, then the loop idles), then request a single frame.
//
// Per encoded frame k it writes, into the run directory:
//   pix_f<k>.hex  - every pixel word the encoder accepted (one per line)
//   enc_f<k>.hex  - every JPEG byte the encoder emitted (one per line)
//   q_f<k>.txt    - QUALITY written by rate control before that frame
// and, for the whole run, rtp.txt: one Ethernet frame per line (hex bytes),
// with a "# FRAME <n> size=<bytes>" note at each rtp_done (it can land inside
// the line of the packet still draining; the checker splits on the RTP marker).
// run_vtpg_stream_sim.py checks them against the Python reference encoder.
//
// Verilog-2001 plus delays; runs on Verilator (--binary --timing) or Icarus.

`timescale 1ns / 1ps

module tb_vtpg_stream;
    localparam IMG_W      = 1280;
    localparam IMG_H      = 720;
    localparam JPEG_WORDS = 65536;
    localparam [18:0] JPEG_CAP_BYTES = JPEG_WORDS * 4;
    // RC_GOOD_FRAMES=1 makes rate control raise QUALITY after every small
    // frame, so each frame is encoded at a different quality - the per-frame
    // QUALITY latch is exercised on every frame boundary.
    localparam [2:0]  RC_GOOD_FRAMES = 3'd1;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    // ------------------------------------------------------------------
    // Runtime VTPG config: the UDP control block's power-on defaults (no
    // packets), which is what the board shows before any key is pressed.
    // ------------------------------------------------------------------
    wire [3:0]  cfg_pattern_r;
    wire [23:0] solid_color_r, box_color_r;
    wire [15:0] box_w_r, box_h_r, box_dx_r, box_dy_r, grid_spacing_r, checker_size_r;
    wire [31:0] box_img_x_step_r, box_img_y_step_r;
    vtpg_udp_control u_udp_control (
        .clk(clk), .rst_n(rst_n),
        .udp_data(8'd0), .udp_valid(1'b0), .udp_last(1'b0), .udp_err(1'b0), .udp_dst_port(16'd0),
        .start_loop(), .stop_loop(), .single_req(),
        .cfg_pattern(cfg_pattern_r), .solid_color(solid_color_r), .box_color(box_color_r),
        .box_w(box_w_r), .box_h(box_h_r), .box_dx(box_dx_r), .box_dy(box_dy_r),
        .grid_spacing(grid_spacing_r), .checker_size(checker_size_r),
        .box_img_x_step(box_img_x_step_r), .box_img_y_step(box_img_y_step_r)
    );

    // ------------------------------------------------------------------
    // VTPG - parameters copied from demo_top_vtpg_eth
    // ------------------------------------------------------------------
    wire        frame_kick;
    wire [15:0] vid_tdata;
    wire        vid_tvalid, vid_tready, vid_tlast, vid_tuser;
    vtpgz_core #(
        .EN_COLORBAR(1), .EN_MOVING_BOX(1), .EN_SOLID(1),
        .EN_HGRAD(1), .EN_VGRAD(1), .EN_CHECKER(1),
        .EN_GRID(1), .EN_RAMP(1), .EN_NOISE(1),
        .EN_IMAGE(1),
        .IMAGE_W(128), .IMAGE_H(128), .IMAGE_OUT_W(1280), .IMAGE_OUT_H(720),
        .IMAGE_HEX_FILE("mandrill_128x128_ycbcr.mem"),
        .EN_BOX_IMAGE(1),
        .BOX_IMAGE_W(32), .BOX_IMAGE_H(32),
        .BOX_IMAGE_HEX_FILE("banana_32x32_ycbcr.mem"),
        .OUTPUT_MODE(2), .YUV_SUBSAMPLE(1), .BPC(8)
    ) u_vtpg (
        .aclk(clk), .aresetn(rst_n),
        .cfg_enable(1'b1), .cfg_sw_fsync(1'b0), .cfg_ext_sync(1'b1),
        .cfg_img_width(IMG_W[15:0]), .cfg_img_height(IMG_H[15:0]),
        .cfg_pattern(cfg_pattern_r),
        .cfg_solid_color(solid_color_r), .cfg_box_color(box_color_r),
        .cfg_box_width(box_w_r), .cfg_box_height(box_h_r),
        .cfg_box_dx(box_dx_r), .cfg_box_dy(box_dy_r),
        .cfg_grid_spacing(grid_spacing_r), .cfg_grid_color(24'hEB_80_80),
        .cfg_checker_size(checker_size_r),
        .cfg_frame_rate_div(32'd2), .cfg_bar_width(16'd160),
        .cfg_hg_step(16'd16), .cfg_vg_step(16'd16),
        .cfg_box_border_color(24'h00_80_80), .cfg_box_border_width(8'd2),
        .cfg_box_img_x_step(box_img_x_step_r), .cfg_box_img_y_step(box_img_y_step_r),
        .cfg_tid(16'd0), .cfg_tdest(16'd0),
        .cfg_smpte_side_d(16'd0), .cfg_smpte_bar_c(16'd0), .cfg_smpte_row_h(16'd0),
        .cfg_smpte_pluge_p(16'd0), .cfg_smpte_ramp_step(16'd0),
        .sts_busy(), .sts_frame_count(),
        .m_axis_tdata(vid_tdata), .m_axis_tvalid(vid_tvalid), .m_axis_tready(vid_tready),
        .m_axis_tlast(vid_tlast), .m_axis_tuser(vid_tuser),
        .frame_sync_in(frame_kick)
    );

    // ------------------------------------------------------------------
    // Encoder + AXI-Lite init master (as on the board)
    // ------------------------------------------------------------------
    wire [4:0]  ei_awaddr;  wire ei_awvalid, ei_awready;
    wire [31:0] ei_wdata;   wire [3:0] ei_wstrb; wire ei_wvalid, ei_wready;
    wire [1:0]  ei_bresp;   wire ei_bvalid, ei_bready;
    wire [4:0]  ei_araddr;  wire ei_arvalid, ei_arready;
    wire [31:0] ei_rdata;   wire [1:0] ei_rresp; wire ei_rvalid, ei_rready;
    wire        init_done;
    wire        enc_quality_req, enc_quality_busy, enc_quality_done;
    wire [6:0]  enc_quality_value;
    axi_init u_init (
        .clk(clk), .rst_n(rst_n),
        .m_axi_awaddr(ei_awaddr), .m_axi_awvalid(ei_awvalid), .m_axi_awready(ei_awready),
        .m_axi_wdata(ei_wdata), .m_axi_wstrb(ei_wstrb), .m_axi_wvalid(ei_wvalid),
        .m_axi_wready(ei_wready), .m_axi_bresp(ei_bresp), .m_axi_bvalid(ei_bvalid),
        .m_axi_bready(ei_bready), .m_axi_araddr(ei_araddr), .m_axi_arvalid(ei_arvalid),
        .m_axi_arready(ei_arready), .m_axi_rdata(ei_rdata), .m_axi_rresp(ei_rresp),
        .m_axi_rvalid(ei_rvalid), .m_axi_rready(ei_rready),
        .quality_req(enc_quality_req), .quality_value(enc_quality_value),
        .quality_busy(enc_quality_busy), .quality_done(enc_quality_done),
        .init_done(init_done)
    );

    wire [7:0] jpg_tdata;
    wire       jpg_tvalid, jpg_tlast;
    mjpegzero_enc_top #(
        .LITE_MODE(0), .LITE_QUALITY(75), .IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H)
    ) u_enc (
        .clk(clk), .rst_n(rst_n),
        .s_axis_vid_tdata(vid_tdata), .s_axis_vid_tvalid(vid_tvalid),
        .s_axis_vid_tready(vid_tready), .s_axis_vid_tlast(vid_tlast),
        .s_axis_vid_tuser(vid_tuser),
        .m_axis_jpg_tdata(jpg_tdata), .m_axis_jpg_tvalid(jpg_tvalid),
        .m_axis_jpg_tlast(jpg_tlast),
        .s_axi_awaddr(ei_awaddr), .s_axi_awvalid(ei_awvalid), .s_axi_awready(ei_awready),
        .s_axi_wdata(ei_wdata), .s_axi_wstrb(ei_wstrb), .s_axi_wvalid(ei_wvalid),
        .s_axi_wready(ei_wready), .s_axi_bresp(ei_bresp), .s_axi_bvalid(ei_bvalid),
        .s_axi_bready(ei_bready), .s_axi_araddr(ei_araddr), .s_axi_arvalid(ei_arvalid),
        .s_axi_arready(ei_arready), .s_axi_rdata(ei_rdata), .s_axi_rresp(ei_rresp),
        .s_axi_rvalid(ei_rvalid), .s_axi_rready(ei_rready)
    );

    // ------------------------------------------------------------------
    // Capture -> buffer -> RTP packetizer -> per-frame store-and-forward
    // ------------------------------------------------------------------
    wire        cap_reset, cap_done, jpeg_overflow;
    wire [18:0] jpeg_byte_cnt;
    wire        jpeg_we;
    wire [16:0] jpeg_waddr;
    wire [31:0] jpeg_wdata;
    jpeg_capture #(.JPEG_WORDS(JPEG_WORDS)) u_jpeg_capture (
        .clk(clk), .rst_n(rst_n), .cap_reset(cap_reset),
        .jpg_tvalid(jpg_tvalid), .jpg_tdata(jpg_tdata), .jpg_tlast(jpg_tlast),
        .we(jpeg_we), .waddr(jpeg_waddr), .wdata(jpeg_wdata),
        .jpeg_size(jpeg_byte_cnt), .cap_done(cap_done), .overflow(jpeg_overflow)
    );

    wire [16:0] rtp_mem_raddr;
    wire [31:0] rtp_mem_rdata;
    demo_jpeg_buffer #(.JPEG_WORDS(JPEG_WORDS), .JPEG_TILE_DEPTH(4096)) u_jpeg_buffer (
        .clk(clk), .we(jpeg_we), .waddr(jpeg_waddr), .wdata(jpeg_wdata),
        .raddr(rtp_mem_raddr), .rdata(rtp_mem_rdata)
    );

    wire        rtp_start, rtp_busy, rtp_done;
    wire [7:0]  rtp_tx_tdata;
    wire        rtp_tx_tvalid, rtp_tx_tready, rtp_tx_tlast;
    wire [3:0]  vstate;
    wire [31:0] frame_cnt;
    wire        loop_en;
    wire [6:0]  rc_quality;
    wire [15:0] rc_dropped_frames;
    jpeg_rtp_tx #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .SCAN_OFF(623), .EOI_BYTES(2),
        .QT_LUMA_OFF(25), .QT_CHROMA_OFF(94), .SCAN_CHUNK(11'd1024)
    ) u_rtp (
        .clk(clk), .rst_n(rst_n),
        .our_mac(48'h02_00_00_00_00_01), .our_ip(32'hC0_A8_ED_32), .src_port(16'd5004),
        .dst_mac(48'hAA_BB_CC_DD_EE_FF), .dst_ip(32'hC0_A8_ED_01), .dst_port(16'd5004),
        .ssrc(32'h0A0B0C0D), .rtp_timestamp({frame_cnt[19:0], 12'd0}),
        .start(rtp_start), .jpeg_size(jpeg_byte_cnt),
        .busy(rtp_busy), .done_pulse(rtp_done),
        .mem_raddr(rtp_mem_raddr), .mem_rdata(rtp_mem_rdata),
        .tx_data(rtp_tx_tdata), .tx_valid(rtp_tx_tvalid),
        .tx_last(rtp_tx_tlast), .tx_ready(rtp_tx_tready)
    );

    wire [7:0] fb_tdata;
    wire       fb_tvalid, fb_tlast;
    reg        fb_tready;
    axis_frame_buffer #(.AW(11)) u_fb (
        .clk(clk), .rst_n(rst_n),
        .s_tdata(rtp_tx_tdata), .s_tvalid(rtp_tx_tvalid),
        .s_tlast(rtp_tx_tlast), .s_tready(rtp_tx_tready),
        .m_tdata(fb_tdata), .m_tvalid(fb_tvalid),
        .m_tlast(fb_tlast), .m_tready(fb_tready)
    );
    // The MAC drains in bursts; 3 of every 4 cycles ready is enough backpressure
    // to exercise the store-and-forward without making the run slow.
    reg [1:0] drain_ph = 2'd0;
    always @(posedge clk) begin
        drain_ph  <= drain_ph + 2'd1;
        fb_tready <= (drain_ph != 2'd0);
    end

    // ------------------------------------------------------------------
    // Stream control (start/stop/single replayed by the initial block)
    // ------------------------------------------------------------------
    reg start_loop = 1'b0, stop_loop = 1'b0, single_req = 1'b0;
    vtpg_stream_control #(
        .JPEG_CAP_BYTES(JPEG_CAP_BYTES), .RC_GOOD_FRAMES(RC_GOOD_FRAMES)
    ) u_stream_control (
        .clk(clk), .rst_n(rst_n),
        .start_loop(start_loop), .stop_loop(stop_loop), .single_req(single_req),
        .init_done(init_done),
        .enc_quality_req(enc_quality_req), .enc_quality_value(enc_quality_value),
        .enc_quality_busy(enc_quality_busy), .enc_quality_done(enc_quality_done),
        .frame_kick(frame_kick), .cap_reset(cap_reset), .cap_done(cap_done),
        .jpeg_overflow(jpeg_overflow), .jpeg_byte_cnt(jpeg_byte_cnt),
        .rtp_start(rtp_start), .rtp_busy(rtp_busy), .rtp_done(rtp_done),
        .vstate(vstate), .frame_cnt(frame_cnt), .loop_en(loop_en),
        .rc_quality(rc_quality), .rc_dropped_frames(rc_dropped_frames)
    );

    // ------------------------------------------------------------------
    // Dumps
    // ------------------------------------------------------------------
    integer pix_fd = 0, enc_fd = 0, rtp_fd = 0, q_fd = 0;
    integer pix_k = 0, enc_k = 0;
    integer kicks = 0, streamed = 0;
    reg [6:0] last_q = 7'd0;
    reg [8*32-1:0] fname;

    always @(posedge clk) if (rst_n) begin
        // Pixel words into the encoder; a new file at each start-of-frame.
        if (vid_tvalid && vid_tready) begin
            if (vid_tuser) begin
                if (pix_fd != 0) $fclose(pix_fd);
                $sformat(fname, "pix_f%0d.hex", pix_k);
                pix_fd = $fopen(fname, "w");
                $sformat(fname, "q_f%0d.txt", pix_k);
                q_fd = $fopen(fname, "w");
                $fwrite(q_fd, "%0d\n", last_q);
                $fclose(q_fd);
                pix_k = pix_k + 1;
            end
            if (pix_fd != 0) $fwrite(pix_fd, "%04x\n", vid_tdata);
        end
        // Encoder JPEG bytes; one file per frame, closed on TLAST (EOI).
        if (jpg_tvalid) begin
            if (enc_fd == 0) begin
                $sformat(fname, "enc_f%0d.hex", enc_k);
                enc_fd = $fopen(fname, "w");
            end
            $fwrite(enc_fd, "%02x\n", jpg_tdata);
            if (jpg_tlast) begin
                $fclose(enc_fd);
                enc_fd = 0;
                enc_k = enc_k + 1;
            end
        end
        // Ethernet frames leaving the store-and-forward buffer.
        if (fb_tvalid && fb_tready) begin
            $fwrite(rtp_fd, "%02x ", fb_tdata);
            if (fb_tlast) $fwrite(rtp_fd, "\n");
        end
        if (rtp_done) begin
            streamed = streamed + 1;
            $fwrite(rtp_fd, "# FRAME %0d size=%0d\n", frame_cnt, jpeg_byte_cnt);
        end
        if (enc_quality_done) last_q <= enc_quality_value;
        if (frame_kick) begin
            kicks = kicks + 1;
            $display("[%0t] kick %0d  Q=%0d  loop_en=%0d", $time, kicks, last_q, loop_en);
        end
        if (cap_done && vstate == 4'd5)
            $display("[%0t] captured %0d bytes%s", $time, jpeg_byte_cnt,
                     jpeg_overflow ? " (OVERFLOW)" : "");
    end

    task wait_cycles(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) @(posedge clk);
        end
    endtask

    integer idle_kicks;
    initial begin
        rtp_fd = $fopen("rtp.txt", "w");
        wait_cycles(20);
        rst_n = 1'b1;
        wait (init_done);
        wait_cycles(10);

        // 1) start: stream continuously
        $display("[%0t] host: start", $time);
        @(posedge clk); start_loop = 1'b1; @(posedge clk); start_loop = 1'b0;
        wait (streamed == 2);

        // 2) stop while the third frame is encoding: it must still stream,
        //    then the loop must go idle and kick nothing more.
        wait (vstate == 4'd5);
        wait_cycles(1000);
        $display("[%0t] host: stop (frame 3 encoding)", $time);
        @(posedge clk); stop_loop = 1'b1; @(posedge clk); stop_loop = 1'b0;
        wait (streamed == 3);
        wait (vstate == 4'd0);
        idle_kicks = kicks;
        wait_cycles(200000);
        if (kicks != idle_kicks) begin
            $display("FAIL: loop kicked %0d frame(s) after stop", kicks - idle_kicks);
            $finish;
        end

        // 3) single: exactly one more frame
        $display("[%0t] host: single", $time);
        @(posedge clk); single_req = 1'b1; @(posedge clk); single_req = 1'b0;
        wait (streamed == 4);
        wait (vstate == 4'd0);
        wait_cycles(200000);
        if (kicks != 4) begin
            $display("FAIL: %0d kicks after single, expected 4", kicks);
            $finish;
        end

        $display("DONE frames=%0d kicks=%0d streamed=%0d encoded=%0d dropped=%0d rc_q=%0d",
                 frame_cnt, kicks, streamed, enc_k, rc_dropped_frames, rc_quality);
        $fclose(rtp_fd);
        $finish;
    end

    // Watchdog: 4 frames at ~1M cycles each, plus streaming and idle checks.
    initial begin
        #200_000_000;
        $display("FAIL: watchdog  kicks=%0d streamed=%0d encoded=%0d vstate=%0d",
                 kicks, streamed, enc_k, vstate);
        $finish;
    end
endmodule
