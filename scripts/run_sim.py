#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# run_sim.py — RTL simulation using Vivado xsim
# ============================================================================
# Usage: python scripts/run_sim.py [lite|full] [720p|1080p|WIDTHxHEIGHT] [vcd] [quality=N]
#   lite:      LITE_MODE=1 (fixed quality table)
#   full:      LITE_MODE=0 (runtime AXI quality)
#   720p:      1280x720 test image
#   1080p:     1920x1080 test image
#   vcd:       dump full VCD to build/sim/tb_mjpegzero_enc.vcd
#   quality=N  LITE_QUALITY override (requires lite)
# ============================================================================

import argparse
import glob
import os
import shutil
import subprocess
import sys

PROJ_DIR  = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))
RTL_DIR   = os.path.join(PROJ_DIR, 'rtl')
SIM_DIR   = os.path.join(PROJ_DIR, 'sim')
BUILD_DIR = os.path.join(PROJ_DIR, 'build', 'sim')
TV_DIR    = os.path.join(SIM_DIR, 'test_vectors')


def find_vivado_bin():
    """Return path to Vivado bin dir, or None."""
    for name in ('vivado', 'vivado.bat'):
        exe = shutil.which(name)
        if exe:
            return os.path.dirname(exe)
    if sys.platform == 'win32':
        drives = [os.environ.get('SystemDrive', 'C:') + os.sep, 'D:' + os.sep]
        roots  = [os.path.join(d, p) for d in drives
                  for p in ('AMDDesignTools', 'Xilinx')]
        bin_name = 'vivado.bat'
    else:
        roots    = ['/tools/Xilinx', '/opt/Xilinx', '/opt/AMD']
        bin_name = 'vivado'
    for root in roots:
        if not os.path.isdir(root):
            continue
        for ver in sorted(os.listdir(root), reverse=True):
            cand = os.path.join(root, ver, 'Vivado', 'bin', bin_name)
            if os.path.isfile(cand):
                return os.path.dirname(cand)
    return None


def vivado_tool(viv_bin, name):
    """Return full path to a Vivado tool, using .bat extension on Windows."""
    if sys.platform == 'win32':
        return os.path.join(viv_bin, name + '.bat')
    return os.path.join(viv_bin, name)


def run(cmd, cwd=None):
    print(' '.join(str(x) for x in cmd))
    r = subprocess.run(cmd, cwd=cwd)
    if r.returncode != 0:
        sys.exit(r.returncode)


