// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// demo_top.v — mjpegZero board demo, fcapz + 720p streaming
// Shared across Arty S7-50 and Arty A7-100T (board differences in XDC only)
//
// Host communicates via the fpgacapZero EJTAG-AXI bridge on BSCANE2 USER4
// (same USB cable as programming). No UART required. An fpgacapZero ELA on
// USER1/USER2 captures 32 curated encoder/AXI signals for hardware debug.
// Pixel data streams directly from fcapz to the encoder; an on-chip JPEG
// buffer holds the compressed output.
//
// AXI4 address map (32-bit, byte-addressed):
//   0x0000_0000 – 0x01BF_FFFF  PIXEL_PORT  (write only, burst)
//                                Each 32-bit word = 2 pixels: [31:16]=odd {Cr,Y1}
//                                                              [15:0] =even {Cb,Y0}
//   0x0200_0000                 DEMO_CTRL   (write)  [0]=start [1]=reset
//                               DEMO_STATUS (read)   [0]=enc_done [1]=overflow
//                                                    [2]=axi_error [3]=running
//                                                    [4]=armed
//   0x0200_0004                 JPEG_SIZE   (read)   [18:0]=byte count
//   0x0300_0000 – 0x0301_FFFF  JPEG_PORT   (read only, burst)
//                                32-bit LE words; valid data = JPEG_SIZE bytes
//
// Encoder: LITE_MODE=1, LITE_QUALITY=75, 1280x720
// Verilog 2001

