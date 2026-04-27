#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
demo.py — mjpegZero board host program (fpgacapZero JTAG-to-AXI, 720p)
Supports: Arty S7-50, Arty A7-100T (any board using demo_top + fcapz_ejtagaxi)

Converts images/video to 1280×720 YUYV, transfers them to the FPGA over the
fpgacapZero JTAG-to-AXI bridge on USER4 (same USB cable used for programming),
and retrieves the compressed JPEG output.

Drives the FPGA directly from Python via the fcapz host library — no Vivado
Tcl console required. Requires:
  - Vivado's hw_server running (e.g. `hw_server` on 127.0.0.1:3121)
  - xsdb on PATH (ships with Vivado)
  - The fcapz package on PYTHONPATH (provided by the fcapz/ git submodule)

Usage:
  # Encode a single image (program bitstream on connect)
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
"""

import argparse
import os
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

try:
    from tqdm import tqdm
    HAS_TQDM = True
except ImportError:
    HAS_TQDM = False

# ---------------------------------------------------------------------------
# Locate the fcapz host library (ships as a git submodule at <repo>/fcapz)
# ---------------------------------------------------------------------------
_REPO_ROOT = Path(__file__).resolve().parents[3]
_FCAPZ_HOST = _REPO_ROOT / "fcapz" / "host"
if _FCAPZ_HOST.is_dir() and str(_FCAPZ_HOST) not in sys.path:
    sys.path.insert(0, str(_FCAPZ_HOST))
_PYTHON_DIR = _REPO_ROOT / "python"
if _PYTHON_DIR.is_dir() and str(_PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(_PYTHON_DIR))

from fcapz.transport import XilinxHwServerTransport
from fcapz.ejtagaxi import EjtagAxiController
from yuyv_convert import rgb_array_to_yuyv_words

# Encoder resolution (must match RTL parameters)
IMG_W = 1280
IMG_H = 720
FRAME_BYTES = IMG_W * IMG_H * 2           # 1 843 200 bytes (YUYV 4:2:2)
FRAME_WORDS = FRAME_BYTES // 4            # 460 800 32-bit words

# AXI address map (must match demo_top.v)
AXI_PIXEL = 0x00000000
AXI_CTRL  = 0x02000000
AXI_SIZE  = 0x02000004
AXI_CAP   = 0x02000008
AXI_JPEG  = 0x03000000

DEFAULT_JPEG_MAX_BYTES = 256 * 1024       # fallback when old bitstreams lack AXI_CAP
BURST_WORDS    = 256                      # AXI4 max burst — must fit bridge FIFO_DEPTH

STATUS_DONE     = 1 << 0
STATUS_OVERFLOW = 1 << 1
STATUS_AXI_ERR  = 1 << 2
STATUS_RUNNING  = 1 << 3
STATUS_ARMED    = 1 << 4


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

    words, _, _ = rgb_array_to_yuyv_words(img_rgb)
    return np.array(words, dtype='<u2').tobytes()


def prepare_image(path: str) -> np.ndarray:
    """Load an image, resize to 1280×720, return RGB uint8 array."""
    return np.array(
        Image.open(path).convert('RGB').resize((IMG_W, IMG_H), Image.LANCZOS)
    )


def _yuyv_to_words(yuyv: bytes) -> list[int]:
    """Pack YUYV byte stream into 32-bit little-endian words for AXI writes."""
    if len(yuyv) != FRAME_BYTES:
        raise ValueError(f"YUYV must be {FRAME_BYTES} bytes, got {len(yuyv)}")
    arr = np.frombuffer(yuyv, dtype=np.uint8).view(np.uint32)
    return arr.tolist()


def _trim_to_eoi(buf: bytearray) -> bytes:
    """Trim buffer at the JPEG EOI marker (0xFFD9) if found."""
    idx = buf.rfind(b"\xff\xd9")
    if idx >= 0:
        return bytes(buf[:idx + 2])
    return bytes(buf)


# ---------------------------------------------------------------------------
# fcapz-backed hardware wrapper
# ---------------------------------------------------------------------------

def _default_jpeg_max_for_target(fpga_name: str | None, bitfile: str | None) -> int:
    name = f"{fpga_name or ''} {bitfile or ''}".lower()
    if "xc7s50" in name or "s7_50" in name or "spartan" in name:
        return 64 * 1024
    return DEFAULT_JPEG_MAX_BYTES


class FcapzHW:
    """Drive demo_top over the fpgacapZero JTAG-to-AXI bridge.

    Holds a persistent hw_server/xsdb session through XilinxHwServerTransport
    and layers EjtagAxiController on top for AXI reads/writes.
    """

    def __init__(self, fpga_name: str = "xc7a100t", bitfile: str = None,
                 host: str = "127.0.0.1", port: int = 3121,
                 jpeg_max_bytes: int | None = None):
        self.fpga_name = fpga_name
        self.bitfile = bitfile
        self.host = host
        self.port = port
        self.jpeg_max_bytes = jpeg_max_bytes or _default_jpeg_max_for_target(fpga_name, bitfile)
        self._transport = None
        self._axi = None

    # -- connection lifecycle -------------------------------------------------

    def _connect(self, program: bool = False):
        if self._axi is not None:
            return
        bitfile = self.bitfile if program else None
        if program and not bitfile:
            raise ValueError("program=True requires a bitfile")
        self._transport = XilinxHwServerTransport(
            host=self.host, port=self.port,
            fpga_name=self.fpga_name,
            bitfile=bitfile,
            # ready_probe_addr=0 reads ELA id register on USER1 — confirms the
            # fcapz stack is alive before we trust AXI traffic on USER4.
            ready_probe_addr=0x0000,
        )
        self._transport.connect()
        self._axi = EjtagAxiController(self._transport, chain=4)
        self._axi.connect()

    def close(self):
        if self._axi is not None:
            try:
                self._axi.close()
            finally:
                self._axi = None
        if self._transport is not None:
            try:
                self._transport.close()
            finally:
                self._transport = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    # -- high-level ops -------------------------------------------------------

    def program(self):
        if not self.bitfile:
            raise ValueError("No bitfile specified")
        print(f"Programming {self.bitfile}...")
        # Opening a fresh transport with bitfile= triggers FPGA programming.
        self.close()
        self._connect(program=True)

    def reset(self):
        self._connect()
        self._axi.axi_write(AXI_CTRL, 0x2)   # bit1 = reset
        print("Reset pulse sent.")

    def capacity(self) -> int:
        """Read JPEG buffer capacity from RTL, with a fallback for old bitstreams."""
        self._connect()
        try:
            cap = self._axi.axi_read(AXI_CAP)
        except Exception:
            cap = 0
        if 0 < cap <= DEFAULT_JPEG_MAX_BYTES:
            return cap
        return self.jpeg_max_bytes

    def status(self):
        self._connect()
        st = self._axi.axi_read(AXI_CTRL)
        sz = self._axi.axi_read(AXI_SIZE) & 0x7FFFF
        cap = self.capacity()
        flags = []
        if st & STATUS_DONE:
            flags.append("done")
        if st & STATUS_OVERFLOW:
            flags.append("overflow")
        if st & STATUS_AXI_ERR:
            flags.append("axi_error")
        if st & STATUS_RUNNING:
            flags.append("running")
        if st & STATUS_ARMED:
            flags.append("armed")
        print(f"status = {','.join(flags) or 'idle'}   jpeg_byte_cnt = {sz} / {cap} bytes")

    def encode_yuyv_file(self, yuyv_path: str, out_path: str) -> int:
        """Upload a .yuyv file, encode, save JPEG. Returns byte count."""
        with open(yuyv_path, "rb") as f:
            yuyv = f.read()
        jpg = self.encode_yuyv_bytes(yuyv)
        with open(out_path, "wb") as f:
            f.write(jpg)
        return len(jpg)

    def encode_yuyv_bytes(self, yuyv: bytes) -> bytes:
        """Full encode cycle: reset, upload pixels, start, poll done, read JPEG."""
        self._connect()
        words = _yuyv_to_words(yuyv)

        # 1. Reset state machine
        self._axi.axi_write(AXI_CTRL, 0x2)

        # 2. Arm the encoder before pixel uploads. RTL waits for a small FIFO prefill.
        self._axi.axi_write(AXI_CTRL, 0x1)

        # 3. Stream pixel data in AXI4 bursts
        iterator = range(0, len(words), BURST_WORDS)
        if HAS_TQDM:
            iterator = tqdm(iterator, desc="Uploading pixels",
                            total=(len(words) + BURST_WORDS - 1) // BURST_WORDS,
                            unit="burst")
        for start in iterator:
            chunk = words[start:start + BURST_WORDS]
            self._axi.burst_write(AXI_PIXEL + start * 4, chunk)

        # 4. Poll enc_done
        t0 = time.time()
        while True:
            st = self._axi.axi_read(AXI_CTRL)
            if st & STATUS_OVERFLOW:
                cap = self.capacity()
                raise RuntimeError(f"JPEG output overflowed FPGA buffer ({cap} bytes)")
            if st & STATUS_AXI_ERR:
                raise RuntimeError("FPGA demo reported an AXI protocol/address error")
            if st & STATUS_DONE:
                break
            if time.time() - t0 > 10.0:
                raise RuntimeError("Encode timeout — enc_done never asserted")
            time.sleep(0.01)

        # 5. Read JPEG size
        size_bytes = self._axi.axi_read(AXI_SIZE) & 0x7FFFF
        max_bytes = self.capacity()
        if size_bytes == 0 or size_bytes > max_bytes:
            raise RuntimeError(f"Unexpected JPEG size: {size_bytes} bytes (capacity {max_bytes})")
        size_words = (size_bytes + 3) // 4

        # 6. Read JPEG from BRAM in AXI4 bursts
        out_words: list[int] = []
        iterator = range(0, size_words, BURST_WORDS)
        if HAS_TQDM:
            iterator = tqdm(iterator, desc="Downloading JPEG",
                            total=(size_words + BURST_WORDS - 1) // BURST_WORDS,
                            unit="burst")
        for start in iterator:
            count = min(BURST_WORDS, size_words - start)
            out_words.extend(
                self._axi.burst_read(AXI_JPEG + start * 4, count)
            )

        buf = bytearray(
            np.array(out_words, dtype=np.uint32).tobytes()[:size_bytes]
        )
        return _trim_to_eoi(buf)


# ---------------------------------------------------------------------------
# Batch helpers
# ---------------------------------------------------------------------------

def encode_images(paths: list, out_dir: str, hw: FcapzHW,
                  program: bool = False):
    """Encode a list of image files into JPEGs under out_dir."""
    if len(paths) > 8:
        print(f"Warning: only first 8 of {len(paths)} images will be encoded")
        paths = paths[:8]

    Path(out_dir).mkdir(parents=True, exist_ok=True)

    if program:
        hw.program()

    it = tqdm(paths, desc="Frames") if HAS_TQDM else paths
    for p in it:
        stem = Path(p).stem
        out_path = os.path.join(out_dir, f"{stem}.jpg")
        jpg = hw.encode_yuyv_bytes(rgb_to_yuyv(prepare_image(p)))
        with open(out_path, "wb") as f:
            f.write(jpg)
        print(f"  {stem}.jpg — {len(jpg)} bytes")

    print(f"Done. JPEGs saved to {out_dir}/")


def encode_video(video_path: str, out_dir: str, hw: FcapzHW,
                 max_frames: int = 8, program: bool = False):
    """Encode up to max_frames from video_path into JPEGs under out_dir."""
    try:
        import cv2
    except ImportError:
        print("opencv-python not installed. Install with: pip install opencv-python")
        sys.exit(1)

    Path(out_dir).mkdir(parents=True, exist_ok=True)

    if program:
        hw.program()

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    n = 0
    total = min(int(cap.get(cv2.CAP_PROP_FRAME_COUNT)), max_frames)
    pbar = tqdm(total=total, desc="Frames") if HAS_TQDM else None

    while cap.isOpened() and n < max_frames:
        ret, frame = cap.read()
        if not ret:
            break
        rgb = cv2.cvtColor(
            cv2.resize(frame, (IMG_W, IMG_H)), cv2.COLOR_BGR2RGB
        )
        jpg = hw.encode_yuyv_bytes(rgb_to_yuyv(rgb))
        out_path = os.path.join(out_dir, f"frame_{n:04d}.jpg")
        with open(out_path, "wb") as f:
            f.write(jpg)
        n += 1
        if pbar:
            pbar.update(1)

    cap.release()
    if pbar:
        pbar.close()

    print(f"Done. {n} JPEGs saved to {out_dir}/")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _default_fpga_for_bitfile(bitfile: str | None) -> str:
    """Guess fpga_name from a bitfile path (falls back to xc7a100t)."""
    if not bitfile:
        return "xc7a100t"
    name = bitfile.lower()
    if "s7_50" in name or "s7" in name or "spartan" in name:
        return "xc7s50"
    return "xc7a100t"


def main():
    parser = argparse.ArgumentParser(
        description="mjpegZero demo host (fpgacapZero JTAG-to-AXI, 720p)")
    parser.add_argument('--bit', metavar='FILE',
                        help='Bitstream to program before encoding')
    parser.add_argument('--program', action='store_true',
                        help='Program --bit before encoding')
    parser.add_argument('--fpga', default=None,
                        help='FPGA name for hw_server (e.g. xc7a100t, xc7s50)')
    parser.add_argument('--hw-host', default='127.0.0.1',
                        help='hw_server host (default: 127.0.0.1)')
    parser.add_argument('--hw-port', type=int, default=3121,
                        help='hw_server port (default: 3121)')
    parser.add_argument('--image', nargs='+', metavar='FILE',
                        help='Input image(s), up to 8')
    parser.add_argument('--video', metavar='FILE',
                        help='Input video file')
    parser.add_argument('--out', metavar='FILE',
                        help='Output JPEG path (single image only)')
    parser.add_argument('--out-dir', metavar='DIR', default='results',
                        help='Output directory for JPEGs (default: results/)')
    parser.add_argument('--max', type=int, default=8,
                        help='Max frames from video (default: 8)')
    parser.add_argument('--jpeg-max-bytes', type=int, default=None,
                        help='Override JPEG output buffer capacity for old bitstreams')
    parser.add_argument('--status', action='store_true',
                        help='Print encoder status and exit')
    parser.add_argument('--reset', action='store_true',
                        help='Reset FPGA demo state and exit')

    args = parser.parse_args()

    fpga = args.fpga or _default_fpga_for_bitfile(args.bit)

    if args.program and not args.bit:
        parser.error('--program requires --bit')

    with FcapzHW(fpga_name=fpga, bitfile=args.bit,
                 host=args.hw_host, port=args.hw_port,
                 jpeg_max_bytes=args.jpeg_max_bytes) as hw:

        if args.status:
            hw.status()
            return

        if args.reset:
            hw.reset()
            return

        if args.image:
            if len(args.image) == 1 and args.out:
                if args.program:
                    hw.program()
                jpg = hw.encode_yuyv_bytes(rgb_to_yuyv(prepare_image(args.image[0])))
                with open(args.out, "wb") as f:
                    f.write(jpg)
                print(f"Saved: {args.out} ({len(jpg)} bytes)")
            else:
                encode_images(args.image, args.out_dir, hw, program=args.program)

        elif args.video:
            encode_video(args.video, args.out_dir, hw,
                         max_frames=args.max, program=args.program)

        else:
            parser.print_help()


if __name__ == '__main__':
    main()
