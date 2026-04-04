# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Efinix Efinity Synthesis — TCL launcher
# Target: Efinix Trion T20 / Titanium Ti60
# ============================================================================
#
# Efinity uses Python (efx_run.py) as its primary scripting interface.
# This TCL script is a thin wrapper; the real implementation is in
# scripts/synth/efinix/run_synth.py.
#
# Usage (from Efinity TCL console):
#   source scripts/synth/efinix/run_synth.tcl
#
# Or from shell:
#   python scripts/synth/efinix/run_synth.py [lite [quality]]
#
# Typical device strings:
#   Trion T8  : T8F81I4          (8k LEs, BGA81)
#   Trion T20 : T20F256I4        (20k LEs, BGA256)   ← default
#   Titanium Ti60: Ti60F225I     (60k LEs, BGA225)
# ============================================================================

# Delegate to the Python runner
set script_dir [file normalize [file dirname [info script]]]
set py_script  [file join $script_dir run_synth.py]

if {[info exists argv]} {
    set py_args $argv
} else {
    set py_args {}
}

set cmd "python $py_script $py_args"
puts "Launching: $cmd"
set rc [catch {exec {*}[split $cmd " "]} output]
puts $output
if {$rc != 0} {
    error "Efinix synthesis failed (rc=$rc)"
}
