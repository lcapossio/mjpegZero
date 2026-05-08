#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# run_postsim.py — Post-synthesis functional simulation
# ============================================================================
# Synthesizes mjpegzero_enc_top with Vivado, exports a funcsim netlist,
# then simulates the netlist with the standard testbench.
# Catches synthesis-introduced bugs invisible in RTL simulation.
#
# Usage: python scripts/run_postsim.py [vhdl] [lite] [720p] [vcd] [quality=N]
#   vhdl:      synthesize the VHDL RTL instead of the Verilog RTL
#   lite:      LITE_MODE=1 (lite mode)
#   720p:      1280x720 test image
#   vcd:       dump full VCD
#   quality=N  LITE_QUALITY override (requires lite)
# ============================================================================

import glob
import os
import shutil
import subprocess
import sys

PROJ_DIR  = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))
RTL_DIR   = os.path.join(PROJ_DIR, 'rtl')
SIM_DIR   = os.path.join(PROJ_DIR, 'sim')
BUILD_ROOT = os.path.join(PROJ_DIR, 'build')
TV_DIR    = os.path.join(SIM_DIR, 'test_vectors')


def find_vivado():
    """Return (vivado_exe, vivado_bin_dir) or exit."""
    for name in ('vivado', 'vivado.bat'):
        exe = shutil.which(name)
        if exe:
            return exe, os.path.dirname(exe)
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
                return cand, os.path.dirname(cand)
    sys.exit('ERROR: Vivado not found. Add Vivado/bin to PATH.')


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
    import argparse
    parser = argparse.ArgumentParser(description='Post-synthesis simulation')
    parser.add_argument('flags', nargs='*',
                        help='Options: lite, 720p, vcd, quality=N')
    args = parser.parse_args()

    lite_mode    = 'lite' in args.flags
    vhdl_mode    = 'vhdl' in args.flags
    mode_720p    = '720p' in args.flags
    dump_vcd     = 'vcd'  in args.flags
    lite_quality = next((f.split('=', 1)[1] for f in args.flags
                         if f.startswith('quality=')), None)

    vivado_exe, viv = find_vivado()

    build_dir = os.path.join(BUILD_ROOT, 'postsim_vhdl' if vhdl_mode else 'postsim')

    os.makedirs(build_dir, exist_ok=True)

    # -------------------------------------------------------------------------
    # Step 1: Synthesize and export funcsim.v
    # -------------------------------------------------------------------------
    print('=' * 70)
    print(f'Post-synthesis sim: RTL={"VHDL" if vhdl_mode else "Verilog"}  '
          f'LITE_MODE={int(lite_mode)}  '
          f'720P={int(mode_720p)}  Q={lite_quality or "default"}')
    print('Step 1: Synthesizing and exporting funcsim.v...')
    print('=' * 70)

    tcl_args = []
    if lite_mode:
        tcl_args.append('lite')
        if lite_quality:
            tcl_args.append(lite_quality)

    synth_tcl = os.path.join(PROJ_DIR, 'scripts',
                             'synth_for_postsim_vhdl.tcl' if vhdl_mode
                             else 'synth_for_postsim.tcl')
    cmd = [vivado_exe, '-mode', 'batch', '-nolog', '-nojournal',
           '-source', synth_tcl]
    if tcl_args:
        cmd += ['-tclargs'] + tcl_args
    run(cmd)

    funcsim = os.path.join(build_dir, 'funcsim.v')
    if not os.path.isfile(funcsim):
        sys.exit('SYNTHESIS/EXPORT FAILED: funcsim.v not found')

    # -------------------------------------------------------------------------
    # Step 2: Compile netlist + testbench
    # -------------------------------------------------------------------------
    print('\nStep 2: Compiling post-synth netlist + testbench...')

    defines = ['-d', 'POSTSIM']
    if lite_mode:    defines += ['-d', 'LITE_MODE']
    if mode_720p:    defines += ['-d', 'TB_720P']
    if dump_vcd:     defines += ['-d', 'DUMP_VCD']
    if lite_quality:
        vh = os.path.join(build_dir, 'sim_defines.vh')
        with open(vh, 'w') as f:
            f.write(f'`define LITE_QUALITY {lite_quality}\n')
        defines += ['-d', 'HAVE_DEFINES']

    os.makedirs(os.path.join(build_dir, 'test_vectors'), exist_ok=True)
    for f in glob.glob(os.path.join(TV_DIR, '*')):
        shutil.copy2(f, os.path.join(build_dir, 'test_vectors'))

    # Locate glbl.v
    vivado_root = os.path.dirname(viv)
    glbl_v = os.path.join(vivado_root, 'data', 'verilog', 'src', 'glbl.v')
    if not os.path.isfile(glbl_v):
        glbl_v = os.path.join(os.path.dirname(vivado_root),
                              'data', 'verilog', 'src', 'glbl.v')

    xvlog = vivado_tool(viv, 'xvlog')
    run([xvlog, glbl_v], cwd=build_dir)
    run([xvlog] + defines + [funcsim], cwd=build_dir)
    run([xvlog, '--sv'] + defines + ['-i', build_dir,
        os.path.join(SIM_DIR, 'tb_mjpegzero_enc.sv')], cwd=build_dir)

    # -------------------------------------------------------------------------
    # Step 3: Elaborate
    # -------------------------------------------------------------------------
    print('\nStep 3: Elaborating...')
    run([vivado_tool(viv, 'xelab'), 'tb_mjpegzero_enc', 'glbl',
         '-s', 'postsim_snap', '-timescale', '1ns/1ps',
         '-L', 'unisims_ver'], cwd=build_dir)

    # -------------------------------------------------------------------------
    # Step 4: Simulate
    # -------------------------------------------------------------------------
    print('\nStep 4: Running post-synthesis simulation...')
    if dump_vcd:
        wave_tcl = os.path.join(build_dir, 'wave.tcl')
        with open(wave_tcl, 'w') as f:
            f.write('open_vcd postsim_output.vcd\n'
                    'log_vcd [get_objects -r /*]\nrun all\nclose_vcd\nquit\n')
        run([vivado_tool(viv, 'xsim'), 'postsim_snap',
             '-t', wave_tcl, '-onfinish', 'quit'], cwd=build_dir)
    else:
        run([vivado_tool(viv, 'xsim'), 'postsim_snap',
             '-R', '-onfinish', 'quit'], cwd=build_dir)

    out_jpg = os.path.join(build_dir, 'sim_output.jpg')
    if os.path.isfile(out_jpg):
        print(f'\nOutput: {out_jpg} ({os.path.getsize(out_jpg)} bytes)')
    else:
        print('\nWARNING: No sim_output.jpg produced')


if __name__ == '__main__':
    main()
