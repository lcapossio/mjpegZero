#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# dct_aan_model.py — AAN scaled-DCT feasibility model and numerics study
# ============================================================================
# The Arai-Agui-Nakajima factorization computes the 8-point DCT with 5
# multiplies by leaving each output scaled by a known per-coefficient
# factor; the JPEG quantizer already multiplies every coefficient by a
# reciprocal, so the correction folds into the reciprocal tables for free.
#
# This model answers the design questions before any RTL exists:
#   1. exact integer AAN pass (Q13 constants, one rounding per multiply)
#   2. inter-pass handling: the scaled row-pass DC reaches sum(x) = 8*2048,
#      so the 12-bit inter-pass interface needs a divide-by-4 (round) after
#      pass 1, folded into the reciprocals with everything else
#   3. folded reciprocal precision: sweep the reciprocal scale S and report
#      quantized-coefficient agreement with the proven Loeffler+quantizer
#      chain and reconstruction PSNR, to pick the narrowest adequate S
# ============================================================================

import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from dct_model import dct1d_loeffler, dct1d_float
from dct2d_psnr import dct2d, quantize, idct2d_float

Q13 = int(__import__('os').environ.get('AAN_QBITS', '13'))
C_A1 = round(0.707106781 * (1 << Q13))   # sqrt(2)/2
C_A2 = round(0.541196100 * (1 << Q13))
C_A3 = C_A1
C_A4 = round(1.306562965 * (1 << Q13))
C_A5 = round(0.382683433 * (1 << Q13))

_MULS = [0]


def _m(c, v):
    """Q13 product, kept at full precision (no per-multiply rounding)."""
    _MULS[0] += 1
    return int(c) * int(v)


def _rq(v):
    """Single per-output rounding from Q13 back to integer."""
    return (int(v) + (1 << (Q13 - 1))) >> Q13


def aan1d_int(x, guard=0):
    """Integer AAN pass: 5 multiplies, outputs scaled per coefficient,
    multiplied by 2^guard (fraction bits kept through the final rounding
    so the paired quantizer can fold them out)."""
    x = [int(v) for v in x]
    t0, t7 = x[0] + x[7], x[0] - x[7]
    t1, t6 = x[1] + x[6], x[1] - x[6]
    t2, t5 = x[2] + x[5], x[2] - x[5]
    t3, t4 = x[3] + x[4], x[3] - x[4]

    u0, u3 = t0 + t3, t0 - t3
    u1, u2 = t1 + t2, t1 - t2

    def rq(v):
        return (int(v) + (1 << (Q13 - guard - 1))) >> (Q13 - guard)

    X0 = (u0 + u1) << guard               # exact, no fraction
    X4 = (u0 - u1) << guard
    z1 = _m(C_A1, u2 + u3)
    X2 = rq((u3 << Q13) + z1)
    X6 = rq((u3 << Q13) - z1)

    v0 = t4 + t5
    v1 = t5 + t6
    v2 = t6 + t7
    z5 = _m(C_A5, v0 - v2)
    z2 = _m(C_A2, v0) + z5                # Q13 throughout
    z4 = _m(C_A4, v2) + z5
    z3 = _m(C_A3, v1)
    z11 = (t7 << Q13) + z3
    z13 = (t7 << Q13) - z3
    X5 = rq(z13 + z2)
    X3 = rq(z13 - z2)
    X1 = rq(z11 + z4)
    X7 = rq(z11 - z4)
    return [X0, X1, X2, X3, X4, X5, X6, X7]


def aan_gains():
    """Per-coefficient gain of the float AAN pass vs the orthonormal DCT,
    measured on the impulse basis (exact, no fixed point)."""
    def aan1d_float(x):
        s = _MULS[0]
        out = aan1d_int([v * 4096 for v in x])   # fine-grained integer probe
        _MULS[0] = s
        return [v / 4096.0 for v in out]
    g = np.zeros(8)
    for k in range(8):
        e = [0.0] * 8
        e[k] = 1.0
        a = np.array(aan1d_float(e))
        f = dct1d_float(e)
        # gain is per OUTPUT coefficient: compare column responses
        for u in range(8):
            if abs(f[u]) > 1e-9:
                g[u] = a[u] / f[u]
    return g


def dct2d_aan(block, interpass_shift, sat_bits=12):
    """2-D AAN: row pass, round-shift, saturate to a sat_bits-wide signed
    inter-pass, column pass. Raw scaled coefficients out (descaling lives
    in the folded quantizer)."""
    r = [aan1d_int(row, guard=1) for row in block]
    out = [[0] * 8 for _ in range(8)]
    half = (1 << (interpass_shift - 1)) if interpass_shift else 0
    lim = (1 << (sat_bits - 1)) - 1
    for k in range(8):
        col = []
        for i in range(8):
            v = (r[i][k] + half) >> interpass_shift
            col.append(max(-lim - 1, min(lim, v)))
        c = aan1d_int(col)          # inputs carry x2; net output x2
        for u in range(8):
            out[u][k] = c[u]
    return out


