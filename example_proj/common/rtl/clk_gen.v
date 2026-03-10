// SPDX-License-Identifier: MIT
// Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
// Copyright (c) 2026 Leonardo Capossio — bard0 design
//
// clk_gen.v — 100 MHz → 150 MHz clock generation for Arty S7-50
// Uses MMCME2_ADV primitive: CLKFBOUT_MULT_F=9, CLKOUT0_DIVIDE_F=6
// VCO = 900 MHz (within 600–1200 MHz range for XC7S50-1)
// Verilog 2001

`timescale 1ns / 1ps

module clk_gen (
    input  wire clk_in,    // 100 MHz board oscillator (pin E3)
    input  wire reset,     // active-high async reset
    output wire clk_out,   // 150 MHz output
    output wire locked     // PLL lock indicator
);

    wire clkfb;
    wire clkout0_buf;

    MMCME2_ADV #(
        .BANDWIDTH            ("OPTIMIZED"),
        .CLKOUT4_CASCADE      ("FALSE"),
        .COMPENSATION         ("ZHOLD"),
        .STARTUP_WAIT         ("FALSE"),
        .DIVCLK_DIVIDE        (1),
        .CLKFBOUT_MULT_F      (9.000),   // VCO = 100 * 9 = 900 MHz
        .CLKFBOUT_PHASE       (0.000),
        .CLKOUT0_DIVIDE_F     (6.000),   // 900 / 6 = 150 MHz
        .CLKOUT0_PHASE        (0.000),
        .CLKOUT0_DUTY_CYCLE   (0.500),
        .CLKIN1_PERIOD        (10.000),  // 100 MHz = 10 ns
        .REF_JITTER1          (0.010)
    ) u_mmcm (
        .CLKOUT0  (clkout0_buf),
        .CLKOUT0B (),
        .CLKOUT1  (), .CLKOUT1B (),
        .CLKOUT2  (), .CLKOUT2B (),
        .CLKOUT3  (), .CLKOUT3B (),
        .CLKOUT4  (), .CLKOUT5  (), .CLKOUT6  (),
        .CLKFBOUT (clkfb),
        .CLKFBOUTB(),
        .LOCKED   (locked),
        .CLKIN1   (clk_in),
        .CLKIN2   (1'b0),
        .CLKINSEL (1'b1),
        .PWRDWN   (1'b0),
        .RST      (reset),
        .CLKFBIN  (clkfb),
        // unused dynamic ports
        .DADDR(7'h0), .DCLK(1'b0), .DEN(1'b0), .DI(16'h0), .DWE(1'b0),
        .DO(), .DRDY(),
        .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(), .PSCLK(1'b0)
    );

    BUFG u_bufg (
        .I (clkout0_buf),
        .O (clk_out)
    );

endmodule
