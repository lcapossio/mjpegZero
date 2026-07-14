// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// debayer — Malvar-He-Cutler 5x5 gradient-corrected demosaic
//
// Function
//   Reconstructs full RGB from a Bayer mosaic using the MHC linear kernels
//   (Malvar, He, Cutler, ICASSP 2004), all normalized to a common /16 scale:
//   every interpolated sample is one shift-and-add convolution, rounded once
//   ((acc + 8) >>> 4) and clamped to [0, 2^DATA_W - 1]. Zero multipliers.
//   Boundaries use mirror-2 reflection on both axes, realized by tap
//   selection rather than padding. Bit-exact contract:
//   streamline/verify/debayer_model.py::demosaic_mhc.
//
// Interface
//   Valid-only stream in: one Bayer sample per clock, raster order, s_sof on
//   each frame's first pixel; bayer_phase {py, px} is sampled at s_sof and
//   gives the color of pixel (0,0) — 00=R, 01=Gr, 10=Gb, 11=B. Stream out:
//   one RGB pixel per clock, raster order, m_sof on the first.
//
// Contract
//   Four IMG_WIDTH-deep line memories buffer the window; output row cy
//   emerges while input row cy+2 streams, so latency is two lines plus a
//   small pipeline. The stream may gap anywhere, with two requirements any
//   blanked sensor source meets: at least 2 idle cycles after each line's
//   last sample (the mirrored line-tail outputs occupy them) and at least
//   2*(IMG_WIDTH+6) + 8 idle cycles after the frame's last sample (the
//   final two output rows self-pace from the line memories, each preceded
//   by a short drain pause for the previous row's mirrored tail).
// -----------------------------------------------------------------------------

