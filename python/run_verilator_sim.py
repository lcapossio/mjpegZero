#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Verilator functional simulation for mjpegZero.

Compiles the RTL with Verilator and runs the C++ testbench as a functional
simulation (no coverage instrumentation — faster compile, no --coverage flag).
Validates each output JPEG for SOI/EOI markers and decodes it with Pillow to
confirm it is a valid image.

Usage:
    python python/run_verilator_sim.py [--lite] [--qualities 50,75,95]

Outputs:
    build/sim_verilator/sim_output_<tag>.jpg  — encoded JPEG per quality/mode
    PASS / FAIL printed to stdout

Requirements:
    verilator >= 4.x, g++, make
    Pillow (pip install Pillow)
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
BUILD_DIR  = os.path.join(PROJ_DIR, 'build', 'sim_verilator')
TV_DIR     = os.path.join(SIM_DIR, 'test_vectors')

_CORE_RTL = [
    'vendor/sim/bram_sdp.v',
    'dct_1d.v', 'dct_2d.v', 'input_buffer.v', 'quantizer.v',
    'zigzag_reorder.v', 'huffman_encoder.v', 'bitstream_packer.v',
    'jfif_writer.v', 'axi4_lite_regs.v', 'rgb_to_ycbcr.v',
    'mjpegzero_enc_top.v',
]

TEST_QUALITIES = [50, 75, 95]
MIN_JPEG_BYTES = 100
MAX_JPEG_BYTES = 500_000


def find_tool(name):
    return shutil.which(name)


def verilate(build_dir, lite_mode, lite_quality=95):
    """Compile RTL with Verilator (functional sim, no coverage). Returns True on success."""
    obj_dir   = os.path.join(build_dir, 'obj_dir')
    rtl_files = [os.path.join(RTL_DIR, f) for f in _CORE_RTL]
    tb_cpp    = os.path.join(SIM_DIR, 'tb_verilator.cpp')

    defines = ['-GLITE_MODE=1' if lite_mode else '-GLITE_MODE=0']
    if lite_mode:
        defines.append(f'-GLITE_QUALITY={lite_quality}')
    defines += ['-GIMG_WIDTH=64', '-GIMG_HEIGHT=8']

    cmd = [
        'verilator',
        '--cc',
        '--exe',
        '--build',
        '-Wall',
        '-Wno-TIMESCALEMOD',
        '-Wno-WIDTHEXPAND',
        '-Wno-WIDTHTRUNC',
        '--bbox-unsup',
        '--top-module', 'mjpegzero_enc_top',
        '--Mdir', obj_dir,
        '-o', os.path.join(build_dir, 'sim_verilator'),
    ] + defines + rtl_files + [tb_cpp]

    mode_str = f'{"lite" if lite_mode else "full"}'
    q_str    = f'Q{lite_quality}' if lite_mode else 'dynamic-Q'
    print(f'  Verilating ({mode_str}, {q_str})...')
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout)
    if result.returncode != 0:
        print('  ERROR: Verilator compilation failed')
        if result.stderr:
            print(result.stderr)
        return False
    return True


def run_sim(build_dir, quality, tag):
    """Run the Verilator sim binary. Returns True on success."""
    sim_bin = os.path.join(build_dir, 'sim_verilator')
    tv_src  = os.path.join(TV_DIR, 'yuyv_input.hex')
    out_jpg = os.path.join(build_dir, f'sim_output_{tag}.jpg')
    cov_dat = os.path.join(build_dir, f'coverage_{tag}.dat')  # unused but tb expects arg

    tv_dst = os.path.join(build_dir, 'test_vectors')
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
        return False, out_jpg
    return True, out_jpg


