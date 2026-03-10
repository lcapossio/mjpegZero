// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// bram_sdp.v — Purely behavioral Simple Dual-Port BRAM (simulation / CI)
// ============================================================================
// Vendor-neutral behavioral model for use with iverilog, Verilator, or any
// simulator that does not have RAMB36E1 / vendor primitive models.
//
// Read latency: 2 clock cycles — matches rtl/vendor/amd/bram_sdp.v (DOB_REG=1)
// so the rest of the pipeline sees identical timing behaviour.
//
// Do NOT use for synthesis — no ram_style attributes, no vendor pragmas.
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

    reg [WIDTH-1:0] mem    [0:DEPTH-1];
    reg [WIDTH-1:0] rdata_r;

    // Stage 1 — BRAM array read (registered, matches RAMB36E1 array latency)
    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata_r <= mem[raddr];
    end

    // Stage 2 — Output register (matches DOB_REG=1)
    always @(posedge clk)
        rdata <= rdata_r;

endmodule
