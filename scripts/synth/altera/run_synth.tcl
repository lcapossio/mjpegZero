# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Quartus Prime Synthesis Script for mjpegZero
# Target: Intel/Altera — edit DEVICE and FAMILY for your target
# ============================================================================
#
# Prerequisites:
#   - Intel Quartus Prime (Standard or Pro) installed and on PATH
#   - Run: quartus_sh --script scripts/synth/altera/run_synth.tcl
#
# Typical device settings:
#   Cyclone IV:   DEVICE = EP4CE22F17C6,  FAMILY = "Cyclone IV E"
#   Cyclone V:    DEVICE = 5CEBA4F23C7N,  FAMILY = "Cyclone V"
#   Arria 10:     DEVICE = 10AX115S2F45I1SG, FAMILY = "Arria 10"
#
# Key differences from AMD/Xilinx:
#   - Use rtl/vendor/altera/bram_sdp.v (inferred M9K/M20K)
#   - Parameters passed via set_global_assignment -name VERILOG_MACRO
#   - No TCL-mode synthesis; use --flow compile or a .qpf project file
#   - Timing constraints: use .sdc (Synopsys Design Constraints)
#
# ============================================================================

error "Intel/Quartus synthesis not yet implemented.\
 Edit this file and replace with Quartus Tcl flow.\
 Reference: Intel Quartus Prime Scripting Reference Manual."

# TODO: Implement Quartus flow, for example:
#
# load_package flow
# project_new mjpeg_encoder -overwrite
# set_global_assignment -name FAMILY "Cyclone V"
# set_global_assignment -name DEVICE 5CEBA4F23C7N
# set_global_assignment -name TOP_LEVEL_ENTITY synth_timing_wrapper
# set_global_assignment -name VERILOG_FILE rtl/vendor/altera/bram_sdp.v
# set_global_assignment -name VERILOG_FILE rtl/dct_1d.v
# ... (remaining RTL files)
# set_global_assignment -name SDC_FILE scripts/synth/altera/timing.sdc
# execute_flow -compile
# project_close
