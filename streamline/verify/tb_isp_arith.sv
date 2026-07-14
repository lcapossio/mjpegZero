// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_isp_arith.sv — blc / wb_gains / ccm bit-exact checks
// ============================================================================
// Compile with -DTB_MODE_{BLC|WB|CCM} and -DTB_W/-DTB_H (frame geometry for
// the Bayer stages; CCM streams pixels without geometry). Stimulus in
// stim.hex (1 value per line for BLC/WB, 3 for CCM), expected in exp.hex.
// Static parameters (blacks/gains/matrix) in params.hex. Random gaps
// throughout; two frames prove SOF recovery.
// ============================================================================

`timescale 1ns / 1ps

module tb_isp_arith;

    localparam W = `TB_W;
    localparam H = `TB_H;
    localparam N = W * H;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [11:0] stim [0:3*N-1];
    reg [11:0] expd [0:3*N-1];
    reg [15:0] prm  [0:15];

    integer out_idx = 0, errors = 0, eidx;
    integer i, frame;
    reg [31:0] lfsr = 32'h15BAD5EE;

    reg        s_valid = 0, s_sof = 0;
    reg [11:0] s_data = 0, s_r = 0, s_g = 0, s_b = 0;
    wire       m_valid, m_sof;
    wire [11:0] m_data, m_r, m_g, m_b;

`ifdef TB_MODE_BLC
    blc #(.DATA_W(12), .IMG_WIDTH(W)) dut (
        .clk(clk), .rst_n(rst_n), .bayer_phase(prm[0][1:0]),
        .black_r(prm[1][11:0]), .black_gr(prm[2][11:0]),
        .black_gb(prm[3][11:0]), .black_b(prm[4][11:0]),
        .s_valid(s_valid), .s_data(s_data), .s_sof(s_sof),
        .m_valid(m_valid), .m_data(m_data), .m_sof(m_sof));
`endif
`ifdef TB_MODE_WB
    wb_gains #(.DATA_W(12), .IMG_WIDTH(W)) dut (
        .clk(clk), .rst_n(rst_n), .bayer_phase(prm[0][1:0]),
        .gain_r(prm[1][11:0]), .gain_gr(prm[2][11:0]),
        .gain_gb(prm[3][11:0]), .gain_b(prm[4][11:0]),
        .s_valid(s_valid), .s_data(s_data), .s_sof(s_sof),
        .m_valid(m_valid), .m_data(m_data), .m_sof(m_sof));
`endif
`ifdef TB_MODE_CCM
    ccm #(.DATA_W(12)) dut (
        .clk(clk), .rst_n(rst_n),
        .m00($signed(prm[1][12:0])), .m01($signed(prm[2][12:0])), .m02($signed(prm[3][12:0])),
        .m10($signed(prm[4][12:0])), .m11($signed(prm[5][12:0])), .m12($signed(prm[6][12:0])),
        .m20($signed(prm[7][12:0])), .m21($signed(prm[8][12:0])), .m22($signed(prm[9][12:0])),
        .s_valid(s_valid), .s_r(s_r), .s_g(s_g), .s_b(s_b), .s_sof(s_sof),
        .m_valid(m_valid), .m_r(m_r), .m_g(m_g), .m_b(m_b), .m_sof(m_sof));
`endif

    always @(posedge clk) begin
        if (m_valid) begin
            eidx = out_idx % N;
`ifdef TB_MODE_CCM
            if (m_r !== expd[3*eidx] || m_g !== expd[3*eidx+1]
                || m_b !== expd[3*eidx+2]) begin
                if (errors < 6)
                    $display("MISMATCH px %0d: got %0d,%0d,%0d exp %0d,%0d,%0d",
                             eidx, m_r, m_g, m_b, expd[3*eidx],
                             expd[3*eidx+1], expd[3*eidx+2]);
                errors = errors + 1;
            end
`else
            if (m_data !== expd[eidx]) begin
                if (errors < 6)
                    $display("MISMATCH px %0d (%0d,%0d): got %0d exp %0d",
                             eidx, eidx / W, eidx % W, m_data, expd[eidx]);
                errors = errors + 1;
            end
`endif
            if (m_sof !== (eidx == 0)) begin
                $display("MISMATCH: m_sof at %0d", out_idx);
                errors = errors + 1;
            end
            out_idx = out_idx + 1;
        end
    end

    initial begin
        $readmemh("stim.hex", stim);
        $readmemh("exp.hex", expd);
        $readmemh("params.hex", prm);

        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        for (frame = 0; frame < 2; frame = frame + 1) begin
            for (i = 0; i < N; i = i + 1) begin
                s_valid = 1;
                s_sof   = (i == 0);
`ifdef TB_MODE_CCM
                s_r = stim[3*i]; s_g = stim[3*i+1]; s_b = stim[3*i+2];
`else
                s_data = stim[i];
`endif
                @(negedge clk);
                s_valid = 0;
                s_sof   = 0;
                lfsr = {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
                if (lfsr[2:0] == 3'b000)
                    repeat (1 + lfsr[4:3]) @(negedge clk);
            end
            repeat (8) @(negedge clk);
        end

        if (out_idx != 2*N)
            $display("FAIL: expected %0d outputs, got %0d", 2*N, out_idx);
        else if (errors != 0)
            $display("FAIL: %0d mismatches", errors);
        else
            $display("PASS: %0d outputs bit-exact", out_idx);
        $finish;
    end

endmodule
