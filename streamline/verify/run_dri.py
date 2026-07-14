#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# run_dri.py — restart markers through the full encoder
# ============================================================================
# Encodes a 64x16 frame (8 MCUs) with restart intervals of 0, 1, and 3
# through the full streamline encoder and checks, per DRI value:
#
#   structure : the DRI segment declares the interval; the entropy stream
#               contains exactly the T.81 marker count at the T.81 cadence,
#               cycling RST0..RST7
#   losslessness : decoded pixels are BIT-IDENTICAL to the DRI=0 encode of
#               the same frame (restart re-arranges the entropy stream and
#               resets DC prediction; it must not change one pixel)
#   determinism : frame 2 of each run is byte-identical to frame 1 (the
#               restart counter and predictors fully reset per frame)
#
# The same DRI=1 encode is also run on the all-rtl encoder and compared,
# documenting whether the upstream packer's restart-tail defect is
# reachable on this content.
# ============================================================================

import io
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.normpath(os.path.join(HERE, '..', '..'))
ENC = os.path.join(PROJ, 'streamline', 'rtl', 'encoder')
RTL = os.path.join(PROJ, 'rtl')

SHARED = [os.path.join(RTL, m + '.v') for m in
          ('bram_sdp', 'input_buffer', 'jfif_writer', 'axi4_lite_regs',
           'rgb_to_ycbcr', 'mjpegzero_enc_top')]
SL = [os.path.join(ENC, m + '.v') for m in
      ('dct_1d', 'dct_2d', 'quantizer', 'zigzag_reorder',
       'huffman_encoder', 'bitstream_packer')]
RT = [os.path.join(RTL, m + '.v') for m in
      ('dct_1d', 'dct_2d', 'quantizer', 'zigzag_reorder',
       'huffman_encoder', 'bitstream_packer')]

W, H, NF, Q = 64, 16, 2, 90
MCUS = (W // 16) * (H // 8)


def run_sim(build, dri, sources):
    os.makedirs(build, exist_ok=True)
    shutil.copytree(os.path.join(PROJ, 'sim', 'test_vectors'),
                    os.path.join(build, 'test_vectors'), dirs_exist_ok=True)
    with open(os.path.join(build, 'qsched.hex'), 'w') as f:
        f.write(('%02x\n' % Q) * NF)
    defines = [f'-DTB_W={W}', f'-DTB_H={H}', f'-DTB_NF={NF}',
               '-DTV_HEX_FILE="test_vectors/yuyv_64x16.hex"']
    if dri:
        defines.append(f'-DTB_DRI={dri}')
    r = subprocess.run(
        ['iverilog', '-g2012', '-o', os.path.join(build, 'tb.vvp')]
        + defines + SHARED + sources + [os.path.join(HERE, 'tb_qswitch.sv')],
        capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stderr[:400])
        sys.exit('compile failed')
    r = subprocess.run(['vvp', 'tb.vvp'], cwd=build,
                       capture_output=True, text=True)
    if 'DONE' not in r.stdout:
        print(r.stdout[-400:])
        sys.exit(f'sim failed in {build}')
    return [open(os.path.join(build, f'frame_{i}.jpg'), 'rb').read()
            for i in range(NF)]


def scan_markers(data):
    """DRI segment value and ordered RSTn list from the scan section."""
    dri_val = None
    i = data.find(b'\xff\xdd')
    if i >= 0:
        dri_val = (data[i+4] << 8) | data[i+5]
    sos = data.find(b'\xff\xda')
    rst = []
    j = sos
    while j < len(data) - 1:
        if data[j] == 0xFF and 0xD0 <= data[j+1] <= 0xD7:
            rst.append(data[j+1] - 0xD0)
            j += 2
        else:
            j += 1
    return dri_val, rst


def decode(data):
    from PIL import Image
    import numpy as np
    return np.asarray(Image.open(io.BytesIO(data)).convert('RGB'))


def main():
    import numpy as np
    base = os.path.join(PROJ, 'build', 'dri')
    ok = True

    ref = run_sim(os.path.join(base, 'sl_dri0'), 0, SL)
    ref_px = decode(ref[0])

    for dri in (1, 3):
        frames = run_sim(os.path.join(base, f'sl_dri{dri}'), dri, SL)
        dv, rst = scan_markers(frames[0])
        n_exp = (MCUS - 1) // dri
        struct_ok = (dv == dri and len(rst) == n_exp
                     and rst == [k % 8 for k in range(n_exp)])
        px = decode(frames[0])
        lossless = bool((px == ref_px).all())
        det = frames[1] == frames[0]
        ok &= struct_ok and lossless and det
        print(f'DRI={dri}: segment={dv} markers={len(rst)}/{n_exp} '
              f'cycle={"ok" if struct_ok else "BAD"} '
              f'pixels-vs-DRI0={"identical" if lossless else "DIFFER"} '
              f'frame2=={"frame1" if det else "DIFFERENT"} '
              f'({len(frames[0])} B)')

    # rtl comparison at DRI=1: documented, not gated (upstream defect 2)
    sl1 = run_sim(os.path.join(base, 'sl_dri1'), 1, SL)[0]
    rt1 = run_sim(os.path.join(base, 'rt_dri1'), 1, RT)[0]
    if sl1 == rt1:
        print('rtl DRI=1: byte-identical to streamline '
              '(tail-drop not reachable on this content)')
    else:
        try:
            same = bool((decode(rt1) == ref_px).all())
            print(f'rtl DRI=1: DIFFERS from streamline; rtl decode '
                  f'{"matches" if same else "DOES NOT match"} DRI=0 pixels '
                  f'(defect 2 {"not visible" if same else "CONFIRMED end to end"})')
        except Exception as e:
            print(f'rtl DRI=1: DIFFERS and fails to decode: {e} '
                  f'(defect 2 CONFIRMED end to end)')

    print('DRI PASS' if ok else 'DRI FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
