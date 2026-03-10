# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Efinix Efinity Synthesis Script for mjpegZero
# Target: Efinix Trion / Titanium
# ============================================================================
#
# Note: Efinity uses Python scripts (.py) rather than Tcl for project control.
# This file documents the flow; the actual runner is efx_run.py.
#
# Prerequisites:
#   Efinix Efinity 2023.2+ installed; run via:
#     efx_run.py --project scripts/synth/efinix/mjpeg_encoder.xml --flow compile
#
# Typical device settings:
#   Trion:    T20F256I4          (20k LEs, 256-ball FBGA)
#   Titanium: Ti60F225I          (60k LEs, 225-ball FBGA)
#
# Key differences from AMD/Xilinx:
#   - Use rtl/vendor/efinix/bram_sdp.v (inferred EFX_RAM_AR or FIFO36K)
#   - Project defined in XML (create via Efinity GUI, then script-automate)
#   - Timing constraints: .sdc format
#   - Synthesis tool: Efinity Mapper + Placer
#
# ============================================================================

error "Efinix Efinity synthesis not yet implemented.\
 Create an Efinity project XML and invoke efx_run.py."

# TODO:
#   1. Create Efinity project via GUI: add all rtl/vendor/efinix/ + rtl/*.v files
#      (except rtl/bram_sdp.v — use rtl/vendor/efinix/bram_sdp.v instead)
#   2. Export project XML to scripts/synth/efinix/mjpeg_encoder.xml
#   3. Automate: efx_run.py --project scripts/synth/efinix/mjpeg_encoder.xml \
#                            --flow compile
#   4. Replace this error with the Efinity Tcl API calls if using Tcl mode.
