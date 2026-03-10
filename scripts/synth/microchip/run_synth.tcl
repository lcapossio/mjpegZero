# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Microchip Libero SoC Synthesis Script for mjpegZero
# Target: Microchip PolarFire / SmartFusion2 / IGLOO2
# ============================================================================
#
# Prerequisites:
#   Microchip Libero SoC 2023.1+ installed; run via:
#     libero SCRIPT:scripts/synth/microchip/run_synth.tcl
#
# Typical device settings:
#   PolarFire:     MPF300TS-FCG1152I   (300k LUT4, 1152-ball FCBGA)
#   SmartFusion2:  M2S090T-FGG484I
#
# Key differences from AMD/Xilinx:
#   - Use rtl/vendor/microchip/bram_sdp.v (inferred uSRAM/LSRAM)
#   - Synthesis uses Synplify Pro backend (Synplify attributes respected)
#   - Timing constraints: .sdc format
#   - No generic pass-through; use set_parameter after create_design
#
# ============================================================================

error "Microchip Libero SoC synthesis not yet implemented.\
 Edit this file and replace with Libero Tcl flow."

# TODO: Implement Libero flow, for example:
#
# new_project -location ./build/microchip -name mjpeg_encoder \
#             -family PolarFire -die MPF300TS -package FCG1152 \
#             -speed -I -hdl VERILOG
# create_links \
#   -hdl_source rtl/vendor/microchip/bram_sdp.v \
#   -hdl_source rtl/dct_1d.v \
#   ... (remaining RTL files)
# set_root synth_timing_wrapper
# run_tool -name {SYNTHESIZE}
# run_tool -name {PLACEROUTE}
# run_tool -name {VERIFYTIMING}
# export_reports
