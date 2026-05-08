// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies - commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio - bard0 design
//
// Behavioral tiled JPEG output buffer for the board demo shell.
//
// The tile depth is chosen to keep Vivado from inferring cascaded BRAMs for a
// large JPEG buffer, while preserving the original one-cycle read timing used
// by the AXI readback FSM.

`timescale 1ns / 1ps

module demo_jpeg_buffer #(
    parameter JPEG_WORDS      = 65536,
    parameter JPEG_TILE_DEPTH = 4096
) (
    input  wire        clk,
    input  wire        we,
    input  wire [16:0] waddr,
    input  wire [31:0] wdata,
    input  wire [16:0] raddr,
    output reg  [31:0] rdata
);

    localparam JPEG_ADDR_W = $clog2(JPEG_WORDS);
    localparam JPEG_TILES = (JPEG_WORDS + JPEG_TILE_DEPTH - 1) / JPEG_TILE_DEPTH;
    localparam JPEG_SEL_BITS = (JPEG_TILES <= 1) ? 1 : $clog2(JPEG_TILES);
    localparam JPEG_INNER_W = $clog2(JPEG_TILE_DEPTH);

    wire [31:0] tile_dout [0:JPEG_TILES-1];

    genvar gi;
    generate
        for (gi = 0; gi < JPEG_TILES; gi = gi + 1) begin : g_tile
            (* ram_style = "block" *) reg [31:0] mem [0:JPEG_TILE_DEPTH-1];
            reg [31:0] tile_rdata;
            wire tile_we;

            if (JPEG_TILES == 1) begin : g_we_one
                assign tile_we = we;
            end else begin : g_we_multi
                assign tile_we = we &&
                    (waddr[JPEG_ADDR_W-1 -: JPEG_SEL_BITS] == gi[JPEG_SEL_BITS-1:0]);
            end

            always @(posedge clk) begin
                if (tile_we)
                    mem[waddr[JPEG_INNER_W-1:0]] <= wdata;
                tile_rdata <= mem[raddr[JPEG_INNER_W-1:0]];
            end

            assign tile_dout[gi] = tile_rdata;
        end
    endgenerate

    generate
        if (JPEG_TILES == 1) begin : g_out_one
            always @(*) begin
                rdata = tile_dout[0];
            end
        end else begin : g_out_mux
            integer mi;
            always @(*) begin
                rdata = tile_dout[0];
                for (mi = 1; mi < JPEG_TILES; mi = mi + 1)
                    if (raddr[JPEG_ADDR_W-1 -: JPEG_SEL_BITS] == mi[JPEG_SEL_BITS-1:0])
                        rdata = tile_dout[mi];
            end
        end
    endgenerate

endmodule
