#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# ============================================================================
# Efinix Efinity Synthesis Script for mjpegZero
# Target: Efinix Trion T20F256I4 (default) / Titanium Ti60F225I
# ============================================================================
#
# Usage:
#   python scripts/synth/efinix/run_synth.py [lite [quality]]
#
# This script:
#   1. Generates an Efinity project XML from a template
#   2. Writes an SDC timing constraint file
#   3. Invokes efx_run.py to run the full compile flow
#
# Requirements:
#   - Efinix Efinity 2023.2+ installed and efx_run.py on PATH
#   - EFXPT_HOME environment variable set (usually auto-set by Efinity installer)
#
# Typical device strings:
#   Trion T8  : T8F81I4
#   Trion T20 : T20F256I4   ← default
#   Titanium Ti60: Ti60F225I
# ============================================================================

import argparse
import os
import sys
import shutil
import subprocess
import textwrap

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR   = os.path.normpath(os.path.join(SCRIPT_DIR, '../../..'))
RTL_DIR    = os.path.join(PROJ_DIR, 'rtl')
VENDOR_DIR = os.path.join(RTL_DIR, 'vendor', 'efinix')

# Default device — edit for your target
DEVICE   = 'T20F256I4'
FAMILY   = 'Trion'
TARGET_MHZ = 150


def generate_xml(output_dir, rtl_files, sdc_file, device, family,
                 lite_mode, lite_quality, img_width, img_height):
    """Generate an Efinity project XML file."""
    proj_name = 'mjpegzero'
    xml_path  = os.path.join(output_dir, f'{proj_name}.xml')

    # Build source file entries
    src_entries = '\n'.join(
        f'      <efxpt:source_file source="{f}" type="VERILOG" />'
        for f in rtl_files
    )

    # Build Verilog define list (Efinity uses these for preprocessor + param override)
    defines = [f'LITE_MODE={lite_mode}']
    if lite_mode:
        defines.append(f'LITE_QUALITY={lite_quality}')
    define_str = ' '.join(defines)

    xml = textwrap.dedent(f"""\
        <?xml version="1.0" encoding="utf-8"?>
        <efxpt:design xmlns:efxpt="http://www.efinixinc.com/peri_design"
                      name="{proj_name}"
                      device="{device}"
                      family="{family}"
                      version="2">
          <efxpt:synthesize
              top="synth_timing_wrapper"
              language="VERILOG"
              work_dir="{os.path.join(output_dir, 'work')}"
              defines="{define_str}">
            <efxpt:source_files>
{src_entries}
            </efxpt:source_files>
          </efxpt:synthesize>
          <efxpt:place_and_route
              sdc="{sdc_file}"
              work_dir="{os.path.join(output_dir, 'work')}" />
        </efxpt:design>
        """)

    with open(xml_path, 'w') as f:
        f.write(xml)
    return xml_path


def generate_sdc(output_dir, target_mhz):
    """Write SDC timing constraints."""
    period  = 1000.0 / target_mhz
    sdc_path = os.path.join(output_dir, 'timing.sdc')
    sdc = textwrap.dedent(f"""\
        # mjpegZero — SDC for Efinix Efinity
        create_clock -period {period:.3f} -name clk [get_ports clk]
        set_false_path -from [get_ports rst_n]
        set_false_path -from [get_ports {{vid_tdata vid_tvalid vid_tlast vid_tuser}}]
        set_false_path -from [get_ports {{axi_awaddr axi_awvalid axi_wdata axi_wstrb axi_wvalid axi_bready}}]
        set_false_path -from [get_ports {{axi_araddr axi_arvalid axi_rready}}]
        set_false_path -to   [get_ports {{jpg_tvalid jpg_tdata jpg_tlast vid_tready}}]
        set_false_path -to   [get_ports {{axi_awready axi_wready axi_bresp axi_bvalid}}]
        set_false_path -to   [get_ports {{axi_arready axi_rdata axi_rresp axi_rvalid}}]
        """)
    with open(sdc_path, 'w') as f:
        f.write(sdc)
    return sdc_path


def main():
    parser = argparse.ArgumentParser(description='Efinix Efinity synthesis for mjpegZero')
    parser.add_argument('mode',    nargs='?', default='full',
                        help='"lite" for LITE_MODE=1 (default: full)')
    parser.add_argument('quality', nargs='?', type=int, default=95,
                        help='LITE_QUALITY when lite mode (default: 95)')
    parser.add_argument('--device',  default=DEVICE,
                        help=f'Efinity device part number (default: {DEVICE})')
    parser.add_argument('--family',  default=FAMILY,
                        help=f'Device family (default: {FAMILY})')
    args = parser.parse_args()

    lite_mode    = 1 if args.mode == 'lite' else 0
    lite_quality = args.quality
    img_width    = 1280 if lite_mode else 1920
    img_height   = 720  if lite_mode else 1080

    mode_str = (f'LITE ({img_width}x{img_height}, Q{lite_quality})'
                if lite_mode else f'FULL ({img_width}x{img_height}, dynamic Q)')

    mode_suffix = '_lite' if lite_mode else ''
    output_dir  = os.path.join(PROJ_DIR, 'build', f'synth_efinix{mode_suffix}')
    os.makedirs(output_dir, exist_ok=True)
    os.makedirs(os.path.join(output_dir, 'work'), exist_ok=True)

    rtl_files = [
        os.path.join(VENDOR_DIR, 'bram_sdp.v'),
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
        os.path.join(RTL_DIR, 'synth_timing_wrapper.v'),
    ]

    sdc_path = generate_sdc(output_dir, TARGET_MHZ)
    xml_path = generate_xml(output_dir, rtl_files, sdc_path,
                            args.device, args.family,
                            lite_mode, lite_quality, img_width, img_height)

    print('=' * 65)
    print(f'Efinix Efinity Synthesis  [{mode_str}]')
    print(f'Device: {args.device}  Family: {args.family}')
    print(f'Target: {TARGET_MHZ} MHz')
    print(f'Project XML: {xml_path}')
    print('=' * 65)

    # Locate efx_run.py
    efx_run = shutil.which('efx_run.py') or shutil.which('efx_run')
    if not efx_run:
        efxpt_home = os.environ.get('EFXPT_HOME', '')
        candidate  = os.path.join(efxpt_home, 'bin', 'efx_run.py')
        if os.path.exists(candidate):
            efx_run = candidate
        else:
            print('ERROR: efx_run.py not found. Set EFXPT_HOME or add Efinity bin/ to PATH.')
            return 1

    cmd = [sys.executable, efx_run, '--project', xml_path, '--flow', 'compile']
    print(f'Running: {" ".join(cmd)}')
    result = subprocess.run(cmd, cwd=output_dir)

    print('=' * 65)
    if result.returncode == 0:
        print('SYNTHESIS COMPLETE')
    else:
        print(f'SYNTHESIS FAILED (rc={result.returncode})')
    print(f'Outputs: {output_dir}')
    print('=' * 65)
    return result.returncode


if __name__ == '__main__':
    sys.exit(main())
