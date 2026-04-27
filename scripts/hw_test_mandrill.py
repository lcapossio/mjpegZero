#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
hw_test_mandrill.py — End-to-end hardware verification with mandrill 720p

1. Convert mandrill_720p.png → mandrill_720p.yuyv (binary)
2. Run RTL sim:  python scripts/run_sim.py lite 720p quality=75
3. Run HW encode through the fcapz host stack
4. Compare: HW JPEG vs RTL sim JPEG vs original PNG

Usage:
    python scripts/hw_test_mandrill.py [--skip-sim] [--skip-hw] [--bit build/arty_a7_demo.bit]
"""

import os, sys, subprocess, argparse
import numpy as np
from PIL import Image

REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), '..'))

# Import shared YUYV conversion (guarantees bit-exact input for sim and HW)
sys.path.insert(0, os.path.join(REPO, 'python'))
sys.path.insert(0, os.path.join(REPO, 'example_proj', 'common', 'python'))
from yuyv_convert import png_to_yuyv
from demo import FcapzHW, _default_fpga_for_bitfile
PYTHON = sys.executable


def run_rtl_sim():
    """Run RTL simulation: lite 720p quality=75."""
    print("\n" + "="*70)
    print("RTL SIMULATION: lite 720p quality=75")
    print("="*70)
    cmd = [sys.executable, os.path.join(REPO, 'scripts', 'run_sim.py'), 'lite', '720p', 'quality=75']
    r = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=600)
    # Print last 20 lines
    lines = (r.stdout + r.stderr).strip().split('\n')
    for line in lines[-20:]:
        print(f"  {line}")
    sim_jpg = os.path.join(REPO, 'build', 'sim', 'sim_output.jpg')
    if os.path.isfile(sim_jpg):
        sz = os.path.getsize(sim_jpg)
        print(f"  RTL sim JPEG: {sim_jpg} ({sz} bytes)")
        return sim_jpg
    else:
        print("  WARNING: sim_output.jpg not found")
        return None


def run_hw_encode(yuyv_path, jpg_path, args):
    """Encode on hardware through the fcapz bridge."""
    print("\n" + "="*70)
    print("HARDWARE ENCODE: fcapz")
    print("="*70)
    fpga = args.fpga or _default_fpga_for_bitfile(args.bit)
    with FcapzHW(fpga_name=fpga, bitfile=args.bit,
                 host=args.hw_host, port=args.hw_port,
                 jpeg_max_bytes=args.jpeg_max_bytes) as hw:
        if args.program:
            hw.program()
        nbytes = hw.encode_yuyv_file(yuyv_path, jpg_path)
        print(f"  HW JPEG: {jpg_path} ({nbytes} bytes)")

    if os.path.isfile(jpg_path):
        return jpg_path

    print("  WARNING: HW JPEG not found")
    return None


def psnr_y(img_a, img_b):
    """Y-channel PSNR between two RGB images (as numpy arrays)."""
    # Convert to YCbCr, extract Y
    def to_y(rgb):
        return 0.299*rgb[:,:,0] + 0.587*rgb[:,:,1] + 0.114*rgb[:,:,2]
    ya = to_y(img_a.astype(np.float64))
    yb = to_y(img_b.astype(np.float64))
    h = min(ya.shape[0], yb.shape[0])
    w = min(ya.shape[1], yb.shape[1])
    mse = np.mean((ya[:h,:w] - yb[:h,:w])**2)
    if mse == 0:
        return float('inf'), 0.0, 0
    return 10*np.log10(255**2/mse), mse, int(np.max(np.abs(ya[:h,:w]-yb[:h,:w])))


def make_comparison(original, hw_decoded, sim_decoded, out_path, diff_scale=8):
    """Build 4-panel comparison: Original | HW | Sim | Diff(HW-Sim)."""
    h, w = original.shape[:2]
    gap = 4
    lh = 28  # label height

    panels = [original]
    labels = [f"Original {w}x{h}"]

    if hw_decoded is not None:
        panels.append(hw_decoded)
        p, _, _ = psnr_y(original, hw_decoded)
        labels.append(f"HW encode  PSNR={p:.2f} dB")
    if sim_decoded is not None:
        panels.append(sim_decoded)
        p, _, _ = psnr_y(original, sim_decoded)
        labels.append(f"RTL sim  PSNR={p:.2f} dB")
    if hw_decoded is not None and sim_decoded is not None:
        if hw_decoded.shape == sim_decoded.shape:
            diff = np.clip(
                np.abs(hw_decoded.astype(np.int16) - sim_decoded.astype(np.int16)) * diff_scale,
                0, 255).astype(np.uint8)
            panels.append(diff)
            p, _, mx = psnr_y(hw_decoded, sim_decoded)
            labels.append(f"HW-Sim diff x{diff_scale}  PSNR={p:.2f}")
        else:
            print(f"  WARNING: HW {hw_decoded.shape} vs Sim {sim_decoded.shape} — skipping diff panel")

    n = len(panels)
    total_w = n * w + (n-1) * gap
    total_h = h + lh
    canvas = Image.new('RGB', (total_w, total_h), (30, 30, 30))

    from PIL import ImageDraw, ImageFont
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 14)
    except Exception:
        font = ImageFont.load_default()

    for i, (panel, label) in enumerate(zip(panels, labels)):
        x = i * (w + gap)
        canvas.paste(Image.fromarray(panel), (x, lh))
        draw.text((x + 4, 4), label, fill=(220, 220, 100), font=font)

    canvas.save(out_path)
    print(f"  Comparison saved: {out_path} ({canvas.width}x{canvas.height})")
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--skip-sim', action='store_true', help='Skip RTL simulation')
    ap.add_argument('--skip-hw', action='store_true', help='Skip hardware encode')
    ap.add_argument('--bit', metavar='FILE', help='Bitstream to program when --program is set')
    ap.add_argument('--program', action='store_true', help='Program --bit before hardware encode')
    ap.add_argument('--fpga', default=None, help='FPGA name for hw_server (e.g. xc7a100t, xc7s50)')
    ap.add_argument('--hw-host', default='127.0.0.1', help='hw_server host (default: 127.0.0.1)')
    ap.add_argument('--hw-port', type=int, default=3121, help='hw_server port (default: 3121)')
    ap.add_argument('--jpeg-max-bytes', type=int, default=None,
                    help='Override JPEG output buffer capacity for old bitstreams')
    args = ap.parse_args()

    if args.program and not args.bit:
        ap.error('--program requires --bit')

    png_path  = os.path.join(REPO, 'python', 'test_images', 'mandrill_720p.png')
    yuyv_path = os.path.join(REPO, 'mandrill_720p.yuyv')
    sim_hex   = os.path.join(REPO, 'sim', 'test_vectors', 'yuyv_720p.hex')
    hw_jpg    = os.path.join(REPO, 'hw_mandrill.jpg')
    sim_jpg   = os.path.join(REPO, 'build', 'sim', 'sim_output.jpg')
    cmp_png   = os.path.join(REPO, 'hw_test_comparison.png')

    # 1. Load original
    print("="*70)
    print("MANDRILL 720p END-TO-END HARDWARE VERIFICATION")
    print("="*70)
    original = np.array(Image.open(png_path).convert('RGB'))
    print(f"  Original: {png_path} ({original.shape[1]}x{original.shape[0]})")

    # 2. Convert to YUYV (single shared conversion for both sim and HW)
    print("\n[1] Converting PNG -> YUYV (shared conversion)...")
    os.makedirs(os.path.dirname(sim_hex), exist_ok=True)
    png_to_yuyv(png_path, bin_path=yuyv_path, hex_path=sim_hex)

    # 3. RTL sim
    sim_decoded = None
    if not args.skip_sim:
        sim_result = run_rtl_sim()
        if sim_result and os.path.isfile(sim_result):
            sim_decoded = np.array(Image.open(sim_result).convert('RGB'))
    elif os.path.isfile(sim_jpg):
        print(f"\n  Using existing RTL sim JPEG: {sim_jpg}")
        sim_decoded = np.array(Image.open(sim_jpg).convert('RGB'))

    # 4. HW encode
    hw_decoded = None
    if not args.skip_hw:
        hw_result = run_hw_encode(yuyv_path, hw_jpg, args)
        if hw_result and os.path.isfile(hw_result):
            hw_decoded = np.array(Image.open(hw_result).convert('RGB'))
    elif os.path.isfile(hw_jpg):
        print(f"\n  Using existing HW JPEG: {hw_jpg}")
        hw_decoded = np.array(Image.open(hw_jpg).convert('RGB'))

    # 5. PSNR comparison
    print("\n" + "="*70)
    print("RESULTS")
    print("="*70)

    if hw_decoded is not None:
        p, mse, mx = psnr_y(original, hw_decoded)
        sz = os.path.getsize(hw_jpg)
        print(f"  HW  vs Original:  Y-PSNR={p:.2f} dB  MSE={mse:.2f}  MaxErr={mx}  ({sz} bytes)")

    if sim_decoded is not None:
        if original.shape[:2] == sim_decoded.shape[:2]:
            p, mse, mx = psnr_y(original, sim_decoded)
            sz = os.path.getsize(sim_jpg)
            print(f"  Sim vs Original:  Y-PSNR={p:.2f} dB  MSE={mse:.2f}  MaxErr={mx}  ({sz} bytes)")
        else:
            sz = os.path.getsize(sim_jpg)
            print(f"  Sim vs Original:  SKIPPED (resolution mismatch: sim={sim_decoded.shape[1]}x{sim_decoded.shape[0]})  ({sz} bytes)")

    if hw_decoded is not None and sim_decoded is not None:
        if hw_decoded.shape == sim_decoded.shape:
            p, mse, mx = psnr_y(hw_decoded, sim_decoded)
            print(f"  HW  vs Sim:       Y-PSNR={p:.2f} dB  MSE={mse:.2f}  MaxErr={mx}")

            # Byte-level comparison of JPEG files
            hw_bytes  = open(hw_jpg, 'rb').read()
            sim_bytes = open(sim_jpg, 'rb').read()
            if hw_bytes == sim_bytes:
                print(f"  JPEG files: IDENTICAL ({len(hw_bytes)} bytes)")
            else:
                print(f"  JPEG files: DIFFER (HW={len(hw_bytes)} bytes, Sim={len(sim_bytes)} bytes)")
        else:
            print(f"  HW  vs Sim:       SKIPPED (resolution mismatch: HW={hw_decoded.shape[1]}x{hw_decoded.shape[0]}, Sim={sim_decoded.shape[1]}x{sim_decoded.shape[0]})")

    # 6. Comparison image
    print()
    make_comparison(original, hw_decoded, sim_decoded, cmp_png)

    # 7. Pass/fail
    print()
    ok = True
    if hw_decoded is not None:
        p, _, _ = psnr_y(original, hw_decoded)
        if p < 30:
            print(f"FAIL: HW PSNR {p:.2f} dB < 30 dB")
            ok = False
    if sim_decoded is not None:
        p, _, _ = psnr_y(original, sim_decoded)
        if p < 30:
            print(f"FAIL: Sim PSNR {p:.2f} dB < 30 dB")
            ok = False
    if ok:
        print("PASS: All PSNR checks passed")

    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
