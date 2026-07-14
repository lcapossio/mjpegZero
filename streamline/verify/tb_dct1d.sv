// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_dct1d.sv — dct_1d bit-exact check against the Python golden model
// ============================================================================
// Reads dct1d_stim.hex (rows of 8 samples, 16-bit two's complement) and
// dct1d_exp.hex (expected coefficients from dct_model.py::dct1d_loeffler),
// drives the rows through the DUT — alternating back-to-back streaming and
// pseudo-random inter-row gaps — and compares every output coefficient.
// ============================================================================

`timescale 1ns / 1ps

module tb_dct1d;

    localparam MAX_ROWS = 4096;

    reg         clk = 0;
    reg         rst_n = 0;
    reg         in_valid = 0;
    reg  signed [11:0] in_data = 0;
    wire        out_valid;
    wire signed [15:0] out_data;
    wire        out_last;

    dct_1d dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data), .in_last(1'b0),
        .out_valid(out_valid), .out_data(out_data), .out_last(out_last)
    );

    always #5 clk = ~clk;

    reg [15:0] stim [0:MAX_ROWS*8-1];
    reg [15:0] expd [0:MAX_ROWS*8-1];

    integer n_rows, out_idx, errors, i, r, gap;
    reg [31:0] lfsr = 32'h0D15EA5E;

    always @(posedge clk) begin
        if (out_valid) begin
            if (out_data !== $signed(expd[out_idx])) begin
                if (errors < 10)
                    $display("MISMATCH row %0d k %0d: got %0d expected %0d",
                             out_idx / 8, out_idx % 8,
                             out_data, $signed(expd[out_idx]));
                errors = errors + 1;
            end
            if (out_last && (out_idx % 8) != 7) begin
                $display("MISMATCH: out_last misaligned at %0d", out_idx);
                errors = errors + 1;
            end
            out_idx = out_idx + 1;
        end
    end

    initial begin
        $readmemh("dct1d_stim.hex", stim);
        $readmemh("dct1d_exp.hex", expd);
        n_rows = 0;
        while (n_rows < MAX_ROWS && stim[n_rows*8] !== 16'hxxxx)
            n_rows = n_rows + 1;

        out_idx = 0;
        errors = 0;

        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        for (r = 0; r < n_rows; r = r + 1) begin
            for (i = 0; i < 8; i = i + 1) begin
                in_valid = 1;
                in_data  = stim[r*8 + i][11:0];
                @(negedge clk);
            end
            in_valid = 0;
            // First half of the rows streams back-to-back (gap 0); the
            // second half inserts 1..7 idle cycles between rows.
            if (r >= n_rows / 2) begin
                lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                gap = 1 + (lfsr[2:0] % 7);
                repeat (gap) @(negedge clk);
            end
        end

        repeat (20) @(negedge clk);

        if (out_idx != n_rows * 8)
            $display("FAIL: expected %0d coefficients, got %0d",
                     n_rows * 8, out_idx);
        else if (errors != 0)
            $display("FAIL: %0d mismatches in %0d coefficients",
                     errors, out_idx);
        else
            $display("PASS: %0d rows, %0d coefficients bit-exact",
                     n_rows, out_idx);
        $finish;
    end

endmodule
