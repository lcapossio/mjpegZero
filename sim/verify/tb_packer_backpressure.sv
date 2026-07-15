// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// tb_packer_backpressure.sv — regression bench for the non-truthful bp_ready
// ============================================================================
// A per-cycle producer streams variable-length codes into bitstream_packer,
// treating bp_ready as a real AXI-style ready: whenever (in_valid && bp_ready)
// at a clock edge, it considers the offered code delivered and advances.
//
// Output backpressure (out_ready stalls 1 of every 4 cycles) is applied.  If
// bp_ready is not truthful (missing the (!out_valid||out_ready) accept term),
// the producer marks codes delivered that the packer never latched -> those
// bits are missing from the output stream and the reconstructed bitstream is
// shorter than / differs from what the producer sent.
//
// The reconstructed entropy bits (stuffing removed) are compared against the
// concatenation of every code the producer believes it sent.
//
//   iverilog -g2012 -o bp.vvp rtl/bitstream_packer.v sim/verify/tb_packer_backpressure.sv
//   vvp bp.vvp
// ============================================================================

`timescale 1ns / 1ps

module tb_packer_backpressure;

    localparam CLK = 10;
    localparam N   = 48;   // number of codes to stream

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

    // ---- Code table ----
    reg [31:0] code_bits [0:N];
    reg [5:0]  code_len  [0:N];
    integer i;
    integer L;
    initial begin
        for (i = 0; i < N; i = i + 1) begin
            L            = 4 + (i % 13);               // 4..16 bits
            code_len[i]  = L[5:0];
            // Code lives in the top L bits, MSB-aligned, ZEROS below — exactly
            // what the Huffman encoder produces.  The packer OR-accumulates
            // in_bits, so any nonzero bits below the code would corrupt the
            // next code; mask them off here.
            code_bits[i] = ((i + 1) * 32'h9E3779B1) & (32'hFFFFFFFF << (32 - L));
        end
        code_bits[N] = 32'd0; code_len[N] = 6'd0;      // guard slot
    end

    // ---- Phases ----
    localparam RUN = 0, FLUSH = 1, DONE = 2;
    integer phase = RUN;
    integer send_idx = 0;
    reg     flush_done = 1'b0;
    reg     done = 1'b0;
    integer brc = 0;

    // ---- Expected (sent) bitstream ----
    reg exp [0:8191];
    integer exp_len = 0;

    // ---- Captured output bytes ----
    reg [7:0] obytes [0:2047];
    reg       olast  [0:2047];
    integer   nb = 0;

    // ------------------------------------------------------------------
    // Driver: update DUT inputs on negedge so they are stable at posedge
    // (avoids two-always-block races on the sampled handshake).
    // ------------------------------------------------------------------
    always @(negedge clk) begin
        if (!rst_n) begin
            in_valid   <= 1'b0;
            in_bits    <= 32'd0;
            in_len     <= 6'd0;
            in_flush   <= 1'b0;
            in_restart <= 1'b0;
            out_ready  <= 1'b1;
            brc        <= 0;
        end else begin
            brc       <= brc + 1;
            out_ready <= (brc[1:0] != 2'b11);   // stall 1 of every 4 cycles
            if (phase == RUN) begin
                in_valid <= (send_idx < N);
                in_bits  <= (send_idx < N) ? code_bits[send_idx] : 32'd0;
                in_len   <= (send_idx < N) ? code_len[send_idx]  : 6'd0;
                in_flush <= 1'b0;
            end else if (phase == FLUSH) begin
                in_valid <= 1'b0;
                in_flush <= !flush_done;        // one-cycle flush pulse
                flush_done <= 1'b1;
            end else begin
                in_valid <= 1'b0;
                in_flush <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // Monitor: sample the synchronous handshake at posedge.
    // ------------------------------------------------------------------
    integer k;
    always @(posedge clk) begin
        if (rst_n) begin
            // capture an output byte transfer
            if (out_valid && out_ready) begin
                obytes[nb] = out_data;
                olast[nb]  = out_last;
                nb = nb + 1;
            end
            case (phase)
                RUN: begin
                    // producer trusts bp_ready as a real ready
                    if (in_valid && bp_ready) begin
                        for (k = 0; k < in_len; k = k + 1) begin
                            exp[exp_len] = in_bits[31 - k];
                            exp_len = exp_len + 1;
                        end
                        send_idx = send_idx + 1;
                        if (send_idx == N)
                            phase = FLUSH;
                    end
                end
                FLUSH: begin
                    if (out_valid && out_ready && out_last)
                        phase = DONE;
                end
                DONE: done = 1'b1;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Checker
    // ------------------------------------------------------------------
    reg act [0:16383];
    integer act_len = 0;
    integer b, j;
    reg skip;
    integer errors = 0;

    initial begin
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // wait for completion
        wait (done == 1'b1);
        repeat (4) @(negedge clk);

        // reconstruct emitted entropy bits, removing byte-stuffing and the
        // final tlast dummy byte
        skip = 1'b0;
        for (b = 0; b < nb; b = b + 1) begin
            if (olast[b]) begin
                // dummy end-of-frame byte, carries no entropy data
            end else if (skip) begin
                skip = 1'b0;                 // this 0x00 was a stuff byte
            end else begin
                for (k = 0; k < 8; k = k + 1) begin
                    act[act_len] = obytes[b][7 - k];
                    act_len = act_len + 1;
                end
                if (obytes[b] == 8'hFF)
                    skip = 1'b1;
            end
        end

        $display("INFO: sent %0d codes, %0d bits; captured %0d bytes, %0d entropy bits",
                 send_idx, exp_len, nb, act_len);

        if (act_len < exp_len) begin
            $display("FAIL: output has %0d entropy bits but producer sent %0d -> %0d bits lost",
                     act_len, exp_len, exp_len - act_len);
            errors = errors + 1;
        end

        for (j = 0; j < exp_len; j = j + 1) begin
            if (j < act_len && act[j] !== exp[j]) begin
                $display("FAIL: bit %0d differs (sent %b, got %b) -> code(s) dropped under backpressure",
                         j, exp[j], act[j]);
                errors = errors + 1;
                j = exp_len; // stop at first mismatch
            end
        end

        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED (%0d errors)", errors);
        $finish;
    end

    // safety timeout
    initial begin
        #200000;
        $display("SOME TESTS FAILED (timeout, phase=%0d send_idx=%0d nb=%0d)", phase, send_idx, nb);
        $finish;
    end

endmodule
