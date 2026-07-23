#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Standalone RTL unit-bench runner (iverilog / vvp).

Compiles and runs the self-checking regression benches under sim/verify/ that
target specific entropy-path bugs. Each bench prints 'ALL TESTS PASSED' on
success and 'SOME TESTS FAILED' (or times out) on failure.

These benches guard bugs that the full-encoder golden does NOT reliably catch:
  * tb_zigzag_gapless      — gapless double-buffer cross-block leak (zigzag_reorder)
  * tb_packer_backpressure — codes dropped when bp_ready ignores the output slot
  * tb_packer_restart      — tail bits dropped when a restart arrives with >=8 bits

Exit code: 0 = all benches PASS, 1 = any FAIL / tool missing.
"""

import os
import shutil
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR   = os.path.dirname(SCRIPT_DIR)
RTL_DIR    = os.path.join(PROJ_DIR, 'rtl')
VERIFY_DIR = os.path.join(PROJ_DIR, 'sim', 'verify')
BUILD_DIR  = os.path.join(PROJ_DIR, 'build', 'sim_verify')

# bench name -> RTL sources it needs (besides the bench file itself)
BENCHES = [
    ('tb_zigzag_gapless',      ['zigzag_reorder.v']),
    ('tb_packer_backpressure', ['bitstream_packer.v']),
    ('tb_packer_restart',      ['bitstream_packer.v']),
]


def find_tool(name):
    exe = shutil.which(name)
    if exe:
        return exe
    for prefix in ('/usr/bin', '/usr/local/bin'):
        cand = os.path.join(prefix, name)
        if os.path.isfile(cand):
            return cand
    return None


def run_one(iverilog, vvp, name, rtl_srcs):
    bench = os.path.join(VERIFY_DIR, f'{name}.sv')
    vvp_out = os.path.join(BUILD_DIR, f'{name}.vvp')
    srcs = [os.path.join(RTL_DIR, s) for s in rtl_srcs] + [bench]

    print(f'\n{"-" * 65}\n  Bench: {name}\n{"-" * 65}')
    comp = subprocess.run([iverilog, '-g2012', '-o', vvp_out] + srcs,
                          capture_output=True, text=True)
    if comp.returncode != 0:
        print(f'  ERROR: compile failed (exit {comp.returncode})')
        print(comp.stderr)
        return False

    sim = subprocess.run([vvp, vvp_out], capture_output=True, text=True,
                         cwd=BUILD_DIR)
    out = sim.stdout
    # Echo the informative lines (INFO/FAIL/result) without the vvp banner noise.
    for line in out.splitlines():
        if any(k in line for k in ('INFO:', 'FAIL:', 'PASSED', 'FAILED')):
            print(f'  {line}')

    passed = ('ALL TESTS PASSED' in out) and ('SOME TESTS FAILED' not in out)
    print(f'  >> {"PASS" if passed else "FAIL"}  [{name}]')
    if not passed and sim.stderr:
        print(sim.stderr)
    return passed


def main():
    iverilog = find_tool('iverilog')
    vvp = find_tool('vvp')
    if not iverilog or not vvp:
        missing = [t for t in ('iverilog', 'vvp') if not find_tool(t)]
        print(f"ERROR: {', '.join(missing)} not found. "
              f"apt-get install iverilog (Debian/Ubuntu).")
        return 1

    print('=' * 65)
    print('RTL unit-bench regression (iverilog)')
    print(f'iverilog: {iverilog}')
    print('=' * 65)
    os.makedirs(BUILD_DIR, exist_ok=True)

    results = {name: run_one(iverilog, vvp, name, srcs) for name, srcs in BENCHES}

    print(f'\n{"=" * 65}\nSUMMARY\n{"=" * 65}')
    all_pass = True
    for name, passed in results.items():
        print(f'  {"PASS" if passed else "FAIL"}  {name}')
        all_pass = all_pass and passed
    print(f'{"-" * 65}\nOVERALL RESULT: {"PASS" if all_pass else "FAIL"}\n{"=" * 65}')
    return 0 if all_pass else 1


if __name__ == '__main__':
    sys.exit(main())
