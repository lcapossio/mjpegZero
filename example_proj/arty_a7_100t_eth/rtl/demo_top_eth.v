// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// demo_top_eth.v - Arty A7-100T mjpegZero demo with Ethernet RTP/JPEG egress.
//
// Egress-only extension of demo_top.v: the fcapz EJTAG-AXI path is kept for
// pixel upload + control/status + JTAG JPEG read-back (150 MHz domain). The
// encoded JPEG is additionally streamed to a host as RTP/JPEG (RFC 2435) over
// UDP via the emacZero MAC (100 MHz domain). A host UDP "trigger" packet tells
// the FPGA where to send; fabric streams the JPEG currently in the buffer.
//
//   150 MHz: clk_gen_eth -> fcapz EJTAG-AXI -> encoder -> JPEG buffer (port A)
//   100 MHz: eth_mac_sys (MII) <-> net_rx -> jpeg_rtp_trigger -> jpeg_rtp_tx
//            (reads JPEG buffer port B) -> arty_tx_arbiter -> MAC TX
//   The JPEG buffer is dual-clock TDP; enc_done + jpeg_byte_cnt cross 150->100.
//
// AXI4 map (JTAG side) is identical to demo_top.v. Verilog 2001.

`timescale 1ns / 1ps

module demo_top_eth #(
    parameter JPEG_WORDS = 65536,        // 256 KB (64 RAMB36) - fits A7-100T
    parameter [47:0] OUR_MAC = 48'h02_00_00_00_00_01,
    parameter [31:0] OUR_IP  = 32'hC0_A8_ED_32,   // 192.168.237.50
    parameter [15:0] TRIGGER_PORT = 16'd9999,
    parameter [15:0] RTP_PORT     = 16'd5004
) (
    input  wire CLK100MHZ,
    output wire led0,        // heartbeat
    output wire led1,        // pixels streaming / encoding active
    output wire led2,        // encode done (latched)
    output wire led3,        // ethernet TX activity

    // ---- Ethernet MII (Arty A7 onboard DP83848) ----
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
    localparam FRAME_PXLS = IMG_W * IMG_H;
    localparam JPEG_BYTES = JPEG_WORDS * 4;
    localparam PIX_PREFILL = 32;
    localparam AXI_JPEG_BASE = 32'h0300_0000;
    localparam AXI_CTRL_BASE = 32'h0200_0000;

    // =======================================================================
    // Clocks & resets
    // =======================================================================
    wire clk, clk100, clk25, locked;

    clk_gen_eth u_clkgen (
        .clk_in (CLK100MHZ),
        .reset  (1'b0),
        .clk_150(clk),
        .clk_100(clk100),
        .clk_25 (clk25),
        .locked (locked)
    );

    // 150 MHz domain reset
    reg [3:0] rst_sr;
    wire rst_n = rst_sr[3];
    always @(posedge clk)
        if (!locked) rst_sr <= 4'b0000;
        else         rst_sr <= {rst_sr[2:0], 1'b1};

    // 100 MHz domain reset + PHY reset sequencing
    reg [3:0] rst100_sr;
    wire rst_n_100 = rst100_sr[3];
    always @(posedge clk100)
        if (!locked) rst100_sr <= 4'b0000;
        else         rst100_sr <= {rst100_sr[2:0], 1'b1};

    localparam PHY_RST_CYCLES = 25'd20_000_000;   // 200 ms at 100 MHz
    reg [24:0] phy_rst_cnt;
    reg        phy_rst_done;
    always @(posedge clk100) begin
        if (!locked) begin
            phy_rst_cnt  <= 25'd0;
            phy_rst_done <= 1'b0;
        end else if (phy_rst_cnt < PHY_RST_CYCLES) begin
            phy_rst_cnt <= phy_rst_cnt + 25'd1;
        end else begin
            phy_rst_done <= 1'b1;
        end
    end
    assign ETH_RSTN = phy_rst_done;
    wire eth_rst_n = rst_n_100 & phy_rst_done;

    // PHY 25 MHz reference clock out
    ddr_output u_ref_clk (.clk(clk25), .d1(1'b1), .d2(1'b0), .q(ETH_REF_CLK));

    // =======================================================================
    // Pixel FIFO (64 x 32-bit), distributed RAM, async read  (150 MHz)
    // =======================================================================
    (* ram_style = "distributed" *) reg [31:0] pix_fifo [0:63];
    reg [5:0]  pix_wr_ptr, pix_rd_ptr;
    reg [6:0]  pix_count;
    wire pix_full  = (pix_count == 7'd64);
    wire pix_empty = (pix_count == 7'd0);
    wire [31:0] pix_fifo_out = pix_fifo[pix_rd_ptr];

    // =======================================================================
    // Encoder AXI4-Lite init
    // =======================================================================
    wire [4:0]  ei_awaddr;  wire ei_awvalid, ei_awready;
    wire [31:0] ei_wdata;   wire [3:0] ei_wstrb; wire ei_wvalid, ei_wready;
    wire [1:0]  ei_bresp;   wire ei_bvalid, ei_bready;
    wire [4:0]  ei_araddr;  wire ei_arvalid, ei_arready;
    wire [31:0] ei_rdata;   wire [1:0] ei_rresp; wire ei_rvalid, ei_rready;
    wire init_done;

    axi_init u_init (
        .clk(clk), .rst_n(rst_n),
        .m_axi_awaddr (ei_awaddr),  .m_axi_awvalid(ei_awvalid), .m_axi_awready(ei_awready),
        .m_axi_wdata  (ei_wdata),   .m_axi_wstrb  (ei_wstrb),   .m_axi_wvalid (ei_wvalid),
        .m_axi_wready (ei_wready),  .m_axi_bresp  (ei_bresp),   .m_axi_bvalid (ei_bvalid),
        .m_axi_bready (ei_bready),  .m_axi_araddr (ei_araddr),  .m_axi_arvalid(ei_arvalid),
        .m_axi_arready(ei_arready), .m_axi_rdata  (ei_rdata),   .m_axi_rresp  (ei_rresp),
        .m_axi_rvalid (ei_rvalid),  .m_axi_rready (ei_rready),
        .quality_req  (1'b0),       .quality_value(7'd95),      .quality_busy (),
        .quality_done (),           .init_done    (init_done)
    );

    // =======================================================================
    // MJPEG encoder
    // =======================================================================
    reg  [15:0] enc_tdata;
    reg         enc_tvalid, enc_tlast, enc_tuser;
    wire        enc_tready;
    wire [7:0]  jpg_tdata;
    wire        jpg_tvalid, jpg_tlast;

    mjpegzero_enc_top #(
        .LITE_MODE(1), .LITE_QUALITY(75), .IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H)
    ) u_enc (
        .clk(clk), .rst_n(rst_n),
        .s_axis_vid_tdata (enc_tdata),  .s_axis_vid_tvalid(enc_tvalid),
        .s_axis_vid_tready(enc_tready), .s_axis_vid_tlast (enc_tlast),
        .s_axis_vid_tuser (enc_tuser),
        .m_axis_jpg_tdata (jpg_tdata),  .m_axis_jpg_tvalid(jpg_tvalid),
        .m_axis_jpg_tlast (jpg_tlast),
        .s_axi_awaddr (ei_awaddr),  .s_axi_awvalid(ei_awvalid), .s_axi_awready(ei_awready),
        .s_axi_wdata  (ei_wdata),   .s_axi_wstrb  (ei_wstrb),   .s_axi_wvalid (ei_wvalid),
        .s_axi_wready (ei_wready),  .s_axi_bresp  (ei_bresp),   .s_axi_bvalid (ei_bvalid),
        .s_axi_bready (ei_bready),  .s_axi_araddr (ei_araddr),  .s_axi_arvalid(ei_arvalid),
        .s_axi_arready(ei_arready), .s_axi_rdata  (ei_rdata),   .s_axi_rresp  (ei_rresp),
        .s_axi_rvalid (ei_rvalid),  .s_axi_rready (ei_rready)
    );

    // =======================================================================
    // fcapz EJTAG-AXI bridge on USER4 (150 MHz)
    // =======================================================================
    wire [31:0] m_awaddr;  wire [7:0] m_awlen;  wire [2:0] m_awsize;
    wire [1:0]  m_awburst; wire [2:0] m_awprot; wire m_awvalid;
    reg         m_awready;
    wire [31:0] m_wdata;   wire [3:0] m_wstrb;  wire m_wlast; wire m_wvalid;
    wire        m_wready;
    reg  [1:0]  m_bresp;   reg  m_bvalid; wire m_bready;
    wire [31:0] m_araddr;  wire [7:0] m_arlen;  wire [2:0] m_arsize;
    wire [1:0]  m_arburst; wire [2:0] m_arprot; wire m_arvalid;
    reg         m_arready;
    reg  [31:0] m_rdata;   reg [1:0] m_rresp; reg m_rlast; reg m_rvalid;
    wire        m_rready;

    reg        axi_wr_act;
    reg        enc_running;
    reg        enc_done;

    fcapz_ejtagaxi_xilinx7 #(
        .ADDR_W(32), .DATA_W(32), .FIFO_DEPTH(256), .TIMEOUT(4096), .CHAIN(4)
    ) u_jtag (
        .axi_clk(clk), .axi_rst(~rst_n),
        .m_axi_awaddr (m_awaddr),  .m_axi_awlen (m_awlen),  .m_axi_awsize(m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awprot(m_awprot), .m_axi_awvalid(m_awvalid),
        .m_axi_awready(m_awready),
        .m_axi_wdata (m_wdata),    .m_axi_wstrb (m_wstrb),  .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid),   .m_axi_wready(m_wready),
        .m_axi_bresp (m_bresp),    .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_araddr (m_araddr),  .m_axi_arlen (m_arlen),  .m_axi_arsize(m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arprot(m_arprot), .m_axi_arvalid(m_arvalid),
        .m_axi_arready(m_arready),
        .m_axi_rdata (m_rdata),    .m_axi_rresp (m_rresp),  .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid),   .m_axi_rready(m_rready),
        .debug_tck(), .debug_tck_edge(), .debug_axi(), .debug_axi_edge()
    );

    // =======================================================================
    // AXI4 write slave + pixel pump + JPEG capture (150 MHz) -- as demo_top.v
    // =======================================================================
    localparam [1:0] AW_IDLE = 2'd0, AW_DATA = 2'd1, AW_RESP = 2'd2;
    reg [1:0]  aw_state;
    reg [31:0] aw_addr;
    reg        aw_bad, aw_to_pixel, aw_to_ctrl, axi_error, axi_rd_error_pulse;

    assign m_wready = (aw_state == AW_DATA) &&
                      ((aw_to_pixel && !pix_full) || aw_to_ctrl || aw_bad);
    wire aw_hs = m_wvalid && m_wready;

    reg        start_armed;
    reg [18:0] jpeg_byte_cnt;
    reg [1:0]  jp_phase;
    reg [23:0] jp_accum;
    reg [16:0] jp_wptr;
    reg        flush_pend;
    reg        jpeg_overflow;
    wire jpeg_word_room = (jp_wptr < JPEG_WORDS[16:0]);
    wire jpeg_byte_room = (jpeg_byte_cnt < JPEG_BYTES[18:0]);

    reg        pix_sub;
    reg [31:0] pix_word;
    reg [10:0] pix_col;
    reg [19:0] pix_sent;

    wire do_push = aw_hs && aw_to_pixel;
    wire do_pop  = enc_running && !pix_empty &&
                   (pix_sent < FRAME_PXLS[19:0]) && !enc_tvalid && pix_sub;

    always @(posedge clk)
        if (do_push) pix_fifo[pix_wr_ptr] <= m_wdata;

    always @(posedge clk) begin
        if (!rst_n) begin
            aw_state<=AW_IDLE; m_awready<=1'b0; m_bvalid<=1'b0; m_bresp<=2'b00;
            aw_addr<=32'd0; axi_wr_act<=1'b0; aw_bad<=1'b0; aw_to_pixel<=1'b0;
            aw_to_ctrl<=1'b0; axi_error<=1'b0;
            pix_wr_ptr<=6'd0; pix_rd_ptr<=6'd0; pix_count<=7'd0;
            enc_running<=1'b0; start_armed<=1'b0; enc_done<=1'b0;
            jpeg_byte_cnt<=19'd0; jp_phase<=2'd0; jp_accum<=24'd0; jp_wptr<=17'd0;
            flush_pend<=1'b0; jpeg_overflow<=1'b0;
            enc_tvalid<=1'b0; enc_tlast<=1'b0; enc_tuser<=1'b0; enc_tdata<=16'd0;
            pix_sub<=1'b0; pix_word<=32'd0; pix_col<=11'd0; pix_sent<=20'd0;
        end else begin
            m_awready<=1'b0; axi_wr_act<=1'b0;
            if (axi_rd_error_pulse) axi_error<=1'b1;

            case (aw_state)
                AW_IDLE: if (m_awvalid) begin
                    m_awready<=1'b1; aw_addr<=m_awaddr;
                    aw_to_pixel<=!m_awaddr[25];
                    aw_to_ctrl <= m_awaddr[25] && !m_awaddr[24];
                    aw_bad <= (m_awsize!=3'b010)||(m_awburst!=2'b01)||
                              (m_awaddr[1:0]!=2'b00)||(m_awaddr[25]&&m_awaddr[24]);
                    aw_state<=AW_DATA;
                end
                AW_DATA: if (aw_hs) begin
                    axi_wr_act<=1'b1;
                    if (aw_bad) axi_error<=1'b1;
                    if (aw_to_pixel) pix_wr_ptr<=pix_wr_ptr+6'd1;
                    if (aw_to_ctrl) begin
                        if (aw_addr[3:2]==2'b00) begin
                            if (m_wdata[1]) begin
                                enc_running<=1'b0; start_armed<=1'b0; enc_done<=1'b0;
                                axi_error<=1'b0; jpeg_overflow<=1'b0;
                                pix_wr_ptr<=6'd0; pix_rd_ptr<=6'd0; pix_count<=7'd0;
                                pix_col<=11'd0; pix_sent<=20'd0; pix_sub<=1'b0;
                                enc_tvalid<=1'b0; jp_phase<=2'd0; jp_wptr<=17'd0;
                                jpeg_byte_cnt<=19'd0; flush_pend<=1'b0;
                            end
                            if (m_wdata[0]) begin
                                enc_running<=1'b0; start_armed<=1'b1; enc_done<=1'b0;
                                jpeg_overflow<=1'b0; pix_col<=11'd0; pix_sent<=20'd0;
                                pix_sub<=1'b0; enc_tvalid<=1'b0; jp_phase<=2'd0;
                                jp_wptr<=17'd0; jpeg_byte_cnt<=19'd0; flush_pend<=1'b0;
                            end
                        end else axi_error<=1'b1;
                    end
                    aw_addr<=aw_addr+32'd4;
                    if (m_wlast) aw_state<=AW_RESP;
                end
                AW_RESP: begin
                    m_bresp <= aw_bad ? 2'b10 : 2'b00;
                    if (!m_bvalid) m_bvalid<=1'b1;
                    else if (m_bready) begin m_bvalid<=1'b0; aw_state<=AW_IDLE; end
                end
                default: aw_state<=AW_IDLE;
            endcase

            if (do_push && !do_pop)      pix_count<=pix_count+7'd1;
            else if (!do_push && do_pop) pix_count<=pix_count-7'd1;

            if (start_armed && !enc_running && (pix_count>=PIX_PREFILL[6:0])) begin
                enc_running<=1'b1; start_armed<=1'b0;
            end

            flush_pend<=1'b0;
            if (jpg_tvalid && enc_running) begin
                if (jpeg_byte_room) begin
                    jpeg_byte_cnt<=jpeg_byte_cnt+19'd1;
                    case (jp_phase)
                        2'd0: jp_accum[7:0]<=jpg_tdata;
                        2'd1: jp_accum[15:8]<=jpg_tdata;
                        2'd2: jp_accum[23:16]<=jpg_tdata;
                        2'd3: if (jpeg_word_room) jp_wptr<=jp_wptr+17'd1;
                    endcase
                    jp_phase<=jp_phase+2'd1;
                end else jpeg_overflow<=1'b1;
                if (jpg_tlast) begin
                    enc_running<=1'b0; start_armed<=1'b0; enc_done<=1'b1;
                    if (jp_phase!=2'd3 && jpeg_word_room && !jpeg_overflow)
                        flush_pend<=1'b1;
                end
            end

            if (enc_tvalid && enc_tready) begin
                enc_tvalid<=1'b0; enc_tlast<=1'b0; enc_tuser<=1'b0;
            end
            if (enc_running && !pix_empty && (pix_sent<FRAME_PXLS[19:0]) && !enc_tvalid) begin
                if (!pix_sub) begin
                    pix_word<=pix_fifo_out; enc_tdata<=pix_fifo_out[15:0];
                end else begin
                    enc_tdata<=pix_word[31:16]; pix_rd_ptr<=pix_rd_ptr+6'd1;
                end
                enc_tvalid<=1'b1;
                enc_tuser<=(pix_sent==20'd0);
                enc_tlast<=(pix_col==IMG_W[10:0]-11'd1);
                pix_sub<=~pix_sub;
                pix_sent<=pix_sent+20'd1;
                if (pix_col==IMG_W[10:0]-11'd1) pix_col<=11'd0;
                else pix_col<=pix_col+11'd1;
            end
        end
    end

    // =======================================================================
    // JPEG buffer (dual-clock TDP): port A = write+JTAG read (150),
    //                               port B = Ethernet read (100)
    // =======================================================================
    localparam [2:0] AR_IDLE=3'd0, AR_PRE=3'd1, AR_DATA=3'd2;
    reg [2:0]  ar_state;
    reg [31:0] ar_addr;
    reg [7:0]  ar_rem;
    reg [16:0] ar_widx;
    reg        ar_bad, ar_to_jpeg;
    wire        jpeg_we;
    wire [31:0] jpeg_wdata;
    wire [31:0] jpeg_rd_data;

    assign jpeg_we = (jpg_tvalid && enc_running && jp_phase==2'd3 && jpeg_word_room) ||
                     (flush_pend && jpeg_word_room);
    assign jpeg_wdata = (jpg_tvalid && enc_running && jp_phase==2'd3) ?
                        {jpg_tdata, jp_accum} : {8'd0, jp_accum};

    wire [16:0] rtp_mem_raddr;
    wire [31:0] rtp_mem_rdata;

    jpeg_buffer_dc #(.JPEG_WORDS(JPEG_WORDS), .JPEG_TILE_DEPTH(4096)) u_jpeg_buffer (
        .clk_a (clk),
        .we    (jpeg_we),
        .addr_a(jpeg_we ? jp_wptr : ar_widx),
        .wdata (jpeg_wdata),
        .rdata_a(jpeg_rd_data),
        .clk_b (clk100),
        .addr_b(rtp_mem_raddr),
        .rdata_b(rtp_mem_rdata)
    );

    always @(posedge clk) begin
        if (!rst_n) begin
            ar_state<=AR_IDLE; m_arready<=1'b0; m_rvalid<=1'b0; m_rlast<=1'b0;
            m_rresp<=2'b00; m_rdata<=32'd0; ar_addr<=32'd0; ar_rem<=8'd0;
            ar_widx<=17'd0; ar_bad<=1'b0; ar_to_jpeg<=1'b0; axi_rd_error_pulse<=1'b0;
        end else begin
            m_arready<=1'b0; axi_rd_error_pulse<=1'b0;
            case (ar_state)
                AR_IDLE: begin
                    m_rvalid<=1'b0;
                    if (m_arvalid) begin
                        m_arready<=1'b1; ar_addr<=m_araddr; ar_rem<=m_arlen;
                        ar_widx<=(m_araddr-AXI_JPEG_BASE)>>2;
                        ar_to_jpeg<=m_araddr[25]&&m_araddr[24];
                        ar_bad<=(m_arsize!=3'b010)||(m_arburst!=2'b01)||
                                (m_araddr[1:0]!=2'b00)||(!m_araddr[25])||
                                ((m_araddr[25]&&m_araddr[24])&&
                                 ((((m_araddr-AXI_JPEG_BASE)>>2)+{24'd0,m_arlen})>=JPEG_WORDS[31:0]));
                        ar_state<=AR_PRE;
                    end
                end
                AR_PRE: ar_state<=AR_DATA;
                AR_DATA: begin
                    if (ar_bad) begin m_rdata<=32'd0; axi_rd_error_pulse<=1'b1; end
                    else if (ar_to_jpeg) m_rdata<=jpeg_rd_data;
                    else case (ar_addr[4:2])
                        // [4:0] existing; [11:5]={macbp,arp,mactx,rtpdone,rtprun,trg,udp} debug
                        3'd0: m_rdata<={20'd0,dbg_s2,start_armed,enc_running,axi_error,jpeg_overflow,enc_done};
                        3'd1: m_rdata<={13'd0,jpeg_byte_cnt};
                        3'd2: m_rdata<=JPEG_BYTES[31:0];
                        3'd3: m_rdata<=dstip_s2;                  // 0x0C: captured dst IP
                        3'd4: m_rdata<=dstmac_s2[31:0];           // 0x10: dst MAC[31:0]
                        3'd5: m_rdata<={16'd0,dstmac_s2[47:32]};  // 0x14: dst MAC[47:32]
                        3'd6: m_rdata<={16'd0,dstport_s2};        // 0x18: dst port
                        3'd7: m_rdata<={16'd0,frames_s2};         // 0x1C: MAC frame count
                    endcase
                    m_rvalid<=1'b1; m_rlast<=(ar_rem==8'd0);
                    m_rresp<=ar_bad?2'b10:2'b00;
                    if (m_rvalid && m_rready) begin
                        if (ar_rem==8'd0) begin
                            m_rvalid<=1'b0; m_rlast<=1'b0; ar_state<=AR_IDLE;
                        end else begin
                            ar_addr<=ar_addr+32'd4; ar_widx<=ar_widx+17'd1;
                            ar_rem<=ar_rem-8'd1; m_rvalid<=1'b0; ar_state<=AR_PRE;
                        end
                    end
                end
                default: ar_state<=AR_IDLE;
            endcase
        end
    end

    // =======================================================================
    // CDC: enc_done + jpeg_byte_cnt  (150 -> 100). jpeg_byte_cnt is stable once
    // enc_done is high (it stops counting at jpg_tlast), so a qualifier sync +
    // double-registered bus is safe.
    // =======================================================================
    reg [2:0]  encdone_sync;
    reg [18:0] jsize_a, jsize_b;
    always @(posedge clk100) begin
        encdone_sync <= {encdone_sync[1:0], enc_done};
        jsize_a <= jpeg_byte_cnt;
        jsize_b <= jsize_a;
    end
    wire        frame_ready_100 = encdone_sync[2];
    wire [18:0] jpeg_size_100   = jsize_b;

    // =======================================================================
    // Ethernet island (100 MHz)
    // =======================================================================
    // --- MAC CSR (mac_csr_init -> eth_mac_sys) ---
    wire [7:0]  ci_awaddr;  wire ci_awvalid, ci_awready;
    wire [31:0] ci_wdata;   wire [3:0] ci_wstrb; wire ci_wvalid, ci_wready;
    wire [1:0]  ci_bresp;   wire ci_bvalid, ci_bready;
    wire [7:0]  ci_araddr;  wire ci_arvalid, ci_arready;
    wire [31:0] ci_rdata;   wire [1:0] ci_rresp; wire ci_rvalid, ci_rready;
    wire mac_init_done;

    mac_csr_init #(.MAC_ADDR(OUR_MAC), .CTRL_VAL(9'h02B)) u_mac_init (
        .clk(clk100), .rst_n(eth_rst_n),
        .m_axi_awaddr(ci_awaddr), .m_axi_awvalid(ci_awvalid), .m_axi_awready(ci_awready),
        .m_axi_wdata(ci_wdata), .m_axi_wstrb(ci_wstrb), .m_axi_wvalid(ci_wvalid),
        .m_axi_wready(ci_wready), .m_axi_bresp(ci_bresp), .m_axi_bvalid(ci_bvalid),
        .m_axi_bready(ci_bready),
        .m_axi_araddr(ci_araddr), .m_axi_arvalid(ci_arvalid), .m_axi_arready(ci_arready),
        .m_axi_rdata(ci_rdata), .m_axi_rresp(ci_rresp), .m_axi_rvalid(ci_rvalid),
        .m_axi_rready(ci_rready), .init_done(mac_init_done)
    );

    // --- MAC RX / TX streams ---
    wire [7:0] mac_rx_tdata;  wire mac_rx_tvalid, mac_rx_tlast, mac_rx_terror, mac_rx_tsof;
    wire [7:0] mac_tx_tdata;  wire mac_tx_tvalid, mac_tx_tready, mac_tx_tlast;
    wire       mdio_o, mdio_oe, mdio_i;
    wire       mac_irq;

    eth_mac_sys #(.PHY_INTERFACE("MII"), .MAX_FRAME(1518)) u_mac (
        .clk(clk100), .rst_n(eth_rst_n),
        .s_axi_awaddr(ci_awaddr), .s_axi_awvalid(ci_awvalid), .s_axi_awready(ci_awready),
        .s_axi_wdata(ci_wdata), .s_axi_wstrb(ci_wstrb), .s_axi_wvalid(ci_wvalid),
        .s_axi_wready(ci_wready), .s_axi_bresp(ci_bresp), .s_axi_bvalid(ci_bvalid),
        .s_axi_bready(ci_bready),
        .s_axi_araddr(ci_araddr), .s_axi_arvalid(ci_arvalid), .s_axi_arready(ci_arready),
        .s_axi_rdata(ci_rdata), .s_axi_rresp(ci_rresp), .s_axi_rvalid(ci_rvalid),
        .s_axi_rready(ci_rready),
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

    // --- net_rx ---
    wire [7:0]  ud_data;  wire ud_valid, ud_last;
    wire [31:0] ud_src_ip;
    wire [15:0] ud_src_port, ud_dst_port, ud_length;
    wire [47:0] rx_src_mac;
    wire [7:0]  arp_rx_data;  wire arp_rx_valid, arp_rx_last;

    net_rx u_net_rx (
        .clk(clk100), .rst_n(eth_rst_n),
        .s_axis_tdata(mac_rx_tdata), .s_axis_tvalid(mac_rx_tvalid),
        .s_axis_tlast(mac_rx_tlast), .s_axis_tsof(mac_rx_tsof), .s_axis_terror(mac_rx_terror),
        .arp_data(arp_rx_data), .arp_valid(arp_rx_valid), .arp_last(arp_rx_last),
        .icmp_data(), .icmp_valid(), .icmp_last(), .icmp_src_ip(),
        .udp_data(ud_data), .udp_valid(ud_valid), .udp_last(ud_last),
        .udp_src_ip(ud_src_ip), .udp_src_port(ud_src_port),
        .udp_dst_port(ud_dst_port), .udp_length(ud_length),
        .rx_src_mac(rx_src_mac), .our_ip(OUR_IP)
    );

    // --- ARP responder (so the host can resolve the FPGA's IP) ---
    wire [7:0] arp_tx_tdata;  wire arp_tx_tvalid, arp_tx_tready, arp_tx_tlast;
    wire       arp_reply_sent;
    arp_responder u_arp (
        .clk(clk100), .rst_n(eth_rst_n), .enable(1'b1),
        .rx_tdata(mac_rx_tdata), .rx_tvalid(mac_rx_tvalid), .rx_tlast(mac_rx_tlast),
        .rx_terror(mac_rx_terror), .rx_tsof(mac_rx_tsof),
        .tx_tdata(arp_tx_tdata), .tx_tvalid(arp_tx_tvalid),
        .tx_tready(arp_tx_tready), .tx_tlast(arp_tx_tlast),
        .our_mac(OUR_MAC), .our_ip(OUR_IP), .arp_reply_sent(arp_reply_sent)
    );

    // --- trigger capture ---
    wire        trg_start;
    wire [47:0] trg_dst_mac;
    wire [31:0] trg_dst_ip;
    wire [15:0] trg_dst_port, trg_src_port;
    wire        rtp_busy;

    jpeg_rtp_trigger #(
        .TRIGGER_PORT(TRIGGER_PORT), .RTP_DST_PORT(RTP_PORT), .RTP_SRC_PORT(RTP_PORT)
    ) u_trig (
        .clk(clk100), .rst_n(eth_rst_n),
        .udp_valid(ud_valid), .udp_last(ud_last), .udp_dst_port(ud_dst_port),
        .udp_rx_src_mac(rx_src_mac), .udp_rx_src_ip(ud_src_ip),
        .busy(rtp_busy),
        .start(trg_start), .dst_mac(trg_dst_mac), .dst_ip(trg_dst_ip),
        .dst_port(trg_dst_port), .src_port(trg_src_port)
    );

    // --- RTP/JPEG packetizer (reads JPEG buffer port B) ---
    wire [7:0] rtp_tx_tdata;  wire rtp_tx_tvalid, rtp_tx_tready, rtp_tx_tlast;
    wire       rtp_done;

    jpeg_rtp_tx #(
        .IMG_W(IMG_W), .IMG_H(IMG_H), .SCAN_OFF(623), .EOI_BYTES(2),
        .QT_LUMA_OFF(25), .QT_CHROMA_OFF(94), .SCAN_CHUNK(11'd1024)
    ) u_rtp (
        .clk(clk100), .rst_n(eth_rst_n),
        .our_mac(OUR_MAC), .our_ip(OUR_IP), .src_port(trg_src_port),
        .dst_mac(trg_dst_mac), .dst_ip(trg_dst_ip), .dst_port(trg_dst_port),
        .ssrc(32'h0A0B0C0D), .rtp_timestamp(32'd0),
        .start(trg_start & frame_ready_100), .jpeg_size(jpeg_size_100),
        .busy(rtp_busy), .done_pulse(rtp_done),
        .mem_raddr(rtp_mem_raddr), .mem_rdata(rtp_mem_rdata),
        .tx_data(rtp_tx_tdata), .tx_valid(rtp_tx_tvalid),
        .tx_last(rtp_tx_tlast), .tx_ready(rtp_tx_tready)
    );

    // --- per-frame store-and-forward (gap-free frames for the cut-through MAC) ---
    wire [7:0] rtpfb_tdata; wire rtpfb_tvalid, rtpfb_tlast, rtpfb_tready;
    axis_frame_buffer #(.AW(11)) u_fb (
        .clk(clk100), .rst_n(eth_rst_n),
        .s_tdata(rtp_tx_tdata), .s_tvalid(rtp_tx_tvalid),
        .s_tlast(rtp_tx_tlast), .s_tready(rtp_tx_tready),
        .m_tdata(rtpfb_tdata), .m_tvalid(rtpfb_tvalid),
        .m_tlast(rtpfb_tlast), .m_tready(rtpfb_tready)
    );

    // --- TX arbiter (ARP + RTP) ---
    arty_tx_arbiter u_arb (
        .clk(clk100), .rst_n(eth_rst_n), .arp_tx_active(1'b0),
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
    // Debug: sticky flags (clk100) for each Ethernet-island stage, synced to
    // clk150 and exposed in DEMO_STATUS. arp_reply is a known-good control
    // (ARP works), so it must read 1 and validates the sticky+CDC+read path.
    // =======================================================================
    reg dbg_udp, dbg_trg, dbg_rtprun, dbg_rtpdone, dbg_mactx, dbg_arp, dbg_macbp;
    reg [15:0] mactx_frames;   // count of complete frames handed to the MAC
    always @(posedge clk100) begin
        if (!eth_rst_n) begin
            dbg_udp<=1'b0; dbg_trg<=1'b0; dbg_rtprun<=1'b0;
            dbg_rtpdone<=1'b0; dbg_mactx<=1'b0; dbg_arp<=1'b0; dbg_macbp<=1'b0;
            mactx_frames<=16'd0;
        end else begin
            if (ud_valid && ud_last) dbg_udp    <= 1'b1;
            if (trg_start)           dbg_trg    <= 1'b1;
            if (rtp_busy)            dbg_rtprun <= 1'b1;
            if (rtp_done)            dbg_rtpdone<= 1'b1;
            if (mac_tx_tvalid)       dbg_mactx  <= 1'b1;
            if (arp_reply_sent)      dbg_arp    <= 1'b1;
            // MAC asserted valid but not ready -> it IS draining to MII (backpressure)
            if (mac_tx_tvalid && !mac_tx_tready) dbg_macbp <= 1'b1;
            // complete frame accepted by the MAC
            if (mac_tx_tvalid && mac_tx_tready && mac_tx_tlast)
                mactx_frames <= mactx_frames + 16'd1;
        end
    end
    wire [6:0] dbg_100 = {dbg_macbp, dbg_arp, dbg_mactx, dbg_rtpdone, dbg_rtprun, dbg_trg, dbg_udp};
    reg  [6:0] dbg_s1, dbg_s2;
    // Captured RTP destination + MAC frame count (clk100) synced to clk150.
    reg [47:0] dstmac_s1, dstmac_s2;
    reg [31:0] dstip_s1, dstip_s2;
    reg [15:0] dstport_s1, dstport_s2;
    reg [15:0] frames_s1, frames_s2;
    always @(posedge clk) begin
        dbg_s1 <= dbg_100;          dbg_s2 <= dbg_s1;
        dstmac_s1 <= trg_dst_mac;   dstmac_s2 <= dstmac_s1;
        dstip_s1  <= trg_dst_ip;    dstip_s2  <= dstip_s1;
        dstport_s1<= trg_dst_port;  dstport_s2<= dstport_s1;
        frames_s1 <= mactx_frames;  frames_s2 <= frames_s1;
    end

    // =======================================================================
    // LEDs
    // =======================================================================
    reg [25:0] hb_cnt;
    reg        hb_toggle;
    always @(posedge clk) begin
        if (hb_cnt==26'd49_999_999) begin hb_cnt<=26'd0; hb_toggle<=~hb_toggle; end
        else hb_cnt<=hb_cnt+26'd1;
    end

    // ethernet TX activity stretch (100 MHz -> visible)
    reg [22:0] eth_act_cnt;
    reg        eth_act;
    always @(posedge clk100) begin
        if (mac_tx_tvalid && mac_tx_tready) begin eth_act<=1'b1; eth_act_cnt<=23'h7FFFFF; end
        else if (eth_act_cnt!=23'd0) eth_act_cnt<=eth_act_cnt-23'd1;
        else eth_act<=1'b0;
    end

    assign led0 = hb_toggle;
    assign led1 = start_armed || enc_running;
    assign led2 = enc_done;
    assign led3 = eth_act;

endmodule
