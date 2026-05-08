// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies - commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio - bard0 design
//
// ============================================================================
// bram_sdp.v - Vendor-neutral tiled behavioral Simple Dual-Port RAM
// ============================================================================
// Two-cycle read latency:
//   cycle 1: registered memory array read
//   cycle 2: registered output
//
// This file is the single Verilog bram_sdp implementation used by simulation
// and synthesis flows. Vendor tools may infer block RAM or another suitable
// memory resource from the behavioral description. The 4096-deep behavioral
// tiling makes the desired memory banking visible without instantiating vendor
// primitives.
// ============================================================================

module bram_sdp #(
    parameter DEPTH = 8192,
    parameter WIDTH = 8
) (
    input  wire                       clk,
    input  wire                       we,
    input  wire [$clog2(DEPTH)-1:0]   waddr,
    input  wire [WIDTH-1:0]           wdata,
    input  wire [$clog2(DEPTH)-1:0]   raddr,
    output reg  [WIDTH-1:0]           rdata
);

    localparam TILE_DEPTH = 4096;
    localparam N_TILES    = (DEPTH + TILE_DEPTH - 1) / TILE_DEPTH;
    localparam ADDR_W     = $clog2(DEPTH);
    localparam SEL_BITS   = (N_TILES <= 1) ? 1 : $clog2(N_TILES);
    localparam INNER_W    = (N_TILES <= 1) ? ADDR_W : (ADDR_W - SEL_BITS);

    wire [SEL_BITS-1:0] rsel_now;
    reg  [SEL_BITS-1:0] rsel_d1;
    // rsel_d2 is only consumed by the multi-tile output mux. Single-tile
    // instances still build the common read-select pipeline for uniform timing.
    /* verilator lint_off UNUSEDSIGNAL */
    reg  [SEL_BITS-1:0] rsel_d2;
    /* verilator lint_on UNUSEDSIGNAL */

    generate
        if (N_TILES <= 1) begin : g_sel_one
            assign rsel_now = 1'b0;
        end else begin : g_sel_multi
            assign rsel_now = raddr[ADDR_W-1 -: SEL_BITS];
        end
    endgenerate

    always @(posedge clk) begin
        rsel_d1 <= rsel_now;
        rsel_d2 <= rsel_d1;
    end

    wire [WIDTH-1:0] tile_dout [0:N_TILES-1];

    genvar gi;
    generate
        for (gi = 0; gi < N_TILES; gi = gi + 1) begin : g_tile
            reg [WIDTH-1:0] mem [0:TILE_DEPTH-1];
            reg [WIDTH-1:0] rdata_r;
            reg [WIDTH-1:0] rdata_q;

            wire tile_we;
            if (N_TILES == 1) begin : g_we_one
                assign tile_we = we;
            end else begin : g_we_multi
                assign tile_we = we &&
                    (waddr[ADDR_W-1 -: SEL_BITS] == gi[SEL_BITS-1:0]);
            end

            always @(posedge clk) begin
                if (tile_we)
                    mem[waddr[INNER_W-1:0]] <= wdata;
                rdata_r <= mem[raddr[INNER_W-1:0]];
                rdata_q <= rdata_r;
            end

            assign tile_dout[gi] = rdata_q;
        end
    endgenerate

    generate
        if (N_TILES == 1) begin : g_out_one
            always @(*) begin
                rdata = tile_dout[0];
            end
        end else begin : g_out_mux
            integer mi;
            always @(*) begin
                rdata = tile_dout[0];
                for (mi = 1; mi < N_TILES; mi = mi + 1)
                    if (rsel_d2 == mi[SEL_BITS-1:0])
                        rdata = tile_dout[mi];
            end
        end
    endgenerate

endmodule
