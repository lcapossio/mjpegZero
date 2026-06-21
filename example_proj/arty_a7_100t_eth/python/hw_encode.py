#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# hw_encode.py - upload a 1280x720 YUYV frame over JTAG (fcapz EJTAG-AXI) and
# encode it, leaving the JPEG in the FPGA buffer (and saving the JTAG read-back
# as a reference). The FPGA must already be programmed; we connect without
# reprogramming, so the ELA ready-probe is skipped (demo_top_eth has no ELA).
#
# Usage: python hw_encode.py <in.yuyv> <out_jtag.jpg>

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "common" / "python"))
from demo import FcapzHW   # noqa: E402

def main():
    yuyv = sys.argv[1] if len(sys.argv) > 1 else "mandrill_720p.yuyv"
    out  = sys.argv[2] if len(sys.argv) > 2 else "out_jtag.jpg"
    # bitfile=None -> connect without programming; transport skips the ELA probe
    hw = FcapzHW(fpga_name="xc7a100t", bitfile=None)
    try:
        n = hw.encode_yuyv_file(yuyv, out)
        print("encoded %d bytes -> %s" % (n, out))
    finally:
        hw.close()

if __name__ == "__main__":
    main()
