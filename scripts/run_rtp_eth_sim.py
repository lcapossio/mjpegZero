#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# ============================================================================
# run_rtp_eth_sim.py - M2 integration sim for the Ethernet egress chain
# ============================================================================
# Builds net_rx + jpeg_rtp_trigger + jpeg_rtp_tx + arty_tx_arbiter, injects a
# UDP trigger frame, captures the arbiter's RTP/JPEG output, and verifies it
# (M1 gates G1-G4 + G5: the emitted destination equals the trigger sender).
#
# Usage: python scripts/run_rtp_eth_sim.py [path/to/input.jpg]
# ============================================================================

import json
import os
import shutil
import subprocess
import sys

PROJ_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))
OUTDIR   = os.path.join(PROJ_DIR, 'sim', 'rtp_test')
BUILDDIR = os.path.join(PROJ_DIR, 'build', 'rtp_sim')
VERIFY   = os.path.join(PROJ_DIR, 'python', 'rtp_jpeg_verify.py')

SOURCES = [
    os.path.join(PROJ_DIR, 'sim', 'tb_jpeg_rtp_eth.sv'),
    os.path.join(PROJ_DIR, 'rtl', 'eth', 'jpeg_rtp_tx.v'),
    os.path.join(PROJ_DIR, 'rtl', 'eth', 'jpeg_rtp_trigger.v'),
    os.path.join(PROJ_DIR, 'rtl', 'eth', 'axis_frame_buffer.v'),
    os.path.join(PROJ_DIR, 'emaczero', 'rtl', 'net', 'net_rx.v'),
    os.path.join(PROJ_DIR, 'emaczero', 'fpga', 'arty_a7', 'rtl', 'arty_tx_arbiter.v'),
]

DEFAULT_JPEGS = [
    os.path.join(PROJ_DIR, 'build', 'demo_sim', 'demo_sim_output.jpg'),
    os.path.join(PROJ_DIR, 'sim', 'sim_output.jpg'),
]

# Must match the constants in sim/tb_jpeg_rtp_eth.sv
EXPECT_DST_MAC  = 'aabbccddeeff'   # HOST_MAC
EXPECT_DST_IP   = '192.168.1.77'   # HOST_IP
EXPECT_DST_PORT = 5004             # RTP_DST_PORT


def tool(name):
    p = shutil.which(name)
    if p:
        return p
    cand = os.path.join('/c/iverilog/bin', name)
    if os.path.isfile(cand) or os.path.isfile(cand + '.exe'):
        return cand
    return name


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

    r = run([sys.executable, VERIFY, 'prep', inp, OUTDIR], cwd=PROJ_DIR)
    if r.returncode != 0:
        return r.returncode
    with open(os.path.join(OUTDIR, 'meta.json')) as f:
        meta = json.load(f)

    vvp = os.path.join(BUILDDIR, 'tb_jpeg_rtp_eth.vvp')
    r = run([tool('iverilog'), '-g2012',
             '-DTB_IMG_W=%d' % meta['width'], '-DTB_IMG_H=%d' % meta['height'],
             '-o', vvp] + SOURCES, cwd=PROJ_DIR)
    if r.returncode != 0:
        return r.returncode

    r = run([tool('vvp'), vvp, '+JPEG_BYTES=%d' % meta['size']], cwd=PROJ_DIR)
    if r.returncode != 0:
        return r.returncode

    captured = os.path.join(OUTDIR, 'captured.txt')
    r = run([sys.executable, VERIFY, 'check', OUTDIR, captured, inp,
             'dstmac=%s' % EXPECT_DST_MAC, 'dstip=%s' % EXPECT_DST_IP,
             'dstport=%d' % EXPECT_DST_PORT], cwd=PROJ_DIR)
    return r.returncode


if __name__ == '__main__':
    sys.exit(main())
