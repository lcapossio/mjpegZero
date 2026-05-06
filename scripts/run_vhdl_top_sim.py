#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# Mixed-language simulation for the VHDL mjpegzero_enc_top.
#
# This reuses the existing SystemVerilog encoder testbench and Verilog leaf
# modules, while replacing translated blocks with their rtl/vhdl counterparts.

import argparse
import glob
import os
import shutil
import subprocess
import sys

PROJ_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))
RTL_DIR = os.path.join(PROJ_DIR, 'rtl')
VHDL_DIR = os.path.join(RTL_DIR, 'vhdl')
SIM_DIR = os.path.join(PROJ_DIR, 'sim')
BUILD_ROOT = os.path.join(PROJ_DIR, 'build', 'sim_vhdl_top')
TV_DIR = os.path.join(SIM_DIR, 'test_vectors')


def find_vivado_bin():
    for name in ('vivado', 'vivado.bat'):
        exe = shutil.which(name)
        if exe:
            return os.path.dirname(exe)
    if sys.platform == 'win32':
        drives = [os.environ.get('SystemDrive', 'C:') + os.sep, 'D:' + os.sep]
        roots = [os.path.join(d, p) for d in drives for p in ('AMDDesignTools', 'Xilinx')]
        bin_name = 'vivado.bat'
    else:
        roots = ['/tools/Xilinx', '/opt/Xilinx', '/opt/AMD']
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
    if sys.platform == 'win32':
        return os.path.join(viv_bin, name + '.bat')
    return os.path.join(viv_bin, name)


def run(cmd, cwd=None):
    print(' '.join(str(x) for x in cmd))
    result = subprocess.run(cmd, cwd=cwd)
    if result.returncode != 0:
        sys.exit(result.returncode)


def run_checked_sim(cmd, cwd=None):
    print(' '.join(str(x) for x in cmd))
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    if result.returncode != 0:
        sys.exit(result.returncode)
    if 'SOME TESTS FAILED' in result.stdout:
        sys.exit('ERROR: testbench reported SOME TESTS FAILED')
    if 'ALL TESTS PASSED' not in result.stdout:
        sys.exit('ERROR: testbench did not report ALL TESTS PASSED')


def main():
    parser = argparse.ArgumentParser(description='Vivado xsim mixed-language VHDL top simulation')
    parser.add_argument('flags', nargs='*', help='Options: lite, 720p, vcd, quality=N')
    args = parser.parse_args()

    lite_mode = 'lite' in args.flags
    mode_720p = '720p' in args.flags
    dump_vcd = 'vcd' in args.flags
    lite_quality = next((f.split('=', 1)[1] for f in args.flags if f.startswith('quality=')), None)
    tag_parts = ['lite' if lite_mode else 'full', '720p' if mode_720p else 'small']
    if lite_quality:
        tag_parts.append(f'q{lite_quality}')
    build_dir = os.path.join(BUILD_ROOT, '_'.join(tag_parts))

    viv = find_vivado_bin()
    if not viv:
        sys.exit('ERROR: Vivado not found. Add Vivado/bin to PATH.')

    os.makedirs(os.path.join(build_dir, 'test_vectors'), exist_ok=True)
    if not os.path.isfile(os.path.join(TV_DIR, 'yuyv_720p.hex')):
        print('Generating test vectors (yuyv_720p.hex missing)...')
        result = subprocess.run([sys.executable, os.path.join(PROJ_DIR, 'python', 'generate_test_vectors.py')])
        if result.returncode != 0:
            sys.exit('ERROR: generate_test_vectors.py failed')

    for path in glob.glob(os.path.join(TV_DIR, '*')):
        shutil.copy2(path, os.path.join(build_dir, 'test_vectors'))

    defines = ['-d', 'VHDL_DUT']
    if lite_mode:
        defines += ['-d', 'LITE_MODE']
    if mode_720p:
        defines += ['-d', 'TB_720P']
    if dump_vcd:
        defines += ['-d', 'DUMP_VCD']
    if lite_quality:
        with open(os.path.join(build_dir, 'sim_defines.vh'), 'w') as f:
            f.write(f'`define LITE_QUALITY {lite_quality}\n')
        defines += ['-d', 'HAVE_DEFINES']

    xvlog = vivado_tool(viv, 'xvlog')
    xvhdl = vivado_tool(viv, 'xvhdl')
    xelab = vivado_tool(viv, 'xelab')
    xsim = vivado_tool(viv, 'xsim')

    print('=' * 70)
    print(f'VHDL top  LITE_MODE={int(lite_mode)}  720P={int(mode_720p)}  Q={lite_quality or "default"}')
    print('Step 1: Compiling Verilog leaf sources...')
    print('=' * 70)
    run([xvlog] + defines + [
        os.path.join(RTL_DIR, 'vendor', 'sim', 'bram_sdp.v'),
        os.path.join(RTL_DIR, 'dct_1d.v'),
        os.path.join(RTL_DIR, 'dct_2d.v'),
        os.path.join(RTL_DIR, 'quantizer.v'),
        os.path.join(RTL_DIR, 'huffman_encoder.v'),
        os.path.join(RTL_DIR, 'jfif_writer.v'),
    ], cwd=build_dir)

    print('\nStep 2: Compiling VHDL sources...')
    run([xvhdl, '--2008',
         os.path.join(VHDL_DIR, 'mjpegzero_pkg.vhd'),
         os.path.join(VHDL_DIR, 'axi4_lite_regs.vhd'),
         os.path.join(VHDL_DIR, 'input_buffer.vhd'),
         os.path.join(VHDL_DIR, 'bitstream_packer.vhd'),
         os.path.join(VHDL_DIR, 'rgb_to_ycbcr.vhd'),
         os.path.join(VHDL_DIR, 'zigzag_reorder.vhd'),
         os.path.join(VHDL_DIR, 'mjpegzero_enc_top.vhd')], cwd=build_dir)

    print('\nStep 3: Compiling SystemVerilog testbench...')
    run([xvlog, '--sv'] + defines + ['-i', build_dir,
        os.path.join(SIM_DIR, 'tb_mjpegzero_enc.sv')], cwd=build_dir)

    print('\nStep 4: Elaborating mixed-language snapshot...')
    run([xelab, 'tb_mjpegzero_enc', '-s', 'sim_vhdl_top_snapshot',
         '-timescale', '1ns/1ps'], cwd=build_dir)

    print('\nStep 5: Running simulation...')
    if dump_vcd:
        wave_tcl = os.path.join(build_dir, 'wave.tcl')
        with open(wave_tcl, 'w') as f:
            f.write('open_vcd tb_mjpegzero_enc_vhdl_top.vcd\n'
                    'log_vcd [get_objects -r /*]\nrun all\nclose_vcd\nquit\n')
        run_checked_sim([xsim, 'sim_vhdl_top_snapshot', '-t', wave_tcl, '-onfinish', 'quit'], cwd=build_dir)
    else:
        run_checked_sim([xsim, 'sim_vhdl_top_snapshot', '-R', '-onfinish', 'quit'], cwd=build_dir)

    out_jpg = os.path.join(build_dir, 'sim_output.jpg')
    if os.path.isfile(out_jpg):
        print(f'\nOutput: {out_jpg} ({os.path.getsize(out_jpg)} bytes)')
    else:
        print('\nWARNING: No sim_output.jpg produced')


if __name__ == '__main__':
    main()
