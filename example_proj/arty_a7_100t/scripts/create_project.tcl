# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# create_project.tcl — Vivado project-mode script for Arty A7-100T MJPEG demo
#
# Usage (from repo root):
#   vivado -mode batch -source example_proj/arty_a7_100t/scripts/create_project.tcl
#
# Outputs:
#   example_proj/arty_a7_100t/build/arty_a7_demo.bit  — bitstream
#   example_proj/arty_a7_100t/build/reports/           — utilization + timing reports
# ============================================================================

set part "xc7a100tcsg324-1"
set top  "demo_top"

# Locate directories
set script_dir  [file normalize [file dirname [info script]]]
set repo_root   [file normalize [file join $script_dir ../../..]]
set ex_dir      [file normalize [file join $script_dir ..]]
set common_dir  [file normalize [file join $script_dir ../../common]]
set build_dir   [file normalize [file join $ex_dir build]]
set rpt_dir     [file normalize [file join $build_dir reports]]
set proj_dir    [file normalize [file join $build_dir project]]

file mkdir $build_dir
file mkdir $rpt_dir
# Force-clean the project directory so Vivado doesn't reuse stale run checkpoints
file delete -force $proj_dir

# ============================================================================
# Source files
# ============================================================================
set fcapz_rtl [file normalize $repo_root/fcapz/rtl]

set rtl_files [list \
    $repo_root/rtl/vendor/amd/bram_sdp.v \
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
    $common_dir/rtl/clk_gen.v \
    $common_dir/rtl/axi_init.v \
    $common_dir/rtl/demo_top.v \
    $fcapz_rtl/dpram.v \
    $fcapz_rtl/reset_sync.v \
    $fcapz_rtl/trig_compare.v \
    $fcapz_rtl/fcapz_async_fifo.v \
    $fcapz_rtl/jtag_reg_iface.v \
    $fcapz_rtl/fcapz_regbus_mux.v \
    $fcapz_rtl/jtag_burst_read.v \
    $fcapz_rtl/fcapz_ela.v \
    $fcapz_rtl/fcapz_ejtagaxi.v \
    $fcapz_rtl/jtag_tap/jtag_tap_xilinx7.v \
    $fcapz_rtl/fcapz_ela_xilinx7.v \
    $fcapz_rtl/fcapz_ejtagaxi_xilinx7.v \
]

set xdc_file [file normalize $ex_dir/constraints/arty_a7_100t.xdc]

# ============================================================================
# Create Vivado project
# ============================================================================
create_project -force arty_a7_demo $proj_dir -part $part

add_files -norecurse $rtl_files
add_files -fileset constrs_1 -norecurse $xdc_file

set_property top $top [current_fileset]

# fcapz_ela.v uses `include "fcapz_version.vh" — add fcapz/rtl to include path
set_property include_dirs [list $fcapz_rtl] [get_filesets sources_1]

# Top-level generics
set_property generic {LITE_MODE=1 LITE_QUALITY=75 IMG_WIDTH=1280 IMG_HEIGHT=720 JPEG_WORDS=65536} \
    [get_filesets sources_1]

# ============================================================================
# Synthesis
# ============================================================================
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]

puts "======================================================================"
puts "Starting synthesis..."
puts "======================================================================"

launch_runs synth_1 -jobs 4
wait_on_run synth_1

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed — see $proj_dir/arty_a7_demo.runs/synth_1/"
}
puts "Synthesis complete."

open_run synth_1 -name synth_1
report_utilization    -file $rpt_dir/synth_utilization.rpt
report_timing_summary -file $rpt_dir/synth_timing.rpt
write_checkpoint -force $build_dir/post_synth.dcp

# ============================================================================
# Implementation
# ============================================================================
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

puts "======================================================================"
puts "Starting implementation..."
puts "======================================================================"

launch_runs impl_1 -jobs 4
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed — see $proj_dir/arty_a7_demo.runs/impl_1/"
}
puts "Implementation complete."

open_run impl_1 -name impl_1
report_utilization    -file $rpt_dir/impl_utilization.rpt
report_timing_summary -file $rpt_dir/impl_timing_summary.rpt
report_timing -nworst 10 -file $rpt_dir/impl_timing_worst10.rpt
write_checkpoint -force $build_dir/post_route.dcp

# ============================================================================
# Bitstream
# ============================================================================
puts "Writing bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set bit_src [glob -nocomplain $proj_dir/arty_a7_demo.runs/impl_1/*.bit]
if {[llength $bit_src] > 0} {
    file copy -force [lindex $bit_src 0] $build_dir/arty_a7_demo.bit
    puts "======================================================================"
    puts "DONE — bitstream: $build_dir/arty_a7_demo.bit"
    puts "======================================================================"
} else {
    error "Bitstream not found — check impl run logs"
}

# ============================================================================
# Parse and print post-route WNS
# ============================================================================
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
    else           { puts "TIMING VIOLATION — check reports" }
}
puts "Reports: $rpt_dir"
