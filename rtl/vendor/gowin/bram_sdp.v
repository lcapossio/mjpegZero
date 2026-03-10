// SPDX-License-Identifier: Apache-2.0
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// bram_sdp.v — GOWIN inferred Simple Dual-Port Block RAM
// ============================================================================
// Synthesises to BSRAM (BSRAMx9) / SSRAM blocks on GW1N / GW2A / GW5A.
// GOWIN EDA uses (* rw_check = 0 *) to suppress read-during-write warnings
// and (* ram_style = "block" *) for BRAM target.
//
// Read latency: 2 clock cycles (matches Xilinx DOB_REG=1 behaviour).
//
// For explicit instantiation use the GOWIN Gowin_SDPB IP primitive
// with OUTREG_EN="TRUE".  Generate via GOWIN EDA IP Core Generator.
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

    (* ram_style = "block" *) (* rw_check = 0 *) reg [WIDTH-1:0] mem [0:DEPTH-1];
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
