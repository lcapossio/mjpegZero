#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Verify Huffman tables against the JPEG standard (ITU-T T.81 Annex K).

Builds all four Huffman tables (DC luma, DC chroma, AC luma, AC chroma) from
the BITS/VALS arrays in jpeg_common.py and verifies:
  1. Code counts match the VALS arrays
  2. Codes are valid prefix codes (no code is a prefix of another)
  3. Code lengths match the BITS array specification
  4. Well-known reference codes from Annex K Table K.3/K.4/K.5/K.6 are correct

Exits with code 0 on success, 1 on any error.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jpeg_common import (
    DC_LUMA_BITS, DC_LUMA_VALS, DC_CHROMA_BITS, DC_CHROMA_VALS,
    AC_LUMA_BITS, AC_LUMA_VALS, AC_CHROMA_BITS, AC_CHROMA_VALS,
    build_huffman_table,
)


def build_rom_entries(bits, vals):
    """Build ROM entries as the RTL stores them: {symbol: (code_length, code_msb_aligned_16bit)}"""
    table = build_huffman_table(bits, vals)
    rom = {}
    for sym, (code_len, code_val) in table.items():
        code_msb = code_val << (16 - code_len)
        rom[sym] = (code_len, code_msb)
    return rom


def verify_code_counts(name, bits, vals, table):
    """Verify the number of codes matches BITS and VALS."""
    errors = []
    expected_total = len(vals)
    actual_total = len(table)
    if expected_total != actual_total:
        errors.append(f"  {name}: expected {expected_total} codes, got {actual_total}")

    # Check codes per length match BITS array
    len_counts = {}
    for sym, (code_len, code_val) in table.items():
        len_counts[code_len] = len_counts.get(code_len, 0) + 1

    for i, count in enumerate(bits):
        bit_len = i + 1
        actual = len_counts.get(bit_len, 0)
        if actual != count:
            errors.append(f"  {name}: length {bit_len}: expected {count} codes, got {actual}")

    return errors


def verify_prefix_property(name, table):
    """Verify no code is a prefix of another (valid prefix code)."""
    errors = []
    codes = []
    for sym, (code_len, code_val) in table.items():
        codes.append((code_len, code_val, sym))

    for i, (len_a, val_a, sym_a) in enumerate(codes):
        for j, (len_b, val_b, sym_b) in enumerate(codes):
            if i >= j:
                continue
            min_len = min(len_a, len_b)
            # Compare the first min_len bits
            mask = (1 << min_len) - 1
            a_prefix = val_a >> (len_a - min_len)
            b_prefix = val_b >> (len_b - min_len)
            if a_prefix == b_prefix and len_a != len_b:
                errors.append(
                    f"  {name}: 0x{sym_a:02X} (len={len_a}) is prefix of 0x{sym_b:02X} (len={len_b})"
                )
                if len(errors) > 3:
                    return errors
    return errors


def verify_reference_codes(name, table, reference):
    """Verify specific well-known codes from the JPEG standard."""
    errors = []
    for sym, (exp_len, exp_val) in reference.items():
        if sym not in table:
            errors.append(f"  {name}: symbol 0x{sym:02X} missing from table")
            continue
        act_len, act_val = table[sym]
        if act_len != exp_len or act_val != exp_val:
            errors.append(
                f"  {name}: symbol 0x{sym:02X}: "
                f"expected ({exp_len}, {exp_val:0{exp_len}b}), "
                f"got ({act_len}, {act_val:0{act_len}b})"
            )
    return errors


