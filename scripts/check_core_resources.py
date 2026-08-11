#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
"""Check Verilog/VHDL core resource equivalence from Vivado reports.

The reports are produced by scripts/synth/amd/run_core_synth.tcl:

    vivado -mode batch -source scripts/synth/amd/run_core_synth.tcl -tclargs verilog
    vivado -mode batch -source scripts/synth/amd/run_core_synth.tcl -tclargs vhdl
    vivado -mode batch -source scripts/synth/amd/run_core_synth.tcl -tclargs verilog lite
    vivado -mode batch -source scripts/synth/amd/run_core_synth.tcl -tclargs vhdl lite

Hard resources must match exactly. LUT/FF counts are allowed a small tolerance
because different HDL frontends can map equivalent logic a little differently.

Reports that predate the RTL they describe are rejected before any comparison:
mixing a report built from one commit with one built from another fabricates a
large Verilog/VHDL gap that reads as a real architectural difference.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
SYNTH_TCL = ROOT / "scripts" / "synth" / "amd" / "run_core_synth.tcl"


@dataclass(frozen=True)
class Resources:
    lut: int
    ff: int
    bram_tiles: int
    ramb36: int
    ramb18: int
    dsp: int


def _first_int(pattern: str, text: str, default: Optional[int] = None) -> int:
    match = re.search(pattern, text, re.MULTILINE)
    if match:
        return int(match.group(1))
    if default is not None:
        return default
    raise ValueError(f"pattern not found: {pattern}")


def parse_utilization(path: Path) -> Resources:
    if not path.is_file():
        raise FileNotFoundError(path)
    text = path.read_text(errors="replace")
    return Resources(
        lut=_first_int(r"^\|\s*Slice LUTs\*?\s*\|\s*(\d+)\s*\|", text),
        ff=_first_int(r"^\|\s*Slice Registers\s*\|\s*(\d+)\s*\|", text),
        bram_tiles=_first_int(r"^\|\s*Block RAM Tile\s*\|\s*(\d+)\s*\|", text),
        ramb36=_first_int(r"^\|\s*RAMB36E1\s*\|\s*(\d+)\s*\|", text, 0),
        ramb18=_first_int(r"^\|\s*RAMB18E1\s*\|\s*(\d+)\s*\|", text, 0),
        dsp=_first_int(r"^\|\s*DSPs\s*\|\s*(\d+)\s*\|", text),
    )


def report_path(language: str, lite: bool) -> Path:
    suffix = "_lite" if lite else ""
    return ROOT / "build" / f"core_synth_{language}{suffix}" / "utilization.rpt"


_MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}


def report_time(path: Path) -> float:
    """When Vivado generated this report, as a POSIX timestamp.

    Prefers the report's own "| Date : Tue Aug 11 19:02:49 2026" banner over the
    file mtime, since that is the actual synthesis time. Falls back to the mtime
    if the banner is missing or malformed.
    """
    match = re.search(r"^\|\s*Date\s*:\s*(.+?)\s*$", path.read_text(errors="replace"), re.MULTILINE)
    if match:
        # Split on whitespace rather than strptime: Vivado pads single-digit days
        # ("Aug  4") and %b is locale-sensitive.
        parts = match.group(1).split()
        if len(parts) == 5 and parts[1] in _MONTHS:
            try:
                hour, minute, second = (int(x) for x in parts[3].split(":"))
                return datetime(
                    int(parts[4]), _MONTHS[parts[1]], int(parts[2]), hour, minute, second
                ).timestamp()
            except ValueError:
                pass
    return path.stat().st_mtime


def source_files(language: str) -> list[Path]:
    """The RTL sources a core build of this language reads (non-recursive)."""
    directory, pattern = (ROOT / "rtl", "*.v") if language == "verilog" else (ROOT / "rtl" / "vhdl", "*.vhd")
    files = sorted(directory.glob(pattern))
    if not files:
        raise RuntimeError(f"no {language} RTL sources found under {directory}")
    return files


def _git(args: list[str]) -> Optional[str]:
    try:
        result = subprocess.run(
            ["git", *args], cwd=ROOT, capture_output=True, text=True, check=True
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout


def rtl_change_time(language: str) -> float:
    """When this language's RTL last actually changed, as a POSIX timestamp.

    Source mtimes alone are not usable: a checkout or merge rewrites them without
    changing content, which would condemn a perfectly valid report. So prefer the
    commit time, and only consult mtimes for files git reports as dirty.
    """
    files = source_files(language)
    paths = [path.relative_to(ROOT).as_posix() for path in files]

    commit = _git(["log", "-1", "--format=%ct", "--", *paths])
    if commit is None:
        return max(path.stat().st_mtime for path in files)  # no git: mtime is all we have

    threshold = float(commit.strip() or 0.0)

    status = _git(["status", "--porcelain", "--", *paths]) or ""
    dirty = {line[3:].strip().strip('"') for line in status.splitlines() if line.strip()}
    for path in files:
        if path.relative_to(ROOT).as_posix() in dirty:
            threshold = max(threshold, path.stat().st_mtime)

    return threshold


def _fmt(timestamp: float) -> str:
    return datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d %H:%M")


def check_freshness() -> list[str]:
    """Reject reports older than the RTL they claim to describe.

    Without this, the comparison silently reads whatever is left in build/. Two
    reports generated from different commits produce a large bogus Verilog/VHDL
    gap that looks like a real architectural difference.
    """
    errors: list[str] = []

    for language in ("verilog", "vhdl"):
        threshold = rtl_change_time(language)
        for lite in (False, True):
            path = report_path(language, lite)
            if not path.is_file():
                continue
            generated = report_time(path)
            if generated < threshold:
                errors.append(
                    f"{path.parent.name}: report is stale - generated {_fmt(generated)}, "
                    f"but {language} RTL changed {_fmt(threshold)}; re-run synthesis "
                    f"for BOTH languages"
                )

    return errors


def run_synth(language: str, lite: bool) -> None:
    vivado = shutil.which("vivado") or shutil.which("vivado.bat")
    if not vivado:
        raise RuntimeError("Vivado not found on PATH")

    args = [vivado, "-mode", "batch", "-source", str(SYNTH_TCL), "-tclargs", language]
    if lite:
        args.append("lite")

    env = os.environ.copy()
    env.setdefault("XILINX_LOCAL_USER_DATA", str(ROOT / ".xilinx_local"))
    print("$ " + " ".join(args))
    result = subprocess.run(args, cwd=ROOT, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"Vivado core synthesis failed for {language}{' lite' if lite else ''}")


def within_tolerance(a: int, b: int, pct: float, abs_tol: int) -> bool:
    delta = abs(a - b)
    limit = max(abs_tol, round(max(a, b) * pct / 100.0))
    return delta <= limit


def compare_mode(name: str, verilog: Resources, vhdl: Resources, pct: float, abs_tol: int) -> list[str]:
    errors: list[str] = []
    exact_fields = ("bram_tiles", "ramb36", "ramb18", "dsp")
    soft_fields = ("lut", "ff")

    print(f"\n{name}")
    print("  HDL      LUT    FF  BRAM  RAMB36  RAMB18  DSP")
    print(
        f"  Verilog {verilog.lut:5d} {verilog.ff:5d} {verilog.bram_tiles:5d}"
        f" {verilog.ramb36:7d} {verilog.ramb18:7d} {verilog.dsp:4d}"
    )
    print(
        f"  VHDL    {vhdl.lut:5d} {vhdl.ff:5d} {vhdl.bram_tiles:5d}"
        f" {vhdl.ramb36:7d} {vhdl.ramb18:7d} {vhdl.dsp:4d}"
    )

    for field in exact_fields:
        if getattr(verilog, field) != getattr(vhdl, field):
            errors.append(f"{name}: {field} mismatch: Verilog={getattr(verilog, field)} VHDL={getattr(vhdl, field)}")

    for field in soft_fields:
        va = getattr(verilog, field)
        vb = getattr(vhdl, field)
        if not within_tolerance(va, vb, pct, abs_tol):
            errors.append(f"{name}: {field} drift too large: Verilog={va} VHDL={vb}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-synth", action="store_true", help="run all four core synth jobs before checking")
    parser.add_argument("--soft-pct", type=float, default=5.0, help="allowed LUT/FF percent drift")
    parser.add_argument("--soft-abs", type=int, default=100, help="minimum allowed LUT/FF absolute drift")
    parser.add_argument(
        "--allow-stale",
        action="store_true",
        help="compare reports even if they predate the RTL (not a valid comparison)",
    )
    args = parser.parse_args()

    if args.run_synth:
        for language in ("verilog", "vhdl"):
            run_synth(language, lite=False)
            run_synth(language, lite=True)

    if not args.allow_stale:
        stale = check_freshness()
        if stale:
            print("RESOURCE CHECK FAILED (stale reports)")
            for err in stale:
                print(f"  - {err}")
            print("\n  Re-run: python scripts/check_core_resources.py --run-synth")
            return 1

    errors: list[str] = []
    for name, lite in (("full", False), ("lite", True)):
        verilog = parse_utilization(report_path("verilog", lite))
        vhdl = parse_utilization(report_path("vhdl", lite))
        errors.extend(compare_mode(name, verilog, vhdl, args.soft_pct, args.soft_abs))

    if errors:
        print("\nRESOURCE CHECK FAILED")
        for err in errors:
            print(f"  - {err}")
        return 1

    print("\nRESOURCE CHECK PASSED")
    print(f"  Hard resources match exactly; LUT/FF within max({args.soft_abs}, {args.soft_pct:.1f}%).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
