#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# ============================================================================
# run_rtp_sim.py - M1 standalone sim for the RTP/JPEG packetizer (jpeg_rtp_tx)
# ============================================================================
# Flow:
#   1. prep   : a real JPEG -> 32-bit LE word hex for $readmemh (+ dims/size)
#   2. iverilog: compile sim/tb_jpeg_rtp_tx.sv + rtl/eth/jpeg_rtp_tx.v
#   3. vvp    : run; the TB captures the emitted packets to captured.txt
#   4. check  : depacketize and verify byte-exactness vs the source JPEG
#
# Usage: python scripts/run_rtp_sim.py [path/to/input.jpg]
# Default input: build/demo_sim/demo_sim_output.jpg (320x176, 3 packets).
# ============================================================================

import json
import os
import shutil
import subprocess
import sys

PROJ_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))
OUTDIR   = os.path.join(PROJ_DIR, 'sim', 'rtp_test')
BUILDDIR = os.path.join(PROJ_DIR, 'build', 'rtp_sim')
TB       = os.path.join(PROJ_DIR, 'sim', 'tb_jpeg_rtp_tx.sv')
DUT      = os.path.join(PROJ_DIR, 'rtl', 'eth', 'jpeg_rtp_tx.v')
VERIFY   = os.path.join(PROJ_DIR, 'python', 'rtp_jpeg_verify.py')

DEFAULT_JPEGS = [
    os.path.join(PROJ_DIR, 'build', 'demo_sim', 'demo_sim_output.jpg'),
    os.path.join(PROJ_DIR, 'sim', 'sim_output.jpg'),
    os.path.join(PROJ_DIR, 'build', 'coverage', 'sim_output_full_q75.jpg'),
]


def tool(name):
    p = shutil.which(name)
    if p:
        return p
    cand = os.path.join('/c/iverilog/bin', name)
    if os.path.isfile(cand) or os.path.isfile(cand + '.exe'):
        return cand
    return name  # let subprocess fail with a clear error


def run(cmd, **kw):
    print('+ ' + ' '.join(cmd))
    return subprocess.run(cmd, **kw)


def main():
    inp = sys.argv[1] if len(sys.argv) > 1 else None
    if inp is None:
        for c in DEFAULT_JPEGS:
            if os.path.isfile(c):
                inp = c
                break
    if inp is None or not os.path.isfile(inp):
        print('ERROR: no input JPEG found; pass one explicitly.')
        return 2

    os.makedirs(OUTDIR, exist_ok=True)
    os.makedirs(BUILDDIR, exist_ok=True)

    # 1. prep
    r = run([sys.executable, VERIFY, 'prep', inp, OUTDIR], cwd=PROJ_DIR)
    if r.returncode != 0:
        return r.returncode
    with open(os.path.join(OUTDIR, 'meta.json')) as f:
        meta = json.load(f)
    jpeg_bytes, img_w, img_h = meta['size'], meta['width'], meta['height']

    # 2. iverilog compile
    vvp = os.path.join(BUILDDIR, 'tb_jpeg_rtp_tx.vvp')
    r = run([tool('iverilog'), '-g2012',
             '-DTB_IMG_W=%d' % img_w, '-DTB_IMG_H=%d' % img_h,
             '-o', vvp, TB, DUT], cwd=PROJ_DIR)
    if r.returncode != 0:
        return r.returncode

    # 3. run (cwd=PROJ_DIR so the TB's fixed relative paths resolve)
    r = run([tool('vvp'), vvp, '+JPEG_BYTES=%d' % jpeg_bytes], cwd=PROJ_DIR)
    if r.returncode != 0:
        return r.returncode

    # 4. check
    captured = os.path.join(OUTDIR, 'captured.txt')
    r = run([sys.executable, VERIFY, 'check', OUTDIR, captured, inp], cwd=PROJ_DIR)
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
