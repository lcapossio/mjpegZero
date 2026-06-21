# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# ============================================================================
# create_project.tcl — Vivado script for the Arty A7-100T Ethernet RTP/JPEG demo
#
# Usage (from repo root):
#   vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/create_project.tcl
#   vivado -mode batch -source .../create_project.tcl -tclargs synth   ;# stop after synth
#
# Outputs under example_proj/arty_a7_100t_eth/build/.
# ============================================================================

set synth_only 0
if {$argc >= 1 && [lindex $argv 0] eq "synth"} { set synth_only 1 }

set part "xc7a100tcsg324-1"
set top  "demo_top_eth"

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ../../..]]
set ex_dir     [file normalize [file join $script_dir ..]]
set common_dir [file normalize [file join $script_dir ../../common]]
set build_dir  [file normalize [file join $ex_dir build]]
set rpt_dir    [file normalize [file join $build_dir reports]]
set proj_dir   [file normalize [file join $build_dir project]]

file mkdir $build_dir
file mkdir $rpt_dir
file delete -force $proj_dir

set fcapz_rtl [file normalize $repo_root/fcapz/rtl]
set emac_rtl  [file normalize $repo_root/emaczero/rtl]
set emac_arty [file normalize $repo_root/emaczero/fpga/arty_a7/rtl]

set rtl_files [list \
    $repo_root/rtl/bram_sdp.v \
    $repo_root/rtl/dct_1d.v \
    $repo_root/rtl/dct_2d.v \
    $repo_root/rtl/input_buffer.v \
    $repo_root/rtl/quantizer.v \
    $repo_root/rtl/zigzag_reorder.v \
    $repo_root/rtl/huffman_encoder.v \
    $repo_root/rtl/bitstream_packer.v \
    $repo_root/rtl/jfif_writer.v \
    $repo_root/rtl/axi4_lite_regs.v \
    $repo_root/rtl/rgb_to_ycbcr.v \
    $repo_root/rtl/mjpegzero_enc_top.v \
    $common_dir/rtl/axi_init.v \
    $ex_dir/rtl/clk_gen_eth.v \
    $ex_dir/rtl/jpeg_buffer_dc.v \
    $ex_dir/rtl/demo_top_eth.v \
    $repo_root/rtl/eth/jpeg_rtp_tx.v \
    $repo_root/rtl/eth/jpeg_rtp_trigger.v \
    $repo_root/rtl/eth/mac_csr_init.v \
    $fcapz_rtl/dpram.v \
    $fcapz_rtl/reset_sync.v \
    $fcapz_rtl/trig_compare.v \
    $fcapz_rtl/fcapz_async_fifo.v \
    $fcapz_rtl/jtag_reg_iface.v \
    $fcapz_rtl/fcapz_regbus_mux.v \
    $fcapz_rtl/jtag_pipe_iface.v \
    $fcapz_rtl/jtag_burst_read.v \
    $fcapz_rtl/fcapz_ela.v \
    $fcapz_rtl/fcapz_ejtagaxi.v \
    $fcapz_rtl/jtag_tap/jtag_tap_xilinx7.v \
    $fcapz_rtl/fcapz_ela_xilinx7.v \
    $fcapz_rtl/fcapz_ejtagaxi_xilinx7.v \
    $emac_rtl/crc32.v \
    $emac_rtl/async_fifo.v \
    $emac_rtl/sync_fifo.v \
    $emac_rtl/mii_if.v \
    $emac_rtl/eth_mac_rx.v \
    $emac_rtl/eth_mac_tx.v \
    $emac_rtl/eth_mac.v \
    $emac_rtl/mdio_master.v \
    $emac_rtl/eth_stats.v \
    $emac_rtl/eth_pause.v \
    $emac_rtl/axilite_regs.v \
    $emac_rtl/ddr_output.v \
    $emac_rtl/ddr_input.v \
    $emac_rtl/rgmii_if.v \
    $emac_rtl/gmii_cdc.v \
    $emac_rtl/net/tx_csum_off.v \
    $emac_rtl/eth_mac_sys.v \
    $emac_rtl/net/net_rx.v \
    $emac_arty/arp_responder.v \
    $emac_arty/arty_tx_arbiter.v \
]

set xdc_file [file normalize $ex_dir/constraints/arty_a7_100t_eth.xdc]

create_project -force arty_a7_eth $proj_dir -part $part
add_files -norecurse $rtl_files
add_files -fileset constrs_1 -norecurse $xdc_file
set_property top $top [current_fileset]

puts "======================================================================"
puts "Synthesis (top=$top, part=$part)"
puts "======================================================================"
# XILINX_7SERIES selects the real Xilinx DDR/ODDR/IDDR primitives inside the
# emacZero MII/RGMII wrappers (ddr_output, ddr_input, gmii_cdc, ...).
synth_design -top $top -part $part -flatten_hierarchy rebuilt \
    -directive PerformanceOptimized -verilog_define XILINX_7SERIES
report_utilization    -file $rpt_dir/synth_utilization.rpt
report_timing_summary -file $rpt_dir/synth_timing.rpt
write_checkpoint -force $build_dir/post_synth.dcp
puts "Synthesis complete."

if {$synth_only} {
    puts "synth-only mode: stopping after synthesis."
    return
}

puts "======================================================================"
puts "Implementation"
puts "======================================================================"
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore -tns_cleanup
phys_opt_design -directive Explore

report_utilization    -file $rpt_dir/impl_utilization.rpt
report_timing_summary -file $rpt_dir/impl_timing_summary.rpt
report_timing -nworst 10 -file $rpt_dir/impl_timing_worst10.rpt
write_checkpoint -force $build_dir/post_route.dcp

write_bitstream -force $build_dir/arty_a7_eth_demo.bit
puts "======================================================================"
puts "DONE — bitstream: $build_dir/arty_a7_eth_demo.bit"
puts "======================================================================"
