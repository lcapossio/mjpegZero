#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# hw_capture_enc.py - read the RAW encoder output (jpg_tdata) captured on silicon
# into a dedicated BRAM, via JTAG at 0x0200_4000+, BYPASSING jp_phase /
# demo_jpeg_buffer / jpeg_rtp_tx. Decodes the captured frame and checks the black
# bar. This is the clean cut: washed => the ENCODER output is bad; correct =>
# the capture/buffer/RTP path is bad. Direct measurement, no inference.

import io
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "common" / "python"))
from demo import FcapzHW   # noqa: E402
import numpy as np         # noqa: E402
from PIL import Image, ImageFile   # noqa: E402
ImageFile.LOAD_TRUNCATED_IMAGES = True


def main():
    # trigger the loop so a frame is encoded + captured into jcap (held after 1st)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.sendto(b"GO", ("192.168.237.50", 9999))
    s.close()
    time.sleep(0.5)

    hw = FcapzHW(fpga_name="xc7a100t", bitfile=None)
    try:
        hw._connect()
        print("reading 4096 encoder-output bytes via JTAG (separate path) ...")
        data = bytearray(4096)
        for i in range(4096):
            data[i] = hw._axi.axi_read(0x02004000 + i * 4) & 0xFF
    finally:
        hw.close()

    Path("build/enc_capture.bin").write_bytes(bytes(data))
    s0 = data.find(b"\xff\xd8")
    print("captured 4096 raw jpg_tdata bytes, SOI at offset", s0)
    print("first 24 bytes:", bytes(data[:24]).hex())
    if s0 < 0:
        print("no SOI found - encoder output not captured (arm/trigger issue)")
        return
    jpg = bytes(data[s0:])
    try:
        img = Image.open(io.BytesIO(jpg)).convert("YCbCr")
        img.load()
        a = np.asarray(img).astype(int)
        W = a.shape[1]
        y = 4
        yb = [int(a[y, int((j + 0.5) * W / 8), 0]) for j in range(8)]
        print("\nENCODER OUTPUT (raw jpg_tdata) Ybars:", yb)
        print("expected (correct)               :", [255, 226, 179, 150, 105, 76, 29, 0])
        print("\n=> %s" % ("ENCODER OUTPUT IS WASHED -> the bug IS in the encoder (not downstream)"
                           if yb[7] > 40 else
                           "ENCODER OUTPUT IS CORRECT -> bug is DOWNSTREAM (capture/buffer/RTP), not the encoder!"))
    except Exception as e:
        print("partial-decode note:", e)
        print("(captured %d scan-ish bytes; may need more depth to decode a row)" % len(jpg))


if __name__ == "__main__":
    main()
