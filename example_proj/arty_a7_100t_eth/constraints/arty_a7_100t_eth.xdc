# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# Arty A7-100T constraints for mjpegZero Ethernet RTP/JPEG demo (demo_top_eth)
# Device: XC7A100TCSG324-1
# Combines the fcapz/encoder demo pins with emacZero's MII pinout.

# ----------------------------------------------------------------------------
# Clock — 100 MHz oscillator (pin E3). MMCM derives 150/100/25 MHz.
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -period 10.000 -name CLK100MHZ [get_ports CLK100MHZ]

# ----------------------------------------------------------------------------
# LEDs (active-high) — Digilent Arty A7 LD0..LD3
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN H5  IOSTANDARD LVCMOS33} [get_ports led0]
set_property -dict {PACKAGE_PIN J5  IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN T9  IOSTANDARD LVCMOS33} [get_ports led2]
set_property -dict {PACKAGE_PIN T10 IOSTANDARD LVCMOS33} [get_ports led3]
set_false_path -to [get_ports {led0 led1 led2 led3}]

# ----------------------------------------------------------------------------
# Ethernet MII (Bank 15, LVCMOS33) — onboard DP83848
# ----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN H14 IOSTANDARD LVCMOS33} [get_ports {ETH_TXD[0]}]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports {ETH_TXD[1]}]
set_property -dict {PACKAGE_PIN J13 IOSTANDARD LVCMOS33} [get_ports {ETH_TXD[2]}]
set_property -dict {PACKAGE_PIN H17 IOSTANDARD LVCMOS33} [get_ports {ETH_TXD[3]}]
set_property -dict {PACKAGE_PIN H15 IOSTANDARD LVCMOS33} [get_ports ETH_TX_EN]
set_property -dict {PACKAGE_PIN H16 IOSTANDARD LVCMOS33} [get_ports ETH_TX_CLK]

set_property -dict {PACKAGE_PIN D18 IOSTANDARD LVCMOS33} [get_ports {ETH_RXD[0]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {ETH_RXD[1]}]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports {ETH_RXD[2]}]
set_property -dict {PACKAGE_PIN G17 IOSTANDARD LVCMOS33} [get_ports {ETH_RXD[3]}]
set_property -dict {PACKAGE_PIN G16 IOSTANDARD LVCMOS33} [get_ports ETH_RX_DV]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports ETH_RXERR]
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS33} [get_ports ETH_RX_CLK]

set_property -dict {PACKAGE_PIN G14 IOSTANDARD LVCMOS33} [get_ports ETH_CRS]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports ETH_COL]

set_property -dict {PACKAGE_PIN K13 IOSTANDARD LVCMOS33} [get_ports ETH_MDIO]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports ETH_MDC]

set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS33} [get_ports ETH_REF_CLK]
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33} [get_ports ETH_RSTN]

# ----------------------------------------------------------------------------
# MII receive/transmit clocks from the PHY (25 MHz at 100 Mbps)
# ----------------------------------------------------------------------------
create_clock -period 40.000 -name eth_rx_clk [get_ports ETH_RX_CLK]
create_clock -period 40.000 -name eth_tx_clk [get_ports ETH_TX_CLK]

# The MII clock domains are asynchronous to all CLK100MHZ-derived clocks
# (150/100/25 MHz). The internal 150<->100 crossings (JPEG buffer dual-clock
# port + enc_done/jpeg_byte_cnt synchronizers) are proper CDC; if the related
# 150<->100 analysis reports failures, add set_false_path on those nets.
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks CLK100MHZ] \
    -group [get_clocks eth_rx_clk] \
    -group [get_clocks eth_tx_clk]

# ----------------------------------------------------------------------------
# Bitstream configuration
# ----------------------------------------------------------------------------
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
