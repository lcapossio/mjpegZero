// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// ============================================================================
// bram_sdp.v — Altera (Intel) inferred Simple Dual-Port Block RAM
// ============================================================================
// Synthesises to M9K (Cyclone IV/V), M10K (Cyclone 10), M20K (Arria 10 /
// Stratix 10) depending on the target device.
//
// Quartus inference attributes:
//   (* ramstyle = "no_rw_check" *)  — suppresses read-during-write warnings;
//   Quartus infers SDP block RAM from two-always-block code.
//
// Read latency: 2 clock cycles (matches Xilinx DOB_REG=1 behaviour).
//
// For families that do not support 2-stage registered output, enable
// ALTSYNCRAM or explicitly instantiate the altsyncram megafunction and
// set OUTDATA_REG_B="CLOCK0".
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

    (* ramstyle = "no_rw_check" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
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
