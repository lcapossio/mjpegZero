#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# dct_model.py — fixed-point 1-D DCT models
# ============================================================================
# Two bit-exact models of the 8-point forward DCT, both producing the
# orthonormal DCT (alpha(k) folded into the constants) that the JPEG
# quantizer tables assume:
#
#   dct1d_matrix(x)   — the rtl/dct_1d.v computation: 8 Q12 products per
#                       output coefficient, summed, rounded once (+2048>>12)
#   dct1d_loeffler(x) — the streamline computation: Loeffler/LLM-factored
#                       butterflies with orthonormal constants folded to
#                       Q12; 14 constant multiplies per 8-point transform
#                       (vs 64), one rounding per output
#
# The Loeffler model is the contract for streamline/dct_1d.v: the RTL must
# match it bit-exactly. Both models keep the same per-pass normalization as
# rtl/, so either dct_1d drops into either dct_2d.
#
# Run as a script to audit the multiply count and measure accuracy of both
# models against the double-precision DCT (IEEE-1180-flavored bounds).
# ============================================================================

import numpy as np

Q = 12
HALF = 1 << (Q - 1)


def _fold(v):
    """Orthonormal constant folded to Q12: round(v * 4096)."""
    return int(round(v * (1 << Q)))


_SQ = np.sqrt(2.0)
# Even-half constants (identical to rtl cos_rom entries):
C_A  = _fold(1 / np.sqrt(8))                       # 1448: alpha(0), X0/X4
C_R1 = _fold(0.541196100 / (2 * _SQ))              #  784: = 0.5*cos(6pi/16)
C_R2 = _fold(0.765366865 / (2 * _SQ))              # 1108: = C2 - C6
C_R3 = _fold(1.847759065 / (2 * _SQ))              # 2676: = C2 + C6
# Odd-half constants (LLM structure, orthonormal-folded):
C_T4 = _fold(0.298631336 / (2 * _SQ))              #  433
C_T5 = _fold(2.053119869 / (2 * _SQ))              # 2974
C_T6 = _fold(3.072711026 / (2 * _SQ))              # 4450
C_T7 = _fold(1.501321110 / (2 * _SQ))              # 2174
C_Z1 = _fold(-0.899976223 / (2 * _SQ))             # -1304
C_Z2 = _fold(-2.562915447 / (2 * _SQ))             # -3712
C_Z3 = _fold(-1.961570560 / (2 * _SQ))             # -2841
C_Z4 = _fold(-0.390180644 / (2 * _SQ))             #  -565
C_Z5 = _fold(1.175875602 / (2 * _SQ))              # 1703: = 0.5*cos(3pi/16)

_COS_ROM = np.array([
    [1448]*8,
    [2009, 1703, 1138, 400, -400, -1138, -1703, -2009],
    [1892, 784, -784, -1892, -1892, -784, 784, 1892],
    [1703, -400, -2009, -1138, 1138, 2009, 400, -1703],
    [1448, -1448, -1448, 1448, 1448, -1448, -1448, 1448],
    [1138, -2009, 400, 1703, -1703, -400, 2009, -1138],
    [784, -1892, 1892, -784, -784, 1892, -1892, 784],
    [400, -1138, 1703, -2009, 2009, -1703, 1138, -400],
], dtype=np.int64)


def _round_q(v):
    """Single Q12 round-to-nearest: (v + 2048) >> 12, arithmetic shift."""
    return (int(v) + HALF) >> Q


def dct1d_matrix(x):
    """rtl/dct_1d.v bit-exact: one 8-term Q12 dot product per coefficient."""
    out = []
    for k in range(8):
        acc = sum(int(x[n]) * int(_COS_ROM[k][n]) for n in range(8))
        out.append(_round_q(acc))
    return out


# Every constant multiply in the Loeffler path goes through mul(), so the
# multiply count is measured, not asserted.
_MUL_COUNT = [0]


def mul(c, v):
    _MUL_COUNT[0] += 1
    return int(c) * int(v)