`timescale 1ns / 1ps

module demo_top #(
    parameter JPEG_WORDS = 65536   // 32-bit words for JPEG BRAM; override per board
                                   // 65536 = 256 KB (64 RAMB36) — fits A7-100T
                                   // 16384 =  64 KB (16 RAMB36) — fits S7-50
) (
    input  wire CLK100MHZ,   // 100 MHz board oscillator (pin E3)
    output wire led0,        // heartbeat
    output wire led1,        // pixels streaming / encoding active
    output wire led2,        // encode done (latched)
    output wire led3         // AXI write activity
);

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam IMG_W      = 1280;
    localparam IMG_H      = 720;
    localparam FRAME_PXLS = IMG_W * IMG_H;          // 921 600 pixels
    localparam JPEG_BYTES = JPEG_WORDS * 4;
    localparam PIX_PREFILL = 32;
    // NOTE: Vivado maps array depth to 2^ceil(log2(depth/1024)) RAMB36 banks.
    // depth=65536 → 64 RAMB36 (jpeg_mem) + 11 RAMB36 (encoder line buffers)
    // + a few RAMB36/RAMB18 for the fcapz EJTAG-AXI async FIFOs and ELA buffers.

    // AXI address boundaries
    localparam AXI_JPEG_BASE = 32'h0300_0000;
    localparam AXI_CTRL_BASE = 32'h0200_0000;

    initial begin
        if (JPEG_WORDS < 1) begin
            $display("ERROR: JPEG_WORDS must be at least 1");
            $finish;
        end
        if (JPEG_WORDS > 65536) begin
            $display("ERROR: JPEG_WORDS must be <= 65536 for the demo address counters");
            $finish;
        end
    end

    // -----------------------------------------------------------------------
    // Clock & reset
    // -----------------------------------------------------------------------
    wire clk, locked;
    reg [3:0] rst_sr;
    wire rst_n = rst_sr[3];

    clk_gen u_clkgen (
        .clk_in  (CLK100MHZ),
        .reset   (1'b0),
        .clk_out (clk),
        .locked  (locked)
    );

    always @(posedge clk)
        if (!locked) rst_sr <= 4'b0000;
        else         rst_sr <= {rst_sr[2:0], 1'b1};

    // -----------------------------------------------------------------------
    // JPEG BRAM — 32-bit wide, 65536 entries = 256 KB
    // Write port in a separate synchronous-only always block (required for
    // BRAM inference; async-reset prevents Vivado from mapping to RAMB36).
    // -----------------------------------------------------------------------
    (* ram_style = "block" *) reg [31:0] jpeg_mem [0:JPEG_WORDS-1];

    // -----------------------------------------------------------------------
    // Pixel FIFO — 64 x 32-bit (= 128 pixels); distributed RAM, async read
    // Write port in a separate synchronous-only always block.
    // -----------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [31:0] pix_fifo [0:63];
    reg [5:0]  pix_wr_ptr, pix_rd_ptr;
    reg [6:0]  pix_count;
    wire pix_full  = (pix_count == 7'd64);
    wire pix_empty = (pix_count == 7'd0);
    wire [31:0] pix_fifo_out = pix_fifo[pix_rd_ptr]; // async read

    // -----------------------------------------------------------------------
    // Encoder AXI4-Lite init wires (axi_init -> encoder only)
    // -----------------------------------------------------------------------
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
        .LITE_QUALITY (75),
        .IMG_WIDTH    (IMG_W),
        .IMG_HEIGHT   (IMG_H)
    ) u_enc (
        .clk               (clk), .rst_n(rst_n),
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
    // fpgacapZero EJTAG-AXI bridge on USER4 (active-high reset: !rst_n)
    // -----------------------------------------------------------------------
    wire [31:0] m_awaddr;  wire [7:0] m_awlen;  wire [2:0] m_awsize;
    wire [1:0]  m_awburst; wire [2:0] m_awprot; wire m_awvalid;
    reg         m_awready;
    wire [31:0] m_wdata;   wire [3:0] m_wstrb;  wire m_wlast; wire m_wvalid;
    wire        m_wready;     // combinatorial — asserted same cycle as valid
    reg  [1:0]  m_bresp;   reg  m_bvalid; wire m_bready;
    wire [31:0] m_araddr;  wire [7:0] m_arlen;  wire [2:0] m_arsize;
    wire [1:0]  m_arburst; wire [2:0] m_arprot; wire m_arvalid;
    reg         m_arready;
    reg  [31:0] m_rdata;   reg [1:0] m_rresp; reg m_rlast; reg m_rvalid;
    wire        m_rready;

    fcapz_ejtagaxi_xilinx7 #(
        .ADDR_W     (32),
        .DATA_W     (32),
        .FIFO_DEPTH (256),   // full AXI4 burst (host uses 256-beat bursts)
        .TIMEOUT    (4096),
        .CHAIN      (4)      // USER4
    ) u_jtag (
        .axi_clk (clk), .axi_rst (~rst_n),
        .m_axi_awaddr (m_awaddr),  .m_axi_awlen  (m_awlen),   .m_axi_awsize (m_awsize),
        .m_axi_awburst(m_awburst), .m_axi_awprot (m_awprot),  .m_axi_awvalid(m_awvalid),
        .m_axi_awready(m_awready),
        .m_axi_wdata  (m_wdata),   .m_axi_wstrb  (m_wstrb),   .m_axi_wlast  (m_wlast),
        .m_axi_wvalid (m_wvalid),  .m_axi_wready (m_wready),
        .m_axi_bresp  (m_bresp),   .m_axi_bvalid (m_bvalid),  .m_axi_bready (m_bready),
        .m_axi_araddr (m_araddr),  .m_axi_arlen  (m_arlen),   .m_axi_arsize (m_arsize),
        .m_axi_arburst(m_arburst), .m_axi_arprot (m_arprot),  .m_axi_arvalid(m_arvalid),
        .m_axi_arready(m_arready),
        .m_axi_rdata  (m_rdata),   .m_axi_rresp  (m_rresp),   .m_axi_rlast  (m_rlast),
        .m_axi_rvalid (m_rvalid),  .m_axi_rready (m_rready),
        .debug_tck     (),  .debug_tck_edge(),
        .debug_axi     (),  .debug_axi_edge()
    );

    // -----------------------------------------------------------------------
    // fpgacapZero ELA on USER1.
    // Minimal 16-bit probe: encoder stream handshakes, AXI handshakes,
    // and pipeline state. The demo's hardware test uses EJTAG-AXI; this
    // ELA is intentionally kept small for occasional bring-up captures.
    // -----------------------------------------------------------------------
    wire [15:0] ela_probe = {
        axi_wr_act,            // [15]
        enc_done,              // [14]
        enc_running,           // [13]
        pix_empty,             // [12]
        pix_full,              // [11]
        jpg_tlast,             // [10]
        jpg_tvalid,            // [9]
        enc_tlast,             // [8]
        enc_tuser,             // [7]
        enc_tready,            // [6]
        enc_tvalid,            // [5]
        m_rvalid,              // [4]
        m_arvalid,             // [3]
        m_bvalid,              // [2]
        m_wvalid,              // [1]
        m_awvalid              // [0]
    };

    fcapz_ela_xilinx7 #(
        .SAMPLE_W         (16),
        .DEPTH            (512),
        .INPUT_PIPE       (1),
        .DECIM_EN         (0),
        .EXT_TRIG_EN      (0),
        .TIMESTAMP_W      (0),
        .NUM_SEGMENTS     (1),
        .DUAL_COMPARE     (0),
        .USER1_DATA_EN    (0),
        .SINGLE_CHAIN_BURST(1),
        .CTRL_CHAIN       (1),
        .DATA_CHAIN       (2)
    ) u_ela (
        .sample_clk   (clk),
        .sample_rst   (~rst_n),
        .probe_in     (ela_probe),
        .trigger_in   (1'b0),
        .trigger_out  (),
        .eio_probe_in (1'b0),
        .eio_probe_out()
    );

    // -----------------------------------------------------------------------
    // AXI4 Write slave state machine
    // -----------------------------------------------------------------------
    localparam [1:0] AW_IDLE = 2'd0, AW_DATA = 2'd1, AW_RESP = 2'd2;
    reg [1:0]  aw_state;
    reg [31:0] aw_addr;
    reg        axi_wr_act;
    reg        aw_bad;
    reg        aw_to_pixel;
    reg        aw_to_ctrl;
    reg        axi_error;
    reg        axi_rd_error_pulse;

    // m_wready: combinatorial.
    //   Pixel port (addr bit25=0): ready when FIFO has space.
    //   Ctrl  port (addr[25]=1, addr[24]=0): always ready.
    assign m_wready = (aw_state == AW_DATA) &&
                      ((aw_to_pixel && !pix_full) ||
                       aw_to_ctrl || aw_bad);

    // Handshake fires this cycle: WVALID && WREADY both high
    wire aw_hs = m_wvalid && m_wready;

    // -----------------------------------------------------------------------
    // JPEG capture control registers
    // -----------------------------------------------------------------------
    reg        enc_running;
    reg        start_armed;
    reg        enc_done;
    reg [18:0] jpeg_byte_cnt;
    reg [1:0]  jp_phase;
    reg [23:0] jp_accum;
    reg [16:0] jp_wptr;
    reg        flush_pend;   // flush partial last JPEG word to BRAM
    reg        jpeg_overflow;

    wire jpeg_word_room = (jp_wptr < JPEG_WORDS[16:0]);
    wire jpeg_byte_room = (jpeg_byte_cnt < JPEG_BYTES[18:0]);

    // -----------------------------------------------------------------------
    // Pixel pump control
    // -----------------------------------------------------------------------
    reg        pix_sub;
    reg [31:0] pix_word;
    reg [10:0] pix_col;
    reg [19:0] pix_sent;

    // -----------------------------------------------------------------------
    // Push/pop enable wires for correct simultaneous pix_count update
    // -----------------------------------------------------------------------
    wire do_push = aw_hs && aw_to_pixel;
    wire do_pop  = enc_running && !pix_empty &&
                   (pix_sent < FRAME_PXLS[19:0]) && !enc_tvalid && pix_sub;

    // -----------------------------------------------------------------------
    // Pixel FIFO write — separate synchronous block (no async reset)
    // Allows Vivado to infer distributed RAM with async read.
    // -----------------------------------------------------------------------
    always @(posedge clk)
        if (do_push)
            pix_fifo[pix_wr_ptr] <= m_wdata;

    // -----------------------------------------------------------------------
    // JPEG BRAM write — separate synchronous block (no async reset)
    // Allows Vivado to infer RAMB36 for the 192 KB jpeg_mem array.
    // -----------------------------------------------------------------------
    always @(posedge clk)
        if (jpg_tvalid && enc_running && jp_phase == 2'd3 && jpeg_word_room)
            jpeg_mem[jp_wptr] <= {jpg_tdata, jp_accum};
        else if (flush_pend && jpeg_word_room)
            jpeg_mem[jp_wptr] <= {8'd0, jp_accum};   // flush partial last word (zero-pad MSB)

    // -----------------------------------------------------------------------
    // JPEG BRAM read — synchronous registered output (1-cycle latency)
    // AR_PRE state provides the latency gap; AR_DATA uses jpeg_rd_data.
    // -----------------------------------------------------------------------
    reg [31:0] jpeg_rd_data;
    always @(posedge clk)
        jpeg_rd_data <= jpeg_mem[ar_widx];  // ar_widx declared below in AR block

    // -----------------------------------------------------------------------
    // Main always block — write slave, FIFO ptrs, pixel pump, JPEG ctrl
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            aw_state    <= AW_IDLE;
            m_awready   <= 1'b0;
            m_bvalid    <= 1'b0;
            m_bresp     <= 2'b00;
            aw_addr     <= 32'd0;
            axi_wr_act  <= 1'b0;
            aw_bad      <= 1'b0;
            aw_to_pixel <= 1'b0;
            aw_to_ctrl  <= 1'b0;
            axi_error   <= 1'b0;

            pix_wr_ptr  <= 6'd0;
            pix_rd_ptr  <= 6'd0;
            pix_count   <= 7'd0;

            enc_running <= 1'b0;
            start_armed <= 1'b0;
            enc_done    <= 1'b0;
            jpeg_byte_cnt <= 19'd0;
            jp_phase    <= 2'd0;
            jp_accum    <= 24'd0;
            jp_wptr     <= 17'd0;
            flush_pend  <= 1'b0;
            jpeg_overflow <= 1'b0;

            enc_tvalid  <= 1'b0;
            enc_tlast   <= 1'b0;
            enc_tuser   <= 1'b0;
            enc_tdata   <= 16'd0;
            pix_sub     <= 1'b0;
            pix_word    <= 32'd0;
            pix_col     <= 11'd0;
            pix_sent    <= 20'd0;
        end else begin
            m_awready  <= 1'b0;
            axi_wr_act <= 1'b0;

            if (axi_rd_error_pulse)
                axi_error <= 1'b1;

            // ================================================================
            // AXI4 Write slave
            // ================================================================
            case (aw_state)
                AW_IDLE: begin
                    if (m_awvalid) begin
                        m_awready <= 1'b1;
                        aw_addr   <= m_awaddr;
                        aw_to_pixel <= !m_awaddr[25];
                        aw_to_ctrl  <=  m_awaddr[25] && !m_awaddr[24];
                        aw_bad      <= (m_awsize != 3'b010) ||
                                       (m_awburst != 2'b01) ||
                                       (m_awaddr[1:0] != 2'b00) ||
                                       (m_awaddr[25] && m_awaddr[24]);
                        aw_state  <= AW_DATA;
                    end
                end

                AW_DATA: begin
                    if (aw_hs) begin
                        axi_wr_act <= 1'b1;
                        if (aw_bad)
                            axi_error <= 1'b1;

                        // Pixel port: advance write pointer (data written by
                        // separate synchronous block to allow LUTRAM inference)
                        if (aw_to_pixel)
                            pix_wr_ptr <= pix_wr_ptr + 6'd1;

                        // Ctrl register port (addr[25]=1, addr[24]=0)
                        if (aw_to_ctrl) begin
                            if (aw_addr[3:2] == 2'b00) begin // DEMO_CTRL
                                if (m_wdata[1]) begin  // RESET
                                    enc_running   <= 1'b0;
                                    start_armed   <= 1'b0;
                                    enc_done      <= 1'b0;
                                    axi_error     <= 1'b0;
                                    jpeg_overflow <= 1'b0;
                                    pix_wr_ptr    <= 6'd0;
                                    pix_rd_ptr    <= 6'd0;
                                    pix_count     <= 7'd0;
                                    pix_col       <= 11'd0;
                                    pix_sent      <= 20'd0;
                                    pix_sub       <= 1'b0;
                                    enc_tvalid    <= 1'b0;
                                    jp_phase      <= 2'd0;
                                    jp_wptr       <= 17'd0;
                                    jpeg_byte_cnt <= 19'd0;
                                    flush_pend    <= 1'b0;
                                end
                                if (m_wdata[0]) begin  // START
                                    enc_running   <= 1'b0;
                                    start_armed   <= 1'b1;
                                    enc_done      <= 1'b0;
                                    jpeg_overflow <= 1'b0;
                                    pix_col       <= 11'd0;
                                    pix_sent      <= 20'd0;
                                    pix_sub       <= 1'b0;
                                    enc_tvalid    <= 1'b0;
                                    jp_phase      <= 2'd0;
                                    jp_wptr       <= 17'd0;
                                    jpeg_byte_cnt <= 19'd0;
                                    flush_pend    <= 1'b0;
                                end
                            end else begin
                                axi_error <= 1'b1;
                            end
                        end

                        aw_addr <= aw_addr + 32'd4;
                        if (m_wlast) aw_state <= AW_RESP;
                    end
                end

                AW_RESP: begin
                    m_bresp  <= aw_bad ? 2'b10 : 2'b00;
                    if (!m_bvalid) begin
                        m_bvalid <= 1'b1;
                    end else if (m_bready) begin
                        m_bvalid <= 1'b0;
                        aw_state <= AW_IDLE;
                    end
                end

                default: aw_state <= AW_IDLE;
            endcase

            // ================================================================
            // pix_count: single update handles simultaneous push and pop
            // ================================================================
            if (do_push && !do_pop)
                pix_count <= pix_count + 7'd1;
            else if (!do_push && do_pop)
                pix_count <= pix_count - 7'd1;

            if (start_armed && !enc_running && (pix_count >= PIX_PREFILL[6:0])) begin
                enc_running <= 1'b1;
                start_armed <= 1'b0;
            end

            // ================================================================
            // JPEG capture control (data written by separate BRAM block above)
            // ================================================================
            flush_pend <= 1'b0;  // default: clear (set for one cycle below if needed)
            if (jpg_tvalid && enc_running) begin
                if (jpeg_byte_room) begin
                    jpeg_byte_cnt <= jpeg_byte_cnt + 19'd1;
                    case (jp_phase)
                        2'd0: jp_accum[7:0]   <= jpg_tdata;
                        2'd1: jp_accum[15:8]  <= jpg_tdata;
                        2'd2: jp_accum[23:16] <= jpg_tdata;
                        2'd3: begin
                            if (jpeg_word_room)
                                jp_wptr <= jp_wptr + 17'd1;
                        end
                    endcase
                    jp_phase <= jp_phase + 2'd1;
                end else begin
                    jpeg_overflow <= 1'b1;
                end
                if (jpg_tlast) begin
                    enc_running <= 1'b0;
                    start_armed <= 1'b0;
                    enc_done    <= 1'b1;
                    // If the stream ends mid-word (jp_phase != 3), the partial
                    // accumulator was not written to BRAM. Flush it next cycle.
                    if (jp_phase != 2'd3 && jpeg_word_room && !jpeg_overflow)
                        flush_pend <= 1'b1;
                end
            end

            // ================================================================
            // Pixel pump — drains FIFO into encoder AXI-Stream
            // ================================================================
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

        end // rst_n else
    end // always

    // -----------------------------------------------------------------------
    // AXI4 Read slave FSM (reads JPEG BRAM + ctrl registers)
    // -----------------------------------------------------------------------
    localparam [2:0] AR_IDLE=3'd0, AR_PRE=3'd1, AR_DATA=3'd2;
    reg [2:0]  ar_state;
    reg [31:0] ar_addr;
    reg [7:0]  ar_rem;
    reg [16:0] ar_widx;   // declared here; referenced in jpeg_rd_data block above
    reg        ar_bad;
    reg        ar_to_jpeg;

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
            ar_widx   <= 17'd0;
            ar_bad    <= 1'b0;
            ar_to_jpeg <= 1'b0;
            axi_rd_error_pulse <= 1'b0;
        end else begin
            m_arready <= 1'b0;
            axi_rd_error_pulse <= 1'b0;

            case (ar_state)
                AR_IDLE: begin
                    m_rvalid <= 1'b0;
                    if (m_arvalid) begin
                        m_arready <= 1'b1;
                        ar_addr   <= m_araddr;
                        ar_rem    <= m_arlen;
                        ar_widx   <= (m_araddr - AXI_JPEG_BASE) >> 2;
                        ar_to_jpeg <= m_araddr[25] && m_araddr[24];
                        ar_bad    <= (m_arsize != 3'b010) ||
                                     (m_arburst != 2'b01) ||
                                     (m_araddr[1:0] != 2'b00) ||
                                     (!m_araddr[25]) ||
                                     ((m_araddr[25] && m_araddr[24]) &&
                                      ((((m_araddr - AXI_JPEG_BASE) >> 2) + {24'd0, m_arlen}) >= JPEG_WORDS[31:0]));
                        ar_state  <= AR_PRE;
                    end
                end

                AR_PRE: begin
                    // BRAM read issued (jpeg_rd_data <= jpeg_mem[ar_widx] runs
                    // this cycle); result available at start of AR_DATA.
                    ar_state <= AR_DATA;
                end

                AR_DATA: begin
                    if (ar_bad) begin
                        m_rdata <= 32'd0;
                        axi_rd_error_pulse <= 1'b1;
                    end else if (ar_to_jpeg) begin
                        // JPEG port: use registered BRAM output
                        m_rdata <= jpeg_rd_data;
                    end else begin
                        // Ctrl registers (enc_done / jpeg_byte_cnt)
                        case (ar_addr[3:2])
                            2'd0: m_rdata <= {27'd0, start_armed, enc_running, axi_error, jpeg_overflow, enc_done};
                            2'd1: m_rdata <= {13'd0, jpeg_byte_cnt};
                            2'd2: m_rdata <= JPEG_BYTES[31:0];
                            default: m_rdata <= 32'd0;
                        endcase
                    end
                    m_rvalid <= 1'b1;
                    m_rlast  <= (ar_rem == 8'd0);
                    m_rresp  <= ar_bad ? 2'b10 : 2'b00;

                    if (m_rvalid && m_rready) begin
                        if (ar_rem == 8'd0) begin
                            m_rvalid <= 1'b0;
                            m_rlast  <= 1'b0;
                            ar_state <= AR_IDLE;
                        end else begin
                            ar_addr  <= ar_addr + 32'd4;
                            ar_widx  <= ar_widx + 17'd1;
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
    // LED outputs
    // -----------------------------------------------------------------------
    reg [25:0] hb_cnt;
    reg        hb_toggle;
    always @(posedge clk) begin
        if (hb_cnt == 26'd49_999_999) begin
            hb_cnt   <= 26'd0;
            hb_toggle <= ~hb_toggle;
        end else
            hb_cnt <= hb_cnt + 26'd1;
    end

    assign led0 = hb_toggle;    // heartbeat 1.5 Hz
    assign led1 = start_armed || enc_running;
    assign led2 = enc_done;
    assign led3 = axi_wr_act;

endmodule
