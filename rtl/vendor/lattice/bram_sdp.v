// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// bram_sdp.v — Lattice inferred Simple Dual-Port Block RAM
// ============================================================================
// Synthesises to EBR (ECP5, Crosslink-NX) or LRAM (iCE40 UltraPlus) depending
// on device.  Tested with Lattice Radiant and Diamond tool flows.
//
// Radiant/Synplify attribute: (* syn_ramstyle = "block_ram" *)
// Lattice LSE attribute:      (* ram_style = "block" *)
//
// Read latency: 2 clock cycles (matches Xilinx DOB_REG=1 behaviour).
//
// If the synthesiser does not honour the 2-stage output register,
// replace with an explicit PDPW16KD (ECP5) instantiation and set
// OUTREG="OUTREG".
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

    (* syn_ramstyle = "block_ram" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
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
