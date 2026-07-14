// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_debayer.sv — debayer bit-exact check against the Python golden model
// ============================================================================
// Compile with -DTB_W / -DTB_H / -DTB_PHASE. Reads cfa.hex and rgb_exp.hex
// (r, g, b per pixel), drives the frame with line blanking and random
// mid-line gaps, waits out the self-paced frame flush, and compares every
// output pixel and the m_sof mark.
// ============================================================================

`timescale 1ns / 1ps

module tb_debayer;

    localparam W = `TB_W;
    localparam H = `TB_H;
    localparam [1:0] PHASE = `TB_PHASE;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         s_valid = 0;
    reg  [11:0] s_data = 0;
    reg         s_sof = 0;
    wire        m_valid, m_sof;
    wire [11:0] m_r, m_g, m_b;

    debayer #(.DATA_W(12), .IMG_WIDTH(W), .IMG_HEIGHT(H)) dut (
        .clk(clk), .rst_n(rst_n), .bayer_phase(PHASE),
        .s_valid(s_valid), .s_data(s_data), .s_sof(s_sof),
        .m_valid(m_valid), .m_r(m_r), .m_g(m_g), .m_b(m_b), .m_sof(m_sof)
    );

    always #5 clk = ~clk;

    reg [11:0] cfa [0:W*H-1];
    reg [11:0] exp_rgb [0:3*W*H-1];

    integer out_idx = 0, errors = 0, eidx;
    integer x, y, frame;
    reg [31:0] lfsr = 32'hB0BA1DEA;

    always @(posedge clk) begin
        if (m_valid) begin
            eidx = out_idx % (W*H);
            if (m_r !== exp_rgb[3*eidx] || m_g !== exp_rgb[3*eidx+1]
                || m_b !== exp_rgb[3*eidx+2]) begin
                if (errors < 8)
                    $display("MISMATCH px %0d (%0d,%0d): got %0d,%0d,%0d exp %0d,%0d,%0d",
                             out_idx, eidx / W, eidx % W, m_r, m_g, m_b,
                             exp_rgb[3*eidx], exp_rgb[3*eidx+1],
                             exp_rgb[3*eidx+2]);
                errors = errors + 1;
            end
            if (m_sof !== (out_idx % (W*H) == 0)) begin
                $display("MISMATCH: m_sof misaligned at %0d", out_idx);
                errors = errors + 1;
            end
            out_idx = out_idx + 1;
        end
    end

    initial begin
        $readmemh("cfa.hex", cfa);
        $readmemh("rgb_exp.hex", exp_rgb);

        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        // Two frames back to back: the second proves inter-frame recovery.
        for (frame = 0; frame < 2; frame = frame + 1) begin
            for (y = 0; y < H; y = y + 1) begin
                for (x = 0; x < W; x = x + 1) begin
                    s_valid = 1;
                    s_sof   = (x == 0 && y == 0);
                    s_data  = cfa[y*W + x];
                    @(negedge clk);
                    s_valid = 0;
                    s_sof   = 0;
                    // occasional mid-line gap (allowed anywhere)
                    lfsr = {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
                    if (lfsr[3:0] == 4'h0)
                        repeat (1 + lfsr[5:4]) @(negedge clk);
                end
                repeat (6) @(negedge clk);            // line blanking
            end
            repeat (2 * (W + 2) + 24) @(negedge clk); // frame flush
        end

        if (out_idx != 2*W*H)
            $display("FAIL: expected %0d pixels, got %0d", 2*W*H, out_idx);
        else if (errors != 0)
            $display("FAIL: %0d mismatches", errors);
        else
            $display("PASS: %0dx%0d phase %0d, 2 frames, %0d pixels bit-exact",
                     W, H, PHASE, out_idx);
        $finish;
    end

endmodule
