# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# Arty S7-50 constraints for mjpegZero demo (fcapz, 720p)
# Device: XC7S50CSGA324-1
# Reference: Digilent Arty S7-50 schematic / master XDC
# No UART pins; host communication uses fcapz through FT2232H Channel A.

# ----------------------------------------------------------------------------
# Clock — 100 MHz oscillator
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name CLK100MHZ [get_ports CLK100MHZ]

# E3 is not in the same clock region/column as MMCME2_ADV_X1Y1.
# Use FALSE to allow general routing for the pre-MMCM path; the PLL absorbs the jitter.
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets CLK100MHZ_IBUF]

# The MMCME2_ADV generates 150 MHz internally; constrain it:
create_generated_clock -name clk_150 \
    -source [get_pins u_clkgen/u_mmcm/CLKIN1] \
    -master_clock CLK100MHZ \
    [get_pins u_clkgen/u_bufg/O]

# ----------------------------------------------------------------------------
# LEDs (active-high)
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports led0]
# led1: K15 is not a valid ball in the CSGA324 package; auto-place on any free I/O.
set_property IOSTANDARD LVCMOS33 [get_ports led1]
# Allow bitstream generation with the auto-placed led1 pin:
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN N14 IOSTANDARD LVCMOS33} [get_ports led3]

set_false_path -to [get_ports {led0 led1 led2 led3}]
