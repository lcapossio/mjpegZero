#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# isp_rgb_model.py — golden models for gamma_lut and csc_422
# ============================================================================
# Contracts for streamline/rtl/isp/{gamma_lut,csc_422}.v.
#
# gamma: three identical DATA_W -> 8-bit lookups (one shared curve).
#
# csc_422: BT.601 full-range RGB -> YCbCr with the same Q16 arithmetic as
# the proven encoder front end (coefficients x65536, +32768, >> 16, +128
# chroma offset, clamp), then 4:2:2 with a [1,3,3,1]/8 chroma filter
# centered on each pixel pair's midpoint — the JFIF chroma siting — with
# mirror reflection at line edges (index -1 -> 1, W -> W-2). Output words:
# {chroma[15:8], Y[7:0]}, Cb on even pixels, Cr on odd. IMG_WIDTH even.
# ============================================================================


def gamma_px(v, lut):
    return lut[v]


def csc_px(r, g, b):
    """Per-pixel Y, Cb, Cr — bit-exact to rtl/rgb_to_ycbcr.v stage 2/3."""
    def clamp8(v):
        return max(0, min(255, v))
    y = clamp8((19595 * r + 38470 * g + 7471 * b + 32768) >> 16)
    cb = clamp8(((-11056 * r - 21712 * g + 32768 * b + 32768) >> 16) + 128)
    cr = clamp8(((32768 * r - 27440 * g - 5328 * b + 32768) >> 16) + 128)
    return y, cb, cr


def csc_422_line(rgb_line):
    """One line of RGB triples -> list of YUYV16 words (len = width, even)."""
    w = len(rgb_line)
    assert w % 2 == 0
    ys, cbs, crs = [], [], []
    for r, g, b in rgb_line:
        y, cb, cr = csc_px(r, g, b)
        ys.append(y)
        cbs.append(cb)
        crs.append(cr)

    def m(i):
        return -i if i < 0 else (2 * w - 2 - i if i >= w else i)

    words = []
    for k in range(0, w, 2):
        cbf = (cbs[m(k-1)] + 3*cbs[k] + 3*cbs[m(k+1)] + cbs[m(k+2)] + 4) >> 3
        crf = (crs[m(k-1)] + 3*crs[k] + 3*crs[m(k+1)] + crs[m(k+2)] + 4) >> 3
        words.append((cbf << 8) | ys[k])
        words.append((crf << 8) | ys[k+1])
    return words


def csc_422_frame(rgb):
    return [w for line in rgb for w in csc_422_line(line)]
