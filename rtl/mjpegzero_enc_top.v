// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// mjpegZero Top-Level
// ============================================================================
// Top-level module integrating the full JPEG encoding pipeline.
//
// Interfaces:
//   - AXI4-Stream Slave: 16-bit YUYV input video
//   - AXI4-Stream Master: 8-bit JPEG compressed output
//   - AXI4-Lite Slave: Control/status registers
//
// Pipeline:
//   Input Buffer -> 2D DCT -> Quantizer -> Zigzag -> Huffman -> Bitstream -> JFIF
//
// Improvements over v1:
//   - FIFO-based comp_id tracking through pipeline
//   - Backpressure propagation from bitstream packer to Huffman
//   - Runtime quality factor via AXI4-Lite
//   - Restart marker support
//   - Frame byte count reporting
//   - Dynamic JFIF headers (Q-tables read from quantizer)
// ============================================================================

module mjpegzero_enc_top #(
    parameter LITE_MODE     = 1,                           // 0 = runtime AXI quality, 1 = fixed synthesis-time quality
    parameter LITE_QUALITY  = 95,                          // Quality 1-100, used when LITE_MODE=1
    parameter IMG_WIDTH     = 1280,                        // image width in pixels, independent of LITE_MODE
    parameter IMG_HEIGHT    = 720,                         // image height in pixels, independent of LITE_MODE
    parameter EXIF_ENABLE   = 0,                           // 1 = embed APP1/EXIF segment after APP0
    parameter EXIF_X_RES    = 72,                          // X resolution numerator (DPI if EXIF_RES_UNIT=2)
    parameter EXIF_Y_RES    = 72,                          // Y resolution numerator
    parameter EXIF_RES_UNIT = 2,                           // 1=no unit, 2=inch, 3=cm
    parameter RGB_INPUT     = 0,                           // 1 = 24-bit RGB AXI4-Stream input; 0 = 16-bit YUYV
    parameter HUFF_BANKS    = 8,                            // Huffman input-ring depth (blocks in flight): 2, 4, or 8 only; higher = more throughput, more LUTRAM
    parameter VID_DATA_W    = RGB_INPUT ? 24 : 16          // video input data width (derived, do not override)
) (
    input  wire        clk,
    input  wire        rst_n,

    // AXI4-Stream Slave - Video Input (16-bit YUYV when RGB_INPUT=0, 24-bit RGB when RGB_INPUT=1)
    input  wire [VID_DATA_W-1:0] s_axis_vid_tdata,
    input  wire        s_axis_vid_tvalid,
    output wire        s_axis_vid_tready,
    input  wire        s_axis_vid_tlast,
    input  wire        s_axis_vid_tuser,

    // AXI4-Stream Master - JPEG Output (8-bit, no backpressure)
    output wire        m_axis_jpg_tvalid,
    output wire [7:0]  m_axis_jpg_tdata,
    output wire        m_axis_jpg_tlast,

    // AXI4-Lite Slave - Register Interface (5-bit address)
    input  wire [4:0]  s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [4:0]  s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready
);

    initial begin
        if (IMG_WIDTH <= 0 || IMG_HEIGHT <= 0) begin
            $display("ERROR: IMG_WIDTH and IMG_HEIGHT must be positive");
            $finish;
        end
        if ((IMG_WIDTH % 16) != 0) begin
            $display("ERROR: IMG_WIDTH must be a multiple of 16 for 4:2:2 MCUs");
            $finish;
        end
        if ((IMG_HEIGHT % 8) != 0) begin
            $display("ERROR: IMG_HEIGHT must be a multiple of 8");
            $finish;
        end
        if (LITE_QUALITY < 1 || LITE_QUALITY > 100) begin
            $display("ERROR: LITE_QUALITY must be in the range 1..100");
            $finish;
        end
        if (EXIF_RES_UNIT < 1 || EXIF_RES_UNIT > 3) begin
            $display("ERROR: EXIF_RES_UNIT must be 1, 2, or 3");
            $finish;
        end
    end

    // ========================================================================
    // Control/Status
    // ========================================================================
    wire        ctrl_enable;
    wire        ctrl_soft_reset;
    wire [6:0]  ctrl_quality;
    wire [15:0] ctrl_restart_interval;
    wire        sts_busy;
    wire        sts_frame_done_pulse;
    reg  [31:0] frame_cnt;

    // Internal reset (combined)
    wire rst_int_n = rst_n & ~ctrl_soft_reset;

    // ========================================================================
    // Forward declarations for all pipeline wires
    // (Verilog 2001 requires declarations before use)
    // ========================================================================

    // Input buffer -> DCT
    wire        ibuf_blk_valid;
    wire [7:0]  ibuf_blk_data;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        ibuf_blk_sof;      // informational; frames are sequenced by block count
    /* verilator lint_on UNUSEDSIGNAL */
    wire        ibuf_blk_sob;
    wire [1:0]  ibuf_blk_comp;
    wire        ibuf_blk_ready;
    wire        ibuf_blk_start;    // Admission: may begin a new block
    wire        ibuf_blk_avail;    // A strip is buffered, blocks waiting

    // DCT input conversion (level shift: unsigned 0-255 -> signed -128..127)
    wire signed [11:0] dct_in_data = $signed({4'b0, ibuf_blk_data}) - 12'sd128;
    wire        dct_in_valid = ibuf_blk_valid;
    wire        dct_in_sof   = ibuf_blk_sob; // DCT uses sof as block start

    // DCT -> Quantizer
    wire        dct_out_valid;
    wire signed [15:0] dct_out_data;
    wire        dct_out_sof;  // Start of output block

    // Quantizer -> Zigzag
    wire        quant_out_valid;
    wire signed [15:0] quant_out_data;
    wire        quant_out_sob;

    // Zigzag -> Huffman
    wire        zz_out_valid;
    wire signed [15:0] zz_out_data;
    wire        zz_out_sob;

    // Huffman -> Bitstream packer
    wire        huff_out_valid;
    wire [31:0] huff_out_bits;
    wire [5:0]  huff_out_len;
    wire        huff_out_eob;
    wire        huff_bp_ready;  // Backpressure from bitstream packer

    // Bitstream packer -> JFIF writer
    wire        bs_out_valid;
    wire [7:0]  bs_out_data;
    wire        bs_out_last;
    wire        bs_out_ready;

    // Q-table read port (quantizer -> JFIF writer)
    wire [5:0]  qt_rd_addr;
    wire        qt_rd_is_chroma;
    wire [7:0]  qt_rd_data;

    // JFIF writer status
    wire        jfif_headers_done;

    // Quantizer status: Q tables not yet rebuilt for frame_quality
    wire        q_tables_busy;

    // ========================================================================
    // Component ID tracking through pipeline
    // ========================================================================
    // The input buffer tells us which component each block belongs to
    // (0=Y0, 1=Y1, 2=Cb, 3=Cr). We need to delay this to match the
    // DCT + quantizer + zigzag pipeline latency.
    //
    // Instead of a fragile fixed delay, use a small FIFO:
    //   Push: when ibuf_blk_sob (start of block from input buffer)
    //   Pop for quantizer: when dct_out_sof (start of block from DCT output)
    //   Pop for huffman: when zz_out_sob (start of block from zigzag output)
    //
    // We need two separate tracking paths:
    //   1. ibuf -> (DCT latency) -> quantizer comp_id
    //   2. ibuf -> (DCT + quant + zigzag latency) -> huffman comp_id
    //
    // Simple shift-register FIFO (max 4 blocks in flight)

    // --- Comp ID FIFO for quantizer (through DCT) ---
    reg [1:0] comp_fifo_q [0:3];
    reg [2:0] comp_fifo_q_wr, comp_fifo_q_rd;

    always @(posedge clk) begin
        if (!rst_int_n) begin
            comp_fifo_q_wr <= 3'd0;
            comp_fifo_q_rd <= 3'd0;
        end else begin
            if (ibuf_blk_valid && ibuf_blk_sob) begin
                comp_fifo_q[comp_fifo_q_wr[1:0]] <= ibuf_blk_comp;
                comp_fifo_q_wr <= comp_fifo_q_wr + 3'd1;
            end
            if (dct_out_valid && dct_out_sof) begin
                comp_fifo_q_rd <= comp_fifo_q_rd + 3'd1;
            end
        end
    end

    wire [1:0] quant_comp_id = comp_fifo_q[comp_fifo_q_rd[1:0]];

    // --- Comp ID FIFO for Huffman (through DCT + quant + zigzag) ---
    reg [1:0] comp_fifo_h [0:7];
    reg [3:0] comp_fifo_h_wr, comp_fifo_h_rd;

    always @(posedge clk) begin
        if (!rst_int_n) begin
            comp_fifo_h_wr <= 4'd0;
            comp_fifo_h_rd <= 4'd0;
        end else begin
            if (ibuf_blk_valid && ibuf_blk_sob) begin
                comp_fifo_h[comp_fifo_h_wr[2:0]] <= ibuf_blk_comp;
                comp_fifo_h_wr <= comp_fifo_h_wr + 4'd1;
            end
            if (zz_out_valid && zz_out_sob) begin
                comp_fifo_h_rd <= comp_fifo_h_rd + 4'd1;
            end
        end
    end

    wire [1:0] huff_comp_id = comp_fifo_h[comp_fifo_h_rd[2:0]];

    // ========================================================================
    // Frame control
    // ========================================================================
    // One frame at a time through the pipeline:
    //   F_IDLE : wait until a strip is buffered (and ENABLE), then latch the
    //            frame's QUALITY/RESTART so a register write mid-frame cannot
    //            desync the tables from the header already sent
    //   F_QWAIT: wait for the quantizer to rebuild its Q tables, then start
    //            the JFIF headers
    //   F_RUN  : admit exactly TOTAL_BLOCKS blocks (block-granular)
    //   F_DRAIN: wait for the last EOB (frame_done) and for the JFIF writer to
    //            finish EOI and return to idle, then take the next frame
    // Admitting by count keeps every JPEG well formed even when the next
    // frame's strips are already buffered (back-to-back input).
    localparam  TOTAL_BLOCKS = (IMG_WIDTH / 16) * (IMG_HEIGHT / 8) * 4;  // 4 blocks per MCU
    localparam  BLK_W = $clog2(TOTAL_BLOCKS + 1);
    localparam integer     LAST_BLOCK_I = TOTAL_BLOCKS - 1;
    localparam [BLK_W-1:0] LAST_BLOCK   = LAST_BLOCK_I[BLK_W-1:0];

    localparam [1:0] F_IDLE  = 2'd0,
                     F_QWAIT = 2'd1,
                     F_RUN   = 2'd2,
                     F_DRAIN = 2'd3;
    reg  [1:0]       fstate;
    reg              done_seen;

    reg         frame_active;
    reg         frame_start_pulse;
    reg         frame_done_pulse;
    reg [BLK_W-1:0] mcu_count;    // Blocks completed (Huffman EOB) in current frame
    reg [BLK_W-1:0] adm_count;    // Blocks admitted into the pipeline in current frame

    // Per-frame control snapshot
    reg  [6:0]  frame_quality;
    reg  [15:0] frame_restart;
    wire [6:0]  quality_clamped = (ctrl_quality == 7'd0)   ? 7'd1   :
                                  (ctrl_quality > 7'd100) ? 7'd100 : ctrl_quality;

    // Restart marker tracking
    reg [15:0]  mcu_in_segment;    // MCU count within current restart segment
    reg         restart_trigger;   // Pulse to insert restart marker

    wire blk_emerge = ibuf_blk_valid && ibuf_blk_sob;   // a block enters the DCT

    always @(posedge clk) begin
        if (!rst_int_n) begin
            fstate            <= F_IDLE;
            done_seen         <= 1'b0;
            frame_active      <= 1'b0;
            frame_start_pulse <= 1'b0;
            frame_done_pulse  <= 1'b0;
            frame_cnt         <= 32'd0;
            mcu_count         <= {BLK_W{1'b0}};
            adm_count         <= {BLK_W{1'b0}};
            mcu_in_segment    <= 16'd0;
            restart_trigger   <= 1'b0;
            frame_quality     <= 7'd95;
            frame_restart     <= 16'd0;
        end else begin
            frame_start_pulse <= 1'b0;
            frame_done_pulse  <= 1'b0;
            restart_trigger   <= 1'b0;

            case (fstate)
                F_IDLE: begin
                    if (ctrl_enable && ibuf_blk_avail) begin
                        frame_quality <= quality_clamped;
                        frame_restart <= ctrl_restart_interval;
                        fstate        <= F_QWAIT;
                    end
                end
                F_QWAIT: begin
                    // tables_busy sees frame_quality this cycle (registered above)
                    if (!q_tables_busy) begin
                        frame_start_pulse <= 1'b1;
                        frame_active      <= 1'b1;
                        adm_count         <= {BLK_W{1'b0}};
                        fstate            <= F_RUN;
                    end
                end
                F_RUN: begin
                    if (blk_emerge) begin
                        adm_count <= adm_count + 1'b1;
                        if (adm_count == LAST_BLOCK)
                            fstate <= F_DRAIN;
                    end
                end
                F_DRAIN: begin
                    if (frame_done_pulse)
                        done_seen <= 1'b1;
                    // headers_done drops only when the writer is back in idle,
                    // i.e. after this frame's EOI
                    if (done_seen && !jfif_headers_done) begin
                        done_seen <= 1'b0;
                        fstate    <= F_IDLE;
                    end
                end
                default: fstate <= F_IDLE;
            endcase

            // Count completed blocks via Huffman EOB
            // CRITICAL: Must check huff_bp_ready too! The Huffman encoder
            // holds out_valid=1, out_eob=1 for multiple cycles while waiting
            // for the bitstream packer to drain. Without bp_ready, mcu_count
            // increments every cycle, causing frame_done_pulse to fire early
            // and the packer to flush before all blocks are encoded.
            if (huff_out_eob && huff_out_valid && huff_bp_ready) begin
                mcu_count <= mcu_count + 1'b1;

                // Every 4 blocks = 1 MCU completion
                if (mcu_count[1:0] == 2'd3) begin
                    // Check restart interval — skip on last MCU to avoid
                    // restart_trigger colliding with frame_done_pulse (both
                    // asserted same cycle causes packer to emit RST instead of EOI)
                    if (frame_restart != 16'd0 && mcu_count != LAST_BLOCK) begin
                        if (mcu_in_segment + 16'd1 >= frame_restart) begin
                            restart_trigger <= 1'b1;
                            mcu_in_segment  <= 16'd0;
                        end else begin
                            mcu_in_segment <= mcu_in_segment + 16'd1;
                        end
                    end
                end

                // Frame complete
                if (mcu_count == LAST_BLOCK) begin
                    mcu_count        <= {BLK_W{1'b0}};
                    mcu_in_segment   <= 16'd0;
                    frame_active     <= 1'b0;
                    frame_done_pulse <= 1'b1;
                    frame_cnt        <= frame_cnt + 32'd1;
                end
            end
        end
    end

    assign sts_busy = frame_active;
    assign sts_frame_done_pulse = frame_done_pulse;

    // ========================================================================
    // Pipeline flow control
    // A new block may start (block-granular, see input_buffer blk_start) when:
    //   1. Encoder is enabled
    //   2. The frame FSM is admitting and the JFIF headers have been written
    //   3. Pipeline is not full (at most HUFF_BANKS blocks in flight)
    // The Huffman encoder has an NB=HUFF_BANKS-deep input ring. We cap blocks
    // in flight at HUFF_BANKS to prevent ring overflow when the Huffman takes
    // many cycles to process complex blocks. A started block always runs to
    // completion, so the DCT never sees a partial block.
    // ========================================================================

    // HUFF_BANKS must be 2, 4 or 8: pipeline_depth below is 4 bits (so the cap
    // 0..8 cannot wrap) and the Huffman bank ring assumes a power-of-two <= 8.
    // Reject any other value at elaboration (mirrored in huffman_encoder)
    // instead of silently wrapping the counter / indexing nonexistent banks.
    generate if (HUFF_BANKS != 2 && HUFF_BANKS != 4 && HUFF_BANKS != 8)
        begin : g_huff_banks_check
            HUFF_BANKS_must_be_2_4_or_8 illegal_huff_banks_value();
        end
    endgenerate

    localparam [3:0] HUFF_BANKS_CAP = HUFF_BANKS[3:0];
    reg [3:0] pipeline_depth;

    always @(posedge clk) begin
        if (!rst_int_n) begin
            pipeline_depth <= 4'd0;
        end else begin
            // Count every block that actually enters the DCT (not gated by
            // the admission signal, which runs a few cycles ahead of the
            // input buffer's output pipeline), so the count cannot wrap.
            case ({blk_emerge,
                   huff_out_eob && huff_out_valid && huff_bp_ready})
                2'b10: pipeline_depth <= pipeline_depth + 4'd1;
                2'b01: pipeline_depth <= pipeline_depth - 4'd1;
                default: ; // no change or balanced
            endcase
        end
    end

    // Admit blocks until HUFF_BANKS are in flight. This MUST match the Huffman's
    // input-ring depth so the ring (which zigzag cannot backpressure) never
    // overflows. Deeper = the DCT/zigzag run ahead and keep the Huffman fed.
    // The in-flight count updates 4 cycles after a block's first sample is
    // issued, well before the next block (64 samples later) asks to start.
    assign ibuf_blk_ready = 1'b1;
    assign ibuf_blk_start = ctrl_enable && (fstate == F_RUN) && jfif_headers_done &&
                            (pipeline_depth < HUFF_BANKS_CAP);

    // ========================================================================
    // Video input path (YUYV pass-through or RGB→YUYV via rgb_to_ycbcr)
    // ========================================================================
    wire [15:0] vid_yuyv_tdata;
    wire        vid_yuyv_tvalid;
    wire        vid_yuyv_tready;  // driven by input_buffer
    wire        vid_yuyv_tlast;
    wire        vid_yuyv_tuser;

    generate
        if (RGB_INPUT) begin : g_rgb_input
            // ENABLE=0 stalls the stream (no handshake) rather than
            // accepting and dropping pixels.
            wire rgb_tready;
            assign s_axis_vid_tready = rgb_tready & ctrl_enable;
            // 24-bit {R,G,B} AXI4-Stream → 16-bit YUYV (3-cycle pipeline)
            rgb_to_ycbcr u_rgb2yuv (
                .clk          (clk),
                .rst_n        (rst_int_n),
                .s_axis_tdata (s_axis_vid_tdata),
                .s_axis_tvalid(s_axis_vid_tvalid & ctrl_enable),
                .s_axis_tready(rgb_tready),
                .s_axis_tlast (s_axis_vid_tlast),
                .s_axis_tuser (s_axis_vid_tuser),
                .m_axis_tdata (vid_yuyv_tdata),
                .m_axis_tvalid(vid_yuyv_tvalid),
                .m_axis_tready(vid_yuyv_tready),
                .m_axis_tlast (vid_yuyv_tlast),
                .m_axis_tuser (vid_yuyv_tuser)
            );
        end else begin : g_yuyv_input
            // YUYV input: pass through; ENABLE=0 stalls (tready low)
            assign s_axis_vid_tready = vid_yuyv_tready & ctrl_enable;
            assign vid_yuyv_tdata    = s_axis_vid_tdata[15:0];
            assign vid_yuyv_tvalid   = s_axis_vid_tvalid & ctrl_enable;
            assign vid_yuyv_tlast    = s_axis_vid_tlast;
            assign vid_yuyv_tuser    = s_axis_vid_tuser;
        end
    endgenerate

    // ========================================================================
    // FRAME_SIZE: total JPEG bytes (SOI..EOI) of the last completed frame
    // ========================================================================
    reg [31:0] jpg_byte_cnt;
    reg [31:0] last_frame_size;

    always @(posedge clk) begin
        if (!rst_int_n) begin
            jpg_byte_cnt    <= 32'd0;
            last_frame_size <= 32'd0;
        end else if (m_axis_jpg_tvalid) begin
            if (m_axis_jpg_tlast) begin
                last_frame_size <= jpg_byte_cnt + 32'd1;
                jpg_byte_cnt    <= 32'd0;
            end else begin
                jpg_byte_cnt <= jpg_byte_cnt + 32'd1;
            end
        end
    end

    // ========================================================================
    // Module instantiations
    // ========================================================================

    // --- AXI4-Lite Register Interface ---
    axi4_lite_regs #(
        .LITE_MODE  (LITE_MODE)
    ) u_regs (
        .clk                  (clk),
        .rst_n                (rst_n),
        .s_axi_awaddr         (s_axi_awaddr),
        .s_axi_awvalid        (s_axi_awvalid),
        .s_axi_awready        (s_axi_awready),
        .s_axi_wdata          (s_axi_wdata),
        .s_axi_wstrb          (s_axi_wstrb),
        .s_axi_wvalid         (s_axi_wvalid),
        .s_axi_wready         (s_axi_wready),
        .s_axi_bresp          (s_axi_bresp),
        .s_axi_bvalid         (s_axi_bvalid),
        .s_axi_bready         (s_axi_bready),
        .s_axi_araddr         (s_axi_araddr),
        .s_axi_arvalid        (s_axi_arvalid),
        .s_axi_arready        (s_axi_arready),
        .s_axi_rdata          (s_axi_rdata),
        .s_axi_rresp          (s_axi_rresp),
        .s_axi_rvalid         (s_axi_rvalid),
        .s_axi_rready         (s_axi_rready),
        .ctrl_enable          (ctrl_enable),
        .ctrl_soft_reset      (ctrl_soft_reset),
        .ctrl_quality         (ctrl_quality),
        .ctrl_restart_interval(ctrl_restart_interval),
        .sts_busy             (sts_busy),
        .sts_frame_done_pulse (sts_frame_done_pulse),
        .sts_frame_cnt        (frame_cnt),
        .sts_frame_size       (last_frame_size)
    );

    // --- Input Buffer ---
    input_buffer #(
        .IMG_WIDTH  (IMG_WIDTH)
    ) u_input_buffer (
        .clk           (clk),
        .rst_n         (rst_int_n),
        .s_axis_tdata  (vid_yuyv_tdata),
        .s_axis_tvalid (vid_yuyv_tvalid),
        .s_axis_tready (vid_yuyv_tready),
        .s_axis_tlast  (vid_yuyv_tlast),
        .s_axis_tuser  (vid_yuyv_tuser),
        .blk_valid     (ibuf_blk_valid),
        .blk_data      (ibuf_blk_data),
        .blk_sof       (ibuf_blk_sof),
        .blk_sob       (ibuf_blk_sob),
        .blk_comp      (ibuf_blk_comp),
        .blk_ready     (ibuf_blk_ready),
        .blk_start     (ibuf_blk_start),
        /* verilator lint_off PINCONNECTEMPTY */
        .lines_done    (),
        /* verilator lint_on PINCONNECTEMPTY */
        .blk_avail     (ibuf_blk_avail)
    );

    // --- 2D DCT ---
    dct_2d u_dct (
        .clk       (clk),
        .rst_n     (rst_int_n),
        .in_valid  (dct_in_valid),
        .in_data   (dct_in_data),
        .in_sof    (dct_in_sof),
        .out_valid (dct_out_valid),
        .out_data  (dct_out_data),
        .out_sof   (dct_out_sof)
    );

    // --- Quantizer ---
    quantizer #(
        .LITE_MODE    (LITE_MODE),
        .LITE_QUALITY (LITE_QUALITY)
    ) u_quantizer (
        .clk            (clk),
        .rst_n          (rst_int_n),
        .comp_id        (quant_comp_id),
        .quality        (frame_quality),
        .in_valid       (dct_out_valid),
        .in_data        (dct_out_data),
        .in_sof         (dct_out_sof),
        .in_sob         (dct_out_sof),
        .out_valid      (quant_out_valid),
        .out_data       (quant_out_data),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_sof        (),
        /* verilator lint_on PINCONNECTEMPTY */
        .out_sob        (quant_out_sob),
        .qt_rd_addr     (qt_rd_addr),
        .qt_rd_is_chroma(qt_rd_is_chroma),
        .qt_rd_data     (qt_rd_data),
        .tables_busy    (q_tables_busy)
    );

    // --- Zigzag Reorder ---
    zigzag_reorder u_zigzag (
        .clk       (clk),
        .rst_n     (rst_int_n),
        .in_valid  (quant_out_valid),
        .in_data   (quant_out_data),
        .in_sob    (quant_out_sob),
        .out_valid (zz_out_valid),
        .out_data  (zz_out_data),
        .out_sob   (zz_out_sob)
    );

    // --- Huffman Encoder ---
    huffman_encoder #(
        .HUFF_BANKS (HUFF_BANKS)
    ) u_huffman (
        .clk       (clk),
        .rst_n     (rst_int_n),
        .comp_id   (huff_comp_id),
        // DC predictors must reset at every start-of-scan (= each frame) as well
        // as at RST markers (JPEG spec). Without a per-frame reset the predictor
        // carries the previous frame's last DC into the next frame, corrupting its
        // first DC diff and washing out luma contrast (frame 0 OK, frames 1+ washed).
        // We use frame_done_pulse (not frame_start_pulse) so the reset is aligned to
        // the Huffman's own last-block EOB: it always lands AFTER this frame's last
        // block and BEFORE the next frame's first block, regardless of how the pixel
        // source pipelines frames upstream (frame_start_pulse fires early, when 8
        // lines are buffered, and could race a not-yet-drained previous frame).
        // Frame 0 is covered by global reset; frames 1+ by the preceding frame_done.
        // This only feeds the Huffman predictor reset; the packer's RST-marker path
        // (in_restart) stays restart_trigger, so no spurious RST marker is emitted.
        .restart   (restart_trigger || frame_done_pulse),
        .in_valid  (zz_out_valid),
        .in_data   (zz_out_data),
        .in_sob    (zz_out_sob),
        .out_valid (huff_out_valid),
        .out_bits  (huff_out_bits),
        .out_len   (huff_out_len),
        /* verilator lint_off PINCONNECTEMPTY */
        .out_sob   (),
        /* verilator lint_on PINCONNECTEMPTY */
        .out_eob   (huff_out_eob),
        .out_ready (huff_bp_ready)
    );

    // --- Bitstream Packer ---
    bitstream_packer u_bitpacker (
        .clk        (clk),
        .rst_n      (rst_int_n),
        .in_valid   (huff_out_valid),
        .in_bits    (huff_out_bits),
        .in_len     (huff_out_len),
        .in_flush   (frame_done_pulse),
        .in_restart (restart_trigger),
        .bp_ready   (huff_bp_ready),
        .out_valid  (bs_out_valid),
        .out_data   (bs_out_data),
        .out_last   (bs_out_last),
        .out_ready  (bs_out_ready),
        /* verilator lint_off PINCONNECTEMPTY */
        .byte_count ()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    // --- JFIF Writer ---
    jfif_writer #(
        .IMG_WIDTH    (IMG_WIDTH),
        .IMG_HEIGHT   (IMG_HEIGHT),
        .LITE_MODE    (LITE_MODE),
        .LITE_QUALITY (LITE_QUALITY),
        .EXIF_ENABLE   (EXIF_ENABLE),
        .EXIF_X_RES    (EXIF_X_RES),
        .EXIF_Y_RES    (EXIF_Y_RES),
        .EXIF_RES_UNIT (EXIF_RES_UNIT)
    ) u_jfif (
        .clk              (clk),
        .rst_n            (rst_int_n),
        .frame_start      (frame_start_pulse),
        .frame_done       (frame_done_pulse),
        .restart_interval (frame_restart),
        .qt_rd_addr       (qt_rd_addr),
        .qt_rd_is_chroma  (qt_rd_is_chroma),
        .qt_rd_data       (qt_rd_data),
        .scan_valid       (bs_out_valid),
        .scan_data        (bs_out_data),
        .scan_last        (bs_out_last),
        .scan_ready       (bs_out_ready),
        .m_axis_tvalid    (m_axis_jpg_tvalid),
        .m_axis_tdata     (m_axis_jpg_tdata),
        .m_axis_tlast     (m_axis_jpg_tlast),
        .headers_done     (jfif_headers_done)
    );

endmodule
