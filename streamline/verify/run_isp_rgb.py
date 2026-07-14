#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# run_isp_rgb.py — gamma_lut / csc_422 RTL vs golden models
# ============================================================================

import os
import subprocess
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)

from isp_rgb_model import csc_422_frame  # noqa: E402

ISP = os.path.join(PROJ, 'streamline', 'rtl', 'isp')


def whex(path, vals, width):
    with open(path, 'w') as f:
        for v in vals:
            f.write(('%0' + str(width) + 'x\n') % (int(v) & 0xFFFF))


def compile_run(build, mode, w, h, rtl):
    r = subprocess.run(
        ['iverilog', '-g2012', '-o', os.path.join(build, 'tb.vvp'),
         f'-DTB_MODE_{mode}', f'-DTB_W={w}', f'-DTB_H={h}',
         os.path.join(ISP, rtl), os.path.join(HERE, 'tb_isp_rgb.sv')],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[:400])
        return False
    r = subprocess.run(['vvp', 'tb.vvp'], cwd=build,
                       capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines()
             if 'PASS' in l or 'FAIL' in l or 'MISMATCH' in l]
    print(f'  {mode} {w}x{h}:', lines[0] if lines else 'NO VERDICT')
    return bool(lines) and lines[0].startswith('PASS')


def main():
    rng = np.random.default_rng(9)
    ok = True

    # ---- gamma: frame 1 identity truncation, frame 2 an sRGB-like curve
    w, h = 24, 8
    n = w * h
    trips = rng.integers(0, 4096, (n, 3))
    trips[0] = [0, 4095, 2048]
    curve = [min(255, round(255.0 * (v / 4095.0) ** (1 / 2.2)))
             for v in range(4096)]
    exp = [t >> 4 for tri in trips for t in tri] \
        + [curve[t] for tri in trips for t in tri]
    build = os.path.join(PROJ, 'build', 'isp', 'gamma')
    os.makedirs(build, exist_ok=True)
    whex(os.path.join(build, 'stim.hex'), trips.flatten(), 3)
    whex(os.path.join(build, 'exp.hex'), exp, 4)
    whex(os.path.join(build, 'curve.hex'), curve, 2)
    ok &= compile_run(build, 'GAMMA', w, h, 'gamma_lut.v')

    # ---- csc_422: 8-bit RGB frames, directed extremes + random
    for (w, h) in [(32, 6), (20, 5)]:
        n = w * h
        trips = rng.integers(0, 256, (n, 3))
        trips[0] = [255, 255, 255]
        trips[1] = [0, 0, 0]
        trips[2] = [255, 0, 0]
        trips[3] = [0, 0, 255]
        rgb = [[tuple(trips[y*w + x]) for x in range(w)] for y in range(h)]
        exp = csc_422_frame(rgb)
        build = os.path.join(PROJ, 'build', 'isp', f'csc_{w}x{h}')
        os.makedirs(build, exist_ok=True)
        whex(os.path.join(build, 'stim.hex'), trips.flatten(), 3)
        whex(os.path.join(build, 'exp.hex'), exp, 4)
        ok &= compile_run(build, 'CSC', w, h, 'csc_422.v')

    print('ALL PASS' if ok else 'SOME FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