def validate_jpeg(jpeg_path):
    """Validate JPEG: check markers and decode with Pillow. Returns (ok, reason)."""
    if not os.path.exists(jpeg_path):
        return False, 'file not found'

    with open(jpeg_path, 'rb') as f:
        data = f.read()

    size = len(data)
    if size < MIN_JPEG_BYTES:
        return False, f'too small ({size} bytes)'
    if size > MAX_JPEG_BYTES:
        return False, f'too large ({size} bytes)'

    if len(data) < 4 or data[0] != 0xFF or data[1] != 0xD8:
        return False, 'missing SOI (FF D8)'
    if data[-2] != 0xFF or data[-1] != 0xD9:
        return False, 'missing EOI (FF D9)'

    # Check APP0 JFIF marker at byte 2
    if len(data) >= 6 and data[2] == 0xFF and data[3] == 0xE0:
        app0_present = True
    else:
        app0_present = False

    # Optionally check for APP1 EXIF at expected position
    app1_offset = 20  # right after APP0 when EXIF enabled
    has_app1 = (len(data) > app1_offset + 3 and
                data[app1_offset] == 0xFF and data[app1_offset + 1] == 0xE1)

    try:
        from PIL import Image
        import io
        img = Image.open(io.BytesIO(data))
        img.verify()
        pil_ok = True
    except ImportError:
        pil_ok = None  # Pillow not installed, skip
    except Exception as e:
        return False, f'Pillow decode failed: {e}'

    detail = f'{size} bytes, APP0={app0_present}, APP1/EXIF={has_app1}'
    if pil_ok is False:
        return False, f'Pillow rejected JPEG — {detail}'
    return True, detail


def main():
    parser = argparse.ArgumentParser(description='Verilator functional simulation for mjpegZero')
    parser.add_argument('--lite', action='store_true',
                        help='Test LITE_MODE=1 (default: full mode)')
    parser.add_argument('--qualities', type=str, default=None,
                        help='Comma-separated quality levels (default: 50,75,95)')
    args = parser.parse_args()

    qualities = TEST_QUALITIES
    if args.qualities:
        qualities = [int(q) for q in args.qualities.split(',')]

    mode_str = 'LITE_MODE=1' if args.lite else 'LITE_MODE=0'
    print('=' * 65)
    print(f'Verilator Functional Simulation  [{mode_str}]')
    print(f'Qualities: {qualities}')
    print('=' * 65)

    for tool in ('verilator', 'g++', 'make'):
        if not find_tool(tool):
            print(f'ERROR: {tool} not found in PATH')
            return 1

    os.makedirs(BUILD_DIR, exist_ok=True)

    tv_file = os.path.join(TV_DIR, 'yuyv_input.hex')
    if not os.path.isfile(tv_file):
        print('  Test vectors missing — generating...')
        gen = os.path.join(SCRIPT_DIR, 'generate_test_vectors.py')
        r = subprocess.run([sys.executable, gen], capture_output=True, text=True)
        if r.returncode != 0:
            print(f'ERROR: generate_test_vectors.py failed:\n{r.stderr}')
            return 1

    results = []

    for q in qualities:
        tag = f'{"lite" if args.lite else "full"}_q{q}'
        print(f'\n{"-" * 65}')
        print(f'  {tag}')
        print(f'{"-" * 65}')

        # Lite mode: recompile per quality (compile-time param)
        # Full mode: compile once for all qualities
        if args.lite:
            compile_ok = verilate(BUILD_DIR, lite_mode=True, lite_quality=q)
        else:
            compile_ok = (q == qualities[0] and verilate(BUILD_DIR, lite_mode=False)) or \
                         (q != qualities[0])
            # Re-use compiled binary for full mode (quality set at runtime via AXI)
            if q == qualities[0]:
                compile_ok = verilate(BUILD_DIR, lite_mode=False)
            else:
                compile_ok = True  # already compiled

        if not compile_ok:
            results.append((tag, False, 'compile failed'))
            continue

        sim_ok, out_jpg = run_sim(BUILD_DIR, q, tag)
        if not sim_ok:
            results.append((tag, False, 'simulation failed'))
            continue

        jpeg_ok, detail = validate_jpeg(out_jpg)
        results.append((tag, jpeg_ok, detail))

        status = 'PASS' if jpeg_ok else 'FAIL'
        print(f'  JPEG validation: {status} — {detail}')

    # Summary
    print(f'\n{"=" * 65}')
    print('RESULTS')
    print(f'{"=" * 65}')
    all_pass = True
    for tag, ok, detail in results:
        status = 'PASS' if ok else 'FAIL'
        print(f'  [{status}] {tag}: {detail}')
        if not ok:
            all_pass = False

    print(f'{"=" * 65}')
    print(f'OVERALL: {"PASS" if all_pass else "FAIL"}')
    print(f'{"=" * 65}')
    return 0 if all_pass else 1


if __name__ == '__main__':
    sys.exit(main())
