// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// demo_top_bare.v — demo_top without clk_gen and jtag_axi_0
// Exposes AXI4 master ports directly so a testbench can drive them.
// Parameterized for simulation at small image sizes.
// Verilog 2001

`timescale 1ns / 1ps

module demo_top_bare #(
    parameter IMG_W       = 1280,
    parameter IMG_H       = 720,
    parameter LITE_QUALITY = 75,
    parameter JPEG_WORDS  = 65536   // 32-bit words; 65536 = 256 KB
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4 master (driven by testbench — replaces jtag_axi_0)
    input  wire [31:0] m_awaddr,
    input  wire [7:0]  m_awlen,
    input  wire [2:0]  m_awsize,
    input  wire [1:0]  m_awburst,
    input  wire [2:0]  m_awprot,
    input  wire        m_awvalid,
    output reg         m_awready,

    input  wire [31:0] m_wdata,
    input  wire [3:0]  m_wstrb,
    input  wire        m_wlast,
    input  wire        m_wvalid,
    output wire        m_wready,

    output reg  [1:0]  m_bresp,
    output reg         m_bvalid,
    input  wire        m_bready,

    input  wire [31:0] m_araddr,
    input  wire [7:0]  m_arlen,
    input  wire [2:0]  m_arsize,
    input  wire [1:0]  m_arburst,
    input  wire [2:0]  m_arprot,
    input  wire        m_arvalid,
    output reg         m_arready,

    output reg  [31:0] m_rdata,
    output reg  [1:0]  m_rresp,
    output reg         m_rlast,
    output reg         m_rvalid,
    input  wire        m_rready,

    // Status outputs (for waveform visibility)
    output wire        led0,
    output wire        led1,
    output wire        led2,
    output wire        led3
);

    // -----------------------------------------------------------------------
    // Derived parameters
    // -----------------------------------------------------------------------
    localparam FRAME_PXLS = IMG_W * IMG_H;
    localparam AXI_JPEG_BASE = 32'h0300_0000;
    localparam AXI_CTRL_BASE = 32'h0200_0000;

    // JPEG_WORDS_LOG2: for ar_widx bounds — just use 16 bits wide (safe up to 65536)

    // -----------------------------------------------------------------------
    // JPEG BRAM — 32-bit wide
    // -----------------------------------------------------------------------
    (* ram_style = "block" *) reg [31:0] jpeg_mem [0:JPEG_WORDS-1];

    // -----------------------------------------------------------------------
    // Pixel FIFO — 64 x 32-bit, distributed RAM, async read
    // -----------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [31:0] pix_fifo [0:63];
    reg [5:0]  pix_wr_ptr, pix_rd_ptr;
    reg [6:0]  pix_count;
    wire       pix_full  = (pix_count == 7'd64);
    wire       pix_empty = (pix_count == 7'd0);
    wire [31:0] pix_fifo_out = pix_fifo[pix_rd_ptr];

    // -----------------------------------------------------------------------
    // Encoder AXI4-Lite init (axi_init -> encoder)
    // -----------------------------------------------------------------------
    wire [4:0]  ei_awaddr;  wire ei_awvalid, ei_awready;
    wire [31:0] ei_wdata;   wire [3:0] ei_wstrb; wire ei_wvalid, ei_wready;
    wire [1:0]  ei_bresp;   wire ei_bvalid, ei_bready;
    wire [4:0]  ei_araddr;  wire ei_arvalid, ei_arready;
    wire [31:0] ei_rdata;   wire [1:0] ei_rresp; wire ei_rvalid, ei_rready;
    wire        init_done;

    axi_init u_init (
        .clk(clk), .rst_n(rst_n),
        .m_axi_awaddr (ei_awaddr),  .m_axi_awvalid(ei_awvalid), .m_axi_awready(ei_awready),
        .m_axi_wdata  (ei_wdata),   .m_axi_wstrb  (ei_wstrb),   .m_axi_wvalid (ei_wvalid),
        .m_axi_wready (ei_wready),  .m_axi_bresp  (ei_bresp),   .m_axi_bvalid (ei_bvalid),
        .m_axi_bready (ei_bready),  .m_axi_araddr (ei_araddr),  .m_axi_arvalid(ei_arvalid),
        .m_axi_arready(ei_arready), .m_axi_rdata  (ei_rdata),   .m_axi_rresp  (ei_rresp),
        .m_axi_rvalid (ei_rvalid),  .m_axi_rready (ei_rready),  .init_done    (init_done)
    );

    // -----------------------------------------------------------------------
    // MJPEG encoder
    // -----------------------------------------------------------------------
    reg  [15:0] enc_tdata;
    reg         enc_tvalid, enc_tlast, enc_tuser;
    wire        enc_tready;
    wire [7:0]  jpg_tdata;
    wire        jpg_tvalid, jpg_tlast;

    mjpegzero_enc_top #(
        .LITE_MODE    (1),
        .LITE_QUALITY (LITE_QUALITY),
        .IMG_WIDTH    (IMG_W),
        .IMG_HEIGHT   (IMG_H)
    ) u_enc (
        .clk               (clk),        .rst_n          (rst_n),
        .s_axis_vid_tdata  (enc_tdata),  .s_axis_vid_tvalid(enc_tvalid),
        .s_axis_vid_tready (enc_tready), .s_axis_vid_tlast (enc_tlast),
        .s_axis_vid_tuser  (enc_tuser),
        .m_axis_jpg_tdata  (jpg_tdata),  .m_axis_jpg_tvalid(jpg_tvalid),
        .m_axis_jpg_tlast  (jpg_tlast),
        .s_axi_awaddr (ei_awaddr),  .s_axi_awvalid(ei_awvalid), .s_axi_awready(ei_awready),
        .s_axi_wdata  (ei_wdata),   .s_axi_wstrb  (ei_wstrb),   .s_axi_wvalid (ei_wvalid),
        .s_axi_wready (ei_wready),  .s_axi_bresp  (ei_bresp),   .s_axi_bvalid (ei_bvalid),
        .s_axi_bready (ei_bready),  .s_axi_araddr (ei_araddr),  .s_axi_arvalid(ei_arvalid),
        .s_axi_arready(ei_arready), .s_axi_rdata  (ei_rdata),   .s_axi_rresp  (ei_rresp),
        .s_axi_rvalid (ei_rvalid),  .s_axi_rready (ei_rready)
    );

    // -----------------------------------------------------------------------
    // AXI4 Write slave
    // -----------------------------------------------------------------------
    localparam [1:0] AW_IDLE = 2'd0, AW_DATA = 2'd1, AW_RESP = 2'd2;
    reg [1:0]  aw_state;
    reg [31:0] aw_addr;
    reg        axi_wr_act;

    assign m_wready = (aw_state == AW_DATA) &&
                      ((!aw_addr[25] && !pix_full) ||
                       ( aw_addr[25] && !aw_addr[24]));

    wire aw_hs = m_wvalid && m_wready;

    // -----------------------------------------------------------------------
    // JPEG capture state
    // -----------------------------------------------------------------------
    reg        enc_running;
    reg        enc_done;
    reg [17:0] jpeg_byte_cnt;
    reg [1:0]  jp_phase;
    reg [23:0] jp_accum;
    reg [15:0] jp_wptr;
    reg        flush_pend;

    // -----------------------------------------------------------------------
    // Pixel pump state
    // -----------------------------------------------------------------------
    reg        pix_sub;
    reg [31:0] pix_word;
    reg [10:0] pix_col;
    reg [19:0] pix_sent;

    // -----------------------------------------------------------------------
    // Push/pop enables
    // -----------------------------------------------------------------------
    wire do_push = aw_hs && !aw_addr[25];
    wire do_pop  = enc_running && !pix_empty &&
                   (pix_sent < FRAME_PXLS[19:0]) && !enc_tvalid && pix_sub;

    // -----------------------------------------------------------------------
    // Pixel FIFO write
    // -----------------------------------------------------------------------
    always @(posedge clk)
        if (do_push)
            pix_fifo[pix_wr_ptr] <= m_wdata;

    // -----------------------------------------------------------------------
    // JPEG BRAM write
    // -----------------------------------------------------------------------
    always @(posedge clk)
        if (jpg_tvalid && enc_running && jp_phase == 2'd3)
            jpeg_mem[jp_wptr] <= {jpg_tdata, jp_accum};
        else if (flush_pend)
            jpeg_mem[jp_wptr] <= {8'd0, jp_accum};

    // -----------------------------------------------------------------------
    // ar_widx — declared here (before the BRAM read always block that uses it)
    // Updated by the AXI4 read slave below.
    // -----------------------------------------------------------------------
    reg [15:0] ar_widx;

    // -----------------------------------------------------------------------
    // JPEG BRAM read (1-cycle latency)
    // -----------------------------------------------------------------------
    reg [31:0] jpeg_rd_data;
    always @(posedge clk)
        jpeg_rd_data <= jpeg_mem[ar_widx];

    // -----------------------------------------------------------------------
    // Main always block
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_state      <= AW_IDLE;
            m_awready     <= 1'b0;
            m_bvalid      <= 1'b0;
            m_bresp       <= 2'b00;
            aw_addr       <= 32'd0;
            axi_wr_act    <= 1'b0;
            pix_wr_ptr    <= 6'd0;
            pix_rd_ptr    <= 6'd0;
            pix_count     <= 7'd0;
            enc_running   <= 1'b0;
            enc_done      <= 1'b0;
            jpeg_byte_cnt <= 18'd0;
            jp_phase      <= 2'd0;
            jp_accum      <= 24'd0;
            jp_wptr       <= 16'd0;
            flush_pend    <= 1'b0;
            enc_tvalid    <= 1'b0;
            enc_tlast     <= 1'b0;
            enc_tuser     <= 1'b0;
            enc_tdata     <= 16'd0;
            pix_sub       <= 1'b0;
            pix_word      <= 32'd0;
            pix_col       <= 11'd0;
            pix_sent      <= 20'd0;
        end else begin
            m_awready  <= 1'b0;
            axi_wr_act <= 1'b0;

            // AXI4 Write slave
            case (aw_state)
                AW_IDLE: begin
                    if (m_awvalid) begin
                        m_awready <= 1'b1;
                        aw_addr   <= m_awaddr;
                        aw_state  <= AW_DATA;
                    end
                end
                AW_DATA: begin
                    if (aw_hs) begin
                        axi_wr_act <= 1'b1;
                        if (!aw_addr[25])
                            pix_wr_ptr <= pix_wr_ptr + 6'd1;
                        if (aw_addr[25] && !aw_addr[24]) begin
                            if (aw_addr[3:2] == 2'b00) begin // DEMO_CTRL
                                if (m_wdata[1]) begin  // RESET
                                    enc_running   <= 1'b0;
                                    enc_done      <= 1'b0;
                                    pix_wr_ptr    <= 6'd0;
                                    pix_rd_ptr    <= 6'd0;
                                    pix_count     <= 7'd0;
                                    pix_col       <= 11'd0;
                                    pix_sent      <= 20'd0;
                                    pix_sub       <= 1'b0;
                                    enc_tvalid    <= 1'b0;
                                    jp_phase      <= 2'd0;
                                    jp_wptr       <= 16'd0;
                                    jpeg_byte_cnt <= 18'd0;
                                    flush_pend    <= 1'b0;
                                end
                                if (m_wdata[0]) begin  // START
                                    enc_running   <= 1'b1;
                                    enc_done      <= 1'b0;
                                    pix_col       <= 11'd0;
                                    pix_sent      <= 20'd0;
                                    pix_sub       <= 1'b0;
                                    enc_tvalid    <= 1'b0;
                                    jp_phase      <= 2'd0;
                                    jp_wptr       <= 16'd0;
                                    jpeg_byte_cnt <= 18'd0;
                                    flush_pend    <= 1'b0;
                                end
                            end
                        end
                        aw_addr <= aw_addr + 32'd4;
                        if (m_wlast) aw_state <= AW_RESP;
                    end
                end
                AW_RESP: begin
                    m_bvalid <= 1'b1;
                    m_bresp  <= 2'b00;
                    if (m_bready) begin
                        m_bvalid <= 1'b0;
                        aw_state <= AW_IDLE;
                    end
                end
                default: aw_state <= AW_IDLE;
            endcase

            // pix_count
            if (do_push && !do_pop)
                pix_count <= pix_count + 7'd1;
            else if (!do_push && do_pop)
                pix_count <= pix_count - 7'd1;

            // JPEG capture
            flush_pend <= 1'b0;
            if (jpg_tvalid && enc_running) begin
                jpeg_byte_cnt <= jpeg_byte_cnt + 18'd1;
                case (jp_phase)
                    2'd0: jp_accum[7:0]   <= jpg_tdata;
                    2'd1: jp_accum[15:8]  <= jpg_tdata;
                    2'd2: jp_accum[23:16] <= jpg_tdata;
                    2'd3: jp_wptr <= jp_wptr + 16'd1;
                endcase
                jp_phase <= jp_phase + 2'd1;
                if (jpg_tlast) begin
                    enc_running <= 1'b0;
                    enc_done    <= 1'b1;
                    if (jp_phase != 2'd3) flush_pend <= 1'b1;
                end
            end

            // Pixel pump
            if (enc_tvalid && enc_tready) begin
                enc_tvalid <= 1'b0;
                enc_tlast  <= 1'b0;
                enc_tuser  <= 1'b0;
            end

            if (enc_running && !pix_empty &&
                (pix_sent < FRAME_PXLS[19:0]) &&
                !enc_tvalid) begin
                if (!pix_sub) begin
                    pix_word  <= pix_fifo_out;
                    enc_tdata <= pix_fifo_out[15:0];
                end else begin
                    enc_tdata  <= pix_word[31:16];
                    pix_rd_ptr <= pix_rd_ptr + 6'd1;
                end
                enc_tvalid <= 1'b1;
                enc_tuser  <= (pix_sent == 20'd0);
                enc_tlast  <= (pix_col == IMG_W[10:0] - 11'd1);
                pix_sub  <= ~pix_sub;
                pix_sent <= pix_sent + 20'd1;
                if (pix_col == IMG_W[10:0] - 11'd1)
                    pix_col <= 11'd0;
                else
                    pix_col <= pix_col + 11'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // AXI4 Read slave
    // -----------------------------------------------------------------------
    localparam [2:0] AR_IDLE = 3'd0, AR_PRE = 3'd1, AR_DATA = 3'd2;
    reg [2:0]  ar_state;
    reg [31:0] ar_addr;
    reg [7:0]  ar_rem;
    // ar_widx declared above (before BRAM read always block)

    always @(posedge clk) begin
        if (!rst_n) begin
            ar_state  <= AR_IDLE;
            m_arready <= 1'b0;
            m_rvalid  <= 1'b0;
            m_rlast   <= 1'b0;
            m_rresp   <= 2'b00;
            m_rdata   <= 32'd0;
            ar_addr   <= 32'd0;
            ar_rem    <= 8'd0;
            ar_widx   <= 16'd0;
        end else begin
            m_arready <= 1'b0;
            case (ar_state)
                AR_IDLE: begin
                    m_rvalid <= 1'b0;
                    if (m_arvalid) begin
                        m_arready <= 1'b1;
                        ar_addr   <= m_araddr;
                        ar_rem    <= m_arlen;
                        ar_widx   <= (m_araddr - AXI_JPEG_BASE) >> 2;
                        ar_state  <= AR_PRE;
                    end
                end
                AR_PRE: begin
                    ar_state <= AR_DATA;
                end
                AR_DATA: begin
                    if (ar_addr[25] && ar_addr[24]) begin
                        m_rdata <= jpeg_rd_data;
                    end else begin
                        case (ar_addr[3:2])
                            2'd0: m_rdata <= {31'd0, enc_done};
                            2'd1: m_rdata <= {14'd0, jpeg_byte_cnt};
                            default: m_rdata <= 32'd0;
                        endcase
                    end
                    m_rvalid <= 1'b1;
                    m_rlast  <= (ar_rem == 8'd0);
                    m_rresp  <= 2'b00;
                    if (m_rvalid && m_rready) begin
                        if (ar_rem == 8'd0) begin
                            m_rvalid <= 1'b0;
                            m_rlast  <= 1'b0;
                            ar_state <= AR_IDLE;
                        end else begin
                            ar_addr  <= ar_addr + 32'd4;
                            ar_widx  <= ar_widx + 16'd1;
                            ar_rem   <= ar_rem - 8'd1;
                            m_rvalid <= 1'b0;
                            ar_state <= AR_PRE;
                        end
                    end
                end
                default: ar_state <= AR_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // LED outputs (heartbeat simplified for sim)
    // -----------------------------------------------------------------------
    reg [25:0] hb_cnt;
    reg        hb_toggle;
    always @(posedge clk) begin
        if (hb_cnt == 26'd49_999_999) begin
            hb_cnt    <= 26'd0;
            hb_toggle <= ~hb_toggle;
        end else
            hb_cnt <= hb_cnt + 26'd1;
    end

    assign led0 = hb_toggle;
    assign led1 = enc_running;
    assign led2 = enc_done;
    assign led3 = axi_wr_act;

endmodule