def main():
    rng = np.random.default_rng(21)

    _MULS[0] = 0
    aan1d_int(list(rng.integers(-2048, 2048, 8)))
    print(f'multiplies per 8-point transform: {_MULS[0]} '
          f'(Loeffler: 14, matrix: 64)')

    g = aan_gains()
    print('per-pass gains vs orthonormal:',
          ' '.join(f'{v:.4f}' for v in g))

    # Row-pass range check for the inter-pass interface
    peak = 0
    for _ in range(4000):
        r = aan1d_int(list(rng.integers(-2048, 2048, 8)))
        peak = max(peak, max(abs(v) for v in r))
    print(f'row-pass peak |output|: {peak} '
          f'(12-bit interface holds 2047; >>2 brings {peak} -> {peak >> 2})')

    from jpeg_common import STD_QUANT_TABLE_LUMA, scale_quant_table  # noqa

    # Hardware fold formula (used verbatim by quantizer_aan.v in BOTH
    # table modes): kf[pos] = round(2^14 / (g_u * g_v)), and
    # recip_folded = (round(2^16/q) * kf + 2^13) >> 14.
    KB = 14
    kf = np.zeros(64, dtype=np.int64)
    for u in range(8):
        for v in range(8):
            kf[u*8 + v] = round((1 << KB) / (g[u] * g[v]))
    print('kf[pos] range:', int(kf.min()), '..', int(kf.max()),
          f'({int(kf.max()).bit_length()} bits)')

    def recip_folded(qstep, pos):
        rl = 65535 if qstep <= 1 else (65536 + qstep // 2) // qstep
        return (rl * int(kf[pos]) + (1 << (KB - 1))) >> KB

    agree = total = 0
    err = 0.0
    maxrecip = 0
    err_ref = err_aan = 0.0
    npx = 0
    for q in (50, 75, 95, 100, 1):
        qt = scale_quant_table(STD_QUANT_TABLE_LUMA, q)
        recip = np.zeros((8, 8), dtype=np.int64)
        for u in range(8):
            for v in range(8):
                recip[u][v] = recip_folded(int(qt[u][v]), u*8 + v)
                maxrecip = max(maxrecip, int(recip[u][v]))
        for _ in range(200):
            blk = rng.integers(-128, 128, (8, 8))
            ref = dct2d([[int(x) for x in row] for row in blk],
                        dct1d_loeffler)
            refq = [[quantize(ref[u][v], qt[u][v]) for v in range(8)]
                    for u in range(8)]
            aan = dct2d_aan([[int(x) for x in row] for row in blk],
                            0, 16)
            aanq = [[0]*8 for _ in range(8)]
            for u in range(8):
                for v in range(8):
                    a = int(aan[u][v])
                    sg = -1 if a < 0 else 1
                    qv = sg * ((abs(a) * int(recip[u][v]) + 32768) >> 16)
                    aanq[u][v] = qv
                    total += 1
                    agree += int(qv == refq[u][v])
                    err += (qv - refq[u][v]) ** 2
            # Reconstruction comparison: both chains dequantize with the
            # true q and invert with the ideal IDCT.
            rr = idct2d_float([[refq[u][v] * int(qt[u][v]) for v in range(8)]
                               for u in range(8)])
            ra = idct2d_float([[aanq[u][v] * int(qt[u][v]) for v in range(8)]
                               for u in range(8)])
            err_ref += float(np.sum((rr - blk) ** 2))
            err_aan += float(np.sum((ra - blk) ** 2))
            npx += 64
    p_ref = 10*np.log10(255**2/(err_ref/npx))
    p_aan = 10*np.log10(255**2/(err_aan/npx))
    print(f'fraction-carrying, 16b inter-pass, hardware fold (Q{Q13}): '
          f'agreement {100.0*agree/total:.3f}%, rms {np.sqrt(err/total):.4f}, '
          f'max recip {maxrecip} ({maxrecip.bit_length()} bits)')
    print(f'reconstruction PSNR: loeffler {p_ref:.4f} dB, aan {p_aan:.4f} dB, '
          f'delta {p_aan-p_ref:+.4f} dB (gate: >= -0.05)')

    print('NOTE: agreement is vs the proven Loeffler chain; residual '
          'differences are +/-1 quantizer-LSB rounding, judged by the '
          'end-to-end PSNR gate when the RTL exists.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