def dct1d_loeffler(x):
    """Loeffler/LLM-factored orthonormal DCT, Q12, one rounding per output.

    Structure (14 multiplies, 32 adds):
      stage 1:  s_i = x_i + x_{7-i}, t_i = x_i - x_{7-i}    (i = 0..3)
      even:     e0 = s0+s3, e1 = s1+s2, e2 = s1-s2, e3 = s0-s3
                X0 = CA*(e0+e1)             X4 = CA*(e0-e1)
                zr = CR1*(e2+e3)
                X2 = zr + CR3*e3            X6 = zr - CR2*e2? — see note
      odd:      z1 = t3+t0, z2 = t2+t1, z3 = t3+t1, z4 = t2+t0
                z5 = CZ5*(z3+z4)
                X7 = CT4*t3 + CZ1*z1 + CZ3*z3 + z5
                X5 = CT5*t2 + CZ2*z2 + CZ4*z4 + z5
                X3 = CT6*t1 + CZ2*z2 + CZ3*z3 + z5
                X1 = CT7*t0 + CZ1*z1 + CZ4*z4 + z5

    Even-half note: with a = e3, b = e2 the rotation is
      X2 = C2*a + C6*b = CR1*(a+b) + CR2*a
      X6 = C6*a - C2*b = CR1*(a+b) - CR3*b
    since CR2 = C2-C6 and CR3 = C2+C6 exactly in Q12 (1108 = 1892-784,
    2676 = 1892+784) — verified by the agreement audit below.
    """
    x = [int(v) for v in x]

    s0, t0 = x[0] + x[7], x[0] - x[7]
    s1, t1 = x[1] + x[6], x[1] - x[6]
    s2, t2 = x[2] + x[5], x[2] - x[5]
    s3, t3 = x[3] + x[4], x[3] - x[4]

    # even half
    e0, e3 = s0 + s3, s0 - s3
    e1, e2 = s1 + s2, s1 - s2

    X0 = _round_q(mul(C_A, e0 + e1))
    X4 = _round_q(mul(C_A, e0 - e1))

    zr = mul(C_R1, e2 + e3)
    X2 = _round_q(zr + mul(C_R2, e3))
    X6 = _round_q(zr - mul(C_R3, e2))

    # odd half (LLM): t3 pairs with X7's leading term, t0 with X1's
    z1 = t3 + t0
    z2 = t2 + t1
    z3 = t3 + t1
    z4 = t2 + t0
    z5 = mul(C_Z5, z3 + z4)

    p1 = mul(C_Z1, z1)
    p2 = mul(C_Z2, z2)
    p3 = mul(C_Z3, z3) + z5
    p4 = mul(C_Z4, z4) + z5

    X7 = _round_q(mul(C_T4, t3) + p1 + p3)
    X5 = _round_q(mul(C_T5, t2) + p2 + p4)
    X3 = _round_q(mul(C_T6, t1) + p2 + p3)
    X1 = _round_q(mul(C_T7, t0) + p1 + p4)

    return [X0, X1, X2, X3, X4, X5, X6, X7]


def dct1d_float(x):
    """Double-precision orthonormal reference."""
    x = np.asarray(x, dtype=np.float64)
    out = np.zeros(8)
    for k in range(8):
        a = np.sqrt(1 / 8) if k == 0 else 0.5
        out[k] = a * np.sum(x * np.cos((2 * np.arange(8) + 1) * k * np.pi / 16))
    return out


def main():
    print('folded constants:', C_A, C_R1, C_R2, C_R3, '|',
          C_T4, C_T5, C_T6, C_T7, C_Z1, C_Z2, C_Z3, C_Z4, C_Z5)

    rng = np.random.default_rng(1)
    n_blocks = 20000
    peak_m = peak_l = sum_m = sum_l = 0.0
    agree = coeff_agree = 0
    for _ in range(n_blocks):
        x = rng.integers(-2048, 2048, 8)
        f = dct1d_float(x)
        m = dct1d_matrix(x)
        _MUL_COUNT[0] = 0
        l = dct1d_loeffler(x)
        muls = _MUL_COUNT[0]
        peak_m = max(peak_m, float(np.max(np.abs(np.array(m) - f))))
        peak_l = max(peak_l, float(np.max(np.abs(np.array(l) - f))))
        sum_m += float(np.mean(np.abs(np.array(m) - f)))
        sum_l += float(np.mean(np.abs(np.array(l) - f)))
        agree += int(m == l)
        coeff_agree += sum(int(a == b) for a, b in zip(m, l))

    print(f'multiplies per 8-point transform: {muls} (matrix path: 64)')
    print(f'matrix   vs float: peak {peak_m:.4f}  mean {sum_m/n_blocks:.5f}')
    print(f'loeffler vs float: peak {peak_l:.4f}  mean {sum_l/n_blocks:.5f}')
    print(f'block agreement  : {agree}/{n_blocks}')
    print(f'coeff agreement  : {coeff_agree}/{n_blocks*8}'
          f' ({100.0*coeff_agree/(n_blocks*8):.3f}%)')

    ok = muls == 14 and peak_l <= peak_m + 0.5
    print('AUDIT', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    import sys
    sys.exit(main())
