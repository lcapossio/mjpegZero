# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# Core-only Vivado synthesis for apples-to-apples Verilog/VHDL comparison.
#
# Usage:
#   vivado -mode batch -source scripts/synth/amd/run_core_synth.tcl \
#          -tclargs <verilog|vhdl> [lite [quality]]
#
# No args after language: LITE_MODE=0, 1920x1080, dynamic quality.
# lite:                   LITE_MODE=1, 1280x720, fixed Q95.
# lite <1-100>:           LITE_MODE=1, 1280x720, fixed custom quality.

if {[llength $argv] < 1} {
    puts "ERROR: expected language argument: verilog or vhdl"
    exit 1
}

set language [string tolower [lindex $argv 0]]
if {$language ne "verilog" && $language ne "vhdl"} {
    puts "ERROR: language must be verilog or vhdl, got '$language'"
    exit 1
}

set lite_mode 0
set lite_quality 95
set img_width 1920
set img_height 1080
set target_mhz 150
set target_period 6.667

if {[llength $argv] > 1 && [lindex $argv 1] eq "lite"} {
    set lite_mode 1
    set img_width 1280
    set img_height 720
    if {[llength $argv] > 2} {
        set lite_quality [lindex $argv 2]
    }
}

set part xc7a100tcsg324-1
set top_module mjpegzero_enc_top

set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ../../..]]
set rtl_dir    [file join $proj_dir rtl]
set vhdl_dir   [file join $rtl_dir vhdl]

set mode_suffix [expr {$lite_mode ? "_lite" : ""}]
set output_dir [file join $proj_dir build core_synth_${language}${mode_suffix}]
file mkdir $output_dir

if {$language eq "verilog"} {
    set src_files [list \
        $rtl_dir/bram_sdp.v \
        $rtl_dir/dct_1d.v \
        $rtl_dir/dct_2d.v \
        $rtl_dir/input_buffer.v \
        $rtl_dir/quantizer.v \
        $rtl_dir/zigzag_reorder.v \
        $rtl_dir/huffman_encoder.v \
        $rtl_dir/bitstream_packer.v \
        $rtl_dir/jfif_writer.v \
        $rtl_dir/axi4_lite_regs.v \
        $rtl_dir/mjpegzero_enc_top.v \
    ]
    read_verilog $src_files
} else {
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
    ]
    read_vhdl $src_files
}

set xdc_file [file join $output_dir timing.xdc]
set fp [open $xdc_file w]
puts $fp "create_clock -period $target_period -name clk \[get_ports clk\]"
close $fp
read_xdc $xdc_file

synth_design -top $top_module -part $part -flatten_hierarchy rebuilt \
    -generic "LITE_MODE=$lite_mode LITE_QUALITY=$lite_quality IMG_WIDTH=$img_width IMG_HEIGHT=$img_height RGB_INPUT=0" \
    -retiming

report_utilization -file [file join $output_dir utilization.rpt]
report_utilization -hierarchical -file [file join $output_dir utilization_hier.rpt]
report_timing_summary -file [file join $output_dir timing_summary.rpt]
report_timing -nworst 20 -file [file join $output_dir timing_worst20.rpt]
report_design_analysis -logic_level_distribution -file [file join $output_dir logic_levels.rpt]
write_checkpoint -force [file join $output_dir post_synth.dcp]

set mode_str [expr {$lite_mode ? "LITE (${img_width}x${img_height}, Q${lite_quality})" : "FULL (${img_width}x${img_height}, dynamic quality)"}]
puts "======================================================================"
puts "CORE SYNTHESIS COMPLETE - [string toupper $language] - $mode_str"
puts "Part: $part"
puts "Target: $target_mhz MHz ($target_period ns)"
puts "Reports written to: $output_dir"
puts "======================================================================"
