#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# gen_filtered_yuyv.py — YUYV test vectors through the csc_422 chroma filter
# ============================================================================
# The legacy YUYV vectors subsample chroma by dropping alternate samples;
# these vectors run the same source crop through the bit-exact csc_422
# model ([1,3,3,1]/8, JFIF siting) so full-encoder measurements reflect the
# camera pipeline's actual chroma path.
# Usage: gen_filtered_yuyv.py <out.hex> [W H]
# ============================================================================

import sys
import os
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from isp_rgb_model import csc_422_frame


def main():
    out = sys.argv[1]
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    img = np.asarray(Image.open(os.path.join(
        os.path.dirname(__file__), '..', '..', 'python', 'test_images',
        'mandrill_720p.png')).convert('RGB'))
    crop = img[0:h, 0:w].astype(np.int64)
    rgb = [[tuple(crop[y][x]) for x in range(w)] for y in range(h)]
    with open(out, 'w') as f:
        for word in csc_422_frame(rgb):
            f.write('%04x\n' % word)
    print(f'{w*h} filtered YUYV words -> {out}')


if __name__ == '__main__':
    sys.exit(main())