def main():
    total_errors = 0

    print("=" * 60)
    print("Huffman Table Verification (ITU-T T.81 Annex K)")
    print("=" * 60)

    # Build all four tables
    tables = {
        "DC Luma":    build_huffman_table(DC_LUMA_BITS, DC_LUMA_VALS),
        "DC Chroma":  build_huffman_table(DC_CHROMA_BITS, DC_CHROMA_VALS),
        "AC Luma":    build_huffman_table(AC_LUMA_BITS, AC_LUMA_VALS),
        "AC Chroma":  build_huffman_table(AC_CHROMA_BITS, AC_CHROMA_VALS),
    }

    bits_arrays = {
        "DC Luma": DC_LUMA_BITS, "DC Chroma": DC_CHROMA_BITS,
        "AC Luma": AC_LUMA_BITS, "AC Chroma": AC_CHROMA_BITS,
    }
    vals_arrays = {
        "DC Luma": DC_LUMA_VALS, "DC Chroma": DC_CHROMA_VALS,
        "AC Luma": AC_LUMA_VALS, "AC Chroma": AC_CHROMA_VALS,
    }

    # --- Test 1: Code counts ---
    print("\n[1] Code counts vs BITS/VALS arrays")
    for name, table in tables.items():
        errs = verify_code_counts(name, bits_arrays[name], vals_arrays[name], table)
        if errs:
            total_errors += len(errs)
            for e in errs:
                print(e)
        else:
            print(f"  {name}: {len(table)} codes — OK")

    # --- Test 2: Prefix code property ---
    print("\n[2] Prefix code property (no code is prefix of another)")
    for name, table in tables.items():
        errs = verify_prefix_property(name, table)
        if errs:
            total_errors += len(errs)
            for e in errs:
                print(e)
        else:
            print(f"  {name}: OK")

    # --- Test 3: Reference codes from ITU-T T.81 Annex K ---
    # Table K.3: DC Luminance — well-known codes
    dc_luma_ref = {
        0:  (2, 0b00),
        1:  (3, 0b010),
        2:  (3, 0b011),
        3:  (3, 0b100),
        4:  (3, 0b101),
        5:  (3, 0b110),
        6:  (4, 0b1110),
        7:  (5, 0b11110),
        8:  (6, 0b111110),
        9:  (7, 0b1111110),
        10: (8, 0b11111110),
        11: (9, 0b111111110),
    }

    # Table K.4: DC Chrominance
    dc_chroma_ref = {
        0:  (2, 0b00),
        1:  (2, 0b01),
        2:  (2, 0b10),
        3:  (3, 0b110),
        4:  (4, 0b1110),
        5:  (5, 0b11110),
        6:  (6, 0b111110),
        7:  (7, 0b1111110),
        8:  (8, 0b11111110),
        9:  (9, 0b111111110),
        10: (10, 0b1111111110),
        11: (11, 0b11111111110),
    }

    # Table K.5: AC Luminance — selected codes
    ac_luma_ref = {
        0x00: (4,  0b1010),       # EOB
        0xF0: (11, 0b11111111001), # ZRL
        0x01: (2,  0b00),
        0x02: (2,  0b01),
        0x03: (3,  0b100),
        0x04: (4,  0b1011),
        0x11: (4,  0b1100),
        0x05: (5,  0b11010),
        0x21: (5,  0b11100),
        0x31: (6,  0b111010),
        0x41: (6,  0b111011),
    }

    # Table K.6: AC Chrominance — selected codes
    ac_chroma_ref = {
        0x00: (2,  0b00),         # EOB
        0x01: (2,  0b01),
        0x02: (3,  0b100),
        0x03: (4,  0b1010),
        0x11: (4,  0b1011),
        0x04: (5,  0b11000),
        0x05: (5,  0b11001),
        0x21: (5,  0b11010),
        0x31: (5,  0b11011),
        0x06: (6,  0b111000),
        0xF0: (10, 0b1111111010),  # ZRL
    }

    print("\n[3] Reference codes from ITU-T T.81 Annex K")
    ref_tables = {
        "DC Luma": dc_luma_ref,
        "DC Chroma": dc_chroma_ref,
        "AC Luma": ac_luma_ref,
        "AC Chroma": ac_chroma_ref,
    }
    for name, ref in ref_tables.items():
        errs = verify_reference_codes(name, tables[name], ref)
        if errs:
            total_errors += len(errs)
            for e in errs:
                print(e)
        else:
            print(f"  {name}: {len(ref)} reference codes — OK")

    # --- Test 4: ROM format (MSB-aligned 16-bit) ---
    print("\n[4] ROM format (MSB-aligned 16-bit codes)")
    rom_tables = {
        "DC Luma":   build_rom_entries(DC_LUMA_BITS, DC_LUMA_VALS),
        "DC Chroma": build_rom_entries(DC_CHROMA_BITS, DC_CHROMA_VALS),
        "AC Luma":   build_rom_entries(AC_LUMA_BITS, AC_LUMA_VALS),
        "AC Chroma": build_rom_entries(AC_CHROMA_BITS, AC_CHROMA_VALS),
    }
    rom_errors = 0
    for name, rom in rom_tables.items():
        for sym, (code_len, code_msb) in rom.items():
            # Verify MSB alignment: lower (16-code_len) bits must be zero
            mask = (1 << (16 - code_len)) - 1
            if code_msb & mask:
                rom_errors += 1
                if rom_errors <= 5:
                    print(f"  {name}: 0x{sym:02X} not MSB-aligned: {code_msb:016b} (len={code_len})")
            # Verify fits in 16 bits
            if code_msb >= 65536:
                rom_errors += 1
                if rom_errors <= 5:
                    print(f"  {name}: 0x{sym:02X} exceeds 16 bits: {code_msb}")
    total_errors += rom_errors
    if rom_errors == 0:
        total_rom = sum(len(r) for r in rom_tables.values())
        print(f"  All {total_rom} ROM entries correctly MSB-aligned — OK")

    # Summary
    print("\n" + "=" * 60)
    if total_errors == 0:
        print("ALL TESTS PASSED")
    else:
        print(f"FAILED: {total_errors} total errors")
    print("=" * 60)

    return 0 if total_errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
