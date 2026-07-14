// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_packer.sv — bitstream_packer torture bench
// ============================================================================
// Drives a deterministic pseudo-random stream of variable-length codes with
// interspersed restart requests and a final flush, under random output
// backpressure. Every accepted code and event is logged to packer_in.log;
// every output byte goes to packer_out.bin. A golden model recomputes the
// expected bytes from the input log, so handshake timing never affects the
// comparison — only the emitted byte sequence does.
// ============================================================================

`timescale 1ns / 1ps

module tb_packer;

    localparam NUM_CODES    = 3000;
    localparam RESTART_EVERY = 37;   // odd spacing => unaligned segment tails

    reg         clk = 0;
    reg         rst_n = 0;
    reg         in_valid = 0;
    reg  [31:0] in_bits = 0;
    reg  [5:0]  in_len = 0;
    reg         in_flush = 0;
    reg         in_restart = 0;
    wire        bp_ready;
    wire        out_valid;
    wire [7:0]  out_data;
    wire        out_last;
    reg         out_ready = 0;
    wire [31:0] byte_count;

    bitstream_packer dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_bits(in_bits), .in_len(in_len),
        .in_flush(in_flush), .in_restart(in_restart), .bp_ready(bp_ready),
        .out_valid(out_valid), .out_data(out_data), .out_last(out_last),
        .out_ready(out_ready), .byte_count(byte_count)
    );

    always #5 clk = ~clk;

    // Deterministic 32-bit LFSR (taps 32,22,2,1)
    reg [31:0] lfsr = 32'hC0FFEE01;
    task lfsr_step;
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    endtask

    // Random output backpressure: ready ~75% of cycles
    always @(posedge clk) begin
        lfsr_step;
        out_ready <= (lfsr[1:0] != 2'b00);
    end

    integer in_log, out_bin;
    integer sent, got_last, i;
    reg [5:0] len;
    reg [31:0] code;

    // Capture output bytes
    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            $fwrite(out_bin, "%c", out_data);
            if (out_last)
                got_last = 1;
        end
    end

    initial begin
        in_log  = $fopen("packer_in.log", "w");
        out_bin = $fopen("packer_out.bin", "wb");
        got_last = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // All stimulus changes on negedges: bp_ready is then stable through
        // the following posedge, so an offer seen with bp_ready high is
        // accepted at exactly that posedge and logged exactly once.
        for (sent = 0; sent < NUM_CODES; sent = sent + 1) begin
            // Length 1..26 (the range Huffman code+amplitude can span);
            // every 13th code is all-ones to force 0xFF stuffing chains.
            lfsr_step;
            len = 6'd1 + (lfsr[4:0] % 6'd26);
            if (sent % 13 == 0)
                code = 32'hFFFFFFFF << (32 - len);
            else begin
                lfsr_step;
                code = (lfsr << (32 - len)) & (32'hFFFFFFFF << (32 - len));
            end

            @(negedge clk);
            in_valid = 1;
            in_bits  = code;
            in_len   = len;
            while (!bp_ready) @(negedge clk);
            $fwrite(in_log, "C %08x %0d\n", in_bits, in_len);
            @(negedge clk);          // past the accepting posedge
            in_valid = 0;

            // Restart request: idle cycles either side, as the encoder's
            // inter-block spacing provides in the real pipeline.
            if (sent % RESTART_EVERY == RESTART_EVERY - 1) begin
                @(negedge clk);
                in_restart = 1;
                $fwrite(in_log, "R\n");
                @(negedge clk);
                in_restart = 0;
                // The marker sequence is done when accepting resumes.
                while (!bp_ready) @(negedge clk);
                @(negedge clk);
            end
        end

        @(negedge clk);
        in_flush = 1;
        $fwrite(in_log, "F\n");
        @(negedge clk);
        in_flush = 0;

        // Drain until the closing byte
        for (i = 0; i < 5000 && !got_last; i = i + 1)
            @(posedge clk);

        if (!got_last)
            $display("FAIL: no out_last within timeout");
        else
            $display("DONE: byte_count=%0d", byte_count);

        $fclose(in_log);
        $fclose(out_bin);
        $finish;
    end

endmodule
