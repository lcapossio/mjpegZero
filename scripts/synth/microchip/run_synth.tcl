# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Microchip Libero SoC Synthesis Script for mjpegZero
# Target: PolarFire MPF300TS-FCG1152I (default)
# ============================================================================
#
# Usage:
#   libero SCRIPT:scripts/synth/microchip/run_synth.tcl
#   libero SCRIPT:scripts/synth/microchip/run_synth.tcl SCRIPT_ARGS:"lite"
#   libero SCRIPT:scripts/synth/microchip/run_synth.tcl SCRIPT_ARGS:"lite 75"
#
# Typical device strings:
#   PolarFire:     MPF300TS  FCG1152  -I  (300k LUT4, 1152-pin FCBGA)
#   SmartFusion2:  M2S090T   FGG484   -I  (90k LUT4, 484-pin FBGA)
#   IGLOO2:        M2GL090T  FGG484   -I
# ============================================================================

# ---- Configuration ----------------------------------------------------------
set lite_mode    0
set lite_quality 95
set img_width    1920
set img_height   1080
set target_mhz   150

if {[info exists script_args]} {
    set args [split $script_args " "]
    if {[lindex $args 0] eq "lite"} {
        set lite_mode   1
        set img_width   1280
        set img_height  720
        if {[llength $args] > 1 && [lindex $args 1] ne ""} {
            set lite_quality [lindex $args 1]
        }
    }
}

# Device — edit for your target
set family  "PolarFire"
set die     "MPF300TS"
set package "FCG1152"
set speed   "-I"
set hdl     "VERILOG"

# ---- Paths ------------------------------------------------------------------
set script_dir [file normalize [file dirname [info script]]]
set proj_dir   [file normalize [file join $script_dir ../../..]]
set rtl_dir    [file join $proj_dir rtl]
set vendor_dir [file join $rtl_dir vendor microchip]

set mode_suffix [expr {$lite_mode ? "_lite" : ""}]
set output_dir  [file normalize [file join $proj_dir build synth_microchip${mode_suffix}]]
file mkdir $output_dir

# ---- Create Libero project --------------------------------------------------
new_project \
    -location $output_dir \
    -name     mjpegzero \
    -family   $family \
    -die      $die \
    -package  $package \
    -speed    $speed \
    -hdl      $hdl

# ---- Add RTL sources --------------------------------------------------------
create_links -hdl_source [list \
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

# ---- Timing constraints (SDC) -----------------------------------------------
set sdc_file [file join $script_dir timing.sdc]
if {[file exists $sdc_file]} {
    create_links -sdc $sdc_file
}

# ---- Set top module ---------------------------------------------------------
set_root synth_timing_wrapper

# ---- Synthesizer options (Synplify Pro) -------------------------------------
# Pass Verilog generics via synplify defines
configure_tool \
    -name {SYNTHESIZE} \
    -params [list \
        {SYNPLIFY_OPTIONS: set_option -hdl_define -set LITE_MODE=$lite_mode} \
    ]

set mode_str [expr {$lite_mode ? \
    "LITE (${img_width}x${img_height}, Q${lite_quality})" : \
    "FULL (${img_width}x${img_height}, dynamic Q)"}]

puts "======================================================================"
puts "SYNTHESIZING - $mode_str"
puts "Family: $family  Die: $die  Package: $package  Speed: $speed"
puts "Target: $target_mhz MHz"
puts "======================================================================"

# ---- Run flows --------------------------------------------------------------
run_tool -name {SYNTHESIZE}
run_tool -name {PLACEROUTE}
run_tool -name {VERIFYTIMING}

# ---- Export reports ---------------------------------------------------------
export_reports \
    -export_dir $output_dir/reports \
    -report_name {Place and Route Report} \
    -report_name {Timing Violations Report}

puts "======================================================================"
puts "SYNTHESIS COMPLETE"
puts "Reports: $output_dir/reports"
puts "======================================================================"

save_project
close_project
