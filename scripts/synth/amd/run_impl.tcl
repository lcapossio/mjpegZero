# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Vivado Implementation Script for mjpegZero
# Runs place & route on the synthesized design
# Target: AMD/Xilinx Spartan-7 XC7S50, 150 MHz (6.897 ns period)
# Usage: vivado -mode batch -source scripts/synth/amd/run_impl.tcl
# ============================================================================

set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ../../..]]
set output_dir [file join $proj_dir build impl]
set synth_dir  [file join $proj_dir build synth]
file mkdir $output_dir

# Open synthesized checkpoint
open_checkpoint $synth_dir/post_synth.dcp

# Optimize
opt_design

# Place with timing-driven exploration
place_design -directive Explore

# Report post-place timing
report_timing_summary -file $output_dir/post_place_timing.rpt

# Physical optimization (post-place timing recovery)
phys_opt_design

# Route
route_design

# Post-route physical optimization
phys_opt_design

# Reports
report_utilization -file $output_dir/utilization.rpt
report_timing_summary -file $output_dir/timing_summary.rpt
report_timing -nworst 20 -file $output_dir/timing_worst20.rpt
report_design_analysis -logic_level_distribution -file $output_dir/logic_levels.rpt

# Write checkpoint
write_checkpoint -force $output_dir/post_route.dcp

# Print summary
puts "======================================================================"
puts "IMPLEMENTATION COMPLETE - Target: 150 MHz (6.897 ns)"
puts "======================================================================"

# Extract WNS (tabular format: header, dashes, value row)
set fp [open $output_dir/timing_summary.rpt r]
set content [read $fp]
close $fp

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
    puts "Post-Route WNS: $wns ns"
    set fmax_mhz [expr {1000.0 / (6.897 - $wns)}]
    puts [format "Estimated Fmax: %.1f MHz" $fmax_mhz]
    if {$wns >= 0} {
        puts "TIMING MET at 150 MHz!"
    } else {
        puts "TIMING VIOLATION at 150 MHz: WNS = $wns ns"
        set actual_period [expr {6.897 - $wns}]
        set actual_fmax [expr {1000.0 / $actual_period}]
        puts [format "Achievable Fmax: %.1f MHz (period: %.3f ns)" $actual_fmax $actual_period]
    }
} else {
    puts "Could not parse WNS from timing report"
}

puts "Reports written to: $output_dir"
puts "======================================================================"
