// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_isp_chain.sv — assembled ISP, Bayer in → YUYV out, bit-exact
// ============================================================================
// Compile with -DTB_W/-DTB_H/-DTB_PHASE. Drives cfa.hex through isp_chain
// with sensor-like timing (line blanking, mid-line gaps, frame gaps), loads
// the gamma curve from curve.hex through the write port before streaming,
// and compares every YUYV word against yuyv_exp.hex from the composed
// golden models. Two frames prove inter-frame recovery. CSR values are
// read from params.hex (blacks, pedestal, gains, matrix).
// ============================================================================

`timescale 1ns / 1ps

module tb_isp_chain;

    localparam W = `TB_W;
    localparam H = `TB_H;
    localparam [1:0] PHASE = `TB_PHASE;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [11:0] s_data = 0;
    reg         s_valid = 0, s_sof = 0;
    reg         lut_we = 0;
    reg  [11:0] lut_addr = 0;
    reg  [7:0]  lut_wdata = 0;
    wire        m_valid, m_sof;
    wire [15:0] m_data;

    reg [15:0] prm [0:31];
    reg [11:0] cfa [0:W*H-1];
    reg [15:0] expd [0:W*H-1];
    reg [7:0]  curve [0:4095];

    isp_chain #(.DATA_W(12), .IMG_WIDTH(W), .IMG_HEIGHT(H)) dut (
        .clk(clk), .rst_n(rst_n),
        .bayer_phase(PHASE),
        .black_r(prm[0][11:0]), .black_gr(prm[1][11:0]),
        .black_gb(prm[2][11:0]), .black_b(prm[3][11:0]),
        .pedestal(prm[4][7:0]),
        .gain_r(prm[5][11:0]), .gain_gr(prm[6][11:0]),
        .gain_gb(prm[7][11:0]), .gain_b(prm[8][11:0]),
        .m00($signed(prm[9][12:0])),  .m01($signed(prm[10][12:0])), .m02($signed(prm[11][12:0])),
        .m10($signed(prm[12][12:0])), .m11($signed(prm[13][12:0])), .m12($signed(prm[14][12:0])),
        .m20($signed(prm[15][12:0])), .m21($signed(prm[16][12:0])), .m22($signed(prm[17][12:0])),
        .lut_we(lut_we), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
        .s_valid(s_valid), .s_data(s_data), .s_sof(s_sof),
        .m_valid(m_valid), .m_data(m_data), .m_sof(m_sof)
    );

    integer out_idx = 0, errors = 0, eidx;
    reg [31:0] lfsr = 32'h15CC0DE5;

    always @(posedge clk) begin
        if (m_valid) begin
            eidx = out_idx % (W*H);
            if (m_data !== expd[eidx]) begin
                if (errors < 8)
                    $display("MISMATCH word %0d (%0d,%0d): got %04x exp %04x",
                             eidx, eidx / W, eidx % W, m_data, expd[eidx]);
                errors = errors + 1;
            end
            if (m_sof !== (eidx == 0)) begin
                $display("MISMATCH: m_sof at %0d", out_idx);
                errors = errors + 1;
            end
            out_idx = out_idx + 1;
        end
    end

    integer i, x, y, frame;

    initial begin
        $readmemh("params.hex", prm);
        $readmemh("cfa.hex", cfa);
        $readmemh("yuyv_exp.hex", expd);
        $readmemh("curve.hex", curve);

        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // Load the tone curve before video, as firmware does in blanking.
        for (i = 0; i < 4096; i = i + 1) begin
            lut_we    = 1;
            lut_addr  = i[11:0];
            lut_wdata = curve[i];
            @(negedge clk);
        end
        lut_we = 0;
        repeat (4) @(negedge clk);

        for (frame = 0; frame < 2; frame = frame + 1) begin
            for (y = 0; y < H; y = y + 1) begin
                for (x = 0; x < W; x = x + 1) begin
                    s_valid = 1;
                    s_sof   = (x == 0 && y == 0);
                    s_data  = cfa[y*W + x];
                    @(negedge clk);
                    s_valid = 0;
                    s_sof   = 0;
                    lfsr = {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
                    if (lfsr[3:0] == 4'h0)
                        repeat (1 + lfsr[5:4]) @(negedge clk);
                end
                repeat (8) @(negedge clk);            // line blanking
            end
            repeat (2 * (W + 6) + 40) @(negedge clk); // frame flush
        end

        if (out_idx != 2*W*H)
            $display("FAIL: expected %0d words, got %0d", 2*W*H, out_idx);
        else if (errors != 0)
            $display("FAIL: %0d mismatches", errors);
        else
            $display("PASS: %0dx%0d phase %0d, 2 frames, %0d words bit-exact",
                     W, H, PHASE, out_idx);
        $finish;
    end

endmodule
