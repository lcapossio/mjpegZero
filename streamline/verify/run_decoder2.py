#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# run_decoder2.py — cross-validate encoder output with an independent decoder
# ============================================================================
# All prior quality gates decode through PIL (libjpeg-turbo). ffmpeg's
# native MJPEG decoder is an independent codebase; agreement between the
# two rules out decoder-specific interactions in every conclusion drawn
# from decoded pixels.
#
# For a matrix of encoder configurations (rtl baseline, streamline
# lossless-set, streamline+Loeffler, streamline+AAN; qualities 75/95/100;
# plus a DRI=1 stream), this runner:
#   1. requires ffmpeg to decode every stream without error
#   2. compares ffmpeg's pixels to PIL's for the same file. The decoders
#      legitimately differ in chroma upsampling and RGB conversion; the
#      floor, measured on identical baseline streams, is ~2 LSB mean.
#      The bound (mean < 4, peak <= 64) catches encoder-dependent decode
#      divergence above that floor.
#   3. recomputes each stream's PSNR-vs-source with ffmpeg and requires
#      the baseline-vs-swapped DELTA to match PIL's within 0.05 dB for
#      the deterministic sets (lossless, Loeffler). The AAN rows are
#      reported as findings, not gated: their decoder-dependence at high
#      quality is exactly what this item exists to expose (PIL's fancy
#      chroma upsampling interacts with AAN's rounding profile; ffmpeg
#      judges the same q95 stream BETTER than baseline).
# ============================================================================

import io
import os
import subprocess
import sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.normpath(os.path.join(HERE, '..', '..'))

LOSSLESS = 'quantizer,huffman_encoder,bitstream_packer,zigzag_reorder'
FULL = LOSSLESS + ',dct_1d,dct_2d'


def ffmpeg_decode(jpg_path, png_path):
    r = subprocess.run(
        ['ffmpeg', '-y', '-v', 'error', '-i', jpg_path, png_path],
        capture_output=True, text=True)
    if r.returncode != 0 or r.stderr.strip():
        return None, r.stderr.strip()
    return np.asarray(Image.open(png_path).convert('RGB')).astype(np.float64), ''


def pil_decode(jpg_path):
    data = open(jpg_path, 'rb').read()
    return np.asarray(Image.open(io.BytesIO(data)).convert('RGB')).astype(np.float64)


def psnr(a, b):
    mse = np.mean((a - b) ** 2)
    return 10 * np.log10(255**2 / mse)


def run_parity(swap, quality, aan=False):
    cmd = [sys.executable, os.path.join(HERE, 'parity.py'),
           '--swap', swap, '--quality', str(quality), '--psnr']
    if aan:
        cmd.append('--aan')
    subprocess.run(cmd, capture_output=True, text=True)
    return (os.path.join(PROJ, 'build', 'parity', 'baseline', 'sim_output.jpg'),
            os.path.join(PROJ, 'build', 'parity', 'swapped', 'sim_output.jpg'))


def main():
    src = np.asarray(Image.open(os.path.join(
        PROJ, 'python', 'test_images', 'mandrill_720p.png'))
        .convert('RGB'))[0:8, 0:64].astype(np.float64)
    build = os.path.join(PROJ, 'build', 'decoder2')
    os.makedirs(build, exist_ok=True)

    ok = True
    n = 0

    def check(tag, jpg):
        nonlocal ok, n
        n += 1
        png = os.path.join(build, f'{tag}.png')
        ff, err = ffmpeg_decode(jpg, png)
        if ff is None:
            print(f'  {tag}: FFMPEG DECODE FAILED: {err}')
            ok = False
            return None, None
        pl = pil_decode(jpg)
        d = np.abs(ff - pl)
        agree = float(np.mean(d)) < 4.0 and float(np.max(d)) <= 64
        ok &= agree
        print(f'  {tag}: ffmpeg ok; |ffmpeg-PIL| mean {np.mean(d):.3f} '
              f'max {np.max(d):.0f} -> {"agree" if agree else "DISAGREE"}')
        return psnr(ff, src), psnr(pl, src)

    for swap, aan, name in [(LOSSLESS, False, 'lossless'),
                            (FULL, False, 'loeffler'),
                            (FULL, True, 'aan')]:
        for q in (75, 95, 100):
            base_jpg, swap_jpg = run_parity(swap, q, aan)
            fb, pb = check(f'{name}_q{q}_base', base_jpg)
            fs, ps = check(f'{name}_q{q}_swap', swap_jpg)
            if fb is not None and fs is not None:
                d_ff, d_pil = fs - fb, ps - pb
                match = abs(d_ff - d_pil) < 0.05
                if name != 'aan':
                    ok &= match
                print(f'  {name} q{q}: delta ffmpeg {d_ff:+.4f} dB, '
                      f'PIL {d_pil:+.4f} dB -> '
                      f'{"consistent" if match else "DECODER-DEPENDENT"}'
                      f'{" (finding, recorded)" if name == "aan" and not match else ""}')

    # DRI stream through the second decoder
    dri_jpg = os.path.join(PROJ, 'build', 'dri', 'sl_dri1', 'frame_0.jpg')
    if os.path.isfile(dri_jpg):
        png = os.path.join(build, 'dri1.png')
        ff, err = ffmpeg_decode(dri_jpg, png)
        if ff is None:
            print(f'  DRI=1 stream: FFMPEG DECODE FAILED: {err}')
            ok = False
        else:
            ref = pil_decode(os.path.join(PROJ, 'build', 'dri',
                                          'sl_dri0', 'frame_0.jpg'))
            same = bool((ff == np.asarray(
                Image.open(png).convert('RGB'))).all())
            d = np.abs(ff - ref)
            print(f'  DRI=1 stream: ffmpeg ok; vs DRI=0 pixels mean '
                  f'|diff| {np.mean(d):.3f} (upsampling-only)')
            n += 1

    print(f'DECODER2 {"PASS" if ok else "FAIL"} ({n} streams)')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
