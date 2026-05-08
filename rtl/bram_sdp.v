// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies - commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio - bard0 design
//
// ============================================================================
// bram_sdp.v - Vendor-neutral behavioral Simple Dual-Port RAM
// ============================================================================
// Two-cycle read latency:
//   cycle 1: registered memory array read
//   cycle 2: registered output
//
// This file is the single Verilog bram_sdp implementation used by simulation
// and synthesis flows. Vendor tools may infer block RAM or another suitable
// memory resource from the behavioral description.
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

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [WIDTH-1:0] rdata_r;

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata_r <= mem[raddr];
        rdata <= rdata_r;
    end

endmodule
