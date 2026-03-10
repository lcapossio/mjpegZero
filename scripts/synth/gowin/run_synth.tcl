# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# GOWIN EDA Synthesis Script for mjpegZero
# Target: GOWIN GW1N / GW2A / GW5A
# ============================================================================
#
# Prerequisites:
#   GOWIN EDA 1.9.9+ installed; run via:
#     gw_sh scripts/synth/gowin/run_synth.tcl
#
# Typical device settings:
#   GW1N-9C:  GW1N-LV9QN88PC6/I5   (9k LUTs, QFN88, -C6 commercial)
#   GW2A-18:  GW2A-LV18QN88C8/I7   (18k LUTs, QFN88)
#   GW5A-138: GW5A-LV138PG484AC1   (138k LUTs, PBGA484)
#
# Key differences from AMD/Xilinx:
#   - Use rtl/vendor/gowin/bram_sdp.v (inferred BSRAM with rw_check=0)
#   - Alternatively instantiate Gowin_SDPB primitive from IP Core Generator
#   - Timing constraints: .sdc format
#   - Synthesis: GOWIN Synthesizer (gw_syn)
#   - Place & route: GOWIN Placer (gw_pnr)
#
# ============================================================================

error "GOWIN EDA synthesis not yet implemented.\
 Edit this file and replace with GOWIN EDA Tcl flow."

# TODO: Implement GOWIN flow, for example:
#
# set_device GW2A-LV18QN88C8/I7 -name GW2A-18C
# add_file -type verilog rtl/vendor/gowin/bram_sdp.v
# add_file -type verilog rtl/dct_1d.v
# ... (remaining RTL files)
# set_option -synthesis_tool gowinsyn
# set_option -top_module synth_timing_wrapper
# add_file -type sdc scripts/synth/gowin/timing.sdc
# run all
