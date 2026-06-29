// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// demo_top_vtpg_eth.v - Arty A7-100T: stream a MOVING test pattern as RTP/JPEG.
//
// vtpgZero (colorbars + bouncing box, YUV 4:2:2) feeds the mjpegZero encoder
// directly; an autonomous control FSM loops { kick a VTPG frame -> encode ->
// stream over Ethernet } so the host sees continuous live motion. The bouncing
// box advances one step per frame -> real motion video. Everything runs in a
// single 100 MHz domain (the MII clocks are async, handled inside eth_mac_sys).
//
//   vtpgz_core --(16b {C,Y} 4:2:2)--> mjpegzero_enc_top --> JPEG capture/buffer
//        ^ frame_sync (1 frame per pulse)                          |
//   ctrl FSM: KICK -> wait jpg EOI -> STREAM -> wait rtp_done -> KICK ...
//                                                                  v
//   net_rx -> jpeg_rtp_trigger (captures host addr, enables loop)
//   jpeg_rtp_tx -> axis_frame_buffer -> arty_tx_arbiter -> eth_mac_sys (MII)
//
// fcapz EJTAG-AXI (JTAG) provides read-only debug status + a soft reset.
// Verilog 2001.

`timescale 1ns / 1ps

module demo_top_vtpg_eth #(
    parameter JPEG_WORDS = 65536,
    parameter [47:0] OUR_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] OUR_IP  = 32'hC0_A8_ED_32,   // 192.168.237.50
    parameter [15:0] TRIGGER_PORT   = 16'd9999,
    parameter [15:0] RTP_PORT       = 16'd5004,
    parameter [15:0] VTPG_CTRL_PORT = 16'd9998   // single-byte keyboard cfg commands
) (
    input  wire CLK100MHZ,
    output wire led0,        // heartbeat
    output wire led1,        // loop running
    output wire led2,        // frame encoded (toggles per frame)
    output wire led3,        // ethernet TX activity

    output wire [3:0] ETH_TXD,
    output wire       ETH_TX_EN,
    input  wire       ETH_TX_CLK,
    input  wire [3:0] ETH_RXD,
    input  wire       ETH_RX_DV,
    input  wire       ETH_RXERR,
    input  wire       ETH_RX_CLK,
    input  wire       ETH_CRS,
    input  wire       ETH_COL,
    output wire       ETH_MDC,
    inout  wire       ETH_MDIO,
    output wire       ETH_REF_CLK,
    output wire       ETH_RSTN
);

    localparam IMG_W      = 1280;
    localparam IMG_H      = 720;
    localparam JPEG_BYTES = JPEG_WORDS * 4;
    localparam [18:0] JPEG_CAP_BYTES = JPEG_BYTES[18:0];
    localparam [18:0] RC_HIGH_BYTES  = JPEG_CAP_BYTES - (JPEG_CAP_BYTES >> 3); // 87.5%
    localparam [18:0] RC_LOW_BYTES   = JPEG_CAP_BYTES >> 1;                    // 50.0%
    localparam [6:0]  RC_Q_INIT      = 7'd75;
    localparam [6:0]  RC_Q_MIN       = 7'd5;
    localparam [6:0]  RC_Q_MAX       = 7'd95;
    localparam [6:0]  RC_Q_NEAR_STEP = 7'd5;
    localparam [6:0]  RC_Q_OVF_STEP  = 7'd20;
    localparam [2:0]  RC_GOOD_FRAMES = 3'd4;
    localparam [9:0]  RC_Q_SETTLE_CYCLES = 10'd600;

    function [6:0] rc_quality_sub;
        input [6:0] q;
        input [6:0] delta;
        reg [7:0] min_plus_delta;
        begin
            min_plus_delta = {1'b0, RC_Q_MIN} + {1'b0, delta};
            if ({1'b0, q} <= min_plus_delta)
                rc_quality_sub = RC_Q_MIN;
            else
                rc_quality_sub = q - delta;
        end
    endfunction

    function [6:0] rc_quality_inc;
        input [6:0] q;
        begin
            if (q >= RC_Q_MAX)
                rc_quality_inc = RC_Q_MAX;
            else
                rc_quality_inc = q + 7'd1;
        end
    endfunction

    // =======================================================================
    // Clocks & reset (single 138 MHz functional domain + 25 MHz PHY ref)
    // The whole datapath (vtpg + encoder + control FSM + MAC AXIS side) runs on
    // one clock; the MII side is async and bridged inside eth_mac_sys, so we run
    // that clock at 138 MHz (~1.4x the original 100) for the throughput target.
    // (150 MHz closes for the encoder but the RTP packetizer has sub-0.15 ns
    //  paths there; 138 closes with margin and still exceeds 60 fps @ 720p.)
    // =======================================================================
    wire clk100_unused, clk, clk25, locked;
    clk_gen_eth #(.CLKOUT0_DIV(6.875)) u_clkgen (   // 900/6.875 = 130.9 MHz functional clock (relaxed timing, ~63 fps)
        .clk_in (CLK100MHZ), .reset(1'b0),
        .clk_150(clk), .clk_100(clk100_unused), .clk_25(clk25), .locked(locked)
    );

    reg [3:0] rst_sr;
    wire rst_n = rst_sr[3];
    always @(posedge clk)
        if (!locked) rst_sr <= 4'b0000;
        else         rst_sr <= {rst_sr[2:0], 1'b1};

    localparam PHY_RST_CYCLES = 25'd20_000_000;   // 200 ms @ 100 MHz
    reg [24:0] phy_rst_cnt;
    reg        phy_rst_done;
    always @(posedge clk) begin
        if (!locked) begin phy_rst_cnt <= 25'd0; phy_rst_done <= 1'b0; end
        else if (phy_rst_cnt < PHY_RST_CYCLES) phy_rst_cnt <= phy_rst_cnt + 25'd1;
        else phy_rst_done <= 1'b1;
    end
    assign ETH_RSTN = phy_rst_done;
    wire eth_rst_n = rst_n & phy_rst_done;

    ddr_output u_ref_clk (.clk(clk25), .d1(1'b1), .d2(1'b0), .q(ETH_REF_CLK));

    // soft reset from JTAG CTRL (pulse)
    reg sw_reset;

    // =======================================================================
    // Encoder AXI4-Lite init (enable)
    // =======================================================================
    wire [4:0]  ei_awaddr;  wire ei_awvalid, ei_awready;
    wire [31:0] ei_wdata;   wire [3:0] ei_wstrb; wire ei_wvalid, ei_wready;
    wire [1:0]  ei_bresp;   wire ei_bvalid, ei_bready;
    wire [4:0]  ei_araddr;  wire ei_arvalid, ei_arready;
    wire [31:0] ei_rdata;   wire [1:0] ei_rresp; wire ei_rvalid, ei_rready;
    wire init_done;
    reg         enc_quality_req;
    reg  [6:0]  enc_quality_value;
    wire        enc_quality_busy;
    wire        enc_quality_done;

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

    // =======================================================================
    // Video test pattern generator (colorbars + bouncing box, YUV 4:2:2 8bpc)
    // =======================================================================
    reg         frame_kick;     // 1-cycle pulse -> VTPG external frame sync
    wire [15:0] vid_tdata;       // {C,Y} 4:2:2
    wire        vid_tvalid, vid_tready, vid_tlast, vid_tuser;

    // Runtime vtpg config, written over UDP (VTPG_CTRL_PORT) as KV260-style
    // register writes. The host (stream_view.py) owns all state exactly like the
    // KV260 A53 app; defaults mirror that app's init (box 96x64, white, image-in-box).
    reg [3:0]  cfg_pattern_r;                  // 0..9 (9=image); KV260 PATTERN_SEL
    reg [23:0] solid_color_r, box_color_r;     // {Y,Cb,Cr}
    reg [15:0] box_w_r, box_h_r;               // box size (px)
    reg [15:0] box_dx_r, box_dy_r;             // box speed (px/frame)
    reg [15:0] grid_spacing_r, checker_size_r;
    reg [31:0] box_img_x_step_r, box_img_y_step_r;  // Q16 box-image scaler (0=solid box)

    vtpgz_core #(
        .EN_COLORBAR(1), .EN_MOVING_BOX(1), .EN_SOLID(1),
        .EN_HGRAD(1), .EN_VGRAD(1), .EN_CHECKER(1),
        .EN_GRID(1), .EN_RAMP(1), .EN_NOISE(1),
        .EN_IMAGE(1),                                  // pattern 9 = full-frame mandrill
        .IMAGE_W(128), .IMAGE_H(128), .IMAGE_OUT_W(1280), .IMAGE_OUT_H(720),
        .IMAGE_HEX_FILE("mandrill_128x128_ycbcr.mem"), // YCbCr (OUTPUT_MODE=2 reads {Y,Cb,Cr})
        .EN_BOX_IMAGE(1),                              // mandrill in the moving box ('i' toggle)
        .BOX_IMAGE_W(32), .BOX_IMAGE_H(32),
        .BOX_IMAGE_HEX_FILE("mandrill_32x32_ycbcr.mem"),
        .OUTPUT_MODE(2),     // YUV
        .YUV_SUBSAMPLE(1),   // 4:2:2 -> 16-bit {C,Y}
        .BPC(8)
    ) u_vtpg (
        .aclk(clk), .aresetn(rst_n),
        .cfg_enable(1'b1), .cfg_sw_fsync(1'b0), .cfg_ext_sync(1'b1),
        .cfg_img_width(IMG_W[15:0]), .cfg_img_height(IMG_H[15:0]),
        .cfg_pattern(cfg_pattern_r),
        .cfg_solid_color(solid_color_r),
        .cfg_box_color(box_color_r),
        .cfg_box_width(box_w_r), .cfg_box_height(box_h_r),
        .cfg_box_dx(box_dx_r), .cfg_box_dy(box_dy_r),
        .cfg_grid_spacing(grid_spacing_r), .cfg_grid_color(24'hEB_80_80), .cfg_checker_size(checker_size_r),
        .cfg_frame_rate_div(32'd2), .cfg_bar_width(16'd160),  // bar = 1280/8
        .cfg_hg_step(16'd16), .cfg_vg_step(16'd16),
        .cfg_box_border_color(24'h00_80_80), .cfg_box_border_width(8'd2),  // black ring ({Y,Cb,Cr}), 2px
        .cfg_box_img_x_step(box_img_x_step_r), .cfg_box_img_y_step(box_img_y_step_r),
        .sts_busy(), .sts_frame_count(),
        .m_axis_tdata(vid_tdata), .m_axis_tvalid(vid_tvalid),
        .m_axis_tready(vid_tready), .m_axis_tlast(vid_tlast), .m_axis_tuser(vid_tuser),
        .frame_sync_in(frame_kick)
    );

    // =======================================================================
    // MJPEG encoder (auto-frames each incoming VTPG frame)
    // =======================================================================
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

    // =======================================================================
    // JPEG capture -> demo_jpeg_buffer (1W encoder, 1R jpeg_rtp_tx; single clk)
    // =======================================================================
    reg         cap_reset;       // from control FSM: clear capture for a new frame
    wire        cap_done;        // set when a full JPEG (EOI) has been captured
    wire        jpeg_overflow;   // frame exceeded the buffer (partial capture)
    wire [18:0] jpeg_byte_cnt;   // total bytes captured (-> jpeg_rtp_tx .jpeg_size)

    wire        jpeg_we;
    wire [16:0] jp_wptr;
    wire [31:0] jpeg_wdata;
    wire [16:0] rtp_mem_raddr;
    wire [31:0] rtp_mem_rdata;

    jpeg_capture #(.JPEG_WORDS(JPEG_WORDS)) u_jpeg_capture (
        .clk(clk), .rst_n(rst_n), .cap_reset(cap_reset),
        .jpg_tvalid(jpg_tvalid), .jpg_tdata(jpg_tdata), .jpg_tlast(jpg_tlast),
        .we(jpeg_we), .waddr(jp_wptr), .wdata(jpeg_wdata),
        .jpeg_size(jpeg_byte_cnt), .cap_done(cap_done), .overflow(jpeg_overflow)
    );

    demo_jpeg_buffer #(.JPEG_WORDS(JPEG_WORDS), .JPEG_TILE_DEPTH(4096)) u_jpeg_buffer (
        .clk(clk), .we(jpeg_we), .waddr(jp_wptr), .wdata(jpeg_wdata),
        .raddr(rtp_mem_raddr), .rdata(rtp_mem_rdata)
    );

    // =======================================================================
    // Ethernet island
    // =======================================================================
    // -- MAC CSR bring-up --
    wire [7:0]  ci_awaddr;  wire ci_awvalid, ci_awready;
    wire [31:0] ci_wdata;   wire [3:0] ci_wstrb; wire ci_wvalid, ci_wready;
    wire [1:0]  ci_bresp;   wire ci_bvalid, ci_bready;
    wire [7:0]  ci_araddr;  wire ci_arvalid, ci_arready;
    wire [31:0] ci_rdata;   wire [1:0] ci_rresp; wire ci_rvalid, ci_rready;
    wire mac_init_done;
    mac_csr_init #(.MAC_ADDR(OUR_MAC), .CTRL_VAL(9'h02B)) u_mac_init (
        .clk(clk), .rst_n(eth_rst_n),
        .m_axi_awaddr(ci_awaddr), .m_axi_awvalid(ci_awvalid), .m_axi_awready(ci_awready),
        .m_axi_wdata(ci_wdata), .m_axi_wstrb(ci_wstrb), .m_axi_wvalid(ci_wvalid),
        .m_axi_wready(ci_wready), .m_axi_bresp(ci_bresp), .m_axi_bvalid(ci_bvalid),
        .m_axi_bready(ci_bready), .m_axi_araddr(ci_araddr), .m_axi_arvalid(ci_arvalid),
        .m_axi_arready(ci_arready), .m_axi_rdata(ci_rdata), .m_axi_rresp(ci_rresp),
        .m_axi_rvalid(ci_rvalid), .m_axi_rready(ci_rready), .init_done(mac_init_done)
    );

    wire [7:0] mac_rx_tdata;  wire mac_rx_tvalid, mac_rx_tlast, mac_rx_terror, mac_rx_tsof;
    wire [7:0] mac_tx_tdata;  wire mac_tx_tvalid, mac_tx_tready, mac_tx_tlast;
    wire       mdio_o, mdio_oe, mdio_i, mac_irq;

    eth_mac_sys #(.PHY_INTERFACE("MII"), .MAX_FRAME(1518)) u_mac (
        .clk(clk), .rst_n(eth_rst_n),
        .s_axi_awaddr(ci_awaddr), .s_axi_awvalid(ci_awvalid), .s_axi_awready(ci_awready),
        .s_axi_wdata(ci_wdata), .s_axi_wstrb(ci_wstrb), .s_axi_wvalid(ci_wvalid),
        .s_axi_wready(ci_wready), .s_axi_bresp(ci_bresp), .s_axi_bvalid(ci_bvalid),
        .s_axi_bready(ci_bready), .s_axi_araddr(ci_araddr), .s_axi_arvalid(ci_arvalid),
        .s_axi_arready(ci_arready), .s_axi_rdata(ci_rdata), .s_axi_rresp(ci_rresp),
        .s_axi_rvalid(ci_rvalid), .s_axi_rready(ci_rready),
        .s_axis_tdata(mac_tx_tdata), .s_axis_tvalid(mac_tx_tvalid),
        .s_axis_tready(mac_tx_tready), .s_axis_tlast(mac_tx_tlast),
        .m_axis_tdata(mac_rx_tdata), .m_axis_tvalid(mac_rx_tvalid), .m_axis_tready(1'b1),
        .m_axis_tlast(mac_rx_tlast), .m_axis_terror(mac_rx_terror), .m_axis_tsof(mac_rx_tsof),
        .mii_txd(ETH_TXD), .mii_tx_en(ETH_TX_EN), .mii_tx_clk(ETH_TX_CLK),
        .mii_rxd(ETH_RXD), .mii_rx_dv(ETH_RX_DV), .mii_rx_er(ETH_RXERR),
        .mii_rx_clk(ETH_RX_CLK), .mii_col(ETH_COL), .mii_crs(ETH_CRS),
        .clk_125(1'b0), .clk_125_90(1'b0), .clk_25(1'b0), .clk_2_5(1'b0),
        .rgmii_txd(), .rgmii_tx_ctl(), .rgmii_txc(),
        .rgmii_rxd(4'd0), .rgmii_rx_ctl(1'b0), .rgmii_rxc(1'b0),
        .mdc(ETH_MDC), .mdio_i(mdio_i), .mdio_o(mdio_o), .mdio_oe(mdio_oe),
        .irq(mac_irq)
    );
    assign ETH_MDIO = mdio_oe ? mdio_o : 1'bz;
    assign mdio_i   = ETH_MDIO;

    // -- net_rx --
    wire [7:0]  ud_data;  wire ud_valid, ud_last;
    wire [31:0] ud_src_ip;
    wire [15:0] ud_src_port, ud_dst_port, ud_length;
    wire [47:0] rx_src_mac;
    net_rx u_net_rx (
        .clk(clk), .rst_n(eth_rst_n),
        .s_axis_tdata(mac_rx_tdata), .s_axis_tvalid(mac_rx_tvalid),
        .s_axis_tlast(mac_rx_tlast), .s_axis_tsof(mac_rx_tsof), .s_axis_terror(mac_rx_terror),
        .arp_data(), .arp_valid(), .arp_last(),
        .icmp_data(), .icmp_valid(), .icmp_last(), .icmp_src_ip(),
        .udp_data(ud_data), .udp_valid(ud_valid), .udp_last(ud_last),
        .udp_src_ip(ud_src_ip), .udp_src_port(ud_src_port),
        .udp_dst_port(ud_dst_port), .udp_length(ud_length),
        .rx_src_mac(rx_src_mac), .our_ip(OUR_IP)
    );

    // -- ARP responder --
    wire [7:0] arp_tx_tdata;  wire arp_tx_tvalid, arp_tx_tready, arp_tx_tlast, arp_reply_sent;
    arp_responder u_arp (
        .clk(clk), .rst_n(eth_rst_n), .enable(1'b1),
        .rx_tdata(mac_rx_tdata), .rx_tvalid(mac_rx_tvalid), .rx_tlast(mac_rx_tlast),
        .rx_terror(mac_rx_terror), .rx_tsof(mac_rx_tsof),
        .tx_tdata(arp_tx_tdata), .tx_tvalid(arp_tx_tvalid),
        .tx_tready(arp_tx_tready), .tx_tlast(arp_tx_tlast),
        .our_mac(OUR_MAC), .our_ip(OUR_IP), .arp_reply_sent(arp_reply_sent)
    );

    // -- trigger: captures host MAC/IP, pulses trg_start; we use it to set the
    //    destination + enable the autonomous loop (busy tied 0 = always update) --
    wire        trg_start;
    wire [47:0] trg_dst_mac;
    wire [31:0] trg_dst_ip;
    wire [15:0] trg_dst_port, trg_src_port;
    jpeg_rtp_trigger #(
        .TRIGGER_PORT(TRIGGER_PORT), .RTP_DST_PORT(RTP_PORT), .RTP_SRC_PORT(RTP_PORT)
    ) u_trig (
        .clk(clk), .rst_n(eth_rst_n),
        .udp_valid(ud_valid), .udp_last(ud_last), .udp_dst_port(ud_dst_port),
        .udp_rx_src_mac(rx_src_mac), .udp_rx_src_ip(ud_src_ip),
        .busy(1'b0),
        .start(trg_start), .dst_mac(trg_dst_mac), .dst_ip(trg_dst_ip),
        .dst_port(trg_dst_port), .src_port(trg_src_port)
    );

    // -- host control plane: capture the first UDP payload byte of a TRIGGER_PORT
    //    packet as an opcode, committed at end-of-packet (the same instant u_trig
    //    latches the destination). The destination still latches on every trigger
    //    packet regardless of opcode (u_trig.busy is tied 0). --
    //    VTPG_CTRL_PORT packets carry a KV260-style register write: payload byte 0
    //    is the register offset, bytes 1..4 the 32-bit value (big-endian). The host
    //    (stream_view.py) owns all vtpg state and emits these writes per keystroke.
    reg        ud_in_pkt;
    reg [7:0]  trg_opcode;       // payload byte 0: trigger opcode / vtpg reg offset
    reg [31:0] vc_val;           // VTPG_CTRL_PORT value (bytes 1..4, big-endian)
    reg [2:0]  vc_idx;           // payload byte index (saturating)
    reg        trg_op_valid;     // TRIGGER_PORT: stream control (start/stop/single)
    reg        vtpg_op_valid;    // VTPG_CTRL_PORT: register-write commit
    always @(posedge clk) begin
        if (!eth_rst_n) begin
            ud_in_pkt <= 1'b0; trg_op_valid <= 1'b0; vtpg_op_valid <= 1'b0;
            trg_opcode <= 8'd0; vc_val <= 32'd0; vc_idx <= 3'd0;
        end else begin
            trg_op_valid  <= 1'b0;
            vtpg_op_valid <= 1'b0;
            if (ud_valid) begin
                if (!ud_in_pkt) begin
                    ud_in_pkt  <= 1'b1;
                    trg_opcode <= ud_data;        // byte 0 = opcode / register offset
                    vc_val     <= 32'd0;
                    vc_idx     <= 3'd1;
                end else begin
                    if (vc_idx <= 3'd4) vc_val <= {vc_val[23:0], ud_data};  // bytes 1..4 (BE)
                    if (vc_idx != 3'd7) vc_idx <= vc_idx + 3'd1;
                end
                if (ud_last) begin
                    ud_in_pkt <= 1'b0;
                    if (ud_dst_port == TRIGGER_PORT)   trg_op_valid  <= 1'b1;
                    if (ud_dst_port == VTPG_CTRL_PORT) vtpg_op_valid <= 1'b1;
                end
            end
        end
    end
    reg loop_en;       // continuous-stream enable (set by 'G'/default, cleared by 'S')
    reg single_pend;   // one-shot: stream exactly one frame ('1')

    // -- RTP/JPEG packetizer (started by the control FSM) --
    reg         rtp_start;
    wire [7:0]  rtp_tx_tdata;  wire rtp_tx_tvalid, rtp_tx_tready, rtp_tx_tlast;
    wire        rtp_busy, rtp_done;
    jpeg_rtp_tx #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .SCAN_OFF(623), .EOI_BYTES(2),
        .QT_LUMA_OFF(25), .QT_CHROMA_OFF(94), .SCAN_CHUNK(11'd1024)
    ) u_rtp (
        .clk(clk), .rst_n(eth_rst_n),
        .our_mac(OUR_MAC), .our_ip(OUR_IP), .src_port(trg_src_port),
        .dst_mac(trg_dst_mac), .dst_ip(trg_dst_ip), .dst_port(trg_dst_port),
        .ssrc(32'h0A0B0C0D), .rtp_timestamp({frame_cnt[19:0], 12'd0}),  // distinct per frame so ffmpeg separates frames
        .start(rtp_start), .jpeg_size(jpeg_byte_cnt),
        .busy(rtp_busy), .done_pulse(rtp_done),
        .mem_raddr(rtp_mem_raddr), .mem_rdata(rtp_mem_rdata),
        .tx_data(rtp_tx_tdata), .tx_valid(rtp_tx_tvalid),
        .tx_last(rtp_tx_tlast), .tx_ready(rtp_tx_tready)
    );

    // -- per-frame store-and-forward (gap-free for the cut-through MAC) --
    wire [7:0] rtpfb_tdata; wire rtpfb_tvalid, rtpfb_tlast, rtpfb_tready;
    axis_frame_buffer #(.AW(11)) u_fb (
        .clk(clk), .rst_n(eth_rst_n),
        .s_tdata(rtp_tx_tdata), .s_tvalid(rtp_tx_tvalid),
        .s_tlast(rtp_tx_tlast), .s_tready(rtp_tx_tready),
        .m_tdata(rtpfb_tdata), .m_tvalid(rtpfb_tvalid),
        .m_tlast(rtpfb_tlast), .m_tready(rtpfb_tready)
    );

    arty_tx_arbiter u_arb (
        .clk(clk), .rst_n(eth_rst_n), .arp_tx_active(1'b0),
        .seq_tdata(8'd0),  .seq_tvalid(1'b0),  .seq_tready(),  .seq_tlast(1'b0),
        .arp_tdata(arp_tx_tdata), .arp_tvalid(arp_tx_tvalid),
        .arp_tready(arp_tx_tready), .arp_tlast(arp_tx_tlast),
        .icmp_tdata(8'd0), .icmp_tvalid(1'b0), .icmp_tready(), .icmp_tlast(1'b0),
        .stats_tdata(8'd0),.stats_tvalid(1'b0),.stats_tready(),.stats_tlast(1'b0),
        .udp_tdata(rtpfb_tdata), .udp_tvalid(rtpfb_tvalid),
        .udp_tready(rtpfb_tready), .udp_tlast(rtpfb_tlast),
        .blast_tdata(8'd0),.blast_tvalid(1'b0),.blast_tready(),.blast_tlast(1'b0),
        .m_axis_tdata(mac_tx_tdata), .m_axis_tvalid(mac_tx_tvalid),
        .m_axis_tready(mac_tx_tready), .m_axis_tlast(mac_tx_tlast)
    );

    // =======================================================================
    // Autonomous control FSM: kick a frame -> encode -> stream -> repeat
    // =======================================================================
    localparam [3:0] V_IDLE=4'd0, V_QWRITE=4'd1, V_QWAIT=4'd2,
                     V_KICK=4'd3, V_KWAIT=4'd4, V_ENC=4'd5,
                     V_STREAM=4'd6, V_WAIT=4'd7;
    // Host control opcodes (first UDP payload byte of a TRIGGER_PORT packet):
    //   'G' (0x47) or anything else -> start continuous (back-compat: "GO" streams)
    //   'S'/'s'    or 0x00          -> stop after the current frame finishes
    //   '1'        or 0x02          -> stream exactly one frame
    localparam [7:0] OP_STOP_0=8'h00, OP_STOP_S=8'h53, OP_STOP_s=8'h73,
                     OP_ONE_0 =8'h02, OP_ONE_1 =8'h31;
    reg [3:0]  vstate;
    reg [31:0] frame_cnt;
    reg [6:0]  rc_quality;
    reg [2:0]  rc_good_frames;
    reg [9:0]  rc_qwait_cnt;
    reg [15:0] rc_dropped_frames;
    always @(posedge clk) begin
        if (!rst_n || sw_reset) begin
            vstate<=V_IDLE; frame_kick<=1'b0; cap_reset<=1'b0; rtp_start<=1'b0;
            enc_quality_req<=1'b0; enc_quality_value<=RC_Q_INIT;
            rc_quality<=RC_Q_INIT; rc_good_frames<=3'd0; rc_qwait_cnt<=10'd0;
            rc_dropped_frames<=16'd0;
            frame_cnt<=32'd0; loop_en<=1'b0; single_pend<=1'b0;
            cfg_pattern_r<=4'd0; box_w_r<=16'd96; box_h_r<=16'd64;       // KV260 app inits
            box_dx_r<=16'd4; box_dy_r<=16'd3;
            box_color_r<=24'hEB_80_80; solid_color_r<=24'hEB_80_80;      // white (palette[6])
            grid_spacing_r<=16'd32; checker_size_r<=16'd32;
            box_img_x_step_r<=32'd21845; box_img_y_step_r<=32'd32768;    // (32<<16)/96, /64
        end else begin
            frame_kick<=1'b0; cap_reset<=1'b0; rtp_start<=1'b0;
            enc_quality_req<=1'b0;

            // -- host control plane: opcode carried in the trigger packet --
            if (trg_op_valid) begin
                case (trg_opcode)
                    OP_STOP_0, OP_STOP_S, OP_STOP_s: begin loop_en<=1'b0; single_pend<=1'b0; end
                    OP_ONE_0,  OP_ONE_1:             single_pend <= 1'b1;   // arm one frame
                    default:                         loop_en     <= 1'b1;   // start continuous
                endcase
            end

            // -- vtpg cfg register write (VTPG_CTRL_PORT, KV260 register map) --
            if (vtpg_op_valid) begin
                case (trg_opcode)                                   // byte 0 = reg offset
                    8'h18: cfg_pattern_r    <= vc_val[3:0];         // PATTERN_SEL
                    8'h20: solid_color_r    <= vc_val[23:0];        // SOLID_COLOR
                    8'h24: box_color_r      <= vc_val[23:0];        // BOX_COLOR
                    8'h28: begin box_w_r  <= vc_val[31:16]; box_h_r  <= vc_val[15:0]; end  // BOX_SIZE
                    8'h2C: begin box_dx_r <= vc_val[31:16]; box_dy_r <= vc_val[15:0]; end  // BOX_SPEED
                    8'h34: grid_spacing_r   <= vc_val[15:0];        // GRID_SPACING
                    8'h3C: checker_size_r   <= vc_val[15:0];        // CHECKER_SIZE
                    8'h54: box_img_x_step_r <= vc_val;              // BOX_IMG_X_STEP
                    8'h58: box_img_y_step_r <= vc_val;              // BOX_IMG_Y_STEP
                    default: ;
                endcase
            end

            case (vstate)
                V_IDLE:   if ((loop_en || single_pend) && init_done) begin
                              single_pend <= 1'b0;        // consume the one-shot arm
                              vstate      <= V_QWRITE;
                          end
                V_QWRITE: begin
                    enc_quality_value <= rc_quality;
                    if (enc_quality_done) begin
                        rc_qwait_cnt <= 10'd0;
                        vstate       <= V_QWAIT;
                    end else if (!enc_quality_busy) begin
                        enc_quality_req <= 1'b1;
                    end
                end
                V_QWAIT: begin
                    if (rc_qwait_cnt == RC_Q_SETTLE_CYCLES) begin
                        vstate <= V_KICK;
                    end else begin
                        rc_qwait_cnt <= rc_qwait_cnt + 10'd1;
                    end
                end
                V_KICK: begin
                    cap_reset  <= 1'b1;   // clear capture for the new frame
                    frame_kick <= 1'b1;   // emit one VTPG frame
                    vstate     <= V_KWAIT;
                end
                // One cycle for cap_reset to clear the previous frame's sticky
                // cap_done before V_ENC samples it. Without this, V_ENC sees the
                // stale cap_done=1 and exits immediately -> blank/duplicate frame
                // and a desynced capture->buffer->RTP stream (garbage QT + scan).
                V_KWAIT:  vstate <= V_ENC;
                V_ENC: begin
                    if (cap_done) begin
                        if (jpeg_overflow) begin
                            rc_quality       <= rc_quality_sub(rc_quality, RC_Q_OVF_STEP);
                            rc_good_frames   <= 3'd0;
                            rc_dropped_frames<= rc_dropped_frames + 16'd1;
                            vstate           <= loop_en ? V_QWRITE : V_IDLE;
                        end else begin
                            if (jpeg_byte_cnt > RC_HIGH_BYTES) begin
                                rc_quality     <= rc_quality_sub(rc_quality, RC_Q_NEAR_STEP);
                                rc_good_frames <= 3'd0;
                            end else if (jpeg_byte_cnt < RC_LOW_BYTES) begin
                                if (rc_good_frames == (RC_GOOD_FRAMES - 3'd1)) begin
                                    rc_quality     <= rc_quality_inc(rc_quality);
                                    rc_good_frames <= 3'd0;
                                end else begin
                                    rc_good_frames <= rc_good_frames + 3'd1;
                                end
                            end else begin
                                rc_good_frames <= 3'd0;
                            end
                            vstate <= V_STREAM;
                        end
                    end
                end
                V_STREAM: begin rtp_start<=1'b1;            // hold start until tx accepts
                              if (rtp_busy) vstate<=V_WAIT; end
                V_WAIT:   if (rtp_done) begin
                              frame_cnt <= frame_cnt + 32'd1;
                              vstate    <= loop_en ? V_QWRITE : V_IDLE;
                          end
                default:  vstate<=V_IDLE;
            endcase
        end
    end

    // =======================================================================
    // Debug sticky flags (for JTAG status), all single-domain
    // =======================================================================
    reg dbg_udp, dbg_trg, dbg_mactx, dbg_arp, dbg_macbp;
    reg [15:0] mactx_frames;     // packets the MAC accepted (arbiter out)
    reg [15:0] rtp_pkts;         // packets jpeg_rtp_tx produced
    reg [15:0] fb_pkts;          // packets the frame buffer emitted
    always @(posedge clk) begin
        if (!eth_rst_n || sw_reset) begin
            dbg_udp<=0; dbg_trg<=0; dbg_mactx<=0; dbg_arp<=0; dbg_macbp<=0;
            mactx_frames<=0; rtp_pkts<=0; fb_pkts<=0;
        end else begin
            if (ud_valid && ud_last) dbg_udp<=1'b1;
            if (trg_start)           dbg_trg<=1'b1;
            if (mac_tx_tvalid)       dbg_mactx<=1'b1;
            if (arp_reply_sent)      dbg_arp<=1'b1;
            if (mac_tx_tvalid && !mac_tx_tready) dbg_macbp<=1'b1;
            if (mac_tx_tvalid && mac_tx_tready && mac_tx_tlast) mactx_frames<=mactx_frames+16'd1;
            if (rtp_tx_tvalid && rtp_tx_tready && rtp_tx_tlast) rtp_pkts<=rtp_pkts+16'd1;
            if (rtpfb_tvalid && rtpfb_tready && rtpfb_tlast)    fb_pkts<=fb_pkts+16'd1;
        end
    end

    // =======================================================================
    // Debug probe: capture raw VTPG output {C,Y} at the 8 colorbar centers on
    // line 0 (x = 80,240,...,1200). Read via JTAG words 9..12 to compare the
    // silicon's emitted pixels against the known palette (sim-vs-synth wash).
    // =======================================================================
    reg [10:0] dbg_vx;
    reg        dbg_vl0;
    reg [15:0] dbg_cy0, dbg_cy1, dbg_cy2, dbg_cy3, dbg_cy4, dbg_cy5, dbg_cy6, dbg_cy7;
    wire [10:0] dbg_curx = vid_tuser ? 11'd0 : dbg_vx;
    always @(posedge clk) begin
        if (!eth_rst_n || sw_reset) begin
            dbg_vx<=11'd0; dbg_vl0<=1'b0;
            dbg_cy0<=16'd0; dbg_cy1<=16'd0; dbg_cy2<=16'd0; dbg_cy3<=16'd0;
            dbg_cy4<=16'd0; dbg_cy5<=16'd0; dbg_cy6<=16'd0; dbg_cy7<=16'd0;
        end else if (vid_tvalid && vid_tready) begin
            if (vid_tuser) dbg_vl0 <= 1'b1;
            dbg_vx <= dbg_curx + 11'd1;
            if (vid_tuser || dbg_vl0) begin
                case (dbg_curx)
                    11'd80:   dbg_cy0 <= vid_tdata;
                    11'd240:  dbg_cy1 <= vid_tdata;
                    11'd400:  dbg_cy2 <= vid_tdata;
                    11'd560:  dbg_cy3 <= vid_tdata;
                    11'd720:  dbg_cy4 <= vid_tdata;
                    11'd880:  dbg_cy5 <= vid_tdata;
                    11'd1040: dbg_cy6 <= vid_tdata;
                    11'd1200: dbg_cy7 <= vid_tdata;
                    default: ;
                endcase
            end
            if (vid_tlast) dbg_vl0 <= 1'b0;
        end
    end

    // =======================================================================
    // Debug probe: DCT and quantizer DC extremes (hierarchical refs into u_enc).
    // Tracks most-negative (black block) and most-positive (white block) DC at
    // the DCT output and the quantizer output, over the whole frame. Read via
    // JTAG words 13/14. If DCT |min| ~= max (symmetric) but quant is asymmetric
    // -> quantizer sign bug; if DCT min is already washed/small -> DCT signed-
    // multiply bug.
    // =======================================================================
    reg signed [15:0] dct_dc_min, dct_dc_max, q_dc_min, q_dc_max;
    always @(posedge clk) begin
        if (!eth_rst_n || sw_reset) begin
            dct_dc_min<=16'sd0; dct_dc_max<=16'sd0; q_dc_min<=16'sd0; q_dc_max<=16'sd0;
        end else begin
            if (u_enc.dct_out_valid && u_enc.dct_out_sof) begin
                if ($signed(u_enc.dct_out_data) < dct_dc_min) dct_dc_min <= u_enc.dct_out_data;
                if ($signed(u_enc.dct_out_data) > dct_dc_max) dct_dc_max <= u_enc.dct_out_data;
            end
            if (u_enc.quant_out_valid && u_enc.quant_out_sob) begin
                if ($signed(u_enc.quant_out_data) < q_dc_min) q_dc_min <= u_enc.quant_out_data;
                if ($signed(u_enc.quant_out_data) > q_dc_max) q_dc_max <= u_enc.quant_out_data;
            end
        end
    end

    // =======================================================================
    // Debug probe: LUMA-ONLY quant DC extremes (split Y vs chroma by MCU block
    // position Y0,Y1,Cb,Cr). The frame-wide min/max masked the black bar's luma
    // because saturated chroma hits the same +-128 extremes. q_luma_min is the
    // black bar's luma DC: -128 => encoder luma correct on silicon; washed => not.
    // Read via JTAG word 15.
    // =======================================================================
    reg [1:0]  q_blk;
    reg signed [15:0] q_luma_min, q_luma_max;
    always @(posedge clk) begin
        if (!eth_rst_n || sw_reset) begin
            q_blk<=2'd0; q_luma_min<=16'sd0; q_luma_max<=16'sd0;
        end else if (u_enc.quant_out_valid && u_enc.quant_out_sob) begin
            if (q_blk < 2'd2) begin   // Y0/Y1 luma blocks
                if ($signed(u_enc.quant_out_data) < q_luma_min) q_luma_min <= u_enc.quant_out_data;
                if ($signed(u_enc.quant_out_data) > q_luma_max) q_luma_max <= u_enc.quant_out_data;
            end
            q_blk <= (q_blk==2'd3) ? 2'd0 : q_blk + 2'd1;
        end
    end

    // =======================================================================
    // ENCODER-OUTPUT CAPTURE: record the raw jpg_tdata bytes of one frame (from
    // frame start) into a dedicated BRAM, read via JTAG at 0x0200_4000+ through a
    // SEPARATE path that bypasses jp_phase / demo_jpeg_buffer / jpeg_rtp_tx.
    // Decode offline: washed => the ENCODER output is bad; correct => the
    // capture/buffer/RTP path is bad. Direct measurement, no inference.
    // Arm on the first frame after sw_reset; capture 4096 bytes; hold.
    // =======================================================================
    (* ram_style = "block" *) reg [7:0] jcap_mem [0:4095];
    reg [11:0] jcap_wp;
    reg        jcap_arm, jcap_done;
    always @(posedge clk) begin
        if (!eth_rst_n || sw_reset) begin
            jcap_wp <= 12'd0; jcap_arm <= 1'b0; jcap_done <= 1'b0;
        end else begin
            if (cap_reset && !jcap_done && !jcap_arm && frame_cnt >= 32'd2) jcap_arm <= 1'b1;
            else if (jcap_arm && !jcap_done && jpg_tvalid) begin
                jcap_mem[jcap_wp] <= jpg_tdata;
                if (jcap_wp == 12'd4095) jcap_done <= 1'b1;
                else                     jcap_wp   <= jcap_wp + 12'd1;
            end
        end
    end
    reg [7:0] jcap_rd;
    always @(posedge clk) jcap_rd <= jcap_mem[ar_addr[13:2]];

    // =======================================================================
    // fcapz EJTAG-AXI on USER4: read-only debug status + soft-reset write
    // =======================================================================
    wire [31:0] m_awaddr;  wire [7:0] m_awlen;  wire [2:0] m_awsize;
    wire [1:0]  m_awburst; wire [2:0] m_awprot; wire m_awvalid; reg m_awready;
    wire [31:0] m_wdata;   wire [3:0] m_wstrb;  wire m_wlast; wire m_wvalid; wire m_wready;
    reg  [1:0]  m_bresp;   reg m_bvalid; wire m_bready;
    wire [31:0] m_araddr;  wire [7:0] m_arlen;  wire [2:0] m_arsize;
    wire [1:0]  m_arburst; wire [2:0] m_arprot; wire m_arvalid; reg m_arready;
    reg  [31:0] m_rdata;   reg [1:0] m_rresp; reg m_rlast; reg m_rvalid; wire m_rready;

    fcapz_ejtagaxi_xilinx7 #(
        .ADDR_W(32), .DATA_W(32), .FIFO_DEPTH(256), .TIMEOUT(4096), .CHAIN(4)
    ) u_jtag (
        .axi_clk(clk), .axi_rst(~rst_n),
        .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen), .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awprot(m_awprot), .m_axi_awvalid(m_awvalid),
        .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen), .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arprot(m_arprot), .m_axi_arvalid(m_arvalid),
        .m_axi_arready(m_arready),
        .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready),
        .debug_tck(), .debug_tck_edge(), .debug_axi(), .debug_axi_edge()
    );

    // AW: only DEMO_CTRL (0x0200_0000) write; bit1 = soft reset (1-cycle)
    localparam [1:0] AW_IDLE=2'd0, AW_DATA=2'd1, AW_RESP=2'd2;
    reg [1:0] aw_state; reg aw_ctrl;
    assign m_wready = (aw_state == AW_DATA);
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_state<=AW_IDLE; m_awready<=1'b0; m_bvalid<=1'b0; m_bresp<=2'b00;
            aw_ctrl<=1'b0; sw_reset<=1'b0;
        end else begin
            m_awready<=1'b0; sw_reset<=1'b0;
            case (aw_state)
                AW_IDLE: if (m_awvalid) begin
                    m_awready<=1'b1; aw_ctrl<=m_awaddr[25] && !m_awaddr[24]; aw_state<=AW_DATA;
                end
                AW_DATA: if (m_wvalid && m_wready) begin
                    if (aw_ctrl && m_wdata[1]) sw_reset<=1'b1;   // soft reset pulse
                    if (m_wlast) aw_state<=AW_RESP;
                end
                AW_RESP: begin
                    m_bresp<=2'b00;
                    if (!m_bvalid) m_bvalid<=1'b1;
                    else if (m_bready) begin m_bvalid<=1'b0; aw_state<=AW_IDLE; end
                end
                default: aw_state<=AW_IDLE;
            endcase
        end
    end

    // AR: read-only debug status (ctrl region 0x0200_00xx). word index ar_addr[4:2].
    wire [12:0] dbg_word = {rtp_busy, dbg_macbp, dbg_arp, dbg_mactx, dbg_trg, dbg_udp,
                            jpeg_overflow, loop_en, cap_done, vstate};
    localparam [2:0] AR_IDLE=3'd0, AR_PRE=3'd1, AR_DATA=3'd2;
    reg [2:0] ar_state; reg [31:0] ar_addr; reg [7:0] ar_rem; reg ar_bad;
    always @(posedge clk) begin
        if (!rst_n) begin
            ar_state<=AR_IDLE; m_arready<=1'b0; m_rvalid<=1'b0; m_rlast<=1'b0;
            m_rresp<=2'b00; m_rdata<=32'd0; ar_addr<=32'd0; ar_rem<=8'd0; ar_bad<=1'b0;
        end else begin
            m_arready<=1'b0;
            case (ar_state)
                AR_IDLE: begin
                    m_rvalid<=1'b0;
                    if (m_arvalid) begin
                        m_arready<=1'b1; ar_addr<=m_araddr; ar_rem<=m_arlen;
                        ar_bad<=!(m_araddr[25] && !m_araddr[24]);  // only ctrl region
                        ar_state<=AR_PRE;
                    end
                end
                AR_PRE: ar_state<=AR_DATA;
                AR_DATA: begin
                    if (ar_addr[14]) m_rdata <= {24'd0, jcap_rd}; // encoder-output capture (0x0200_4000+)
                    else
                    case (ar_addr[5:2])
                        4'd0: m_rdata<={4'd0, rc_quality, rc_dropped_frames[7:0], dbg_word}; // status
                        4'd1: m_rdata<={13'd0, jpeg_byte_cnt};    // current frame size
                        4'd2: m_rdata<=frame_cnt;                 // frames streamed
                        4'd3: m_rdata<=trg_dst_ip;
                        4'd4: m_rdata<=trg_dst_mac[31:0];
                        4'd5: m_rdata<={16'd0, trg_dst_mac[47:32]};
                        4'd6: m_rdata<={16'd0, trg_dst_port};
                        4'd7: m_rdata<={16'd0, mactx_frames};
                        4'd8: m_rdata<={rtp_pkts, fb_pkts};       // jpeg_rtp_tx / frame-buf pkts
                        4'd9:  m_rdata<={dbg_cy1, dbg_cy0};       // VTPG {C,Y} bars 0,1
                        4'd10: m_rdata<={dbg_cy3, dbg_cy2};       // bars 2,3
                        4'd11: m_rdata<={dbg_cy5, dbg_cy4};       // bars 4,5
                        4'd12: m_rdata<={dbg_cy7, dbg_cy6};       // bars 6,7
                        4'd13: m_rdata<={dct_dc_max, dct_dc_min}; // DCT DC extremes
                        4'd14: m_rdata<={q_dc_max,   q_dc_min};   // quant DC extremes
                        4'd15: m_rdata<={q_luma_max, q_luma_min}; // LUMA-only quant DC extremes
                        default: m_rdata<=32'd0;
                    endcase
                    m_rvalid<=1'b1; m_rlast<=(ar_rem==8'd0); m_rresp<=ar_bad?2'b10:2'b00;
                    if (m_rvalid && m_rready) begin
                        if (ar_rem==8'd0) begin m_rvalid<=1'b0; m_rlast<=1'b0; ar_state<=AR_IDLE; end
                        else begin ar_addr<=ar_addr+32'd4; ar_rem<=ar_rem-8'd1;
                                   m_rvalid<=1'b0; ar_state<=AR_PRE; end
                    end
                end
                default: ar_state<=AR_IDLE;
            endcase
        end
    end

    // =======================================================================
    // LEDs
    // =======================================================================
    reg [25:0] hb_cnt; reg hb_toggle;
    always @(posedge clk) begin
        if (hb_cnt==26'd49_999_999) begin hb_cnt<=26'd0; hb_toggle<=~hb_toggle; end
        else hb_cnt<=hb_cnt+26'd1;
    end
    reg [22:0] eth_act_cnt; reg eth_act;
    always @(posedge clk) begin
        if (mac_tx_tvalid && mac_tx_tready) begin eth_act<=1'b1; eth_act_cnt<=23'h7FFFFF; end
        else if (eth_act_cnt!=23'd0) eth_act_cnt<=eth_act_cnt-23'd1; else eth_act<=1'b0;
    end
    assign led0 = hb_toggle;
    assign led1 = loop_en;
    assign led2 = frame_cnt[3];   // toggles as frames stream
    assign led3 = eth_act;

endmodule
