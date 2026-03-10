// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// bram_sdp.v — Efinix inferred Simple Dual-Port Block RAM
// ============================================================================
// Synthesises to FIFO36K / EFX_RAM_AR blocks on Trion / Titanium devices.
// Efinity uses standard (* ram_style = "block" *) for BRAM inference.
//
// Read latency: 2 clock cycles (matches Xilinx DOB_REG=1 behaviour).
//
// For explicit instantiation use EFX_RAM_AR with OUTPUT_REG=1.
// Efinity Mapper reference: https://www.efinixinc.com/docs/efinity-mapper-ug-v2.html
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

    (* ram_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [WIDTH-1:0] rdata_r;

    // Stage 1: BRAM array read (registered)
    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        rdata_r <= mem[raddr];
    end

    // Stage 2: Output register (matches Xilinx DOB_REG=1)
    always @(posedge clk)
        rdata <= rdata_r;

endmodule
