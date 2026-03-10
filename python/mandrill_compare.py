# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Generate a 512x512 mandrill (baboon) test image, encode it with the reference
JPEG encoder, decode it back, and produce a side-by-side comparison PNG:

  [ Original ]  |  [ JPEG decoded ]  |  [ Difference ×8 ]

Usage:
    python python/mandrill_compare.py [--quality Q] [--out comparison.png]
"""

import os
import sys
import io
import argparse
import urllib.request

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jpeg_encoder import encode_jpeg


# ---------------------------------------------------------------------------
# Image acquisition
# ---------------------------------------------------------------------------

def get_test_image(size=512):
    """Return a 512×512 RGB numpy array (uint8).
    Tries standard mandrill/baboon sources; falls back to synthetic."""
    try:
        from PIL import Image
    except ImportError:
        print("ERROR: Pillow required.  pip install Pillow")
        sys.exit(1)

    urls = [
        "https://sipi.usc.edu/database/download.php?vol=misc&img=4.2.03",
        "https://upload.wikimedia.org/wikipedia/commons/a/ab/Mandrill2.jpg",
    ]

    img = None
    for url in urls:
        try:
            print(f"  Downloading from {url} …")
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            data = urllib.request.urlopen(req, timeout=20).read()
            img = Image.open(io.BytesIO(data)).convert('RGB')
            print(f"  Got {img.size[0]}×{img.size[1]} image")
            break
        except Exception as e:
            print(f"  Failed: {e}")

    if img is None:
        print("  Using synthetic test image")
        img = _synthetic(size)

    img = img.resize((size, size), Image.LANCZOS)
    return np.array(img, dtype=np.uint8)


def _synthetic(size):
    """Colourful synthetic image: gradients + checker."""
    from PIL import Image
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            r = int(127 + 127 * np.sin(x / 25.0))
            g = int(127 + 127 * np.sin(y / 20.0))
            b = int(127 + 127 * np.sin((x + y) / 35.0))
            checker = ((x // 32) + (y // 32)) % 2
            if checker:
                r, g, b = (r + 80) % 256, g, (b + 40) % 256
            px[x, y] = (r, g, b)
    return img


# ---------------------------------------------------------------------------
# PSNR
# ---------------------------------------------------------------------------

def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return float('inf') if mse == 0 else 10.0 * np.log10(255.0 ** 2 / mse)


# ---------------------------------------------------------------------------
# Side-by-side comparison image
# ---------------------------------------------------------------------------

def make_comparison(original, decoded, diff_scale=8, label_height=24):
    """
    Build a wide comparison image:
        | Original | JPEG decoded | Difference ×diff_scale |

    Labels are drawn above each panel.
    Returns a PIL Image.
    """
    from PIL import Image, ImageDraw, ImageFont

    h, w = original.shape[:2]
    gap = 4  # pixels between panels
    total_w = w * 3 + gap * 2
    total_h = h + label_height

    canvas = Image.new('RGB', (total_w, total_h), (30, 30, 30))

    # Panels
    canvas.paste(Image.fromarray(original), (0, label_height))
    canvas.paste(Image.fromarray(decoded),  (w + gap, label_height))

    # Difference (amplified, clipped to [0,255])
    diff = np.clip(
        np.abs(original.astype(np.int16) - decoded.astype(np.int16)) * diff_scale,
        0, 255
    ).astype(np.uint8)
    canvas.paste(Image.fromarray(diff), (2 * (w + gap), label_height))

    # Labels
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 14)
    except Exception:
        font = ImageFont.load_default()

    ps = psnr(original, decoded)
    labels = [
        f"Original ({w}×{h})",
        f"JPEG decoded  PSNR={ps:.2f} dB",
        f"Difference ×{diff_scale}",
    ]
    for i, lbl in enumerate(labels):
        x = i * (w + gap) + 4
        draw.text((x, 4), lbl, fill=(220, 220, 100), font=font)

    return canvas


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="Mandrill encode/decode comparison")
    ap.add_argument('--quality', type=int, default=95,
                    help='JPEG quality 1-100 (default 95)')
    ap.add_argument('--size', type=int, default=512,
                    help='Image size (square, default 512)')
    ap.add_argument('--diff-scale', type=int, default=8,
                    help='Difference amplification (default 8)')
    ap.add_argument('--out', default=None,
                    help='Output PNG path (default: python/test_images/mandrill_compare_Q<Q>.png)')
    args = ap.parse_args()

    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_images')
    os.makedirs(out_dir, exist_ok=True)

    if args.out is None:
        args.out = os.path.join(out_dir, f'mandrill_compare_Q{args.quality}.png')

    print("=" * 60)
    print(f"Mandrill comparison  Q={args.quality}  size={args.size}×{args.size}")
    print("=" * 60)

    # 1. Get image
    print("\n[1] Acquiring test image …")
    original = get_test_image(args.size)
    print(f"    Shape: {original.shape}")

    # 2. Encode
    print(f"\n[2] Encoding with Python JPEG encoder (Q={args.quality}) …")
    encoded_path = os.path.join(out_dir, f'mandrill_Q{args.quality}.jpg')
    jpeg_bytes = encode_jpeg(original, quality=args.quality, output_path=encoded_path)
    ratio = (args.size * args.size * 3) / len(jpeg_bytes)
    print(f"    Encoded size: {len(jpeg_bytes):,} bytes  ({ratio:.1f}:1 compression)")

    # 3. Decode
    print("\n[3] Decoding …")
    try:
        from PIL import Image
        decoded_img = Image.open(encoded_path).convert('RGB')
        decoded = np.array(decoded_img, dtype=np.uint8)
        print(f"    Decoded shape: {decoded.shape}")
    except Exception as e:
        print(f"ERROR: decode failed: {e}")
        return 1

    # 4. PSNR
    h = min(original.shape[0], decoded.shape[0])
    w = min(original.shape[1], decoded.shape[1])
    ps = psnr(original[:h, :w], decoded[:h, :w])
    print(f"\n[4] PSNR: {ps:.2f} dB")

    # 5. Comparison image
    print(f"\n[5] Building comparison image …")
    comparison = make_comparison(original[:h, :w], decoded[:h, :w], args.diff_scale)
    comparison.save(args.out)
    print(f"    Saved: {args.out}  ({comparison.width}×{comparison.height} px)")

    print("\n" + "=" * 60)
    if ps >= 35.0:
        print(f"PASS  PSNR={ps:.2f} dB (≥35 dB)")
    elif ps >= 30.0:
        print(f"WARNING  PSNR={ps:.2f} dB (30–35 dB acceptable)")
    else:
        print(f"FAIL  PSNR={ps:.2f} dB (<30 dB)")
    print("=" * 60)
    return 0 if ps >= 30.0 else 1


if __name__ == '__main__':
    sys.exit(main())
