// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_isp_rgb.sv — gamma_lut / csc_422 bit-exact checks
// ============================================================================
// Compile with -DTB_MODE_{GAMMA|CSC} and -DTB_W/-DTB_H. Stimulus: RGB
// triples in stim.hex. GAMMA: frame 1 runs the power-up identity curve,
// then curve.hex is loaded through the write port and frame 2 runs it;
// exp.hex holds both frames' expectations (6*N entries). CSC: exp.hex
// holds N YUYV words, expected identically for both frames.
// ============================================================================

`timescale 1ns / 1ps

module tb_isp_rgb;

    localparam W = `TB_W;
    localparam H = `TB_H;
    localparam N = W * H;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [11:0] stim [0:3*N-1];
    reg [15:0] expd [0:6*N-1];

    reg        s_valid = 0, s_sof = 0;
    reg [11:0] s_r = 0, s_g = 0, s_b = 0;
    reg        lut_we = 0;
    reg [11:0] lut_addr = 0;
    reg [7:0]  lut_wdata = 0;

    integer out_idx = 0, errors = 0;
    integer i, frame;
    reg [31:0] lfsr = 32'hC5C0FFEE;

`ifdef TB_MODE_GAMMA
    wire       m_valid, m_sof;
    wire [7:0] m_r, m_g, m_b;
    reg [7:0]  curve [0:4095];

    gamma_lut #(.DATA_W(12)) dut (
        .clk(clk), .rst_n(rst_n),
        .lut_we(lut_we), .lut_addr(lut_addr), .lut_wdata(lut_wdata),
        .s_valid(s_valid), .s_r(s_r), .s_g(s_g), .s_b(s_b), .s_sof(s_sof),
        .m_valid(m_valid), .m_r(m_r), .m_g(m_g), .m_b(m_b), .m_sof(m_sof));

    always @(posedge clk) begin
        if (m_valid) begin
            if (m_r !== expd[3*out_idx][7:0] || m_g !== expd[3*out_idx+1][7:0]
                || m_b !== expd[3*out_idx+2][7:0]) begin
                if (errors < 6)
                    $display("MISMATCH px %0d: got %0d,%0d,%0d exp %0d,%0d,%0d",
                             out_idx, m_r, m_g, m_b, expd[3*out_idx],
                             expd[3*out_idx+1], expd[3*out_idx+2]);
                errors = errors + 1;
            end
            if (m_sof !== (out_idx % N == 0)) begin
                $display("MISMATCH: m_sof at %0d", out_idx);
                errors = errors + 1;
            end
            out_idx = out_idx + 1;
        end
    end
`endif

`ifdef TB_MODE_CSC
    wire        m_valid, m_sof;
    wire [15:0] m_data;

    csc_422 #(.IMG_WIDTH(W)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_r(s_r[7:0]), .s_g(s_g[7:0]), .s_b(s_b[7:0]),
        .s_sof(s_sof),
        .m_valid(m_valid), .m_data(m_data), .m_sof(m_sof));

    always @(posedge clk) begin
        if (m_valid) begin
            if (m_data !== expd[out_idx % N]) begin
                if (errors < 6)
                    $display("MISMATCH word %0d (%0d,%0d): got %04x exp %04x",
                             out_idx % N, (out_idx % N) / W, (out_idx % N) % W,
                             m_data, expd[out_idx % N]);
                errors = errors + 1;
            end
            if (m_sof !== (out_idx % N == 0)) begin
                $display("MISMATCH: m_sof at %0d", out_idx);
                errors = errors + 1;
            end
            out_idx = out_idx + 1;
        end
    end
`endif

    task send_frame;
        begin
            for (i = 0; i < N; i = i + 1) begin
                s_valid = 1;
                s_sof   = (i == 0);
                s_r = stim[3*i]; s_g = stim[3*i+1]; s_b = stim[3*i+2];
                @(negedge clk);
                s_valid = 0;
                s_sof   = 0;
                lfsr = {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
                if (lfsr[2:0] == 3'b000 && (i % W) != W - 1)
                    repeat (1 + lfsr[4:3]) @(negedge clk);
                if ((i % W) == W - 1)
                    repeat (4) @(negedge clk);   // line blanking
            end
            repeat (12) @(negedge clk);
        end
    endtask

    initial begin
        $readmemh("stim.hex", stim);
        $readmemh("exp.hex", expd);

        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        send_frame;

`ifdef TB_MODE_GAMMA
        $readmemh("curve.hex", curve);
        for (i = 0; i < 4096; i = i + 1) begin
            lut_we    = 1;
            lut_addr  = i[11:0];
            lut_wdata = curve[i];
            @(negedge clk);
        end
        lut_we = 0;
        @(negedge clk);
`endif

        send_frame;

        if (out_idx != 2*N)
            $display("FAIL: expected %0d outputs, got %0d", 2*N, out_idx);
        else if (errors != 0)
            $display("FAIL: %0d mismatches", errors);
        else
            $display("PASS: %0d outputs bit-exact", out_idx);
        $finish;
    end

endmodule
