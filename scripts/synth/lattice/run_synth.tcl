# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Lattice Radiant Synthesis Script for mjpegZero
# Target: Lattice ECP5 LFE5U-25F-6BG256C (default)
# ============================================================================
#
# Usage:
#   radiantc scripts/synth/lattice/run_synth.tcl  (Radiant non-project mode)
#
# Or from within Radiant IDE: File → TCL Console → source this script.
#
# Typical device strings (part / package / speed / voltage):
#   ECP5-25:      LFE5U-25F   BG256  -6   "1.1V"
#   ECP5-85:      LFE5U-85F   BG381  -8   "1.1V"
#   CrossLink-NX: LIFCL-40    BG400  -7   "1.0V"
#   MachXO3:      LCMXO3-4300 BG256  -7   "1.2V"
#
# For Lattice Diamond (older devices), the commands are similar but use
# diamondc instead of radiantc. Replace impl/run with:
#   impl -run synthesis
# ============================================================================

# ---- Configuration ----------------------------------------------------------
set lite_mode    0
set lite_quality 95
set img_width    1920
set img_height   1080
set target_mhz   150
set target_period 6.667

if {[info exists argv] && [llength $argv] > 0 && [lindex $argv 0] eq "lite"} {
    set lite_mode   1
    set img_width   1280
    set img_height  720
    if {[llength $argv] > 1} {
        set lite_quality [lindex $argv 1]
    }
}

# Device — edit for your target
set device   "LFE5U-25F"
set package  "BG256"
set speed    "-6"
set voltage  "1.1V"
set perf     "High-Performance_1.1V"

# ---- Paths ------------------------------------------------------------------
set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ../../..]]
set rtl_dir    [file join $proj_dir rtl]
set vendor_dir [file join $rtl_dir vendor lattice]

set mode_suffix [expr {$lite_mode ? "_lite" : ""}]
set output_dir  [file normalize [file join $proj_dir build synth_lattice${mode_suffix}]]
file mkdir $output_dir

# ---- Create project ---------------------------------------------------------
set proj_name "mjpegzero"
set proj_file [file join $output_dir ${proj_name}.rdf]

prj_create -name $proj_name \
           -impl "impl1" \
           -dev  ${device}-${speed}${package} \
           -performance $perf \
           -synthesis "synplify"

prj_set_impl_opt -impl impl1 -opt "VERILOG_VERSION" "Verilog2001"

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
    prj_add_source -impl impl1 $f
}

# ---- Timing constraints (SDC) -----------------------------------------------
set sdc_file [file join $script_dir timing.sdc]
if {[file exists $sdc_file]} {
    prj_add_source -impl impl1 $sdc_file
}

# ---- Top module and generics ------------------------------------------------
prj_set_impl_opt -impl impl1 -opt "top" "synth_timing_wrapper"

# Synplify generic overrides: passed as a comma-separated list
set generics "LITE_MODE=$lite_mode,LITE_QUALITY=$lite_quality,IMG_WIDTH=$img_width,IMG_HEIGHT=$img_height"
prj_set_impl_opt -impl impl1 -opt "SYNPLIFY_OPTIONS" \
    "set_option -hdl_define -set $generics"

# ---- Run synthesis ----------------------------------------------------------
set mode_str [expr {$lite_mode ? \
    "LITE (${img_width}x${img_height}, Q${lite_quality})" : \
    "FULL (${img_width}x${img_height}, dynamic Q)"}]

puts "======================================================================"
puts "SYNTHESIZING - $mode_str"
puts "Device: $device  Package: $package  Speed: $speed"
puts "Target: $target_mhz MHz"
puts "======================================================================"

prj_run -impl impl1 Synthesis
prj_run -impl impl1 Map
prj_run -impl impl1 PAR
prj_run -impl impl1 Timing

# ---- Copy reports -----------------------------------------------------------
set impl_dir [file join $output_dir impl1]
file mkdir $output_dir

puts "======================================================================"
puts "SYNTHESIS COMPLETE"
puts "Reports: $impl_dir"
puts "======================================================================"

prj_save
prj_close
