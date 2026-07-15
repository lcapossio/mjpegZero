// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// tb_zigzag_gapless.sv — regression bench for the gapless double-buffer bug
// ============================================================================
// Feeds two back-to-back (gapless) 64-coefficient blocks into zigzag_reorder
// and checks that block 0's readout is served ENTIRELY from block 0's data.
//
// The bug (live buf_sel in the read mux): with gapless arrival the write side
// toggles buf_sel one cycle before the reader fetches coefficient 63, so
// block 0's last output coefficient is served from block 1's buffer.
//
// Block 0 values are in [100,163], block 1 values in [200,263] (disjoint), so
// any block-1 leakage into block 0's output fails the range check below.
//
//   iverilog -g2012 -o zz.vvp rtl/zigzag_reorder.v sim/verify/tb_zigzag_gapless.sv
//   vvp zz.vvp
// ============================================================================

`timescale 1ns / 1ps

module tb_zigzag_gapless;

    localparam CLK = 10;

    reg               clk = 1'b0;
    reg               rst_n = 1'b0;
    reg               in_valid = 1'b0;
    reg signed [15:0] in_data = 16'sd0;
    reg               in_sob = 1'b0;
    wire              out_valid;
    wire signed [15:0] out_data;
    wire              out_sob;

    zigzag_reorder dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data), .in_sob(in_sob),
        .out_valid(out_valid), .out_data(out_data), .out_sob(out_sob)
    );

    always #(CLK/2) clk = ~clk;

    // ---- Output capture ----
    integer out_cnt = 0;
    reg signed [15:0] cap [0:255];
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            cap[out_cnt] = out_data;
            out_cnt = out_cnt + 1;
        end
    end

    integer s;
    integer errors = 0;
    integer k;

    // ---- Stimulus: one 64-sample block, in_sob on the first sample ----
    task drive_block(input integer base);
        integer i;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_sob   = (i == 0);
                in_data  = base + i;
            end
        end
    endtask

    initial begin
        // Reset
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // Block 0 then block 1, gapless (in_valid never drops between them)
        drive_block(100);   // values 100..163, in_sob on first sample
        drive_block(200);   // values 200..263, in_sob on first sample

        // stop feeding, let both blocks drain out
        @(negedge clk);
        in_valid = 1'b0;
        in_sob   = 1'b0;
        repeat (200) @(negedge clk);

        // ---- Checks ----
        if (out_cnt < 128) begin
            $display("FAIL: expected >=128 output coeffs, got %0d", out_cnt);
            errors = errors + 1;
        end

        // Block 0 = first 64 outputs, must all come from block 0's range.
        for (k = 0; k < 64; k = k + 1) begin
            if (cap[k] < 100 || cap[k] > 163) begin
                $display("FAIL: block0 out[%0d] = %0d (outside block0 range 100..163) -> cross-block leak",
                         k, cap[k]);
                errors = errors + 1;
            end
        end

        // Block 1 = next 64 outputs, must all come from block 1's range.
        for (k = 64; k < 128; k = k + 1) begin
            if (cap[k] < 200 || cap[k] > 263) begin
                $display("FAIL: block1 out[%0d] = %0d (outside block1 range 200..263)",
                         k, cap[k]);
                errors = errors + 1;
            end
        end

        // Spotlight the known-vulnerable coefficient (zigzag pos 63).
        $display("INFO: block0 last coeff out[63] = %0d (expect 163, bug gives 263)", cap[63]);

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED (%0d errors)", errors);
        $finish;
    end

    // safety timeout
    initial begin
        #100000;
        $display("SOME TESTS FAILED (timeout)");
        $finish;
    end

endmodule
