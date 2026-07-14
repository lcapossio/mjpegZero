#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# run_isp_chain.py — assembled ISP RTL vs the composed golden models
# ============================================================================
# Builds a Bayer frame from a mandrill crop, runs the six golden models in
# pipeline order (blc → wb → debayer → ccm → gamma → csc_422) with a real
# sRGB tone curve, nontrivial blacks/pedestal/gains/matrix, and compares
# the RTL chain's YUYV words bit-exactly across Bayer phases and an
# odd-width geometry.
# ============================================================================

import os
import subprocess
import sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.normpath(os.path.join(HERE, '..', '..'))
ISP = os.path.join(PROJ, 'streamline', 'rtl', 'isp')
sys.path.insert(0, HERE)

from debayer_model import demosaic_mhc, rgb_to_cfa            # noqa: E402
from isp_model import blc_frame, wb_frame, ccm_px             # noqa: E402
from isp_rgb_model import csc_422_frame                       # noqa: E402

BLACKS = [64, 60, 58, 72]
PED = 64
GAINS = [420, 256, 260, 505]
M = [[430, -120, -54], [-90, 410, -64], [-30, -150, 436]]
CURVE = [min(255, round(255.0 * (v / 4095.0) ** (1 / 2.2))) for v in range(4096)]

RTL_FILES = [os.path.join(ISP, m + '.v') for m in
             ('blc', 'wb_gains', 'debayer', 'ccm', 'gamma_lut',
              'csc_422', 'isp_chain')]


def golden(cfa, py, px):
    h, w = len(cfa), len(cfa[0])
    x = blc_frame(cfa, py, px, BLACKS, PED)
    x = wb_frame(x, py, px, GAINS, PED)
    R, G, B = demosaic_mhc(np.array(x), py, px, data_w=12)
    rgb8 = [[None] * w for _ in range(h)]
    for yy in range(h):
        for xx in range(w):
            r, g, b = ccm_px((R[yy][xx], G[yy][xx], B[yy][xx]), M, PED)
            rgb8[yy][xx] = (CURVE[r], CURVE[g], CURVE[b])
    return csc_422_frame(rgb8)


def run_case(w, h, py, px, rgb, build):
    os.makedirs(build, exist_ok=True)
    cfa = (rgb_to_cfa(rgb[:h, :w], py, px) * 16).tolist()  # 8b -> 12b samples
    exp = golden(cfa, py, px)

    with open(os.path.join(build, 'cfa.hex'), 'w') as f:
        for row in cfa:
            for v in row:
                f.write('%03x\n' % v)
    with open(os.path.join(build, 'yuyv_exp.hex'), 'w') as f:
        for wd in exp:
            f.write('%04x\n' % wd)
    with open(os.path.join(build, 'curve.hex'), 'w') as f:
        for v in CURVE:
            f.write('%02x\n' % v)
    with open(os.path.join(build, 'params.hex'), 'w') as f:
        for v in (BLACKS + [PED] + GAINS
                  + [c & 0xFFFF for row in M for c in row]):
            f.write('%04x\n' % v)

    phase = py * 2 + px
    r = subprocess.run(
        ['iverilog', '-g2012', '-o', os.path.join(build, 'tb.vvp'),
         f'-DTB_W={w}', f'-DTB_H={h}', f'-DTB_PHASE=2\'d{phase}']
        + RTL_FILES + [os.path.join(HERE, 'tb_isp_chain.sv')],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[:400])
        return False
    r = subprocess.run(['vvp', 'tb.vvp'], cwd=build,
                       capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines()
             if 'PASS' in l or 'FAIL' in l or 'MISMATCH' in l]
    print(f'  {w}x{h} phase {phase}:', lines[0] if lines else 'NO VERDICT')
    return bool(lines) and lines[0].startswith('PASS')


def main():
    img = Image.open(os.path.join(PROJ, 'streamline', 'verify', 'test_images',
                                  'mandrill_720p.png')).convert('RGB')
    rgb = np.asarray(img)[32:96, 96:192].astype(np.int64)
    ramp = (np.arange(rgb.shape[0])[:, None] * 5
            + np.arange(rgb.shape[1])[None, :]) % 173
    rgb = np.clip(rgb + ramp[:, :, None] // 3, 0, 255)

    ok = True
    for i, (w, h, py, px) in enumerate(
            [(48, 16, 0, 0), (48, 16, 1, 1), (26, 12, 0, 1)]):
        build = os.path.join(PROJ, 'streamline', 'build', 'isp_chain', f'case{i}')
        ok &= run_case(w, h, py, px, rgb, build)
    print('ALL PASS' if ok else 'SOME FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
