# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Test the JPEG encoder:
1. Download mandrill test image (or use local)
2. Encode with our encoder
3. Decode with FFmpeg
4. Compute PSNR
5. Visual comparison
"""

import os
import sys
import subprocess
import urllib.request
import numpy as np

# Add parent dir to path so we can import our modules
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from jpeg_encoder import encode_jpeg


def download_test_image(output_path):
    """Download the standard mandrill/baboon test image and resize to 720p."""
    try:
        from PIL import Image
        import io
    except ImportError:
        print("ERROR: Pillow is required. Install with: pip install Pillow")
        sys.exit(1)

    # Try multiple sources for mandrill/baboon
    urls = [
        # USC SIPI standard test images
        "https://sipi.usc.edu/database/download.php?vol=misc&img=4.2.03",
        # Alternative: direct baboon from common test image repos
        "https://upload.wikimedia.org/wikipedia/commons/a/ab/Mandrill2.jpg",
    ]

    img = None
    for url in urls:
        try:
            print(f"Trying to download from: {url}")
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            response = urllib.request.urlopen(req, timeout=30)
            data = response.read()
            img = Image.open(io.BytesIO(data))
            print(f"  Downloaded: {img.size[0]}x{img.size[1]}")
            break
        except Exception as e:
            print(f"  Failed: {e}")
            continue

    if img is None:
        print("Could not download mandrill. Creating a rich synthetic test image instead.")
        img = _create_synthetic_test_image()

    # Convert to RGB if needed
    img = img.convert('RGB')

    # Resize to 1280x720
    img = img.resize((1280, 720), Image.LANCZOS)
    img.save(output_path)
    print(f"Test image saved to {output_path} ({img.size[0]}x{img.size[1]})")
    return img


def _create_synthetic_test_image():
    """Create a rich synthetic 1280x720 test image with gradients and patterns."""
    from PIL import Image, ImageDraw
    img = Image.new('RGB', (1280, 720))
    pixels = img.load()
    for y in range(720):
        for x in range(1280):
            r = int(127 + 127 * np.sin(x / 40.0))
            g = int(127 + 127 * np.sin(y / 30.0))
            b = int(127 + 127 * np.sin((x + y) / 50.0))
            pixels[x, y] = (r, g, b)
    return img


def compute_psnr(img1, img2):
    """Compute PSNR between two images (numpy arrays)."""
    mse = np.mean((img1.astype(np.float64) - img2.astype(np.float64)) ** 2)
    if mse == 0:
        return float('inf')
    return 10.0 * np.log10(255.0 ** 2 / mse)


def decode_with_ffmpeg(input_path, output_path):
    """Decode JPEG using FFmpeg."""
    cmd = [
        'ffmpeg', '-y', '-i', input_path, output_path
    ]
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"FFmpeg STDERR:\n{result.stderr}")
        return False
    return True


def decode_with_pillow(input_path):
    """Decode JPEG using Pillow as backup."""
    from PIL import Image
    img = Image.open(input_path)
    return np.array(img.convert('RGB'))


def main():
    from PIL import Image

    test_img_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_images')
    os.makedirs(test_img_dir, exist_ok=True)

    original_path = os.path.join(test_img_dir, 'mandrill_720p.png')
    encoded_path = os.path.join(test_img_dir, 'encoded_output.jpg')
    decoded_ffmpeg_path = os.path.join(test_img_dir, 'decoded_ffmpeg.png')
    decoded_pillow_path = os.path.join(test_img_dir, 'decoded_pillow.png')

    # Step 1: Get test image
    print("=" * 60)
    print("STEP 1: Download / prepare test image")
    print("=" * 60)
    if not os.path.exists(original_path):
        pil_img = download_test_image(original_path)
    else:
        print(f"Using existing test image: {original_path}")
        pil_img = Image.open(original_path)

    img_rgb = np.array(pil_img.convert('RGB'))
    print(f"Image shape: {img_rgb.shape}, dtype: {img_rgb.dtype}")

    # Step 2: Encode with our encoder
    print("\n" + "=" * 60)
    print("STEP 2: Encode with our JPEG encoder")
    print("=" * 60)
    quality = 95
    print(f"Quality: {quality}")
    jpeg_bytes = encode_jpeg(img_rgb, quality=quality, output_path=encoded_path)
    file_size_kb = len(jpeg_bytes) / 1024
    print(f"Output size: {file_size_kb:.1f} KB")
    compression_ratio = (img_rgb.shape[0] * img_rgb.shape[1] * 3) / len(jpeg_bytes)
    print(f"Compression ratio: {compression_ratio:.1f}:1")

    # Step 3: Decode with FFmpeg
    print("\n" + "=" * 60)
    print("STEP 3: Decode with FFmpeg")
    print("=" * 60)
    ffmpeg_ok = decode_with_ffmpeg(encoded_path, decoded_ffmpeg_path)

    if ffmpeg_ok and os.path.exists(decoded_ffmpeg_path):
        decoded_img = np.array(Image.open(decoded_ffmpeg_path).convert('RGB'))
        print(f"FFmpeg decoded image shape: {decoded_img.shape}")
    else:
        print("FFmpeg decoding failed. Trying Pillow...")
        decoded_img = decode_with_pillow(encoded_path)
        Image.fromarray(decoded_img).save(decoded_pillow_path)
        print(f"Pillow decoded image shape: {decoded_img.shape}")

    # Step 4: Compute PSNR
    print("\n" + "=" * 60)
    print("STEP 4: Compute PSNR")
    print("=" * 60)
    # Ensure same size for comparison
    h = min(img_rgb.shape[0], decoded_img.shape[0])
    w = min(img_rgb.shape[1], decoded_img.shape[1])
    psnr = compute_psnr(img_rgb[:h, :w, :], decoded_img[:h, :w, :])
    print(f"PSNR: {psnr:.2f} dB")

    if psnr >= 35.0:
        print("PASS: PSNR >= 35 dB")
    elif psnr >= 30.0:
        print("WARNING: PSNR is between 30-35 dB (acceptable but could be better)")
    else:
        print("FAIL: PSNR < 30 dB - quality too low")

    # Step 5: Also decode with Pillow for cross-validation
    print("\n" + "=" * 60)
    print("STEP 5: Cross-validate with Pillow decoder")
    print("=" * 60)
    try:
        pillow_decoded = decode_with_pillow(encoded_path)
        psnr_pillow = compute_psnr(img_rgb[:h, :w, :], pillow_decoded[:h, :w, :])
        print(f"PSNR (Pillow decode): {psnr_pillow:.2f} dB")
        Image.fromarray(pillow_decoded).save(decoded_pillow_path)
    except Exception as e:
        print(f"Pillow decode failed: {e}")

    # Summary
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Original:     {original_path}")
    print(f"  Encoded:      {encoded_path} ({file_size_kb:.1f} KB)")
    print(f"  Compression:  {compression_ratio:.1f}:1")
    print(f"  PSNR:         {psnr:.2f} dB")
    print(f"  FFmpeg OK:    {ffmpeg_ok}")
    result = "PASS" if psnr >= 30.0 and ffmpeg_ok else "FAIL"
    print(f"  Result:       {result}")

    return 0 if result == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
