#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
AXI4-Lite register coverage RTL simulation test.

Compiles mjpegZero via iverilog with VERIFY_AXI_REGS=1 and NUM_FRAMES=2,
runs the simulation, and validates register read/write behaviour:

  1. QUALITY register — written before encoding, read back and verified
  2. FRAME_CNT register — must equal NUM_FRAMES after encoding completes
  3. FRAME_SIZE register — must be non-zero (last completed frame byte count)
  4. STATUS[1] frame_done — must be set after last frame
  5. STATUS[1] W1C clear — write-1-to-clear must work
  6. RESTART register — write/readback (structural, does not test RST markers)

Tests run for:
  Full mode (LITE_MODE=0):  QUALITY written = 75; expected readback = 75
  Lite mode (LITE_MODE=1):  QUALITY write ignored; expected readback = 95

Usage:
    python python/verify_axi_regs.py [--lite] [--quality N]

Exit code: 0 = PASS, 1 = FAIL
"""

import argparse
import os
import shutil
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR   = os.path.dirname(SCRIPT_DIR)
RTL_DIR    = os.path.join(PROJ_DIR, 'rtl')
SIM_DIR    = os.path.join(PROJ_DIR, 'sim')
BUILD_DIR  = os.path.join(PROJ_DIR, 'build', 'sim_axi_regs')
TV_DIR     = os.path.join(SIM_DIR, 'test_vectors')

NUM_FRAMES = 2

_CORE_RTL = [
    'vendor/sim/bram_sdp.v',
    'dct_1d.v', 'dct_2d.v', 'input_buffer.v', 'quantizer.v',
    'zigzag_reorder.v', 'huffman_encoder.v', 'bitstream_packer.v',
    'jfif_writer.v', 'axi4_lite_regs.v', 'rgb_to_ycbcr.v',
    'mjpegzero_enc_top.v',
]


def find_tool(name):
    return shutil.which(name)


def compile_rtl(iverilog, vvp_out, defines):
    rtl_files = [os.path.join(RTL_DIR, f) for f in _CORE_RTL]
    rtl_files.append(os.path.join(SIM_DIR, 'tb_iverilog.sv'))
    def_flags = [f'-D{k}={v}' for k, v in defines.items()]
    cmd = [iverilog, '-g2012', '-o', vvp_out] + def_flags + rtl_files
    print('  Compiling: ' + ' '.join(def_flags))
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=PROJ_DIR)
    if result.stdout:
        print(result.stdout)
    if result.returncode != 0:
        print('ERROR: iverilog compilation failed:')
        print(result.stderr)
        return False
    return True


def run_sim(vvp, vvp_out, build_dir):
    result = subprocess.run([vvp, vvp_out], capture_output=True, text=True, cwd=build_dir)
    stdout = result.stdout
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    return stdout


def parse_results(stdout):
    """Parse pass/fail counts and individual FAIL lines from testbench output."""
    passed = 0
    failed = 0
    fail_lines = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith('PASS:'):
            passed += 1
            print(f'  [PASS] {stripped[5:].strip()}')
        elif stripped.startswith('FAIL:'):
            failed += 1
            fail_lines.append(stripped[5:].strip())
            print(f'  [FAIL] {stripped[5:].strip()}')
    return passed, failed, fail_lines


def run_one(iverilog, vvp, build_dir, lite_mode, quality):
    mode_str = 'LITE' if lite_mode else 'FULL'
    tag      = f'axi_{"lite" if lite_mode else "full"}_q{quality}'

    print(f'\n{"-" * 65}')
    print(f'  AXI Register Test: {mode_str}  Q={quality}  NUM_FRAMES={NUM_FRAMES}')
    print(f'{"-" * 65}')

    defines = {
        'TEST_QUALITY':    quality,
        'NUM_FRAMES':      NUM_FRAMES,
        'VERIFY_AXI_REGS': 1,
    }
    if lite_mode:
        defines['LITE_MODE']    = 1
        defines['LITE_QUALITY'] = quality

    vvp_out = os.path.join(build_dir, f'sim_{tag}.vvp')
    if not compile_rtl(iverilog, vvp_out, defines):
        return False

    stdout = run_sim(vvp, vvp_out, build_dir)
    if 'WATCHDOG TIMEOUT' in stdout:
        print('  ERROR: simulation watchdog triggered')
        print(stdout[-1000:])
        return False

    if 'SOME TESTS FAILED' in stdout:
        print('  Structural testbench checks failed')

    passed, failed, fail_lines = parse_results(stdout)

    if failed == 0 and 'ALL TESTS PASSED' in stdout:
        print(f'  >> PASS  ({passed} checks)')
        return True
    else:
        print(f'  >> FAIL  ({passed} passed, {failed} failed)')
        for f in fail_lines:
            print(f'     - {f}')
        return False


def main():
    parser = argparse.ArgumentParser(description='AXI register coverage RTL simulation test')
    parser.add_argument('--lite',    action='store_true',
                        help='Test LITE_MODE=1 (quality writes ignored)')
    parser.add_argument('--quality', type=int, default=75,
                        help='QUALITY register value to write (default: 75)')
    args = parser.parse_args()

    iverilog = find_tool('iverilog')
    vvp      = find_tool('vvp')
    if not iverilog:
        print('ERROR: iverilog not found in PATH')
        return 1
    if not vvp:
        print('ERROR: vvp not found in PATH')
        return 1

    os.makedirs(BUILD_DIR, exist_ok=True)

    # Ensure test vectors exist
    tv_file = os.path.join(TV_DIR, 'yuyv_input.hex')
    if not os.path.isfile(tv_file):
        print('Generating test vectors...')
        gen = os.path.join(SCRIPT_DIR, 'generate_test_vectors.py')
        r = subprocess.run([sys.executable, gen], capture_output=True, text=True)
        if r.returncode != 0:
            print(f'ERROR: generate_test_vectors.py failed:\n{r.stderr}')
            return 1

    # Sync test vectors into build dir
    tv_dst = os.path.join(BUILD_DIR, 'test_vectors')
    os.makedirs(tv_dst, exist_ok=True)
    for f in os.listdir(TV_DIR):
        src = os.path.join(TV_DIR, f)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(tv_dst, f))

    print('=' * 65)
    print(f'AXI Register Coverage Test  (NUM_FRAMES={NUM_FRAMES})')
    print('=' * 65)

    ok = run_one(iverilog, vvp, BUILD_DIR, args.lite, args.quality)

    print(f'\n{"=" * 65}')
    print(f'RESULT: {"PASS" if ok else "FAIL"}')
    print(f'{"=" * 65}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