def main():
    parser = argparse.ArgumentParser(description='Vivado xsim RTL simulation')
    parser.add_argument('flags', nargs='*',
                        help='Options: lite, full, 720p, 1080p, WIDTHxHEIGHT, vcd, quality=N')
    args = parser.parse_args()

    lite_mode    = 'lite' in args.flags
    dump_vcd     = 'vcd'  in args.flags
    lite_quality = next((f.split('=', 1)[1] for f in args.flags
                         if f.startswith('quality=')), None)
    img_width = 64
    img_height = 8
    for flag in args.flags:
        f = flag.lower()
        if f == '720p':
            img_width, img_height = 1280, 720
        elif f == '1080p':
            img_width, img_height = 1920, 1080
        elif 'x' in f and f.replace('x', '').isdigit():
            w, h = f.split('x', 1)
            img_width, img_height = int(w), int(h)

    viv = find_vivado_bin()
    if not viv:
        sys.exit('ERROR: Vivado not found. Add Vivado/bin to PATH.')

    os.makedirs(os.path.join(BUILD_DIR, 'test_vectors'), exist_ok=True)

    # Auto-generate test vectors if missing
    if not os.path.isfile(os.path.join(TV_DIR, 'yuyv_720p.hex')):
        print('Generating test vectors (yuyv_720p.hex missing)...')
        r = subprocess.run([sys.executable,
                            os.path.join(PROJ_DIR, 'python', 'generate_test_vectors.py')])
        if r.returncode != 0:
            sys.exit('ERROR: generate_test_vectors.py failed')

    for f in glob.glob(os.path.join(TV_DIR, '*')):
        shutil.copy2(f, os.path.join(BUILD_DIR, 'test_vectors'))

    # Build define list
    defines = []
    if lite_mode:    defines += ['-d', 'LITE_MODE']
    if dump_vcd:     defines += ['-d', 'DUMP_VCD']

    # Pick the input vector for this resolution and hand it to the TB via
    # TV_HEX_FILE. The TB's yuyv_data array is sized to NUM_PIXELS, so the vector
    # MUST have exactly W*H pixels — a shorter file leaves the tail uninitialized
    # (X) and the encoder streams garbage (the old TB_720P failure mode). The TB
    # scales its watchdog/EOI timeouts from NUM_PIXELS, so no size define is left.
    if (img_width, img_height) == (1280, 720):
        tv_hex = 'yuyv_720p.hex'
    elif (img_width, img_height) == (64, 8):
        tv_hex = 'yuyv_input.hex'
    else:
        tv_hex = f'yuyv_{img_width}x{img_height}.hex'
    if not os.path.isfile(os.path.join(TV_DIR, tv_hex)):
        sys.exit(f'ERROR: no input vector "{tv_hex}" for {img_width}x{img_height}. '
                 f'Supported out of the box: 1280x720 (720p) and 64x8 (default); '
                 f'generate {tv_hex} in {TV_DIR} to sim other sizes.')

    vh = os.path.join(BUILD_DIR, 'sim_defines.vh')
    with open(vh, 'w') as f:
        f.write(f'`define TB_IMG_WIDTH {img_width}\n')
        f.write(f'`define TB_IMG_HEIGHT {img_height}\n')
        f.write(f'`define TV_HEX_FILE "test_vectors/{tv_hex}"\n')
        if lite_quality:
            f.write(f'`define LITE_QUALITY {lite_quality}\n')
    defines += ['-d', 'HAVE_DEFINES']

    print('=' * 70)
    print(f'LITE_MODE={int(lite_mode)}  {img_width}x{img_height}  '
          f'Q={lite_quality or "default"}')
    print('Step 1: Compiling Verilog sources...')
    print('=' * 70)

    xvlog = vivado_tool(viv, 'xvlog')
    run([xvlog] + defines + [
        os.path.join(RTL_DIR, 'bram_sdp.v'),
        os.path.join(RTL_DIR, 'dct_1d.v'),
        os.path.join(RTL_DIR, 'dct_2d.v'),
        os.path.join(RTL_DIR, 'input_buffer.v'),
        os.path.join(RTL_DIR, 'quantizer.v'),
        os.path.join(RTL_DIR, 'zigzag_reorder.v'),
        os.path.join(RTL_DIR, 'huffman_encoder.v'),
        os.path.join(RTL_DIR, 'bitstream_packer.v'),
        os.path.join(RTL_DIR, 'jfif_writer.v'),
        os.path.join(RTL_DIR, 'axi4_lite_regs.v'),
        os.path.join(RTL_DIR, 'mjpegzero_enc_top.v'),
    ], cwd=BUILD_DIR)

    print('\nStep 2: Compiling SystemVerilog testbench...')
    run([xvlog, '--sv'] + defines + ['-i', BUILD_DIR,
        os.path.join(SIM_DIR, 'tb_mjpegzero_enc.sv'),
    ], cwd=BUILD_DIR)

    print('\nStep 3: Elaborating...')
    run([vivado_tool(viv, 'xelab'), 'tb_mjpegzero_enc',
         '-s', 'sim_snapshot', '-timescale', '1ns/1ps'], cwd=BUILD_DIR)

    print('\nStep 4: Running simulation...')
    if dump_vcd:
        wave_tcl = os.path.join(BUILD_DIR, 'wave.tcl')
        with open(wave_tcl, 'w') as f:
            f.write('open_vcd tb_mjpegzero_enc.vcd\n'
                    'log_vcd [get_objects -r /*]\nrun all\nclose_vcd\nquit\n')
        run([vivado_tool(viv, 'xsim'), 'sim_snapshot',
             '-t', wave_tcl, '-onfinish', 'quit'], cwd=BUILD_DIR)
    else:
        run([vivado_tool(viv, 'xsim'), 'sim_snapshot',
             '-R', '-onfinish', 'quit'], cwd=BUILD_DIR)

    out_jpg = os.path.join(BUILD_DIR, 'sim_output.jpg')
    if os.path.isfile(out_jpg):
        print(f'\nOutput: {out_jpg} ({os.path.getsize(out_jpg)} bytes)')
    else:
        print('\nWARNING: No sim_output.jpg produced')


if __name__ == '__main__':
    main()
