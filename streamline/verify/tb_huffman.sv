// SPDX-License-Identifier: Apache-2.0
// ============================================================================
// tb_huffman.sv — huffman_encoder directed + random bench
// ============================================================================
// Feeds directed blocks (zero-run boundaries 15/16/17, DC-only, tail-heavy,
// dense, extreme amplitudes) plus pseudo-random blocks, with restart pulses
// timed one cycle after selected blocks' final-word acceptance — the same
// alignment the top level produces. Every accepted output word is logged as
// "bits len sob eob"; running the same bench against two implementations
// and diffing the logs proves transaction-level equivalence.
// ============================================================================

`timescale 1ns / 1ps

module tb_huffman;

    reg         clk = 0;
    reg         rst_n = 0;
    reg  [1:0]  comp_id = 0;
    reg         restart = 0;
    reg         in_valid = 0;
    reg  signed [15:0] in_data = 0;
    reg         in_sob = 0;
    wire        out_valid;
    wire [31:0] out_bits;
    wire [5:0]  out_len;
    wire        out_sob;
    wire        out_eob;
    reg         out_ready = 0;

    huffman_encoder #(.HUFF_BANKS(4)) dut (
        .clk(clk), .rst_n(rst_n), .comp_id(comp_id), .restart(restart),
        .in_valid(in_valid), .in_data(in_data), .in_sob(in_sob),
        .out_valid(out_valid), .out_bits(out_bits), .out_len(out_len),
        .out_sob(out_sob), .out_eob(out_eob), .out_ready(out_ready)
    );

    always #5 clk = ~clk;

    reg [31:0] lfsr = 32'hBEEF0001;
    task lfsr_step;
        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
    endtask

    always @(posedge clk) begin
        lfsr_step;
        out_ready <= (lfsr[1:0] != 2'b00);   // ~75% ready
    end

    integer log_f;
    integer words, eobs;

    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            $fwrite(log_f, "%08x %02d %b %b\n", out_bits, out_len, out_sob, out_eob);
            words = words + 1;
            if (out_eob)
                eobs = eobs + 1;
        end
    end

    // Data LFSR: stepped once per coefficient sent, never by the clock, so
    // the input stream is identical regardless of how the DUT paces itself.
    reg [31:0] data_lfsr = 32'h5EED0001;
    task data_lfsr_step;
        data_lfsr = {data_lfsr[30:0],
                     data_lfsr[31] ^ data_lfsr[21] ^ data_lfsr[1] ^ data_lfsr[0]};
    endtask

    // Block pattern generator: coefficient value for position i (0 = DC).
    function signed [15:0] coeff_at;
        input [3:0] pattern;
        input [5:0] i;
        begin
            case (pattern)
                4'd0: coeff_at = (i == 0) ? 16'sd100 : 16'sd0;                  // DC only
                4'd1: coeff_at = (i == 0) ? -16'sd50 : (i == 63) ? 16'sd1 : 16'sd0; // lone tail
                4'd2: coeff_at = (i == 0) ? 16'sd0 : (i == 16) ? -16'sd3 : 16'sd0;  // run 15
                4'd3: coeff_at = (i == 0) ? 16'sd7 : (i == 17) ? 16'sd3 : 16'sd0;   // run 16 (ZRL)
                4'd4: coeff_at = (i == 0) ? 16'sd7 : (i == 18) ? -16'sd9 : 16'sd0;  // run 17
                4'd5: coeff_at = (i == 33) ? 16'sd2 : (i == 0) ? 16'sd1 : 16'sd0;   // run 32 (2 ZRL)
                4'd6: coeff_at = (i == 0 || i == 1 || i == 49) ? 16'sd5 : 16'sd0;   // run 47
                4'd7: coeff_at = (i == 0) ? -16'sd2047 : (i == 63) ? 16'sd1023 : (i == 1) ? -16'sd1023 : 16'sd0; // extremes
                4'd8: coeff_at = $signed({12'd0, i[3:0]}) - 16'sd8;             // dense small
                4'd9: coeff_at = 16'sd1;                                        // dense ones
                default: begin                                                  // random sparse
                    coeff_at = (data_lfsr[3:0] == 4'd0)
                             ? $signed({{6{data_lfsr[9]}}, data_lfsr[9:0]}) : 16'sd0;
                end
            endcase
        end
    endfunction

    integer blk, i, guard;
    reg [3:0] pattern;

    task send_block;
        input [3:0] pat;
        input [1:0] comp;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                @(negedge clk);
                data_lfsr_step;
                in_valid = 1;
                in_sob   = (i == 0);
                comp_id  = comp;
                in_data  = coeff_at(pat, i[5:0]);
            end
            @(negedge clk);
            in_valid = 0;
            in_sob   = 0;
        end
    endtask

    initial begin
        log_f = $fopen("huffman_out.log", "w");
        words = 0;
        eobs  = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        for (blk = 0; blk < 60; blk = blk + 1) begin
            pattern = (blk < 22) ? blk[3:0] % 11 : 4'd10;
            // Rotate through components like the real MCU order Y,Y,Cb,Cr
            send_block(pattern, (blk[1:0] == 2'd2) ? 2'd2 :
                                (blk[1:0] == 2'd3) ? 2'd3 : 2'd0);

            // Wait for this block's final word to be accepted.
            guard = 0;
            while (eobs != blk + 1 && guard < 2000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 2000) begin
                $display("FAIL: block %0d never finished", blk);
                $finish;
            end

            // Restart pulse one cycle after acceptance, every 7th block.
            if (blk % 7 == 6) begin
                @(negedge clk);
                restart = 1;
                $fwrite(log_f, "RESTART\n");
                @(negedge clk);
                restart = 0;
            end
            @(negedge clk);
        end

        $display("DONE: %0d words, %0d blocks", words, eobs);
        $fclose(log_f);
        $finish;
    end

endmodule
