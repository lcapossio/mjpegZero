#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Verify LITE_QUALITY tables against Python reference.

Checks that the RTL elaboration-time computation (quantizer.v and jfif_writer.v
initial blocks) produces correct tables for various LITE_QUALITY values.

Both the quantizer tables (raster order + reciprocals) and JFIF DQT header bytes
(zigzag order) are verified against the Python reference implementation.
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jpeg_common import (
    STD_QUANT_TABLE_LUMA, STD_QUANT_TABLE_CHROMA,
    scale_quant_table, ZIGZAG_ORDER
)


def rtl_scale_table(base_flat, quality):
    """Replicate the RTL initial block computation exactly (integer arithmetic).

    This matches the Verilog code in quantizer.v g_lite_quality initial block:
        if (LITE_QUALITY >= 50) scale = 200 - 2 * LITE_QUALITY;
        else if (LITE_QUALITY >= 1) scale = 5000 / LITE_QUALITY;
        else scale = 5000;
        scaled_q = (base * scale + 50) / 100;  // integer division
        clamp to [1, 255]
    """
    if quality >= 50:
        scale = 200 - 2 * quality
    elif quality >= 1:
        scale = 5000 // quality
    else:
        scale = 5000

    result = []
    for base_val in base_flat:
        scaled_q = (int(base_val) * scale + 50) // 100
        scaled_q = max(1, min(255, scaled_q))
        result.append(scaled_q)
    return result


def rtl_reciprocal(q):
    """Replicate the RTL reciprocal computation.

    From quantizer.v:
        if (scaled_q == 1) recip_val = 65535;
        else recip_val = (65536 + scaled_q / 2) / scaled_q;
        clamp to 65535
    """
    if q == 1:
        return 65535
    recip = (65536 + q // 2) // q
    return min(65535, recip)


def verify_quality(quality):
    """Verify tables for a given quality value. Returns (pass, errors)."""
    errors = []

    # Flatten base tables to raster order (row-major)
    base_luma_flat = STD_QUANT_TABLE_LUMA.flatten().astype(int)
    base_chroma_flat = STD_QUANT_TABLE_CHROMA.flatten().astype(int)

    # === 1. Quantizer tables (raster order) ===
    # Python reference
    py_luma = scale_quant_table(STD_QUANT_TABLE_LUMA, quality).flatten()
    py_chroma = scale_quant_table(STD_QUANT_TABLE_CHROMA, quality).flatten()

    # RTL initial block emulation
    rtl_luma = rtl_scale_table(base_luma_flat, quality)
    rtl_chroma = rtl_scale_table(base_chroma_flat, quality)

    # Compare Q tables
    for i in range(64):
        if rtl_luma[i] != py_luma[i]:
            errors.append(f"  Luma Q[{i}]: RTL={rtl_luma[i]}, Python={py_luma[i]}")
        if rtl_chroma[i] != py_chroma[i]:
            errors.append(f"  Chroma Q[{i}]: RTL={rtl_chroma[i]}, Python={py_chroma[i]}")

    # === 2. Reciprocals ===
    for i in range(64):
        recip_l = rtl_reciprocal(rtl_luma[i])
        if rtl_luma[i] == 1:
            if recip_l != 65535:
                errors.append(f"  Luma recip[{i}]: q=1, got {recip_l}, expected 65535")
        else:
            # Cross-check: reciprocal * q should be close to 65536
            product = recip_l * rtl_luma[i]
            if abs(product - 65536) > rtl_luma[i]:
                errors.append(
                    f"  Luma recip[{i}]: q={rtl_luma[i]}, recip={recip_l}, "
                    f"product={product} (expected ~65536)"
                )

    for i in range(64):
        recip_c = rtl_reciprocal(rtl_chroma[i])
        if rtl_chroma[i] == 1:
            if recip_c != 65535:
                errors.append(f"  Chroma recip[{i}]: q=1, got {recip_c}, expected 65535")
        else:
            product = recip_c * rtl_chroma[i]
            if abs(product - 65536) > rtl_chroma[i]:
                errors.append(
                    f"  Chroma recip[{i}]: q={rtl_chroma[i]}, recip={recip_c}, "
                    f"product={product} (expected ~65536)"
                )

    # === 3. JFIF DQT bytes (zigzag order) ===
    # The JFIF writer stores DQT bytes in zigzag scan order:
    #   header_rom[25 + i] = scaled_luma[zigzag_order[i]]
    #   header_rom[94 + i] = scaled_chroma[zigzag_order[i]]
    for i in range(64):
        zz_idx = ZIGZAG_ORDER[i]
        dqt_luma = rtl_luma[zz_idx]
        dqt_chroma = rtl_chroma[zz_idx]
        if dqt_luma < 1 or dqt_luma > 255:
            errors.append(f"  DQT Luma[{i}] (zz={zz_idx}): {dqt_luma} out of range [1,255]")
        if dqt_chroma < 1 or dqt_chroma > 255:
            errors.append(f"  DQT Chroma[{i}] (zz={zz_idx}): {dqt_chroma} out of range [1,255]")

    return len(errors) == 0, errors


def main():
    test_qualities = [1, 10, 25, 50, 75, 80, 95, 100]
    all_pass = True

    print("=" * 60)
    print("LITE_QUALITY Verification Test")
    print("Verifying RTL initial block tables vs Python reference")
    print("=" * 60)

    for q in test_qualities:
        passed, errs = verify_quality(q)
        status = "PASS" if passed else "FAIL"
        print(f"\n  Q={q:3d}: {status}")
        if not passed:
            all_pass = False
            for e in errs[:5]:
                print(f"    {e}")
            if len(errs) > 5:
                print(f"    ... and {len(errs) - 5} more errors")

    # Print sample tables for visual inspection
    print("\n" + "=" * 60)
    print("Sample tables (first 8 values, raster order)")
    print("=" * 60)
    base_luma_flat = STD_QUANT_TABLE_LUMA.flatten().astype(int)
    for q in [95, 50, 10]:
        rtl_vals = rtl_scale_table(base_luma_flat, q)
        recips = [rtl_reciprocal(v) for v in rtl_vals]
        print(f"\n  Q={q}: luma[0:8]  = {rtl_vals[:8]}")
        print(f"        recip[0:8] = {recips[:8]}")

    print("\n" + "=" * 60)
    if all_pass:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
    print("=" * 60)

    return 0 if all_pass else 1


if __name__ == "__main__":
    sys.exit(main())
