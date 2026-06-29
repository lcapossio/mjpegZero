// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_vtpg_enc.sv - reproduce the VTPG->encoder integration bug in simulation.
// Wires vtpgz_core (colorbars + box, YUV 4:2:2) straight into mjpegzero_enc_top,
// exactly like demo_top_vtpg_eth, pulses frame_sync per frame, and dumps every
// encoder JPEG byte to sim_vtpg.bin with per-frame byte counts. Decode offline
// with PIL to check geometry/colors and the alternating-blank behaviour.
//
// Override size with -d VW=<w> -d VH=<h>. Default 128x16 (8 MCU cols, 2 rows).

`timescale 1ns / 1ps

module tb_vtpg_enc;
    localparam CLK_PERIOD = 10;
`ifdef VW
    localparam IMG_W = `VW;
`else
    localparam IMG_W = 1280;
`endif
`ifdef VH
    localparam IMG_H = `VH;
`else
    localparam IMG_H = 16;
`endif
`ifdef NFRAMES
    localparam NFRAMES = `NFRAMES;
`else
    localparam NFRAMES = 1;
`endif

    reg clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    reg rst_n;

    // VTPG -> encoder stream
    wire [15:0] vid_tdata;
    wire        vid_tvalid, vid_tready, vid_tlast, vid_tuser;
    reg         frame_kick;

    vtpgz_core #(
        .EN_COLORBAR(1), .EN_MOVING_BOX(1), .EN_SOLID(1),
        .EN_HGRAD(0), .EN_VGRAD(0), .EN_CHECKER(0),
        .EN_GRID(0), .EN_RAMP(0), .EN_NOISE(0),
        .OUTPUT_MODE(2), .YUV_SUBSAMPLE(1), .BPC(8)
    ) u_vtpg (
        .aclk(clk), .aresetn(rst_n),
        .cfg_enable(1'b1), .cfg_sw_fsync(1'b0), .cfg_ext_sync(1'b1),
        .cfg_img_width(IMG_W[15:0]), .cfg_img_height(IMG_H[15:0]),
        .cfg_pattern(4'd0),
        .cfg_solid_color(24'h00_80_80),
        .cfg_box_color(24'hEB_80_80),
        .cfg_box_width(16'd32), .cfg_box_height(16'd8),
        .cfg_box_dx(16'd4), .cfg_box_dy(16'd2),
        .cfg_grid_spacing(16'd0), .cfg_grid_color(24'd0), .cfg_checker_size(16'd0),
        .cfg_frame_rate_div(32'd2), .cfg_bar_width((IMG_W/8)),
        .cfg_hg_step(16'd0), .cfg_vg_step(16'd0),
        .cfg_box_border_color(24'd0), .cfg_box_border_width(8'd0),
        .sts_busy(), .sts_frame_count(),
        .m_axis_tdata(vid_tdata), .m_axis_tvalid(vid_tvalid),
        .m_axis_tready(vid_tready), .m_axis_tlast(vid_tlast), .m_axis_tuser(vid_tuser),
        .frame_sync_in(frame_kick)
    );

    wire [7:0] jpg_tdata;
    wire       jpg_tvalid, jpg_tlast;
    // AXI-Lite
    reg  [4:0]  awaddr; reg awvalid; wire awready;
    reg  [31:0] wdata; reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp; wire bvalid; reg bready;
    reg  [4:0]  araddr; reg arvalid; wire arready;
    wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready;

`ifdef POSTSIM
    mjpegzero_enc_top dut (   // netlist: params baked in
`else
    mjpegzero_enc_top #(
        .IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H), .LITE_MODE(0), .LITE_QUALITY(75)
    ) dut (
`endif
        .clk(clk), .rst_n(rst_n),
        .s_axis_vid_tdata(vid_tdata), .s_axis_vid_tvalid(vid_tvalid),
        .s_axis_vid_tready(vid_tready), .s_axis_vid_tlast(vid_tlast),
        .s_axis_vid_tuser(vid_tuser),
        .m_axis_jpg_tdata(jpg_tdata), .m_axis_jpg_tvalid(jpg_tvalid),
        .m_axis_jpg_tlast(jpg_tlast),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );

    // Dump encoder bytes
    integer fbin, total, fcount, frame_bytes;
    initial begin fbin = $fopen("sim_vtpg.bin", "wb"); total = 0; fcount = 0; frame_bytes = 0; end
    always @(posedge clk) begin
        if (jpg_tvalid) begin
            $fwrite(fbin, "%c", jpg_tdata);
            total = total + 1; frame_bytes = frame_bytes + 1;
            if (jpg_tlast) begin
                $display("[FRAME %0d] bytes=%0d (total=%0d)", fcount, frame_bytes, total);
                fcount = fcount + 1; frame_bytes = 0;
            end
        end
    end

    task axi_write(input [4:0] a, input [31:0] d);
        begin
            @(posedge clk);
            awaddr=a; awvalid=1; wdata=d; wstrb=4'hF; wvalid=1; bready=1;
            fork
                begin wait(awready); @(posedge clk); awvalid=0; end
                begin wait(wready);  @(posedge clk); wvalid=0;  end
            join
            wait(bvalid); @(posedge clk); bready=0;
        end
    endtask

    integer f;
    initial begin
        rst_n=0; frame_kick=0;
        awaddr=0; awvalid=0; wdata=0; wstrb=0; wvalid=0; bready=0;
        araddr=0; arvalid=0; rready=0;
        repeat(10) @(posedge clk);
        rst_n=1; repeat(5) @(posedge clk);
        axi_write(5'h00, 32'h1);           // enable encoder
        axi_write(5'h0C, 32'd75);          // runtime quality
        repeat(600) @(posedge clk);        // Q-table load
        for (f=0; f<NFRAMES; f=f+1) begin
            @(negedge clk); frame_kick=1; @(negedge clk); frame_kick=0;
            // wait for this frame's EOI
            @(posedge clk);
            wait(jpg_tvalid && jpg_tlast);
            @(posedge clk);
            repeat(50) @(posedge clk);     // settle between frames
        end
        repeat(100) @(posedge clk);
        $display("DONE frames=%0d total=%0d", fcount, total);
        $fclose(fbin);
        $finish;
    end

    initial begin
        #1_500_000_000;   // 1.5 ms... 1.5 s sim time: a full 720p frame needs ~hundreds of ms
        $display("WATCHDOG TIMEOUT total=%0d frames=%0d", total, fcount);
        $fclose(fbin);
        $finish;
    end
endmodule
