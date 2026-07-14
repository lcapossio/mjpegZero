#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# run_debayer.py — debayer RTL vs golden model, all phases and corner sizes
# ============================================================================
# For each (width, height, phase) case: build a CFA from a mandrill crop
# (plus a ramp overlay so every case is distinct), compute expected RGB with
# the bit-exact model, compile tb_debayer.sv with matching defines, run, and
# require PASS. Usage: run_debayer.py [--quick]
# ============================================================================

import os
import subprocess
import sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)

from debayer_model import demosaic_mhc, rgb_to_cfa  # noqa: E402


def run_case(w, h, py, px, rgb, build):
    os.makedirs(build, exist_ok=True)
    cfa = rgb_to_cfa(rgb[:h, :w], py, px) * 16          # 8-bit -> 12-bit
    R, G, B = demosaic_mhc(cfa, py, px, data_w=12)

    with open(os.path.join(build, 'cfa.hex'), 'w') as f:
        for v in cfa.flatten():
            f.write('%03x\n' % v)
    with open(os.path.join(build, 'rgb_exp.hex'), 'w') as f:
        for y in range(h):
            for x in range(w):
                f.write('%03x\n%03x\n%03x\n' % (R[y][x], G[y][x], B[y][x]))

    phase = py * 2 + px
    vvp = os.path.join(build, 'tb.vvp')
    r = subprocess.run(
        ['iverilog', '-g2012', '-o', vvp,
         f'-DTB_W={w}', f'-DTB_H={h}', f'-DTB_PHASE=2\'d{phase}',
         os.path.join(PROJ, 'streamline', 'rtl', 'isp', 'debayer.v'),
         os.path.join(HERE, 'tb_debayer.sv')],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[:400])
        return False
    r = subprocess.run(['vvp', 'tb.vvp'], cwd=build,
                       capture_output=True, text=True)
    line = [l for l in r.stdout.splitlines() if 'PASS' in l or 'FAIL' in l
            or 'MISMATCH' in l]
    print(f'  {w}x{h} phase {phase}:', line[0] if line else 'NO VERDICT')
    return bool(line) and line[0].startswith('PASS')


def main():
    quick = '--quick' in sys.argv
    img = Image.open(os.path.join(PROJ, 'streamline', 'verify', 'test_images',
                                  'mandrill_720p.png')).convert('RGB')
    rgb = np.asarray(img)[64:128, 128:224].astype(np.int64)
    # Overlay a ramp so flat regions still exercise distinct codes.
    ramp = (np.arange(rgb.shape[0])[:, None] * 3
            + np.arange(rgb.shape[1])[None, :]) % 199
    rgb = np.clip(rgb + ramp[:, :, None] // 4, 0, 255)

    cases = [(48, 16, 0, 0), (48, 16, 0, 1), (48, 16, 1, 0), (48, 16, 1, 1),
             (25, 11, 0, 0), (8, 8, 1, 1)]
    if quick:
        cases = cases[:2]

    ok = True
    for i, (w, h, py, px) in enumerate(cases):
        build = os.path.join(PROJ, 'streamline', 'build', 'debayer', f'case{i}')
        ok &= run_case(w, h, py, px, rgb, build)
    print('ALL PASS' if ok else 'SOME FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
