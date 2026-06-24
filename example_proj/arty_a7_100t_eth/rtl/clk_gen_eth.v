// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Leonardo Capossio
//
// clk_gen_eth.v - 100 MHz -> {150, 100, 25} MHz for the Arty A7-100T Ethernet
// demo. One MMCME2_ADV: VCO = 100 * 9 = 900 MHz.
//   CLKOUT0 = 900 / 6  = 150 MHz  (encoder / fcapz / JPEG buffer write)
//   CLKOUT1 = 900 / 9  = 100 MHz  (Ethernet MAC island)
//   CLKOUT2 = 900 / 36 =  25 MHz  (PHY reference, driven out via ODDR)
// Verilog 2001

`timescale 1ns / 1ps

module clk_gen_eth (
    input  wire clk_in,     // 100 MHz board oscillator
    input  wire reset,      // active-high async reset
    output wire clk_150,
    output wire clk_100,
    output wire clk_25,
    output wire locked
);

    wire clkfb, c0, c1, c2;

    MMCME2_ADV #(
        .BANDWIDTH          ("OPTIMIZED"),
        .CLKOUT4_CASCADE    ("FALSE"),
        .COMPENSATION       ("ZHOLD"),
        .STARTUP_WAIT       ("FALSE"),
        .DIVCLK_DIVIDE      (1),
        .CLKFBOUT_MULT_F    (9.000),    // VCO = 900 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (6.000),    // 150 MHz
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT1_DIVIDE     (9),        // 100 MHz
        .CLKOUT1_PHASE      (0.000),
        .CLKOUT1_DUTY_CYCLE (0.500),
        .CLKOUT2_DIVIDE     (36),       // 25 MHz
        .CLKOUT2_PHASE      (0.000),
        .CLKOUT2_DUTY_CYCLE (0.500),
        .CLKIN1_PERIOD      (10.000),
        .REF_JITTER1        (0.010)
    ) u_mmcm (
        .CLKOUT0  (c0), .CLKOUT0B(),
        .CLKOUT1  (c1), .CLKOUT1B(),
        .CLKOUT2  (c2), .CLKOUT2B(),
        .CLKOUT3  (), .CLKOUT3B(),
        .CLKOUT4  (), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT (clkfb), .CLKFBOUTB(),
        .LOCKED   (locked),
        .CLKIN1   (clk_in),
        .CLKIN2   (1'b0),
        .CLKINSEL (1'b1),
        .PWRDWN   (1'b0),
        .RST      (reset),
        .CLKFBIN  (clkfb),
        .DADDR(7'h0), .DCLK(1'b0), .DEN(1'b0), .DI(16'h0), .DWE(1'b0),
        .DO(), .DRDY(),
        .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(), .PSCLK(1'b0)
    );

    BUFG b0 (.I(c0), .O(clk_150));
    BUFG b1 (.I(c1), .O(clk_100));
    BUFG b2 (.I(c2), .O(clk_25));

endmodule
