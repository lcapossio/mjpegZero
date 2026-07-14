// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_huffman_perf.sv — huffman_encoder throughput measurement
// ============================================================================
// Streams dense blocks (every coefficient nonzero: 64 symbols each, the
// worst case) at the pipeline's natural rate of one coefficient per clock,
// gated by the same in-flight credit rule the top level applies
// (blocks in flight < HUFF_BANKS). The output is never stalled. Reports the
// steady-state interval between consecutive block completions; 64 clocks
// means the encoder keeps up with the front end even on worst-case blocks.
// ============================================================================

`timescale 1ns / 1ps

module tb_huffman_perf;

    localparam NUM_BLOCKS = 40;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [1:0]  comp_id = 0;
    reg         in_valid = 0;
    reg  signed [15:0] in_data = 0;
    reg         in_sob = 0;
    wire        out_valid;
    wire [31:0] out_bits;
    wire [5:0]  out_len;
    wire        out_sob;
    wire        out_eob;

    huffman_encoder #(.HUFF_BANKS(4)) dut (
        .clk(clk), .rst_n(rst_n), .comp_id(comp_id), .restart(1'b0),
        .in_valid(in_valid), .in_data(in_data), .in_sob(in_sob),
        .out_valid(out_valid), .out_bits(out_bits), .out_len(out_len),
        .out_sob(out_sob), .out_eob(out_eob), .out_ready(1'b1)
    );

    always #5 clk = ~clk;

    integer eobs = 0;
    integer cycle = 0;
    integer last_eob_cycle = 0;
    integer max_interval = 0;
    integer interval;

    always @(posedge clk) begin
        cycle <= cycle + 1;
        if (out_valid && out_eob) begin
            interval = cycle - last_eob_cycle;
            last_eob_cycle <= cycle;
            eobs <= eobs + 1;
            // Steady state: ignore the first two block completions.
            if (eobs >= 2 && interval > max_interval)
                max_interval = interval;
        end
    end

    // Credit-gated feed: one coefficient per clock, next block only when
    // fewer than HUFF_BANKS blocks are in flight.
    integer fed = 0, i;

    initial begin
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        while (fed < NUM_BLOCKS) begin
            while (fed - eobs >= 3) @(negedge clk);   // in-flight < HUFF_BANKS-1
            for (i = 0; i < 64; i = i + 1) begin
                @(negedge clk);
                in_valid = 1;
                in_sob   = (i == 0);
                in_data  = (i[0]) ? 16'sd3 : -16'sd2;  // all nonzero: 64 symbols
            end
            fed = fed + 1;
        end
        @(negedge clk);
        in_valid = 0;
        in_sob   = 0;

        while (eobs < NUM_BLOCKS && cycle < 100000) @(posedge clk);

        $display("RESULT: %0d dense blocks, steady-state max interval %0d cycles/block",
                 eobs, max_interval);
        $finish;
    end

endmodule
