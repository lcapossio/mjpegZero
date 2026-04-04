# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Quartus Prime Synthesis Script for mjpegZero
# Target: Intel/Altera — default Cyclone V 5CEBA4F23C7N
# ============================================================================
#
# Usage:
#   quartus_sh --script scripts/synth/altera/run_synth.tcl [-tclargs [lite [quality]]]
#
# Examples:
#   quartus_sh --script scripts/synth/altera/run_synth.tcl
#                                          → LITE_MODE=0, 1920×1080, 150 MHz
#   quartus_sh --script scripts/synth/altera/run_synth.tcl -tclargs lite
#                                          → LITE_MODE=1, 1280×720, Q95 fixed
#   quartus_sh --script scripts/synth/altera/run_synth.tcl -tclargs lite 75
#                                          → LITE_MODE=1, 1280×720, Q75 fixed
#
# Typical device strings:
#   Cyclone IV E : EP4CE22F17C6     FAMILY "Cyclone IV E"
#   Cyclone V    : 5CEBA4F23C7N     FAMILY "Cyclone V"
#   Arria 10     : 10AX115S2F45I1SG FAMILY "Arria 10"
#   Agilex 5     : A5ED065BB32AE5SR FAMILY "Agilex 5"
# ============================================================================

package require ::quartus::flow
package require ::quartus::project
package require ::quartus::report

# ---- Configuration ----------------------------------------------------------
set lite_mode    0
set lite_quality 95
set img_width    1920
set img_height   1080
set target_mhz   150
set target_period 6.667

if {[llength $argv] > 0 && [lindex $argv 0] eq "lite"} {
    set lite_mode   1
    set img_width   1280
    set img_height  720
    if {[llength $argv] > 1} {
        set lite_quality [lindex $argv 1]
    }
}

# Device/family — edit for your target
set device  "5CEBA4F23C7N"
set family  "Cyclone V"

# ---- Paths ------------------------------------------------------------------
set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ../../..]]
set rtl_dir    [file join $proj_dir rtl]
set vendor_dir [file join $rtl_dir vendor altera]

set mode_suffix [expr {$lite_mode ? "_lite" : ""}]
set output_dir  [file normalize [file join $proj_dir build synth_altera${mode_suffix}]]
file mkdir $output_dir

# ---- Project setup ----------------------------------------------------------
cd $output_dir
project_new mjpegzero -overwrite

set_global_assignment -name FAMILY  $family
set_global_assignment -name DEVICE  $device
set_global_assignment -name TOP_LEVEL_ENTITY synth_timing_wrapper

# ---- RTL sources ------------------------------------------------------------
foreach f [list \
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
] {
    set_global_assignment -name VERILOG_FILE $f
}

# ---- Top-level parameter overrides ------------------------------------------
# Quartus sets generics on the top entity via VERILOG_PARAMETER assignments.
set_instance_assignment -name VERILOG_PARAMETER "LITE_MODE=$lite_mode" \
    -entity synth_timing_wrapper
set_instance_assignment -name VERILOG_PARAMETER "LITE_QUALITY=$lite_quality" \
    -entity synth_timing_wrapper
set_instance_assignment -name VERILOG_PARAMETER "IMG_WIDTH=$img_width" \
    -entity synth_timing_wrapper
set_instance_assignment -name VERILOG_PARAMETER "IMG_HEIGHT=$img_height" \
    -entity synth_timing_wrapper

# ---- Timing constraints (SDC) -----------------------------------------------
set sdc_file [file join $script_dir timing.sdc]
if {[file exists $sdc_file]} {
    set_global_assignment -name SDC_FILE $sdc_file
} else {
    # Generate a minimal SDC on the fly
    set fp [open $output_dir/timing.sdc w]
    puts $fp "create_clock -period [format %.3f [expr {1000.0/$target_mhz}]] -name clk \[get_ports clk\]"
    puts $fp "set_input_delay  -clock clk 1.5 \[get_ports -no_case {* -regex .*(?<!clk)}\]"
    puts $fp "set_output_delay -clock clk 1.5 \[get_ports *\]"
    close $fp
    set_global_assignment -name SDC_FILE $output_dir/timing.sdc
}

# ---- Optimization -----------------------------------------------------------
set_global_assignment -name OPTIMIZATION_MODE               "Performance (High Effort)"
set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC  ON
set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON
set_global_assignment -name FITTER_EFFORT                   "STANDARD FIT"

# ---- Compile ----------------------------------------------------------------
execute_flow -compile

# ---- Reports ----------------------------------------------------------------
load_report
set mode_str [expr {$lite_mode ? \
    "LITE (${img_width}x${img_height}, Q${lite_quality} fixed)" : \
    "FULL (${img_width}x${img_height}, dynamic quality)"}]

puts "======================================================================"
puts "SYNTHESIS COMPLETE - $mode_str"
puts "Device: $device  Family: $family"
puts "Target: $target_mhz MHz ([format %.3f $target_period] ns)"
puts "======================================================================"

# Print resource summary from report
if {[catch {
    set panel "Resource Section||Resource Utilization by Entity"
    foreach entry [get_report_panel_data -name $panel -col_name "Logic Cells"] {
        puts "  $entry"
    }
} err]} {
    # Fallback: dump flow summary
    foreach line [get_report_panel_data -name "Flow Summary" -col_name "Info"] {
        puts "  $line"
    }
}

# Timing summary
if {[catch {
    set fmax [get_report_panel_data \
        -name "TimeQuest Timing Analyzer||Slow 900mV 0C Model||Fmax Summary" \
        -col_name "Fmax"]
    puts "Fmax (slow model, 0C): [lindex $fmax 0]"
} err]} {
    puts "Note: Run TimeQuest for detailed timing analysis."
}

project_close

puts "======================================================================"
puts "Project files: $output_dir"
puts "======================================================================"
