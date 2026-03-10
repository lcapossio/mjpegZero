# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# Arty A7-100T constraints for mjpegZero demo (JTAG-to-AXI, 720p)
# Device: XC7A100TCSG324-1
# Reference: Digilent Arty A7 master XDC

# ----------------------------------------------------------------------------
# Clock — 100 MHz oscillator
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name CLK100MHZ [get_ports CLK100MHZ]

# On A7-100T, E3 (bank 35 MRCC) has dedicated routing to MMCME2_ADV_X0Y1
# in the same clock column — no CLOCK_DEDICATED_ROUTE workaround needed.
create_generated_clock -name clk_150 \
    -source [get_pins u_clkgen/u_mmcm/CLKIN1] \
    -master_clock CLK100MHZ \
    [get_pins u_clkgen/u_bufg/O]

# ----------------------------------------------------------------------------
# LEDs (active-high) — Digilent Arty A7 LD0..LD3
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports led3]

set_false_path -to [get_ports {led0 led1 led2 led3}]
