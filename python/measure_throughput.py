#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
measure_throughput.py — encoder throughput on detailed content (iverilog).

Encodes 1280x8 strips cut from the 720p mandrill vector (sim/test_vectors/
yuyv_720p.hex) with sim/tb_iverilog.sv built with +PERF, and reports:

  cycles/block   encode window (first block issued -> last EOB) / blocks
  720p fps       projected at 150 MHz: 150e6 / (cycles/block * 28800 blocks)
  ring full      % of cycles the Huffman input ring was full (Huffman-bound)
  packer stall   % of cycles a Huffman code waited on the bitstream packer
  Huffman FSM    % of cycles per state (idle / DC / AC fetch+scan / emit ...)

Each run's JPEG is kept as build/perf/out_q<Q>_r<row>.jpg so RTL changes that
must be bit-exact can be diffed against a baseline (--compare DIR).

Usage:
    python python/measure_throughput.py                  # Q 50/75/95, rows 0/360
    python python/measure_throughput.py --quality 95 --rows 0 200 400
    python python/measure_throughput.py --compare build/perf_baseline
    python python/measure_throughput.py --min-fps 60     # exit 1 below this
"""

import argparse
import filecmp
import os
import re
import shutil
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)
from verify_rtl_sim import compile_rtl, find_tool  # noqa: E402

TV_720P = os.path.join(PROJ_DIR, 'sim', 'test_vectors', 'yuyv_720p.hex')
BUILD = os.path.join(PROJ_DIR, 'build', 'perf')
W, H_FULL, CLK_HZ, BLOCKS_720P = 1280, 720, 150e6, 1280 * 720 // 32

STATES = ['IDLE', 'DC_FETCH', 'DC_ENC', 'DC_EMIT', 'AC_FETCH', 'AC_SCAN',
          'AC_ENC', 'AC_EMIT', 'ZRL', 'EOB', 'DC_CALC']
# Report groups: (label, state indices)
GROUPS = [('idle', [0]), ('dc', [1, 2, 10, 3]), ('ac scan', [4, 5]),
          ('ac enc+emit', [6, 7, 8]), ('eob', [9])]


def cut_strip(row, path):
    with open(TV_720P) as f:
        words = f.read().split()
    if len(words) != W * H_FULL:
        sys.exit(f'ERROR: {TV_720P} has {len(words)} words, expected {W * H_FULL}')
    with open(path, 'w') as f:
        f.write('\n'.join(words[row * W:(row + 8) * W]) + '\n')


def run_case(iverilog, vvp, quality, row, lite):
    tag = f'q{quality}_r{row}' + ('_lite' if lite else '')
    run_dir = os.path.join(BUILD, tag)
    os.makedirs(run_dir, exist_ok=True)
    hex_path = os.path.join(run_dir, 'strip.hex')
    cut_strip(row, hex_path)
    defines = {'PERF': 1, 'TB_IMG_WIDTH': W, 'TEST_QUALITY': quality,
               'TV_HEX_FILE': '"strip.hex"'}
    if lite:
        defines['LITE_MODE'] = 1
        defines['LITE_QUALITY'] = quality
    vvp_out = os.path.join(run_dir, 'tb.vvp')
    if not compile_rtl(iverilog, vvp_out, defines):
        sys.exit(1)
    out_jpg = os.path.join(run_dir, 'sim_output.jpg')
    if os.path.exists(out_jpg):
        os.remove(out_jpg)
    r = subprocess.run([vvp, vvp_out], capture_output=True, text=True, cwd=run_dir)
    m = re.search(r'PERF blocks=(\d+) cycles=(\d+) ring_full=(\d+) '
                  r'packer_stall=(\d+) ibuf_idle=(\d+)', r.stdout)
    s = re.search(r'PERF states((?: \d+)+)', r.stdout)
    if not m or not s or not os.path.exists(out_jpg):
        print(r.stdout[-3000:])
        sys.exit(f'ERROR: no PERF result for {tag}')
    blocks, cycles, ring, stall, idle = map(int, m.groups())
    states = list(map(int, s.group(1).split()))
    kept = os.path.join(BUILD, f'out_{tag}.jpg')
    shutil.copyfile(out_jpg, kept)
    return dict(tag=tag, blocks=blocks, cycles=cycles, ring=ring, stall=stall,
                idle=idle, states=states, jpg=kept,
                size=os.path.getsize(out_jpg))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--quality', type=int, nargs='+', default=[50, 75, 95])
    ap.add_argument('--rows', type=int, nargs='+', default=[0, 360],
                    help='strip start rows in the 720p image (multiple of 8)')
    ap.add_argument('--lite', action='store_true')
    ap.add_argument('--compare', metavar='DIR',
                    help='directory of out_*.jpg from a baseline run; '
                         'fail if any output differs')
    ap.add_argument('--min-fps', type=float, default=None,
                    help='exit 1 if any case projects below this 720p fps')
    args = ap.parse_args()

    iverilog, vvp = find_tool('iverilog'), find_tool('vvp')
    if not iverilog or not vvp:
        sys.exit('ERROR: iverilog/vvp not found in PATH')
    if not os.path.exists(TV_720P):
        sys.exit(f'ERROR: {TV_720P} missing — run python/generate_test_vectors.py')
    for row in args.rows:
        if row % 8 or not 0 <= row <= H_FULL - 8:
            sys.exit(f'ERROR: row {row} must be a multiple of 8 in 0..{H_FULL - 8}')

    results = [run_case(iverilog, vvp, q, row, args.lite)
               for q in args.quality for row in args.rows]

    print()
    hdr = (f'{"case":<14}{"bytes":>7}{"cyc/blk":>9}{"720p fps":>10}'
           f'{"ring full":>11}{"pk stall":>10}  Huffman FSM % '
           + ' / '.join(g for g, _ in GROUPS))
    print(hdr)
    print('-' * len(hdr))
    ok = True
    for r in results:
        cpb = r['cycles'] / r['blocks']
        fps = CLK_HZ / (cpb * BLOCKS_720P)
        groups = ' / '.join(f'{100 * sum(r["states"][i] for i in idx) / r["cycles"]:.0f}'
                            for _, idx in GROUPS)
        print(f'{r["tag"]:<14}{r["size"]:>7}{cpb:>9.1f}{fps:>10.1f}'
              f'{100 * r["ring"] / r["cycles"]:>10.0f}%{100 * r["stall"] / r["cycles"]:>9.0f}%'
              f'  {groups}')
        if args.min_fps is not None and fps < args.min_fps:
            print(f'  FAIL: {fps:.1f} fps < --min-fps {args.min_fps}')
            ok = False

    if args.compare:
        for r in results:
            base = os.path.join(args.compare, os.path.basename(r['jpg']))
            if not os.path.exists(base):
                print(f'  compare: no baseline {base}')
                ok = False
            elif not filecmp.cmp(base, r['jpg'], shallow=False):
                print(f'  FAIL: {os.path.basename(r["jpg"])} differs from baseline')
                ok = False
            else:
                print(f'  bit-exact vs baseline: {os.path.basename(r["jpg"])}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
