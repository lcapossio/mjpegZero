# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# ============================================================================
# Vivado VHDL Synthesis Script for mjpegZero
# Target: AMD/Xilinx Spartan-7 XC7S50 (Arty S7-50, CSGA324, -1)
# Usage: vivado -mode batch -source scripts/synth/amd/run_synth_vhdl.tcl \
#                           [-tclargs [lite [quality]]]
#   No args:      LITE_MODE=0, 1920x1080, 150 MHz target
#   lite:         LITE_MODE=1, 1280x720, 150 MHz target (default Q95)
#   lite <1-100>: LITE_MODE=1, 1280x720, custom quality
# ============================================================================

set lite_mode 0
set lite_quality 95
set img_width 1920
set img_height 1080
set target_mhz 150
set target_period 6.897
if {[llength $argv] > 0 && [lindex $argv 0] eq "lite"} {
    set lite_mode 1
    set img_width 1280
    set img_height 720
    if {[llength $argv] > 1} {
        set lite_quality [lindex $argv 1]
    }
}

set part xc7s50csga324-1
set top_module synth_timing_wrapper

set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ../../..]]
set rtl_dir    [file join $proj_dir rtl]
set vhdl_dir   [file join $rtl_dir vhdl]

set src_files [list \
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
    $vhdl_dir/synth_timing_wrapper.vhd \
]

set mode_suffix [expr {$lite_mode ? "_lite" : ""}]
set output_dir [file join $proj_dir build synth_vhdl${mode_suffix}]
file mkdir $output_dir

read_vhdl -vhdl2008 $src_files

set xdc_file $output_dir/timing.xdc
set fp [open $xdc_file w]
puts $fp "create_clock -period $target_period -name clk \[get_ports clk\]"
puts $fp "# I/O delays for synthesis estimation only"
puts $fp "set_input_delay -clock clk 1.5 \[get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst_n}\]"
puts $fp "set_output_delay -clock clk 1.5 \[get_ports -filter {DIRECTION == OUT}\]"
puts $fp "# False-path I/O for implementation - wrapper validates internal timing only"
puts $fp "set_false_path -from \[get_ports -filter {DIRECTION == IN && NAME != clk}\]"
puts $fp "set_false_path -to \[get_ports -filter {DIRECTION == OUT}\]"
close $fp
read_xdc $xdc_file

synth_design -top $top_module -part $part -flatten_hierarchy rebuilt \
    -generic "LITE_MODE=$lite_mode LITE_QUALITY=$lite_quality IMG_WIDTH=$img_width IMG_HEIGHT=$img_height" \
    -retiming

report_utilization -file $output_dir/utilization.rpt
report_timing_summary -file $output_dir/timing_summary.rpt
report_timing -nworst 20 -file $output_dir/timing_worst20.rpt
report_design_analysis -logic_level_distribution -file $output_dir/logic_levels.rpt

write_checkpoint -force $output_dir/post_synth.dcp

set mode_str [expr {$lite_mode ? "LITE (${img_width}x${img_height}, Q${lite_quality} fixed)" : "FULL (${img_width}x${img_height}, dynamic quality)"}]
puts "======================================================================"
puts "VHDL SYNTHESIS COMPLETE - $mode_str"
puts "Target: $target_mhz MHz ($target_period ns)"
puts "Reports written to: $output_dir"
puts "======================================================================"
