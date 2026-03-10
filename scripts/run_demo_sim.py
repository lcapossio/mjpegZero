#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# run_demo_sim.py — Simulate demo_top_bare with behavioral AXI4 master
# ============================================================================
# Exercises the full demo_top pipeline (pixel upload, encode, JPEG readback)
# at 320x176 (180p class) to validate the demo_top RTL before bitstream rebuild.
#
# Usage: python scripts/run_demo_sim.py [vcd]
#   vcd:  dump full VCD to build/demo_sim/tb_demo_top.vcd
# ============================================================================

import argparse
import os
import shutil
import subprocess
import sys

PROJ_DIR   = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))
RTL_DIR    = os.path.join(PROJ_DIR, 'rtl')
COMMON_RTL = os.path.join(PROJ_DIR, 'example_proj', 'common', 'rtl')
SIM_DIR    = os.path.join(PROJ_DIR, 'sim')
BUILD_DIR  = os.path.join(PROJ_DIR, 'build', 'demo_sim')


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
    parser = argparse.ArgumentParser(description='Vivado xsim demo_top simulation')
    parser.add_argument('flags', nargs='*', help='Options: vcd')
    args = parser.parse_args()

    dump_vcd = 'vcd' in args.flags

    viv = find_vivado_bin()
    if not viv:
        sys.exit('ERROR: Vivado not found. Add Vivado/bin to PATH.')

    os.makedirs(BUILD_DIR, exist_ok=True)

    defines = []
    if dump_vcd:
        defines += ['-d', 'DUMP_VCD']

    print('=' * 70)
    print('Step 1: Compiling Verilog sources...')
    print('=' * 70)

    xvlog = vivado_tool(viv, 'xvlog')
    run([xvlog] + defines + [
        os.path.join(RTL_DIR, 'vendor', 'sim', 'bram_sdp.v'),
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
        os.path.join(COMMON_RTL, 'axi_init.v'),
        os.path.join(COMMON_RTL, 'demo_top_bare.v'),
    ], cwd=BUILD_DIR)

    print('\nStep 2: Compiling SystemVerilog testbench...')
    run([xvlog, '--sv'] + defines +
        [os.path.join(SIM_DIR, 'tb_demo_top.sv')], cwd=BUILD_DIR)

    print('\nStep 3: Elaborating...')
    run([vivado_tool(viv, 'xelab'), 'tb_demo_top',
         '-s', 'demo_snap', '-timescale', '1ns/1ps'], cwd=BUILD_DIR)

    print('\nStep 4: Running simulation...')
    if dump_vcd:
        wave_tcl = os.path.join(BUILD_DIR, 'wave.tcl')
        with open(wave_tcl, 'w') as f:
            f.write('open_vcd tb_demo_top.vcd\n'
                    'log_vcd [get_objects -r /*]\nrun all\nclose_vcd\nquit\n')
        run([vivado_tool(viv, 'xsim'), 'demo_snap',
             '-t', wave_tcl, '-onfinish', 'quit'], cwd=BUILD_DIR)
    else:
        run([vivado_tool(viv, 'xsim'), 'demo_snap',
             '-R', '-onfinish', 'quit'], cwd=BUILD_DIR)

    out_jpg = os.path.join(BUILD_DIR, 'demo_sim_output.jpg')
    if os.path.isfile(out_jpg):
        print(f'\nOutput JPEG: {out_jpg} ({os.path.getsize(out_jpg)} bytes)')
        dest = os.path.join(SIM_DIR, 'demo_sim_output.jpg')
        shutil.copy2(out_jpg, dest)
        print(f'Copied to: {dest}')
    else:
        print('\nWARNING: build/demo_sim/demo_sim_output.jpg not found')


if __name__ == '__main__':
    main()
