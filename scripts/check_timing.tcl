# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Timing Analysis Script
# Extracts key metrics from synthesis/implementation reports
# ============================================================================

proc check_reports {report_dir label} {
    puts "======================================================================"
    puts "$label"
    puts "======================================================================"

    # Utilization
    set util_file $report_dir/utilization.rpt
    if {[file exists $util_file]} {
        set fp [open $util_file r]
        set content [read $fp]
        close $fp

        # Extract LUT, FF, BRAM, DSP usage
        if {[regexp {Slice LUTs\s+\|\s+(\d+)\s+\|\s+\d+\s+\|\s+\d+\s+\|\s+([0-9.]+)} $content match luts pct]} {
            puts "  LUTs:   $luts ($pct%)"
        }
        if {[regexp {Slice Registers\s+\|\s+(\d+)\s+\|\s+\d+\s+\|\s+\d+\s+\|\s+([0-9.]+)} $content match ffs pct]} {
            puts "  FFs:    $ffs ($pct%)"
        }
        if {[regexp {Block RAM Tile\s+\|\s+([0-9.]+)\s+\|\s+\d+\s+\|\s+\d+\s+\|\s+([0-9.]+)} $content match bram pct]} {
            puts "  BRAM:   $bram ($pct%)"
        }
        if {[regexp {DSPs\s+\|\s+(\d+)\s+\|\s+\d+\s+\|\s+\d+\s+\|\s+([0-9.]+)} $content match dsp pct]} {
            puts "  DSP48:  $dsp ($pct%)"
        }
    }

    # Timing
    set timing_file $report_dir/timing_summary.rpt
    if {[file exists $timing_file]} {
        set fp [open $timing_file r]
        set content [read $fp]
        close $fp

        if {[regexp {WNS\(ns\)\s+:\s+([-0-9.]+)} $content match wns]} {
            puts "  WNS:    $wns ns"
        }
        if {[regexp {TNS\(ns\)\s+:\s+([-0-9.]+)} $content match tns]} {
            puts "  TNS:    $tns ns"
        }
    }

    # Logic levels
    set ll_file $report_dir/logic_levels.rpt
    if {[file exists $ll_file]} {
        set fp [open $ll_file r]
        set content [read $fp]
        close $fp
        puts "  Logic level distribution:"
        puts "  (see $ll_file for details)"
    }

    puts ""
}

# Check synthesis reports
set script_dir [file dirname [info script]]
check_reports [file normalize $script_dir/../build/synth] "POST-SYNTHESIS"
check_reports [file normalize $script_dir/../build/impl] "POST-IMPLEMENTATION"
