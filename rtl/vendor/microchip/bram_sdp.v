// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// bram_sdp.v — Microchip (Microsemi) inferred Simple Dual-Port Block RAM
// ============================================================================
// Synthesises to uSRAM (64×12) or LSRAM (1K×18) blocks on PolarFire /
// SmartFusion2 / IGLOO2 depending on size and Libero SoC inference.
//
// Synplify attribute (used by Libero):  (* syn_ramstyle = "block" *)
//
// Read latency: 2 clock cycles (matches Xilinx DOB_REG=1 behaviour).
//
// For large arrays the synthesiser may automatically cascade LSRAM blocks.
// Verify block RAM count in the Libero compile report.
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

    (* syn_ramstyle = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
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
