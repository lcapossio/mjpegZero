#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# run_qswitch.py — mid-stream quality change, byte-exact against pure runs
# ============================================================================
# Three simulations of the streamline encoder (runtime-quality mode):
#   pure-A : one frame at quality A
#   pure-B : one frame at quality B
#   mixed  : frames at A, B, A with the quality written between frames and
#            the next frame's pixels starting immediately (tight case)
# Every mixed frame must be byte-identical to the corresponding pure frame:
# the shadow-bank rebuild is then proven glitch-free end to end, in both
# switch directions, under rate-controller timing.
# ============================================================================

import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.normpath(os.path.join(HERE, '..', '..'))
ENC = os.path.join(PROJ, 'streamline', 'rtl', 'encoder')
RTL = os.path.join(PROJ, 'rtl')

SOURCES = [os.path.join(RTL, m + '.v') for m in
           ('bram_sdp', 'input_buffer', 'jfif_writer', 'axi4_lite_regs',
            'rgb_to_ycbcr', 'mjpegzero_enc_top')] + \
          [os.path.join(ENC, m + '.v') for m in
           ('dct_1d', 'dct_2d', 'quantizer', 'zigzag_reorder',
            'huffman_encoder', 'bitstream_packer')]


def run_sim(build, sched, w=64, h=8):
    os.makedirs(build, exist_ok=True)
    shutil.copytree(os.path.join(PROJ, 'sim', 'test_vectors'),
                    os.path.join(build, 'test_vectors'), dirs_exist_ok=True)
    with open(os.path.join(build, 'qsched.hex'), 'w') as f:
        for q in sched:
            f.write('%02x\n' % q)
    r = subprocess.run(
        ['iverilog', '-g2012', '-o', os.path.join(build, 'tb.vvp'),
         f'-DTB_W={w}', f'-DTB_H={h}', f'-DTB_NF={len(sched)}',
         '-DTV_HEX_FILE="test_vectors/yuyv_input.hex"']
        + SOURCES + [os.path.join(HERE, 'tb_qswitch.sv')],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[:500])
        sys.exit('compile failed')
    r = subprocess.run(['vvp', 'tb.vvp'], cwd=build,
                       capture_output=True, text=True)
    if 'DONE' not in r.stdout:
        print(r.stdout[-500:])
        sys.exit(f'sim failed in {build}')
    return [open(os.path.join(build, f'frame_{i}.jpg'), 'rb').read()
            for i in range(len(sched))]


def main():
    qa, qb = 75, 95
    base = os.path.join(PROJ, 'streamline', 'build', 'qswitch')
    pure_a = run_sim(os.path.join(base, 'pure_a'), [qa])[0]
    pure_b = run_sim(os.path.join(base, 'pure_b'), [qb])[0]
    mixed = run_sim(os.path.join(base, 'mixed'), [qa, qb, qa])

    ok = True
    for i, (frame, ref, name) in enumerate([
            (mixed[0], pure_a, f'pure Q{qa}'),
            (mixed[1], pure_b, f'pure Q{qb}'),
            (mixed[2], pure_a, f'pure Q{qa}')]):
        match = frame == ref
        ok &= match
        print(f'mixed frame {i} ({len(frame)} B) vs {name} ({len(ref)} B): '
              f'{"byte-identical" if match else "MISMATCH"}')
        if not match:
            n = min(len(frame), len(ref))
            d = next((k for k in range(n) if frame[k] != ref[k]), n)
            print(f'  first difference at byte {d}')

    print('QSWITCH PASS' if ok else 'QSWITCH FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
