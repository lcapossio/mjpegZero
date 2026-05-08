# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# ============================================================================
# create_project_vhdl.tcl - Vivado project-mode script for Arty A7-100T MJPEG demo
#
# Builds the existing Verilog board/fcapz shell with the VHDL MJPEG encoder
# hierarchy under demo_top.
#
# Usage (from repo root):
#   vivado -mode batch -source example_proj/arty_a7_100t/scripts/create_project_vhdl.tcl
#
# Outputs:
#   example_proj/arty_a7_100t/build_vhdl/arty_a7_demo_vhdl.bit
#   example_proj/arty_a7_100t/build_vhdl/reports/
# ============================================================================

set part "xc7a100tcsg324-1"
set top  "demo_top"

set script_dir  [file normalize [file dirname [info script]]]
set repo_root   [file normalize [file join $script_dir ../../..]]
set ex_dir      [file normalize [file join $script_dir ..]]
set common_dir  [file normalize [file join $script_dir ../../common]]
set build_dir   [file normalize [file join $ex_dir build_vhdl]]
set rpt_dir     [file normalize [file join $build_dir reports]]
set proj_dir    [file normalize [file join $build_dir project]]

file mkdir $build_dir
file mkdir $rpt_dir
file delete -force $proj_dir

set fcapz_rtl [file normalize $repo_root/fcapz/rtl]
set vhdl_dir  [file normalize $repo_root/rtl/vhdl]

set vhdl_files [list \
    $vhdl_dir/mjpegzero_pkg.vhd \
    $vhdl_dir/axi4_lite_regs.vhd \
    $vhdl_dir/bram_sdp.vhd \
    $vhdl_dir/input_buffer.vhd \
    $vhdl_dir/dct_1d.vhd \
    $vhdl_dir/dct_2d.vhd \
    $vhdl_dir/quantizer.vhd \
    $vhdl_dir/huffman_encoder.vhd \
    $vhdl_dir/bitstream_packer.vhd \
    $vhdl_dir/rgb_to_ycbcr.vhd \
    $vhdl_dir/zigzag_reorder.vhd \
    $vhdl_dir/jfif_writer.vhd \
    $vhdl_dir/mjpegzero_enc_top.vhd \
]

set verilog_files [list \
    $common_dir/rtl/clk_gen.v \
    $common_dir/rtl/axi_init.v \
    $common_dir/rtl/demo_top.v \
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
]

set xdc_file [file normalize $ex_dir/constraints/arty_a7_100t.xdc]

create_project -force arty_a7_demo_vhdl $proj_dir -part $part

add_files -norecurse $vhdl_files
foreach f $vhdl_files {
    set_property file_type {VHDL} [get_files $f]
}
add_files -norecurse $verilog_files
add_files -fileset constrs_1 -norecurse $xdc_file

set_property top $top [current_fileset]
set_property generic {LITE_MODE=1 LITE_QUALITY=75 IMG_WIDTH=1280 IMG_HEIGHT=720 JPEG_WORDS=65536} \
    [get_filesets sources_1]
update_compile_order -fileset sources_1

set_property strategy Flow_PerfOptimized_high [get_runs synth_1]

puts "======================================================================"
puts "Starting VHDL encoder synthesis for Arty A7-100T..."
puts "======================================================================"

launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed - see $proj_dir/arty_a7_demo_vhdl.runs/synth_1/"
}
puts "Synthesis complete."

open_run synth_1 -name synth_1
report_utilization    -file $rpt_dir/synth_utilization.rpt
report_timing_summary -file $rpt_dir/synth_timing.rpt
write_checkpoint -force $build_dir/post_synth.dcp

set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

puts "======================================================================"
puts "Starting implementation..."
puts "======================================================================"

launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed - see $proj_dir/arty_a7_demo_vhdl.runs/impl_1/"
}
puts "Implementation complete."

open_run impl_1 -name impl_1
report_utilization    -file $rpt_dir/impl_utilization.rpt
report_timing_summary -file $rpt_dir/impl_timing_summary.rpt
report_timing -nworst 10 -file $rpt_dir/impl_timing_worst10.rpt
write_checkpoint -force $build_dir/post_route.dcp

puts "Writing bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set bit_src [glob -nocomplain $proj_dir/arty_a7_demo_vhdl.runs/impl_1/*.bit]
if {[llength $bit_src] > 0} {
    file copy -force [lindex $bit_src 0] $build_dir/arty_a7_demo_vhdl.bit
    puts "======================================================================"
    puts "DONE - bitstream: $build_dir/arty_a7_demo_vhdl.bit"
    puts "======================================================================"
} else {
    error "Bitstream not found - check impl run logs"
}

set fp [open $rpt_dir/impl_timing_summary.rpt r]
set content [read $fp]
close $fp

set wns ""
set lines [split $content "\n"]
set in_summary 0
set past_sep   0
foreach line $lines {
    if {[string match "*Design Timing Summary*" $line]} { set in_summary 1; continue }
    if {$in_summary && [string match "*WNS(ns)*" $line]} { continue }
    if {$in_summary && [regexp {^\s+---} $line]} { set past_sep 1; continue }
    if {$in_summary && $past_sep} {
        if {[regexp {^\s+(-?[0-9]+\.[0-9]+)} $line match val]} { set wns $val }
        break
    }
}
if {$wns ne ""} {
    puts "Post-Route WNS: $wns ns"
    if {$wns >= 0} { puts "TIMING MET at 150 MHz!" } \
    else           { puts "TIMING VIOLATION - check reports" }
}
puts "Reports: $rpt_dir"
