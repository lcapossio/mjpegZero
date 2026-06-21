# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# program_fpga.tcl - program the Arty A7-100T with the Ethernet demo bitstream.
#   vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/program_fpga.tcl
# Requires hw_server running (localhost:3121).

set script_dir [file normalize [file dirname [info script]]]
set ex_dir     [file normalize [file join $script_dir ..]]
set bit        [file normalize [file join $ex_dir build arty_a7_eth_demo.bit]]

if {![file exists $bit]} { puts "ERROR: bitstream not found: $bit"; exit 1 }

open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
puts "Programming $dev with $bit ..."
program_hw_devices $dev
refresh_hw_device $dev
puts "DONE: programmed [get_property PROGRAM.FILE $dev]"
close_hw_target
disconnect_hw_server
