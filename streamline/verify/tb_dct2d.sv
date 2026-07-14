// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_dct2d.sv — dct_2d bit-exact check against the Python golden model
// ============================================================================
// Drives 8x8 blocks from dct2d_stim.hex — alternating back-to-back and
// pseudo-random inter-block gaps — and compares every raster-order output
// coefficient against dct2d_exp.hex, including out_sof alignment.
// ============================================================================

`timescale 1ns / 1ps

module tb_dct2d;

    localparam MAX_BLOCKS = 1024;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         in_valid = 0;
    reg  signed [11:0] in_data = 0;
    reg         in_sof = 0;
    wire        out_valid;
    wire signed [15:0] out_data;
    wire        out_sof;

    dct_2d dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data), .in_sof(in_sof),
        .out_valid(out_valid), .out_data(out_data), .out_sof(out_sof)
    );

    always #5 clk = ~clk;

    reg [15:0] stim [0:MAX_BLOCKS*64-1];
    reg [15:0] expd [0:MAX_BLOCKS*64-1];

    integer n_blocks, out_idx, errors, i, b, gap;
    reg [31:0] lfsr = 32'hFACE0FF5;

    always @(posedge clk) begin
        if (out_valid) begin
            if (out_data !== $signed(expd[out_idx])) begin
                if (errors < 10)
                    $display("MISMATCH block %0d coef %0d: got %0d expected %0d",
                             out_idx / 64, out_idx % 64,
                             out_data, $signed(expd[out_idx]));
                errors = errors + 1;
            end
            if (out_sof !== ((out_idx % 64) == 0)) begin
                $display("MISMATCH: out_sof misaligned at %0d", out_idx);
                errors = errors + 1;
            end
            out_idx = out_idx + 1;
        end
    end

    initial begin
        $readmemh("dct2d_stim.hex", stim);
        $readmemh("dct2d_exp.hex", expd);
        n_blocks = 0;
        while (n_blocks < MAX_BLOCKS && stim[n_blocks*64] !== 16'hxxxx)
            n_blocks = n_blocks + 1;

        out_idx = 0;
        errors = 0;

        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        for (b = 0; b < n_blocks; b = b + 1) begin
            for (i = 0; i < 64; i = i + 1) begin
                in_valid = 1;
                in_sof   = (i == 0);
                in_data  = stim[b*64 + i][11:0];
                @(negedge clk);
            end
            in_valid = 0;
            in_sof   = 0;
            if (b >= n_blocks / 2) begin
                lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                gap = 1 + (lfsr[3:0] % 11);
                repeat (gap) @(negedge clk);
            end
        end

        repeat (200) @(negedge clk);

        if (out_idx != n_blocks * 64)
            $display("FAIL: expected %0d coefficients, got %0d",
                     n_blocks * 64, out_idx);
        else if (errors != 0)
            $display("FAIL: %0d mismatches in %0d coefficients",
                     errors, out_idx);
        else
            $display("PASS: %0d blocks, %0d coefficients bit-exact",
                     n_blocks, out_idx);
        $finish;
    end

endmodule
