#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Drift guard for the JPEG quality-scale formula.

The scale factor  ( Q >= 50 -> 200 - 2*Q ,  Q < 50 -> 5000 / Q )  is coded
independently in five places that the compiler/CI cannot cross-check for us:

  1. rtl/quantizer.v      g_lite_quality   (elaboration, closed form)
  2. rtl/jfif_writer.v    g_lite_header    (elaboration, closed form)
  3. rtl/quantizer.v      g_full_quality   (runtime, hand-entered case-LUT of 5000/Q)
  4. rtl/vhdl/quantizer.vhd     (lite closed form + full case-LUT)
  5. rtl/vhdl/jfif_writer.vhd   (lite closed form)

The Python reference (python/jpeg_common.py scale_quant_table) is the canonical
spec. The golden sims only exercise Q = 50/75/95/100, so a typo in a case-LUT
entry — or an edit to one copy but not the others — would slip through at an
untested quality. This test closes that gap:

  (a) the canonical closed form matches scale_quant_table for every Q in 1..100
  (b) each runtime case-LUT entry equals 5000 // Q for all Q in 1..49
  (c) each elaboration copy still carries the canonical closed-form expression

Exit code: 0 = all copies agree, 1 = drift detected.
"""

import os
import re
import sys

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR   = os.path.dirname(SCRIPT_DIR)
RTL_DIR    = os.path.join(PROJ_DIR, 'rtl')

sys.path.insert(0, SCRIPT_DIR)
from jpeg_common import (  # noqa: E402
    scale_quant_table, STD_QUANT_TABLE_LUMA, STD_QUANT_TABLE_CHROMA,
)


# ---------------------------------------------------------------------------
# Canonical formula (the single source of truth this test enforces everywhere)
# ---------------------------------------------------------------------------
def canonical_scale(q):
    """Integer scale factor, identical to the RTL and to scale_quant_table."""
    if q < 1:
        q = 1
    if q > 100:
        q = 100
    return (5000 // q) if q < 50 else (200 - 2 * q)


def canonical_table(base, q):
    scale = canonical_scale(q)
    t = np.floor((np.asarray(base) * scale + 50) / 100).astype(np.int32)
    return np.clip(t, 1, 255)


def read(path):
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        return f.read()


# ---------------------------------------------------------------------------
# (a) canonical closed form vs the Python reference, across ALL qualities
# ---------------------------------------------------------------------------
def check_reference():
    bad = []
    for q in range(1, 101):
        for base in (STD_QUANT_TABLE_LUMA, STD_QUANT_TABLE_CHROMA):
            if not np.array_equal(canonical_table(base, q), scale_quant_table(base, q)):
                bad.append(q)
                break
    if bad:
        print(f'  FAIL: canonical form disagrees with scale_quant_table at Q={bad[:10]}...')
        return False
    print('  PASS: canonical closed form == jpeg_common.scale_quant_table for Q=1..100')
    return True


# ---------------------------------------------------------------------------
# (b) runtime case-LUTs: every "key -> value" must be 5000 // key, keys 1..49
# ---------------------------------------------------------------------------
def check_case_lut(label, text, pair_regex):
    pairs = [(int(k), int(v)) for k, v in re.findall(pair_regex, text)]
    if not pairs:
        print(f'  FAIL: {label}: no case-LUT entries found (regex/structure changed?)')
        return False
    errs = [(k, v) for k, v in pairs if v != 5000 // k]
    keys = {k for k, _ in pairs}
    missing = [q for q in range(1, 50) if q not in keys]
    ok = True
    if errs:
        print(f'  FAIL: {label}: {len(errs)} entr(y/ies) != 5000//Q, e.g. '
              f'Q={errs[0][0]} has {errs[0][1]} (expected {5000 // errs[0][0]})')
        ok = False
    if missing:
        print(f'  FAIL: {label}: missing Q entries {missing[:10]} (expected 1..49)')
        ok = False
    if ok:
        print(f'  PASS: {label}: {len(pairs)} case-LUT entries all == 5000//Q (Q=1..49)')
    return ok


# ---------------------------------------------------------------------------
# (c) elaboration copies carry the canonical closed-form expression
# ---------------------------------------------------------------------------
def check_closed_form(label, text, sub_ge50, sub_lt50):
    ok = True
    for needle in (sub_ge50, sub_lt50):
        if needle not in text:
            print(f'  FAIL: {label}: expected scale expression "{needle}" not found')
            ok = False
    if ok:
        print(f'  PASS: {label}: canonical closed-form scale expression present')
    return ok


def main():
    quant_v = read(os.path.join(RTL_DIR, 'quantizer.v'))
    jfif_v  = read(os.path.join(RTL_DIR, 'jfif_writer.v'))
    quant_vhd = read(os.path.join(RTL_DIR, 'vhdl', 'quantizer.vhd'))
    jfif_vhd  = read(os.path.join(RTL_DIR, 'vhdl', 'jfif_writer.vhd'))

    print('=' * 68)
    print('JPEG quality-scale drift guard')
    print('=' * 68)

    results = [
        check_reference(),
        # (b) runtime case-LUTs
        check_case_lut('quantizer.v  full-mode LUT', quant_v,
                       r"7'd(\d+)\s*:\s*scale_factor_comb\s*=\s*13'd(\d+)"),
        check_case_lut('quantizer.vhd full-mode LUT', quant_vhd,
                       r"when\s+(\d+)\s*=>\s*return\s+(\d+)"),
        # (c) elaboration closed forms (Verilog params vs VHDL 'q')
        check_closed_form('quantizer.v   lite', quant_v,
                          '200 - 2 * LITE_QUALITY', '5000 / LITE_QUALITY'),
        check_closed_form('jfif_writer.v lite', jfif_v,
                          '200 - 2 * LITE_QUALITY', '5000 / LITE_QUALITY'),
        check_closed_form('quantizer.vhd  lite', quant_vhd,
                          '200 - 2 * q', '5000 / q'),
        check_closed_form('jfif_writer.vhd lite', jfif_vhd,
                          '200 - 2 * q', '5000 / q'),
    ]

    print('-' * 68)
    ok = all(results)
    print(f'OVERALL RESULT: {"PASS" if ok else "FAIL — quality-scale copies have drifted"}')
    print('=' * 68)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
