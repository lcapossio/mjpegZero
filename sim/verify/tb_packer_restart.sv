// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// tb_packer_restart.sv — regression bench for dropped tail bits at a restart
// ============================================================================
// A restart is requested on the same cycle a 13-bit code is accepted, so the
// packer enters S_RST_PAD with bit_cnt = 13 (>= 8).  S_RST_PAD only pads a
// wholly sub-byte residual, so the buggy drain path emits one full byte then
// discards the remaining 5 bits before the FF D0 marker.
//
// 13-bit code = 1010101010101:
//   byte 0 = top 8 bits          = 0xAA
//   byte 1 = last 5 bits + 3 pad = 10101_111 = 0xAF   (must be emitted!)
//   then restart marker          = 0xFF 0xD0
//
// Expected (fixed):  AA AF FF D0
// Buggy (5 bits lost): AA FF D0
//
//   iverilog -g2012 -o rst.vvp rtl/bitstream_packer.v sim/verify/tb_packer_restart.sv
//   vvp rst.vvp
// ============================================================================

`timescale 1ns / 1ps

module tb_packer_restart;

    localparam CLK = 10;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         in_valid = 1'b0;
    reg  [31:0] in_bits = 32'd0;
    reg  [5:0]  in_len = 6'd0;
    reg         in_flush = 1'b0;
    reg         in_restart = 1'b0;
    reg         out_ready = 1'b1;
    wire        bp_ready;
    wire        out_valid;
    wire [7:0]  out_data;
    wire        out_last;
    wire [31:0] byte_count;

    bitstream_packer dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_bits(in_bits), .in_len(in_len),
        .in_flush(in_flush), .in_restart(in_restart),
        .bp_ready(bp_ready),
        .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
        .out_ready(out_ready), .byte_count(byte_count)
    );

    always #(CLK/2) clk = ~clk;

    // ---- Capture emitted bytes ----
    reg [7:0] obytes [0:63];
    integer   nb = 0;
    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            obytes[nb] = out_data;
            nb = nb + 1;
        end
    end

    integer errors = 0;
    reg [7:0] expected [0:3];

    initial begin
        expected[0] = 8'hAA;
        expected[1] = 8'hAF;
        expected[2] = 8'hFF;
        expected[3] = 8'hD0;

        rst_n     = 1'b0;
        out_ready = 1'b1;   // never stall the output
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // One cycle: accept a 13-bit code AND request restart simultaneously.
        // 13 bits (1010101010101) followed by 19 don't-care zeros = 32 bits.
        @(negedge clk);
        in_valid   = 1'b1;
        in_bits    = 32'b1010101010101_0000000000000000000;
        in_len     = 6'd13;
        in_restart = 1'b1;

        @(negedge clk);
        in_valid   = 1'b0;
        in_restart = 1'b0;
        in_bits    = 32'd0;
        in_len     = 6'd0;

        // let the restart sequence drain
        repeat (40) @(negedge clk);

        // ---- Checks ----
        $display("INFO: captured %0d bytes:", nb);
        begin : dump
            integer d;
            for (d = 0; d < nb; d = d + 1)
                $display("       byte[%0d] = 0x%02X", d, obytes[d]);
        end

        if (nb != 4) begin
            $display("FAIL: expected 4 bytes (AA AF FF D0), got %0d -> tail bits dropped before restart", nb);
            errors = errors + 1;
        end else begin
            for (integer m = 0; m < 4; m = m + 1) begin
                if (obytes[m] !== expected[m]) begin
                    $display("FAIL: byte[%0d] = 0x%02X, expected 0x%02X", m, obytes[m], expected[m]);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("SOME TESTS FAILED (timeout)");
        $finish;
    end

endmodule
