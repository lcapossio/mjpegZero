// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// jpeg_buffer_dc.v - dual-clock, true-dual-port tiled JPEG output buffer.
//
// Port A (clk_a, ~150 MHz): encoder write + JTAG read-back, time-multiplexed on
//   a single address (write when `we`, otherwise read). These never occur at the
//   same time (writes during encode, JTAG reads after enc_done).
// Port B (clk_b, ~100 MHz): read-only, used by the Ethernet RTP packetizer.
//
// Tiled to stop Vivado cascading BRAMs; each tile maps to one true-dual-port
// RAMB. Both ports read combinationally-muxed registered tile data using the
// current address select, giving one-cycle read latency on each port (the
// consumer must hold the address until data is valid, as the AR FSM and
// jpeg_rtp_tx's hit logic both do).

`timescale 1ns / 1ps

module jpeg_buffer_dc #(
    parameter JPEG_WORDS      = 65536,
    parameter JPEG_TILE_DEPTH = 4096
) (
    // Port A: encoder write + JTAG read (clk_a)
    input  wire        clk_a,
    input  wire        we,
    input  wire [16:0] addr_a,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata_a,
    // Port B: Ethernet read (clk_b)
    input  wire        clk_b,
    input  wire [16:0] addr_b,
    output reg  [31:0] rdata_b
);

    localparam JPEG_ADDR_W   = $clog2(JPEG_WORDS);
    localparam JPEG_TILES    = (JPEG_WORDS + JPEG_TILE_DEPTH - 1) / JPEG_TILE_DEPTH;
    localparam JPEG_SEL_BITS = (JPEG_TILES <= 1) ? 1 : $clog2(JPEG_TILES);
    localparam JPEG_INNER_W  = $clog2(JPEG_TILE_DEPTH);

    wire [31:0] tile_a [0:JPEG_TILES-1];
    wire [31:0] tile_b [0:JPEG_TILES-1];

    genvar gi;
    generate
        for (gi = 0; gi < JPEG_TILES; gi = gi + 1) begin : g_tile
            (* ram_style = "block" *) reg [31:0] mem [0:JPEG_TILE_DEPTH-1];
            reg [31:0] ra, rb;
            wire tile_we;

            if (JPEG_TILES == 1) begin : g_we_one
                assign tile_we = we;
            end else begin : g_we_multi
                assign tile_we = we &&
                    (addr_a[JPEG_ADDR_W-1 -: JPEG_SEL_BITS] == gi[JPEG_SEL_BITS-1:0]);
            end

            // Port A: write-or-read @ clk_a
            always @(posedge clk_a) begin
                if (tile_we)
                    mem[addr_a[JPEG_INNER_W-1:0]] <= wdata;
                ra <= mem[addr_a[JPEG_INNER_W-1:0]];
            end

            // Port B: read @ clk_b
            always @(posedge clk_b) begin
                rb <= mem[addr_b[JPEG_INNER_W-1:0]];
            end

            assign tile_a[gi] = ra;
            assign tile_b[gi] = rb;
        end
    endgenerate

    generate
        if (JPEG_TILES == 1) begin : g_out_one
            always @(*) begin
                rdata_a = tile_a[0];
                rdata_b = tile_b[0];
            end
        end else begin : g_out_mux
            integer mi;
            always @(*) begin
                rdata_a = tile_a[0];
                rdata_b = tile_b[0];
                for (mi = 1; mi < JPEG_TILES; mi = mi + 1) begin
                    if (addr_a[JPEG_ADDR_W-1 -: JPEG_SEL_BITS] == mi[JPEG_SEL_BITS-1:0])
                        rdata_a = tile_a[mi];
                    if (addr_b[JPEG_ADDR_W-1 -: JPEG_SEL_BITS] == mi[JPEG_SEL_BITS-1:0])
                        rdata_b = tile_b[mi];
                end
            end
        end
    endgenerate

endmodule
