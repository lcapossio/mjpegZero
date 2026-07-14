#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# run_isp_arith.py — blc / wb_gains / ccm RTL vs golden models
# ============================================================================
# Directed + random stimulus per module, expected values from isp_model.py,
# each case compiled and simulated with tb_isp_arith.sv.
# ============================================================================

import os
import subprocess
import sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.normpath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, HERE)

from isp_model import blc_frame, wb_frame, ccm_px  # noqa: E402

PEDS = [0, 64]

ISP = os.path.join(PROJ, 'streamline', 'rtl', 'isp')


def write_hex(path, vals, width=3):
    with open(path, 'w') as f:
        for v in vals:
            f.write(('%0' + str(width) + 'x\n') % (int(v) & 0xFFFF))


def run(build, mode, w, h, rtl, stim, exp, params):
    os.makedirs(build, exist_ok=True)
    write_hex(os.path.join(build, 'stim.hex'), stim)
    write_hex(os.path.join(build, 'exp.hex'), exp)
    write_hex(os.path.join(build, 'params.hex'), params, width=4)
    r = subprocess.run(
        ['iverilog', '-g2012', '-o', os.path.join(build, 'tb.vvp'),
         f'-DTB_MODE_{mode}', f'-DTB_W={w}', f'-DTB_H={h}',
         os.path.join(ISP, rtl), os.path.join(HERE, 'tb_isp_arith.sv')],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[:300])
        return False
    r = subprocess.run(['vvp', 'tb.vvp'], cwd=build,
                       capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines()
             if 'PASS' in l or 'FAIL' in l or 'MISMATCH' in l]
    print(f'  {mode} {w}x{h}:', lines[0] if lines else 'NO VERDICT')
    return bool(lines) and lines[0].startswith('PASS')


def main():
    rng = np.random.default_rng(3)
    ok = True

    # Directed extremes plus random, reshaped per case geometry.
    def frame_vals(n):
        v = list(rng.integers(0, 4096, n))
        v[:8] = [0, 1, 4095, 4094, 2048, 64, 63, 65]
        return v

    for (w, h, py, px) in [(32, 10, 0, 0), (21, 9, 1, 1)]:
        vals = frame_vals(w * h)
        # Values straddling black +/- pedestal exercise the footroom path.
        vals[8:16] = [30, 62, 65, 90, 100, 128, 130, 200]
        cfa = [vals[y*w:(y+1)*w] for y in range(h)]

        for ped in PEDS:
            blacks = [64, 60, 58, 72]
            exp = [v for row in blc_frame(cfa, py, px, blacks, ped)
                   for v in row]
            ok &= run(os.path.join(PROJ, 'streamline', 'build', 'isp',
                                   f'blc_{w}x{h}_p{ped}'),
                      'BLC', w, h, 'blc.v', vals, exp,
                      [py*2+px] + blacks + [ped])

            gains = [420, 256, 260, 505]       # U4.8: 1.64, 1.0, 1.016, 1.97
            exp = [v for row in wb_frame(cfa, py, px, gains, ped)
                   for v in row]
            ok &= run(os.path.join(PROJ, 'streamline', 'build', 'isp',
                                   f'wb_{w}x{h}_p{ped}'),
                      'WB', w, h, 'wb_gains.v', vals, exp,
                      [py*2+px] + gains + [ped])

    # CCM: pixel-wise; matrix with negative off-diagonals (typical shape).
    n = 600
    trips = rng.integers(0, 4096, (n, 3))
    trips[0] = [4095, 4095, 4095]
    trips[1] = [0, 0, 0]
    trips[2] = [4095, 0, 4095]
    m = [[430, -120, -54], [-90, 410, -64], [-30, -150, 436]]  # S4.8
    stim = [v for t in trips for v in t]
    for ped in PEDS:
        exp = [v for t in trips for v in ccm_px(t, m, ped)]
        params = [0] + [c & 0xFFFF for row in m for c in row] + [ped]
        ok &= run(os.path.join(PROJ, 'streamline', 'build', 'isp', f'ccm_p{ped}'),
                  'CCM', n, 1, 'ccm.v', stim, exp, params)

    print('ALL PASS' if ok else 'SOME FAILED')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
