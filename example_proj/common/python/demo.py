#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
demo.py — mjpegZero board host program (JTAG-to-AXI, 720p)
Supports: Arty S7-50, Arty A7-100T (any board using demo_top + JTAG-to-AXI)

Converts images/video to 1280×720 YUYV, transfers them to the FPGA over the
Xilinx JTAG-to-AXI Master IP (same USB cable used for programming), and
retrieves the compressed JPEG output.

Communication is driven by host.tcl running inside Vivado's hardware manager.
No separate UART cable is required.

Usage:
  # Encode a single image
  python demo.py --bit build/arty_a7_demo.bit --image photo.jpg --out out.jpg

  # Encode 8 images and save all JPEGs
  python demo.py --image img1.jpg img2.jpg ... img8.jpg --out-dir results/

  # Encode 8 frames from a video
  python demo.py --video clip.mp4 --out-dir results/ --max 8

  # Check encoder status without re-programming
  python demo.py --status

  # Reset the demo state machine
  python demo.py --reset

Dependencies:  pip install Pillow numpy tqdm
Optional:      pip install opencv-python   (for --video input)
Requires:      Vivado (vivado executable in PATH or set via --vivado)
"""

import argparse
import os
import platform
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# Locate vivado: prefer PATH, fall back to platform name
import shutil as _shutil
_VIVADO_DEFAULT = _shutil.which("vivado") or ("vivado.bat" if platform.system() == "Windows" else "vivado")

import numpy as np
from PIL import Image

try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False

# Encoder resolution (must match RTL parameters)
IMG_W = 1280
IMG_H = 720
FRAME_BYTES = IMG_W * IMG_H * 2   # 1 843 200 bytes (YUYV 4:2:2)

# Path to host.tcl (same directory as this script)
HOST_TCL = str(Path(__file__).parent / "host.tcl")


# ---------------------------------------------------------------------------
# YUYV conversion
# ---------------------------------------------------------------------------

def rgb_to_yuyv(img_rgb: np.ndarray) -> bytes:
    """Convert a 1280×720 RGB uint8 array to YUYV bytes (1 843 200 bytes).

    YUYV packing per pixel pair (px0=even, px1=odd):
        AXI word [15:0]  = {Cb, Y0}   (even pixel)
        AXI word [31:16] = {Cr, Y1}   (odd pixel)
    → byte stream: Y0, Cb, Y1, Cr, Y2, Cb', Y3, Cr', ...
    """
    h, w = img_rgb.shape[:2]
    assert w == IMG_W and h == IMG_H, \
        f"Image must be {IMG_W}×{IMG_H}, got {w}×{h}"

    r = img_rgb[:, :, 0].astype(np.float32)
    g = img_rgb[:, :, 1].astype(np.float32)
    b = img_rgb[:, :, 2].astype(np.float32)

    # BT.601 full-range RGB → YCbCr
    y  = np.clip( 0.299*r + 0.587*g + 0.114*b,             0, 255).astype(np.uint8)
    cb = np.clip(-0.168736*r - 0.331264*g + 0.5*b   + 128, 0, 255).astype(np.uint8)
    cr = np.clip( 0.5*r - 0.418688*g - 0.081312*b   + 128, 0, 255).astype(np.uint8)

    # Interleave as Y0 Cb Y1 Cr per pixel pair
    y_even  = y[:, 0::2]
    cb_even = cb[:, 0::2]
    y_odd   = y[:, 1::2]
    cr_even = cr[:, 0::2]

    rows = np.stack([y_even, cb_even, y_odd, cr_even], axis=2)  # (H, W//2, 4)
    return rows.flatten().tobytes()


def prepare_image(path: str) -> np.ndarray:
    """Load an image, resize to 1280×720, return RGB uint8 array."""
    return np.array(
        Image.open(path).convert('RGB').resize((IMG_W, IMG_H), Image.LANCZOS)
    )


# ---------------------------------------------------------------------------
# Vivado hardware manager wrapper
# ---------------------------------------------------------------------------

class VivadoHW:
    """Calls Vivado in batch mode to execute host.tcl commands."""

    def __init__(self, vivado_exe: str = "vivado", bitfile: str = None):
        self.vivado = vivado_exe
        self.bitfile = bitfile

    def _run_tcl(self, *args: str):
        """Run host.tcl with given arguments via Vivado batch mode."""
        cmd = [
            self.vivado, "-mode", "batch",
            "-nolog", "-nojournal",
            "-source", HOST_TCL,
            "-tclargs", *args,
        ]
        result = subprocess.run(cmd, capture_output=False, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"Vivado exited with code {result.returncode}")

    def program(self):
        """Program the board with the stored bitfile."""
        if not self.bitfile:
            raise ValueError("No bitfile specified")
        print(f"Programming {self.bitfile}...")
        self._run_tcl("program", self.bitfile)

    def reset(self):
        """Reset the FPGA demo state machine."""
        self._run_tcl("reset")

    def status(self):
        """Print encoder status."""
        self._run_tcl("status")

    def encode_yuyv_file(self, yuyv_path: str, out_path: str):
        """Upload a .yuyv file, encode, save JPEG."""
        self._run_tcl("encode", yuyv_path, out_path)

    def encode8_dir(self, yuyv_dir: str, out_dir: str):
        """Encode all .yuyv files in yuyv_dir, save JPEGs to out_dir."""
        self._run_tcl("encode8", yuyv_dir, out_dir)


# ---------------------------------------------------------------------------
# High-level encode API
# ---------------------------------------------------------------------------

def encode_images(paths: list, out_dir: str, vivado_hw: VivadoHW,
                  program: bool = False):
    """Prepare up to 8 images as YUYV, encode on FPGA, save JPEGs.

    Parameters
    ----------
    paths      : list of input image paths (any format Pillow supports)
    out_dir    : directory for output JPEGs
    vivado_hw  : VivadoHW instance
    program    : if True, program bitfile before encoding
    """
    if len(paths) > 8:
        print(f"Warning: only first 8 of {len(paths)} images will be encoded")
        paths = paths[:8]

    Path(out_dir).mkdir(parents=True, exist_ok=True)

    if program:
        vivado_hw.program()

    # Convert all images to YUYV and save to a temp directory
    with tempfile.TemporaryDirectory(prefix="mjpeg_demo_") as tmpdir:
        yuyv_paths = []
        it = tqdm(paths, desc="Preparing YUYV") if HAS_TQDM else paths
        for p in it:
            stem = Path(p).stem
            yuyv_path = os.path.join(tmpdir, f"{stem}.yuyv")
            rgb = prepare_image(p)
            with open(yuyv_path, 'wb') as f:
                f.write(rgb_to_yuyv(rgb))
            yuyv_paths.append(yuyv_path)

        # Encode via Vivado host.tcl
        print(f"Encoding {len(yuyv_paths)} image(s) on FPGA...")
        vivado_hw.encode8_dir(tmpdir, out_dir)

    print(f"Done. JPEGs saved to {out_dir}/")


def encode_video(video_path: str, out_dir: str, vivado_hw: VivadoHW,
                 max_frames: int = 8, program: bool = False):
    """Extract frames from video, encode on FPGA, save JPEGs.

    Parameters
    ----------
    video_path : input video file
    out_dir    : directory for output JPEGs
    max_frames : max frames to encode (default 8)
    vivado_hw  : VivadoHW instance
    program    : if True, program bitfile before encoding
    """
    try:
        import cv2
    except ImportError:
        print("opencv-python not installed. Install with: pip install opencv-python")
        sys.exit(1)

    Path(out_dir).mkdir(parents=True, exist_ok=True)

    if program:
        vivado_hw.program()

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    with tempfile.TemporaryDirectory(prefix="mjpeg_demo_") as tmpdir:
        n = 0
        total = min(int(cap.get(cv2.CAP_PROP_FRAME_COUNT)), max_frames)
        pbar = tqdm(total=total, desc="Extracting frames") if HAS_TQDM else None

        while cap.isOpened() and n < max_frames:
            ret, frame = cap.read()
            if not ret:
                break
            rgb = cv2.cvtColor(
                cv2.resize(frame, (IMG_W, IMG_H)), cv2.COLOR_BGR2RGB
            )
            yuyv_path = os.path.join(tmpdir, f"frame_{n:04d}.yuyv")
            with open(yuyv_path, 'wb') as f:
                f.write(rgb_to_yuyv(rgb))
            n += 1
            if pbar:
                pbar.update(1)

        cap.release()
        if pbar:
            pbar.close()

        print(f"Extracted {n} frames. Encoding on FPGA...")
        vivado_hw.encode8_dir(tmpdir, out_dir)

    print(f"Done. {n} JPEGs saved to {out_dir}/")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Arty S7-50 mjpegZero demo host (JTAG-to-AXI, 720p)")
    parser.add_argument('--vivado', default=_VIVADO_DEFAULT,
                        help='Path to vivado executable (default: vivado.bat on Windows, vivado elsewhere)')
    parser.add_argument('--bit', metavar='FILE',
                        help='Bitstream to program before encoding')
    parser.add_argument('--program', action='store_true',
                        help='Program --bit before encoding')
    parser.add_argument('--image', nargs='+', metavar='FILE',
                        help='Input image(s), up to 8')
    parser.add_argument('--video', metavar='FILE',
                        help='Input video file')
    parser.add_argument('--out',    metavar='FILE',
                        help='Output JPEG path (single image only)')
    parser.add_argument('--out-dir', metavar='DIR', default='results',
                        help='Output directory for JPEGs (default: results/)')
    parser.add_argument('--max', type=int, default=8,
                        help='Max frames from video (default: 8)')
    parser.add_argument('--status',  action='store_true',
                        help='Print encoder status and exit')
    parser.add_argument('--reset',   action='store_true',
                        help='Reset FPGA demo state and exit')

    args = parser.parse_args()
    hw = VivadoHW(vivado_exe=args.vivado, bitfile=args.bit)

    if args.program and not args.bit:
        parser.error('--program requires --bit')

    if args.status:
        hw.status()
        return

    if args.reset:
        hw.reset()
        return

    if args.image:
        do_program = args.program or bool(args.bit and not args.status)
        if len(args.image) == 1 and args.out:
            # Single image with explicit output path
            out_dir = tempfile.mkdtemp(prefix="mjpeg_single_")
            encode_images(args.image, out_dir, hw, program=args.program)
            # Move the single output to --out
            jpgs = list(Path(out_dir).glob("*.jpg"))
            if jpgs:
                import shutil
                shutil.move(str(jpgs[0]), args.out)
                print(f"Saved: {args.out}")
        else:
            encode_images(args.image, args.out_dir, hw, program=args.program)

    elif args.video:
        encode_video(args.video, args.out_dir, hw,
                     max_frames=args.max, program=args.program)

    else:
        parser.print_help()


if __name__ == '__main__':
    main()
