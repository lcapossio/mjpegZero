#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Verilator code coverage for mjpegZero.

Compiles the RTL with Verilator --coverage, runs the C++ testbench for
multiple quality levels, merges coverage data, and generates an LCOV report.

Usage:
    python python/run_coverage.py [--lite] [--html]

Outputs:
    build/coverage/coverage_merged.dat   — Verilator coverage database
    build/coverage/coverage.info         — LCOV info file
    build/coverage/html/                 — HTML report (if --html and genhtml available)

Requirements:
    verilator, g++, make (standard on ubuntu-latest)
    lcov (optional, for --html)
"""

import argparse
import os
import sys
import shutil
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR   = os.path.dirname(SCRIPT_DIR)
RTL_DIR    = os.path.join(PROJ_DIR, 'rtl')
SIM_DIR    = os.path.join(PROJ_DIR, 'sim')
BUILD_DIR  = os.path.join(PROJ_DIR, 'build', 'coverage')
TV_DIR     = os.path.join(SIM_DIR, 'test_vectors')

_CORE_RTL = [
    'vendor/sim/bram_sdp.v',
    'dct_1d.v', 'dct_2d.v', 'input_buffer.v', 'quantizer.v',
    'zigzag_reorder.v', 'huffman_encoder.v', 'bitstream_packer.v',
    'jfif_writer.v', 'axi4_lite_regs.v', 'mjpegzero_enc_top.v',
]

TEST_QUALITIES = [50, 75, 95]


def find_tool(name):
    return shutil.which(name)


def verilate(build_dir, lite_mode, lite_quality=95):
    """Compile RTL with Verilator --coverage. Returns True on success."""
    obj_dir = os.path.join(build_dir, 'obj_dir')

    rtl_files = [os.path.join(RTL_DIR, f) for f in _CORE_RTL]
    tb_cpp    = os.path.join(SIM_DIR, 'tb_verilator.cpp')

    # Use -G for Verilog parameter overrides (not -D preprocessor defines)
    defines = ['-GLITE_MODE=1' if lite_mode else '-GLITE_MODE=0']
    if lite_mode:
        defines.append(f'-GLITE_QUALITY={lite_quality}')

    # Fixed small image for coverage
    defines += ['-GIMG_WIDTH=64', '-GIMG_HEIGHT=8']

    cmd = [
        'verilator',
        '--cc',
        '--coverage',
        '--exe',
        '--build',
        '-Wall',
        '-Wno-TIMESCALEMOD',
        '-Wno-WIDTHEXPAND',
        '-Wno-WIDTHTRUNC',
        '--bbox-unsup',
        '--top-module', 'mjpegzero_enc_top',
        '--Mdir', obj_dir,
        '-o', os.path.join(build_dir, 'sim_coverage'),
    ] + defines + rtl_files + [tb_cpp]

    print(f'  Verilating (lite={lite_mode}, q={lite_quality})...')
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout)
    if result.returncode != 0:
        print(f'  ERROR: Verilator compilation failed')
        if result.stderr:
            print(result.stderr)
        return False
    return True


def run_sim(build_dir, quality, tag):
    """Run the Verilator sim binary. Returns True on success."""
    sim_bin = os.path.join(build_dir, 'sim_coverage')
    tv_src  = os.path.join(TV_DIR, 'yuyv_input.hex')
    out_jpg = os.path.join(build_dir, f'sim_output_{tag}.jpg')
    cov_dat = os.path.join(build_dir, f'coverage_{tag}.dat')

    # Ensure test vectors are accessible
    tv_dst = os.path.join(build_dir, 'test_vectors')
    if not os.path.isdir(tv_dst):
        os.makedirs(tv_dst, exist_ok=True)
    tv_link = os.path.join(tv_dst, 'yuyv_input.hex')
    if not os.path.exists(tv_link):
        shutil.copy2(tv_src, tv_link)

    cmd = [
        sim_bin,
        f'+tv={os.path.join("test_vectors", "yuyv_input.hex")}',
        f'+out={os.path.basename(out_jpg)}',
        f'+cov={os.path.basename(cov_dat)}',
        f'+q={quality}',
    ]

    print(f'  Running sim (Q={quality})...')
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=build_dir)
    print(result.stdout.strip())
    if result.returncode != 0:
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        return False
    return True


def merge_coverage(build_dir, tags):
    """Merge per-run .dat files into a single coverage database."""
    dat_files = [os.path.join(build_dir, f'coverage_{t}.dat') for t in tags]
    existing  = [f for f in dat_files if os.path.exists(f)]
    if not existing:
        print('  WARNING: no coverage data files found')
        return False

    merged = os.path.join(build_dir, 'coverage_merged.dat')
    cmd = ['verilator_coverage', '--write', merged] + existing
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f'  ERROR: verilator_coverage merge failed')
        if result.stderr:
            print(result.stderr)
        return False
    print(f'  Merged coverage: {merged}')
    return True


def generate_lcov(build_dir):
    """Convert Verilator coverage to LCOV info format."""
    merged = os.path.join(build_dir, 'coverage_merged.dat')
    info   = os.path.join(build_dir, 'coverage.info')
    cmd = ['verilator_coverage', '--write-info', info, merged]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f'  ERROR: LCOV conversion failed')
        if result.stderr:
            print(result.stderr)
        return False
    print(f'  LCOV info: {info}')
    return True


def generate_html(build_dir):
    """Generate HTML coverage report using genhtml (from lcov package)."""
    genhtml = find_tool('genhtml')
    if not genhtml:
        print('  genhtml not found — skipping HTML report (install lcov)')
        return False
    info = os.path.join(build_dir, 'coverage.info')
    html = os.path.join(build_dir, 'html')
    cmd = [genhtml, info, '-o', html, '--title', 'mjpegZero Coverage']
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f'  ERROR: genhtml failed')
        if result.stderr:
            print(result.stderr)
        return False
    print(f'  HTML report: {html}/index.html')
    return True


def print_summary(build_dir):
    """Print a text summary of coverage from the merged .dat file."""
    merged = os.path.join(build_dir, 'coverage_merged.dat')
    if not os.path.exists(merged):
        return
    cmd = ['verilator_coverage', '--annotate-min', '1', merged]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.stdout:
        # Just show the summary lines
        for line in result.stdout.splitlines():
            if '%' in line or 'Total' in line or 'coverage' in line.lower():
                print(f'  {line}')


def main():
    parser = argparse.ArgumentParser(description='Verilator code coverage for mjpegZero')
    parser.add_argument('--lite', action='store_true',
                        help='Test LITE_MODE=1 (default: full mode)')
    parser.add_argument('--html', action='store_true',
                        help='Generate HTML coverage report (requires lcov/genhtml)')
    parser.add_argument('--qualities', type=str, default=None,
                        help='Comma-separated quality levels (default: 50,75,95)')
    args = parser.parse_args()

    qualities = TEST_QUALITIES
    if args.qualities:
        qualities = [int(q) for q in args.qualities.split(',')]

    mode_str = 'LITE_MODE=1' if args.lite else 'LITE_MODE=0'
    print('=' * 65)
    print(f'Verilator Code Coverage  [{mode_str}]')
    print(f'Qualities: {qualities}')
    print('=' * 65)

    # Check tools
    for tool in ('verilator', 'g++', 'make'):
        if not find_tool(tool):
            print(f'ERROR: {tool} not found in PATH')
            return 1

    os.makedirs(BUILD_DIR, exist_ok=True)

    # Auto-generate test vectors if missing
    tv_file = os.path.join(TV_DIR, 'yuyv_input.hex')
    if not os.path.isfile(tv_file):
        print('  Test vectors missing — generating...')
        gen = os.path.join(SCRIPT_DIR, 'generate_test_vectors.py')
        r = subprocess.run([sys.executable, gen], capture_output=True, text=True)
        if r.returncode != 0:
            print(f'ERROR: generate_test_vectors.py failed:\n{r.stderr}')
            return 1

    tags    = []
    all_ok  = True

    for q in qualities:
        tag = f'{"lite" if args.lite else "full"}_q{q}'
        tags.append(tag)

        print(f'\n{"-" * 65}')
        print(f'  {tag}')
        print(f'{"-" * 65}')

        # Recompile for each quality in lite mode (compile-time param)
        if args.lite:
            if not verilate(BUILD_DIR, lite_mode=True, lite_quality=q):
                all_ok = False; continue
        else:
            # Full mode: compile once, quality set at runtime via AXI
            if q == qualities[0]:
                if not verilate(BUILD_DIR, lite_mode=False):
                    all_ok = False; break

        if not run_sim(BUILD_DIR, q, tag):
            all_ok = False

    # Merge and report
    print(f'\n{"=" * 65}')
    print('COVERAGE REPORT')
    print(f'{"=" * 65}')

    if merge_coverage(BUILD_DIR, tags):
        generate_lcov(BUILD_DIR)
        print_summary(BUILD_DIR)
        if args.html:
            generate_html(BUILD_DIR)

    print(f'\n{"=" * 65}')
    print(f'RESULT: {"PASS" if all_ok else "FAIL"}')
    print(f'{"=" * 65}')
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())
