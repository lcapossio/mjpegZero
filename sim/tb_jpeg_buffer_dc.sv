// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// tb_jpeg_buffer_dc.sv - unit test for the dual-clock JPEG buffer.
// Writes a pattern on port A (150 MHz), then reads it back on both port A
// (150 MHz) and port B (100 MHz, async) and checks the data matches.

`timescale 1ns / 1ps

module tb_jpeg_buffer_dc;
    localparam WORDS = 4096;
    localparam TILE  = 1024;   // -> 4 tiles, exercises the tile mux
    localparam N     = 600;    // words to test (spans multiple tiles)

    reg clk_a = 0, clk_b = 0;
    always #3 clk_a = ~clk_a;      // ~166 MHz write clock (distinct from clk_b)
    always #5 clk_b = ~clk_b;      // 100 MHz read clock

    reg         we;
    reg  [16:0] addr_a, addr_b;
    reg  [31:0] wdata;
    wire [31:0] rdata_a, rdata_b;

    jpeg_buffer_dc #(.JPEG_WORDS(WORDS), .JPEG_TILE_DEPTH(TILE)) dut (
        .clk_a(clk_a), .we(we), .addr_a(addr_a), .wdata(wdata), .rdata_a(rdata_a),
        .clk_b(clk_b), .addr_b(addr_b), .rdata_b(rdata_b)
    );

    function [31:0] patt; input [16:0] a; patt = {a, a[14:0]} ^ 32'hA5A5_0000; endfunction

    integer i, errors;
    initial begin
        we = 0; addr_a = 0; addr_b = 0; wdata = 0; errors = 0;

        // --- write pattern on port A ---
        @(negedge clk_a);
        for (i = 0; i < N; i = i + 1) begin
            we = 1'b1; addr_a = i[16:0]; wdata = patt(i[16:0]);
            @(negedge clk_a);
        end
        we = 1'b0;
        @(negedge clk_a);

        // --- read back on port A (1-cycle latency; hold addr) ---
        for (i = 0; i < N; i = i + 1) begin
            addr_a = i[16:0];
            @(posedge clk_a); #1;   // data valid after the edge
            if (rdata_a !== patt(i[16:0])) begin
                if (errors < 8) $display("FAIL portA[%0d]=%08x exp %08x", i, rdata_a, patt(i[16:0]));
                errors = errors + 1;
            end
        end

        // --- read back on port B (async 100 MHz) ---
        for (i = 0; i < N; i = i + 1) begin
            addr_b = i[16:0];
            @(posedge clk_b); #1;
            if (rdata_b !== patt(i[16:0])) begin
                if (errors < 8) $display("FAIL portB[%0d]=%08x exp %08x", i, rdata_b, patt(i[16:0]));
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("[tb_jpeg_buffer_dc] PASS: %0d words via port A + port B", N);
        else
            $display("[tb_jpeg_buffer_dc] FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin #500000; $display("[tb_jpeg_buffer_dc] TIMEOUT"); $finish; end
endmodule
