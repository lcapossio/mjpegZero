# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Lattice Radiant / Diamond Synthesis Script for mjpegZero
# Target: Lattice — edit DEVICE for your target
# ============================================================================
#
# Prerequisites:
#   Radiant:  Lattice Radiant 3.x+ installed; run via:
#               radiantc scripts/synth/lattice/run_synth.tcl
#   Diamond:  Lattice Diamond 3.x; run via:
#               diamondc scripts/synth/lattice/run_synth.tcl
#
# Typical device settings:
#   ECP5:     LFE5U-25F-6BG256C   (25k LUTs, BGA256)
#   ECP5:     LFE5U-85F-8BG381C   (85k LUTs, BGA381)
#   CrossLink-NX: LIFCL-40-8BG400C
#
# Key differences from AMD/Xilinx:
#   - Use rtl/vendor/lattice/bram_sdp.v (inferred EBR blocks)
#   - Timing constraints: use .ldc (Lattice Design Constraints) or .sdc
#   - Synthesis backend: Synplify Pro (Radiant) or LSE (Diamond)
#
# ============================================================================

error "Lattice Radiant/Diamond synthesis not yet implemented.\
 Edit this file and replace with Radiant/Diamond Tcl flow."

# TODO: Implement Radiant flow, for example:
#
# set_db / set_option  -syn_top  synth_timing_wrapper
# set_option -technology ECP5U
# set_option -part LFE5U-25F
# set_option -package BG256
# set_option -speed_grade -6
# add_file -verilog rtl/vendor/lattice/bram_sdp.v
# add_file -verilog rtl/dct_1d.v
# ... (remaining RTL files)
# set_option -top_module synth_timing_wrapper
# impl -run synthesis
