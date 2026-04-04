# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# GOWIN EDA Synthesis Script for mjpegZero
# Target: GOWIN GW2A-18 (GW2A-LV18QN88C8/I7) default
# ============================================================================
#
# Usage:
#   gw_sh scripts/synth/gowin/run_synth.tcl
#
# Typical device strings:
#   GW1N-9C  : GW1N-LV9QN88PC6/I5   (9k LUTs, QFN88)
#   GW2A-18  : GW2A-LV18QN88C8/I7   (18k LUTs, QFN88)   ← default
#   GW5A-138 : GW5A-LV138PG484AC1/I0 (138k LUTs, PBGA484)
# ============================================================================

# ---- Configuration ----------------------------------------------------------
set lite_mode    0
set lite_quality 95
set img_width    1920
set img_height   1080
set target_mhz   150

if {[info exists argv] && [llength $argv] > 0 && [lindex $argv 0] eq "lite"} {
    set lite_mode   1
    set img_width   1280
    set img_height  720
    if {[llength $argv] > 1} {
        set lite_quality [lindex $argv 1]
    }
}

# Device — edit for your target
set device "GW2A-LV18QN88C8/I7"
set device_name "GW2A-18C"

# ---- Paths ------------------------------------------------------------------
set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ../../..]]
set rtl_dir    [file join $proj_dir rtl]
set vendor_dir [file join $rtl_dir vendor gowin]

set mode_suffix [expr {$lite_mode ? "_lite" : ""}]
set output_dir  [file normalize [file join $proj_dir build synth_gowin${mode_suffix}]]
file mkdir $output_dir

# ---- Project setup ----------------------------------------------------------
set_device $device -name $device_name

# ---- Add RTL sources --------------------------------------------------------
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
    add_file -type verilog $f
}

# ---- Timing constraints (SDC) -----------------------------------------------
set sdc_file [file join $script_dir timing.sdc]
if {[file exists $sdc_file]} {
    add_file -type sdc $sdc_file
}

# ---- Synthesis options ------------------------------------------------------
set_option -synthesis_tool gowinsyn
set_option -top_module     synth_timing_wrapper
set_option -verilog_std    v2001
set_option -use_mspi_as_gpio 1
set_option -use_sspi_as_gpio 1

# Generic overrides (GOWIN uses Verilog macro defines for param override)
set_option -verilog_define "LITE_MODE=$lite_mode"
if {$lite_mode} {
    set_option -verilog_define "LITE_QUALITY=$lite_quality"
}
# Note: IMG_WIDTH / IMG_HEIGHT are module-level parameters; if the tool does not
# pick them up from -verilog_define, set them in synth_timing_wrapper.v directly.

# Optimization: speed
set_option -place_option 1
set_option -route_option  1

# Output directory
set_option -output_base_name [file join $output_dir mjpegzero]

set mode_str [expr {$lite_mode ? \
    "LITE (${img_width}x${img_height}, Q${lite_quality})" : \
    "FULL (${img_width}x${img_height}, dynamic Q)"}]

puts "======================================================================"
puts "SYNTHESIZING - $mode_str"
puts "Device: $device"
puts "Target: $target_mhz MHz"
puts "======================================================================"

# ---- Run all flows ----------------------------------------------------------
run all

puts "======================================================================"
puts "SYNTHESIS COMPLETE"
puts "Outputs: $output_dir"
puts "======================================================================"
