"""
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
Master run script for mjpegZero.
Runs synthesis, checks results, and optionally runs implementation.

Usage:
    python run_all.py synth [--vendor amd]   # Synthesis only
    python run_all.py impl  [--vendor amd]   # Synthesis + implementation
    python run_all.py check [--vendor amd]   # Check existing reports

Supported vendors (--vendor):
    amd       AMD/Xilinx Vivado (default) — Spartan-7 XC7S50
    altera    Intel/Altera Quartus Prime  — stub, not yet implemented
    lattice   Lattice Radiant/Diamond     — stub, not yet implemented
    microchip Microchip Libero SoC        — stub, not yet implemented
    efinix    Efinix Efinity              — stub, not yet implemented
    gowin     GOWIN EDA                   — stub, not yet implemented
"""

import argparse
import os
import sys
import shutil
import subprocess

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
BUILD_DIR   = os.path.join(PROJECT_DIR, "build")

SUPPORTED_VENDORS = ["amd", "altera", "lattice", "microchip", "efinix", "gowin"]


# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------

def find_vivado():
    """Find Vivado executable — checks PATH first, then common install roots."""
    exe = shutil.which("vivado")
    if exe:
        return exe

    if sys.platform == "win32":
        # os.path.join("C:", "foo") yields "C:foo" (relative), not "C:\foo".
        # Append os.sep so "C:" + os.sep = "C:\" for correct absolute join.
        drives = [os.environ.get("SystemDrive", "C:") + os.sep, "D:" + os.sep]
        roots = [
            os.path.join(d, p)
            for d in drives
            for p in ("AMDDesignTools", "Xilinx", os.path.join("Program Files", "Xilinx"))
        ]
        bin_name = "vivado.bat"
    else:
        roots = ["/tools/Xilinx", "/opt/Xilinx", "/opt/AMD", "/tools/AMD"]
        bin_name = "vivado"

    for root in roots:
        if not os.path.isdir(root):
            continue
        for version in sorted(os.listdir(root), reverse=True):
            candidate = os.path.join(root, version, "Vivado", "bin", bin_name)
            if os.path.isfile(candidate):
                return candidate
            candidate2 = os.path.join(root, version, "bin", bin_name)
            if os.path.isfile(candidate2):
                return candidate2

    return None


def find_tool(vendor):
    """Return (tool_path, [extra_args]) for the given vendor, or None if not found."""
    if vendor == "amd":
        exe = find_vivado()
        return (exe, ["-mode", "batch", "-source"]) if exe else None
    if vendor == "altera":
        exe = shutil.which("quartus_sh")
        return (exe, ["--script"]) if exe else None
    if vendor == "lattice":
        exe = shutil.which("radiantc") or shutil.which("diamondc")
        return (exe, []) if exe else None
    if vendor == "microchip":
        exe = shutil.which("libero")
        return (exe, ["SCRIPT:"]) if exe else None
    if vendor == "efinix":
        exe = shutil.which("efx_run.py") or shutil.which("efx_run")
        return (exe, ["--script"]) if exe else None
    if vendor == "gowin":
        exe = shutil.which("gw_sh")
        return (exe, []) if exe else None
    return None


# ---------------------------------------------------------------------------
# Script runner
# ---------------------------------------------------------------------------

def run_synth_script(vendor, tcl_script, log_name):
    """Run a vendor synthesis script and capture output to log."""
    result = find_tool(vendor)
    if result is None:
        print(f"ERROR: Synthesis tool for vendor '{vendor}' not found.")
        print(f"       Install the tool and ensure it is on PATH.")
        return False

    tool_path, extra_args = result

    # For vendors that prefix the script path (e.g. Libero "SCRIPT:<path>")
    if extra_args and extra_args[-1].endswith(":"):
        cmd = [tool_path] + extra_args[:-1] + [extra_args[-1] + tcl_script]
    else:
        cmd = [tool_path] + extra_args + [tcl_script]

    log_file = os.path.join(BUILD_DIR, f"{log_name}.log")
    os.makedirs(BUILD_DIR, exist_ok=True)

    print(f"Running: {' '.join(cmd)}")
    print(f"Log: {log_file}")

    with open(log_file, "w") as log:
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT,
                              cwd=PROJECT_DIR, timeout=3600)

    if proc.returncode != 0:
        print(f"ERROR: Tool returned exit code {proc.returncode}")
        print(f"Check log: {log_file}")
        return False

    print(f"Synthesis tool completed successfully. Log: {log_file}")
    return True


# ---------------------------------------------------------------------------
# Report checker
# ---------------------------------------------------------------------------

def check_reports(vendor):
    """Parse and display synthesis/implementation reports."""
    for stage, subdir in [("Synthesis", "synth"), ("Implementation", "impl")]:
        report_dir  = os.path.join(BUILD_DIR, subdir)
        util_file   = os.path.join(report_dir, "utilization.rpt")
        timing_file = os.path.join(report_dir, "timing_summary.rpt")

        if not os.path.exists(util_file):
            print(f"\n{stage}: No reports found")
            continue

        print(f"\n{'='*60}")
        print(f"{stage} Results ({vendor})")
        print(f"{'='*60}")

        print("Utilization report available at:", util_file)

        if os.path.exists(timing_file):
            with open(timing_file, "r") as f:
                content = f.read()
            # Parse WNS: find "Design Timing Summary" section, skip header + dashes,
            # then read the first data row (first token = WNS value).
            wns = None
            lines = content.split("\n")
            in_summary = past_sep = False
            for line in lines:
                if "Design Timing Summary" in line:
                    in_summary = True
                    continue
                if in_summary and "WNS(ns)" in line:
                    continue
                if in_summary and line.strip().startswith("---"):
                    past_sep = True
                    continue
                if in_summary and past_sep and line.strip():
                    tokens = line.split()
                    if tokens:
                        try:
                            wns = float(tokens[0])
                        except ValueError:
                            pass
                    break
            if wns is not None:
                status = "MET" if wns >= 0 else "VIOLATED"
                print(f"  WNS: {wns:+.3f} ns  ({status})")
            print("Timing report available at:", timing_file)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="mjpegZero synthesis and implementation runner",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "action",
        choices=["synth", "impl", "check"],
        help="Action to perform",
    )
    parser.add_argument(
        "--vendor",
        default="amd",
        choices=SUPPORTED_VENDORS,
        help="Target vendor/tool (default: amd)",
    )
    args = parser.parse_args()

    vendor = args.vendor
    synth_dir = os.path.join(SCRIPT_DIR, "synth", vendor)

    if args.action == "check":
        check_reports(vendor)
        return 0

    synth_tcl = os.path.join(synth_dir, "run_synth.tcl")
    impl_tcl  = os.path.join(synth_dir, "run_impl.tcl")

    if not os.path.isfile(synth_tcl):
        print(f"ERROR: No synthesis script found at {synth_tcl}")
        print(f"       Supported vendors: {', '.join(SUPPORTED_VENDORS)}")
        return 1

    if args.action in ("synth", "impl"):
        ok = run_synth_script(vendor, synth_tcl, f"synth_{vendor}")
        if not ok:
            return 1
        check_reports(vendor)

    if args.action == "impl":
        if not os.path.isfile(impl_tcl):
            print(f"ERROR: No implementation script found at {impl_tcl}")
            print(f"       Implementation is currently only supported for vendor=amd")
            return 1
        ok = run_synth_script(vendor, impl_tcl, f"impl_{vendor}")
        if not ok:
            return 1
        check_reports(vendor)

    return 0


if __name__ == "__main__":
    sys.exit(main())
