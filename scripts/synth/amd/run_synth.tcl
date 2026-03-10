# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Vivado Synthesis Script for mjpegZero
# Target: AMD/Xilinx Spartan-7 XC7S50 (Arty S7-50, CSGA324, -1)
# Usage: vivado -mode batch -source scripts/synth/amd/run_synth.tcl \
#                           [-tclargs [lite [quality]]]
#   No args:      LITE_MODE=0, 1920x1080, 150 MHz target
#   lite:         LITE_MODE=1, 1280x720, 150 MHz target (default Q95)
#   lite <1-100>: LITE_MODE=1, 1280x720, custom quality
# ============================================================================

# Parse command-line arguments
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

# Create project in memory (non-project mode)
set part xc7s50csga324-1
set top_module synth_timing_wrapper

# Source files
set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ../../..]]
set rtl_dir    [file join $proj_dir rtl]
set vendor_dir [file join $rtl_dir vendor amd]

set src_files [list \
    $vendor_dir/bram_sdp.v \
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
    $rtl_dir/synth_timing_wrapper.v \
]

# Output directory
set mode_suffix [expr {$lite_mode ? "_lite" : ""}]
set output_dir [file join $proj_dir build synth${mode_suffix}]
file mkdir $output_dir

# Read sources
read_verilog $src_files

# Create timing constraint
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

# Synthesize with mode and resolution parameters
synth_design -top $top_module -part $part -flatten_hierarchy rebuilt \
    -generic "LITE_MODE=$lite_mode LITE_QUALITY=$lite_quality IMG_WIDTH=$img_width IMG_HEIGHT=$img_height" \
    -retiming

# Reports
report_utilization -file $output_dir/utilization.rpt
report_timing_summary -file $output_dir/timing_summary.rpt
report_timing -nworst 20 -file $output_dir/timing_worst20.rpt

# Report logic levels
report_design_analysis -logic_level_distribution -file $output_dir/logic_levels.rpt

# Write checkpoint
write_checkpoint -force $output_dir/post_synth.dcp

# Print summary
set mode_str [expr {$lite_mode ? "LITE (${img_width}x${img_height}, Q${lite_quality} fixed)" : "FULL (${img_width}x${img_height}, dynamic quality)"}]
puts "======================================================================"
puts "SYNTHESIS COMPLETE - $mode_str"
puts "Target: $target_mhz MHz ($target_period ns)"
puts "======================================================================"

# Parse and display utilization summary
set fp [open $output_dir/utilization.rpt r]
set content [read $fp]
close $fp
puts $content

# Parse and display timing summary
set fp [open $output_dir/timing_summary.rpt r]
set content [read $fp]
close $fp

# Extract WNS from Vivado table format (line-based parsing):
#   | Design Timing Summary
#   ...
#   WNS(ns)      TNS(ns)  ...
#   -------      -------  ...
#   3.339        0.000    ...
set wns ""
set lines [split $content "\n"]
set in_summary 0
set past_separator 0
foreach line $lines {
    if {[string match "*Design Timing Summary*" $line]} {
        set in_summary 1
        continue
    }
    if {$in_summary && [string match "*WNS(ns)*" $line]} {
        continue
    }
    if {$in_summary && [regexp {^\s+---} $line]} {
        set past_separator 1
        continue
    }
    if {$in_summary && $past_separator} {
        if {[regexp {^\s+(-?[0-9]+\.[0-9]+)} $line match val]} {
            set wns $val
        }
        break
    }
}

if {$wns ne ""} {
    puts "WNS: $wns ns"
    set fmax_mhz [expr {1000.0 / ($target_period - $wns)}]
    puts [format "Estimated Fmax: %.1f MHz" $fmax_mhz]
    if {$wns >= 0} {
        puts "TIMING MET at $target_mhz MHz!"
    } elseif {$wns >= -0.5} {
        puts "TIMING CLOSE (WNS > -0.5ns) - proceed to implementation"
    } else {
        puts "TIMING VIOLATION at $target_mhz MHz - checking achievable Fmax"
        set actual_period [expr {$target_period - $wns}]
        set actual_fmax [expr {1000.0 / $actual_period}]
        puts [format "Achievable Fmax: %.1f MHz (period: %.3f ns)" $actual_fmax $actual_period]
    }
} else {
    puts "Could not parse WNS from timing report"
}

puts "======================================================================"
puts "Reports written to: $output_dir"
puts "======================================================================"