module debayer #(
    parameter DATA_W     = 12,
    parameter IMG_WIDTH  = 1920,
    parameter IMG_HEIGHT = 1080
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [1:0]  bayer_phase,   // {py, px}: color at (0,0)

    input  wire        s_valid,
    input  wire [DATA_W-1:0] s_data,
    input  wire        s_sof,

    output reg         m_valid,
    output reg  [DATA_W-1:0] m_r,
    output reg  [DATA_W-1:0] m_g,
    output reg  [DATA_W-1:0] m_b,
    output reg         m_sof
);

    localparam XW = $clog2(IMG_WIDTH);
    localparam YW = $clog2(IMG_HEIGHT);
    localparam signed [XW+1:0] W = IMG_WIDTH;
    localparam signed [YW+1:0] H = IMG_HEIGHT;

    // mirror2(i, n) = reflected index for one axis (period 2n-2).
    function signed [XW+1:0] mirror2x;
        input signed [XW+1:0] i;
        mirror2x = (i < 0) ? -i : (i >= W) ? (W + W - 2 - i) : i;
    endfunction

    function signed [YW+1:0] mirror2y;
        input signed [YW+1:0] i;
        mirror2y = (i < 0) ? -i : (i >= H) ? (H + H - 2 - i) : i;
    endfunction

    // ========================================================================
    // Frame sequencing. Push beats read the line memories and advance the
    // column window; the source paces them while streaming, and the frame
    // flush (final two output rows) self-paces one per clock. Each line's
    // final two outputs (mirrored right edge) need no new columns and run
    // as tail beats in the two cycles after the line's last push.
    // ========================================================================
    localparam S_STREAM = 2'd0,   // rows 0 .. H-1 arriving
               S_FLUSH  = 2'd1,   // self-paced rows serving cy = H-2, H-1
               S_IDLE   = 2'd2,   // frame done, awaiting s_sof
               S_PAUSE  = 2'd3;   // drain a finished row's two tail outputs
                                  // before the next self-paced row pushes

    reg [1:0]          state;
    reg [1:0]          pause_cnt;
    reg                pause_done;   // the row after the pause ends the frame
    reg [XW-1:0]       in_x;       // input/push column
    reg [YW-1:0]       in_y;       // input line (frozen at H-1 in flush)
    reg                fl_line;    // which flush row (0 -> cy=H-2)
    reg [1:0]          ph;         // latched {py, px}

    wire sof_accept = s_valid && s_sof;
    wire push_beat  = (state == S_STREAM) ? s_valid :
                      (state == S_FLUSH);
    wire line_end   = push_beat && (in_x == IMG_WIDTH - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            ph    <= 2'd0;
        end else if (sof_accept) begin
            state   <= S_STREAM;
            ph      <= bayer_phase;
            in_x    <= 1;          // this beat is column 0
            in_y    <= 0;
            fl_line <= 0;
        end else begin
            if (state == S_PAUSE) begin
                pause_cnt <= pause_cnt - 2'd1;
                if (pause_cnt == 2'd0)
                    state <= pause_done ? S_IDLE : S_FLUSH;
            end else if (push_beat) begin
                in_x <= line_end ? {XW{1'b0}} : in_x + 1'b1;
                if (line_end) begin
                    if (state == S_STREAM && in_y == IMG_HEIGHT - 1) begin
                        state      <= S_PAUSE;
                        pause_cnt  <= 2'd3;
                        pause_done <= 1'b0;
                    end else if (state == S_STREAM) begin
                        in_y <= in_y + 1'b1;
                    end else begin
                        state      <= S_PAUSE;
                        pause_cnt  <= 2'd3;
                        pause_done <= fl_line;
                        fl_line    <= 1'b1;
                    end
                end
            end
        end
    end

    wire [XW-1:0] beat_x = sof_accept ? {XW{1'b0}} : in_x;

    // ========================================================================
    // Line memories: four IMG_WIDTH-deep RAMs, rotating so the memory being
    // rewritten with line y is the one holding line y-4 (read-before-write
    // returns the old line at the shared column). One-cycle registered read.
    // ========================================================================
    reg [DATA_W-1:0] lram0 [0:IMG_WIDTH-1];
    reg [DATA_W-1:0] lram1 [0:IMG_WIDTH-1];
    reg [DATA_W-1:0] lram2 [0:IMG_WIDTH-1];
    reg [DATA_W-1:0] lram3 [0:IMG_WIDTH-1];
    reg [DATA_W-1:0] lrd0, lrd1, lrd2, lrd3;

    wire        wr_en   = (state == S_STREAM && s_valid) || sof_accept;
    wire [1:0]  wr_bank = sof_accept ? 2'd0 : in_y[1:0];

    always @(posedge clk) begin
        if (wr_en && wr_bank == 2'd0) lram0[beat_x] <= s_data;
        if (wr_en && wr_bank == 2'd1) lram1[beat_x] <= s_data;
        if (wr_en && wr_bank == 2'd2) lram2[beat_x] <= s_data;
        if (wr_en && wr_bank == 2'd3) lram3[beat_x] <= s_data;
        lrd0 <= lram0[beat_x];
        lrd1 <= lram1[beat_x];
        lrd2 <= lram2[beat_x];
        lrd3 <= lram3[beat_x];
    end

    // Beat pipeline stage 1: RAM data and the live sample are aligned here.
    reg              p1_push, p1_sof;
    reg [XW-1:0]     p1_x;
    reg [YW-1:0]     p1_y;
    reg              p1_flush, p1_flline;
    reg [DATA_W-1:0] p1_live;

    always @(posedge clk) begin
        if (!rst_n) begin
            p1_push <= 1'b0;
        end else begin
            p1_push   <= push_beat || sof_accept;
            p1_sof    <= sof_accept;
            p1_x      <= beat_x;
            p1_y      <= sof_accept ? {YW{1'b0}} : in_y;
            p1_flush  <= (state == S_FLUSH) && !sof_accept;
            p1_flline <= fl_line;
            p1_live   <= s_data;
        end
    end

    // Ordered taps, oldest (line y-4) to newest (line y). While streaming,
    // the newest line rides the live sample; during the flush it is line
    // H-1, read back from its memory.
    wire [1:0] bank_of_y = p1_y[1:0];   // memory holding line y (and y-4)
    reg [DATA_W-1:0] tap [0:4];
    integer ti;
    always @(*) begin
        for (ti = 0; ti < 5; ti = ti + 1)
            tap[ti] = {DATA_W{1'b0}};
        case (bank_of_y)                // taps 0..3 = lines y-4 .. y-1
            2'd0: begin tap[0]=lrd0; tap[1]=lrd1; tap[2]=lrd2; tap[3]=lrd3; end
            2'd1: begin tap[0]=lrd1; tap[1]=lrd2; tap[2]=lrd3; tap[3]=lrd0; end
            2'd2: begin tap[0]=lrd2; tap[1]=lrd3; tap[2]=lrd0; tap[3]=lrd1; end
            2'd3: begin tap[0]=lrd3; tap[1]=lrd0; tap[2]=lrd1; tap[3]=lrd2; end
        endcase
        tap[4] = p1_flush ? tap[3] : p1_live;
        if (p1_flush) begin
            // Flush reads use y = H-1: its line is a stored memory, and the
            // ordered taps are lines H-5 .. H-1 exactly as in streaming.
            case (bank_of_y)
                2'd0: tap[4] = lrd0;
                2'd1: tap[4] = lrd1;
                2'd2: tap[4] = lrd2;
                2'd3: tap[4] = lrd3;
            endcase
        end
    end

    // ========================================================================
    // Row mirror: the pushes of one output row select image rows
    // mirror2(cy-2+j) from the ordered taps (position = row - (y-4)); the
    // top and bottom mirrors land on taps that always hold valid lines.
    // ========================================================================
    wire signed [YW+1:0] o_cy_push =
        p1_flush ? (H - 2 + {{YW{1'b0}}, p1_flline})
                 : ($signed({2'b00, p1_y}) - 2);

    // Streaming and flush both leave the ordered taps holding lines
    // y-4 .. y with y = p1_y, so tap position = wanted row - (y-4).
    wire signed [YW+1:0] row_base = $signed({2'b00, p1_y}) - 4;

    reg [DATA_W-1:0] colv [0:4];        // row-mirrored column vector
    // Tap/window positions are proven to land in 0..4 (see the mirror
    // analyses above), so only the low 3 bits of the differences select.
    /* verilator lint_off UNUSEDSIGNAL */
    reg signed [YW+1:0] want_y, row_pos;
    /* verilator lint_on UNUSEDSIGNAL */
    integer rj;
    always @(*) begin
        for (rj = 0; rj < 5; rj = rj + 1) begin
            want_y   = mirror2y(o_cy_push - 2 + $signed(rj[YW+1:0]));
            row_pos  = want_y - row_base;
            colv[rj] = tap[row_pos[2:0]];
        end
    end

    // ========================================================================
    // Column window: five row-mirrored column vectors, newest at index 4
    // (image column p1_x). Line tails and left mirrors are tap selections,
    // so stale columns are never chosen.
    // ========================================================================
    reg [DATA_W-1:0] hist [0:4][0:4];   // [column age 0=oldest][row]
    integer hc, hr;
    always @(posedge clk) begin
        if (p1_push) begin
            for (hc = 0; hc < 4; hc = hc + 1)
                for (hr = 0; hr < 5; hr = hr + 1)
                    hist[hc][hr] <= hist[hc+1][hr];
            for (hr = 0; hr < 5; hr = hr + 1)
                hist[4][hr] <= colv[hr];
        end
    end

    // ========================================================================
    // Output token stream: the push of column x >= 2 yields output column
    // x-2 one cycle later (when the window holds columns x-4..x); each
    // line then appends two tail tokens for the mirrored right edge.
    // ========================================================================
    reg        tk_valid;
    reg        tk_sof;
    reg [XW-1:0] tk_cx;
    // Only parity (Bayer row color) of the output row is consumed here.
    /* verilator lint_off UNUSEDSIGNAL */
    reg signed [YW+1:0] tk_cy;
    /* verilator lint_on UNUSEDSIGNAL */
    reg [XW-1:0] tk_newest;             // image column at window position 4
    reg [1:0]  tail_cnt;
    reg        frame_first;

    always @(posedge clk) begin
        if (!rst_n) begin
            tk_valid    <= 1'b0;
            tail_cnt    <= 2'd0;
            frame_first <= 1'b0;
        end else begin
            tk_valid <= 1'b0;
            if (p1_sof)
                frame_first <= 1'b1;

            if (p1_push && o_cy_push >= 0 && p1_x >= 2) begin
                tk_valid  <= 1'b1;
                tk_sof    <= frame_first;
                tk_cx     <= p1_x - 2;
                tk_cy     <= o_cy_push;
                tk_newest <= p1_x;
                tail_cnt  <= (p1_x == IMG_WIDTH - 1) ? 2'd2 : 2'd0;
                if (frame_first)
                    frame_first <= 1'b0;
            end else if (tail_cnt != 0) begin
                tk_valid  <= 1'b1;
                tk_sof    <= 1'b0;
                tk_cx     <= tk_cx + 1'b1;
                tail_cnt  <= tail_cnt - 2'd1;
            end
        end
    end

    // Column mirror select: window position of image column
    // mirror2(cx-2+i), relative to the newest held column.
    wire signed [XW+1:0] col_base = $signed({2'b00, tk_newest}) - 4;

    reg [DATA_W-1:0] win [0:4][0:4];    // [row][kernel column]
    /* verilator lint_off UNUSEDSIGNAL */
    reg signed [XW+1:0] want_x, col_pos;
    /* verilator lint_on UNUSEDSIGNAL */
    integer wi, wr2;
    always @(*) begin
        for (wi = 0; wi < 5; wi = wi + 1) begin
            want_x  = mirror2x($signed({2'b00, tk_cx}) - 2 + $signed(wi[XW+1:0]));
            col_pos = want_x - col_base;
            for (wr2 = 0; wr2 < 5; wr2 = wr2 + 1)
                win[wr2][wi] = hist[col_pos[2:0]][wr2];
        end
    end

    // ========================================================================
    // MHC kernels (/16 scale, shift-and-add). Accumulators: positive tap
    // weight sums are at most 26/16, negative at most 12/16, so signed
    // DATA_W+6 bits hold every sum.
    // ========================================================================
    localparam AW = DATA_W + 6;

    function signed [AW-1:0] uext;
        input [DATA_W-1:0] v;
        uext = {{(AW-DATA_W){1'b0}}, v};
    endfunction

    function [DATA_W-1:0] rnd_clamp;
        input signed [AW-1:0] acc;
        reg signed [AW-1:0] r;
        begin
            r = (acc + 8) >>> 4;
            rnd_clamp = (r < 0) ? {DATA_W{1'b0}} :
                        (r > $signed({6'd0, {DATA_W{1'b1}}}))
                                ? {DATA_W{1'b1}} : r[DATA_W-1:0];
        end
    endfunction

    // green at a red/blue site: center 8, plus 4(N S E W), minus 2(NN SS EE WW)
    wire signed [AW-1:0] acc_g =
        (uext(win[2][2]) <<< 3)
      + ((uext(win[1][2]) + uext(win[3][2])
        + uext(win[2][1]) + uext(win[2][3])) <<< 2)
      - ((uext(win[0][2]) + uext(win[4][2])
        + uext(win[2][0]) + uext(win[2][4])) <<< 1);

    // red/blue at the opposite chroma site (diagonal kernel):
    // center 12, plus 4(diagonals), minus 3(NN SS EE WW)
    wire signed [AW-1:0] acc_diag =
        (uext(win[2][2]) <<< 3) + (uext(win[2][2]) <<< 2)
      + ((uext(win[1][1]) + uext(win[1][3])
        + uext(win[3][1]) + uext(win[3][3])) <<< 2)
      - (uext(win[0][2]) + uext(win[4][2])
        + uext(win[2][0]) + uext(win[2][4])) * 3;

    // red/blue at green, same-row orientation:
    // center 10, plus 8(E W), plus 1(NN SS), minus 2(diagonals, EE WW)
    wire signed [AW-1:0] acc_row =
        (uext(win[2][2]) <<< 3) + (uext(win[2][2]) <<< 1)
      + ((uext(win[2][1]) + uext(win[2][3])) <<< 3)
      + (uext(win[0][2]) + uext(win[4][2]))
      - ((uext(win[1][1]) + uext(win[1][3])
        + uext(win[3][1]) + uext(win[3][3])
        + uext(win[2][0]) + uext(win[2][4])) <<< 1);

    // red/blue at green, same-column orientation (transpose of acc_row)
    wire signed [AW-1:0] acc_col =
        (uext(win[2][2]) <<< 3) + (uext(win[2][2]) <<< 1)
      + ((uext(win[1][2]) + uext(win[3][2])) <<< 3)
      + (uext(win[2][0]) + uext(win[2][4]))
      - ((uext(win[1][1]) + uext(win[1][3])
        + uext(win[3][1]) + uext(win[3][3])
        + uext(win[0][2]) + uext(win[4][2])) <<< 1);

    // Bayer color of the output center
    wire cen_odd_y = (tk_cy[0] ^ ph[1]);
    wire cen_odd_x = (tk_cx[0] ^ ph[0]);

    always @(posedge clk) begin
        if (!rst_n) begin
            m_valid <= 1'b0;
            m_sof   <= 1'b0;
        end else begin
            m_valid <= tk_valid;
            m_sof   <= tk_valid && tk_sof;
            if (tk_valid) begin
                case ({cen_odd_y, cen_odd_x})
                    2'b00: begin                       // red site
                        m_r <= win[2][2];
                        m_g <= rnd_clamp(acc_g);
                        m_b <= rnd_clamp(acc_diag);
                    end
                    2'b01: begin                       // green, red row
                        m_r <= rnd_clamp(acc_row);
                        m_g <= win[2][2];
                        m_b <= rnd_clamp(acc_col);
                    end
                    2'b10: begin                       // green, blue row
                        m_r <= rnd_clamp(acc_col);
                        m_g <= win[2][2];
                        m_b <= rnd_clamp(acc_row);
                    end
                    default: begin                     // blue site
                        m_r <= rnd_clamp(acc_diag);
                        m_g <= rnd_clamp(acc_g);
                        m_b <= win[2][2];
                    end
                endcase
            end
        end
    end

endmodule
