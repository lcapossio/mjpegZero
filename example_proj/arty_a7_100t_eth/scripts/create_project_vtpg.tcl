# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# create_project_vtpg.tcl - Arty A7-100T moving-pattern RTP/JPEG demo
#   (vtpgZero -> mjpegZero encoder -> RTP/JPEG over Ethernet, autonomous loop)
#
#   vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/create_project_vtpg.tcl
#   vivado -mode batch -source .../create_project_vtpg.tcl -tclargs synth   ;# synth only

set synth_only 0
if {$argc >= 1 && [lindex $argv 0] eq "synth"} { set synth_only 1 }

set part "xc7a100tcsg324-1"
set top  "demo_top_vtpg_eth"

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ../../..]]
set ex_dir     [file normalize [file join $script_dir ..]]
set common_dir [file normalize [file join $script_dir ../../common]]
set build_dir  [file normalize [file join $ex_dir build]]
set rpt_dir    [file normalize [file join $build_dir reports_vtpg]]
set proj_dir   [file normalize [file join $build_dir project_vtpg]]

file mkdir $build_dir
file mkdir $rpt_dir
file delete -force $proj_dir

set fcapz_rtl [file normalize $repo_root/fcapz/rtl]
set emac_rtl  [file normalize $repo_root/emaczero/rtl]
set emac_arty [file normalize $repo_root/emaczero/fpga/arty_a7/rtl]
set vtpg_rtl  [file normalize $repo_root/vtpgzero/rtl]

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
    $common_dir/rtl/demo_jpeg_buffer.v \
    $common_dir/rtl/jpeg_capture.v \
    $ex_dir/rtl/clk_gen_eth.v \
    $ex_dir/rtl/vtpg_udp_control.v \
    $ex_dir/rtl/vtpg_stream_control.v \
    $ex_dir/rtl/demo_top_vtpg_eth.v \
    $vtpg_rtl/vtpgz_core.v \
    $repo_root/rtl/eth/jpeg_rtp_tx.v \
    $repo_root/rtl/eth/jpeg_rtp_trigger.v \
    $repo_root/rtl/eth/axis_frame_buffer.v \
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

create_project -force arty_a7_vtpg $proj_dir -part $part
add_files -norecurse $rtl_files
# vtpg image memories: YCbCr-converted from the vtpgZero RGB .mem (OUTPUT_MODE=2
# reads the image triple as {Y,Cb,Cr}). $readmemh resolves them by basename.
add_files -norecurse [list \
    $ex_dir/data/mandrill_128x128_ycbcr.mem \
    $ex_dir/data/banana_32x32_ycbcr.mem]
add_files -fileset constrs_1 -norecurse $xdc_file
set_property include_dirs [list $vtpg_rtl] [current_fileset]
set_property top $top [current_fileset]

puts "=== Synthesis (top=$top) ==="
synth_design -top $top -part $part -flatten_hierarchy rebuilt \
    -retiming -verilog_define XILINX_7SERIES
report_utilization    -file $rpt_dir/synth_utilization.rpt
report_timing_summary -file $rpt_dir/synth_timing.rpt
write_checkpoint -force $build_dir/post_synth_vtpg.dcp
puts "Synthesis complete."
if {$synth_only} { puts "synth-only mode: stopping."; return }

puts "=== Implementation ==="
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore -tns_cleanup
phys_opt_design -directive Explore
report_utilization    -file $rpt_dir/impl_utilization.rpt
report_timing_summary -file $rpt_dir/impl_timing_summary.rpt
report_timing -nworst 10 -file $rpt_dir/impl_timing_worst10.rpt
write_checkpoint -force $build_dir/post_route_vtpg.dcp
write_bitstream -force $build_dir/arty_a7_vtpg_demo.bit
puts "DONE - bitstream: $build_dir/arty_a7_vtpg_demo.bit"
