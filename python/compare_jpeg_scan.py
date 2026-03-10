# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Compare two JPEG files at the coefficient level.
Decodes Huffman-coded scan data from both files and compares
DC/AC coefficients block by block to find the exact divergence point.
"""

import sys
import os

# Add parent directory so we can import jpeg_common
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jpeg_common import (
    DC_LUMA_BITS, DC_LUMA_VALS, DC_CHROMA_BITS, DC_CHROMA_VALS,
    AC_LUMA_BITS, AC_LUMA_VALS, AC_CHROMA_BITS, AC_CHROMA_VALS,
    build_huffman_table,
)


def build_decode_table(bits, vals):
    """Build a decode tree from BITS/VALS Huffman spec.
    Returns dict: {(code_length, code_value): symbol}
    """
    table = {}
    code = 0
    val_idx = 0
    for bit_len in range(1, 17):
        count = bits[bit_len - 1]
        for _ in range(count):
            table[(bit_len, code)] = vals[val_idx]
            code += 1
            val_idx += 1
        code <<= 1
    return table


class BitstreamReader:
    """Read bits from a JPEG scan data byte array (handles byte stuffing)."""

    def __init__(self, data):
        self.data = data
        self.pos = 0      # byte position
        self.bit_buf = 0
        self.bits_left = 0
        self.total_bits_read = 0

    def read_bit(self):
        if self.bits_left == 0:
            if self.pos >= len(self.data):
                raise EOFError("End of scan data")
            byte = self.data[self.pos]
            self.pos += 1
            # Handle byte stuffing: 0xFF 0x00 -> 0xFF
            if byte == 0xFF:
                if self.pos < len(self.data) and self.data[self.pos] == 0x00:
                    self.pos += 1  # Skip stuff byte
                else:
                    # This is a marker, not data
                    raise EOFError(f"Marker 0xFF{self.data[self.pos]:02X} at byte {self.pos-1}")
            self.bit_buf = byte
            self.bits_left = 8

        self.bits_left -= 1
        self.total_bits_read += 1
        return (self.bit_buf >> self.bits_left) & 1

    def read_bits(self, n):
        val = 0
        for _ in range(n):
            val = (val << 1) | self.read_bit()
        return val

    def decode_huffman(self, decode_table):
        """Decode one Huffman symbol."""
        code = 0
        for length in range(1, 17):
            code = (code << 1) | self.read_bit()
            key = (length, code)
            if key in decode_table:
                return decode_table[key]
        raise ValueError(f"Invalid Huffman code (16 bits exceeded) at bit {self.total_bits_read}")


def decode_value(br, category):
    """Read 'category' bits and decode the DC/AC value."""
    if category == 0:
        return 0
    bits = br.read_bits(category)
    # If MSB is 0, value is negative
    if bits < (1 << (category - 1)):
        return bits - (1 << category) + 1
    return bits


def extract_scan_data(jpeg_bytes):
    """Find SOS marker and extract scan data (everything after SOS header until EOI)."""
    i = 0
    while i < len(jpeg_bytes) - 1:
        if jpeg_bytes[i] == 0xFF:
            marker = jpeg_bytes[i + 1]
            if marker == 0xDA:  # SOS
                # Skip SOS header
                length = (jpeg_bytes[i + 2] << 8) | jpeg_bytes[i + 3]
                scan_start = i + 2 + length
                # Find end of scan data (next marker that isn't 0xFF00)
                scan_data = bytearray()
                j = scan_start
                while j < len(jpeg_bytes) - 1:
                    if jpeg_bytes[j] == 0xFF and jpeg_bytes[j + 1] != 0x00:
                        # Found a marker - check if it's EOI or RST
                        if jpeg_bytes[j + 1] == 0xD9:  # EOI
                            break
                        elif 0xD0 <= jpeg_bytes[j + 1] <= 0xD7:  # RST
                            j += 2
                            continue
                    scan_data.append(jpeg_bytes[j])
                    j += 1
                return bytes(scan_data), scan_start
            elif marker == 0x00:
                i += 2
            elif marker == 0xD8 or marker == 0xD9:
                i += 2
            elif 0xD0 <= marker <= 0xD7:
                i += 2
            else:
                # Skip marker segment
                if i + 3 < len(jpeg_bytes):
                    seg_len = (jpeg_bytes[i + 2] << 8) | jpeg_bytes[i + 3]
                    i += 2 + seg_len
                else:
                    i += 2
        else:
            i += 1
    raise ValueError("SOS marker not found")


def decode_jpeg_coefficients(jpeg_bytes, num_mcus, is_422=True):
    """Decode all DCT coefficients from a JPEG file.

    For YUV422: each MCU has 4 blocks: Y0, Y1, Cb, Cr

    Returns list of (block_type, dc_value, ac_coeffs[63]) tuples.
    """
    dc_luma_dec = build_decode_table(DC_LUMA_BITS, DC_LUMA_VALS)
    dc_chroma_dec = build_decode_table(DC_CHROMA_BITS, DC_CHROMA_VALS)
    ac_luma_dec = build_decode_table(AC_LUMA_BITS, AC_LUMA_VALS)
    ac_chroma_dec = build_decode_table(AC_CHROMA_BITS, AC_CHROMA_VALS)

    scan_data, scan_offset = extract_scan_data(jpeg_bytes)
    br = BitstreamReader(scan_data)

    blocks = []
    prev_dc_y = 0
    prev_dc_cb = 0
    prev_dc_cr = 0

    for mcu_idx in range(num_mcus):
        # Block order for YUV422: Y0, Y1, Cb, Cr
        block_types = ['Y0', 'Y1', 'Cb', 'Cr'] if is_422 else ['Y', 'Cb', 'Cr']

        for bt in block_types:
            is_luma = bt.startswith('Y')
            dc_table = dc_luma_dec if is_luma else dc_chroma_dec
            ac_table = ac_luma_dec if is_luma else ac_chroma_dec

            # Decode DC
            bit_pos_before = br.total_bits_read
            dc_cat = br.decode_huffman(dc_table)
            dc_diff = decode_value(br, dc_cat)

            if is_luma:
                dc_value = prev_dc_y + dc_diff
                prev_dc_y = dc_value
            elif bt == 'Cb':
                dc_value = prev_dc_cb + dc_diff
                prev_dc_cb = dc_value
            else:
                dc_value = prev_dc_cr + dc_diff
                prev_dc_cr = dc_value

            # Decode AC
            ac_coeffs = [0] * 63
            ac_idx = 0
            while ac_idx < 63:
                ac_sym = br.decode_huffman(ac_table)
                if ac_sym == 0x00:  # EOB
                    break
                elif ac_sym == 0xF0:  # ZRL (16 zeros)
                    ac_idx += 16
                else:
                    run = (ac_sym >> 4) & 0x0F
                    cat = ac_sym & 0x0F
                    ac_idx += run
                    if ac_idx < 63:
                        ac_coeffs[ac_idx] = decode_value(br, cat)
                    ac_idx += 1

            bit_pos_after = br.total_bits_read
            blocks.append({
                'mcu': mcu_idx,
                'type': bt,
                'dc_cat': dc_cat,
                'dc_diff': dc_diff,
                'dc_value': dc_value,
                'ac_coeffs': ac_coeffs,
                'bit_start': bit_pos_before,
                'bit_end': bit_pos_after,
                'bits_used': bit_pos_after - bit_pos_before,
            })

    return blocks, scan_data


def compare_files(ref_path, rtl_path, num_mcus=4):
    """Compare two JPEG files at the coefficient level."""
    with open(ref_path, 'rb') as f:
        ref_bytes = f.read()
    with open(rtl_path, 'rb') as f:
        rtl_bytes = f.read()

    print(f"Reference: {ref_path} ({len(ref_bytes)} bytes)")
    print(f"RTL:       {rtl_path} ({len(rtl_bytes)} bytes)")
    print()

    # Extract and compare scan data raw bytes
    ref_scan, ref_scan_offset = extract_scan_data(ref_bytes)
    rtl_scan, rtl_scan_offset = extract_scan_data(rtl_bytes)
    print(f"Reference scan data: {len(ref_scan)} bytes (starts at offset {ref_scan_offset})")
    print(f"RTL scan data:       {len(rtl_scan)} bytes (starts at offset {rtl_scan_offset})")

    # Show first bytes of scan data
    print(f"\nRef scan (first 40 bytes): {' '.join(f'{b:02X}' for b in ref_scan[:40])}")
    print(f"RTL scan (first 40 bytes): {' '.join(f'{b:02X}' for b in rtl_scan[:40])}")

    # Find first byte difference in scan data
    min_len = min(len(ref_scan), len(rtl_scan))
    first_diff = None
    for i in range(min_len):
        if ref_scan[i] != rtl_scan[i]:
            first_diff = i
            break
    if first_diff is not None:
        print(f"\nFirst scan byte difference at offset {first_diff}:")
        start = max(0, first_diff - 4)
        end = min(min_len, first_diff + 8)
        print(f"  Ref: {' '.join(f'{ref_scan[j]:02X}' for j in range(start, end))}")
        print(f"  RTL: {' '.join(f'{rtl_scan[j]:02X}' for j in range(start, end))}")
        print(f"  Pos: {' '.join('^^' if j == first_diff else '  ' for j in range(start, end))}")
    else:
        if len(ref_scan) == len(rtl_scan):
            print("\nScan data IDENTICAL!")
        else:
            print(f"\nScan data matches for {min_len} bytes but lengths differ")

    # Decode coefficients
    print("\n" + "=" * 70)
    print("COEFFICIENT-LEVEL COMPARISON")
    print("=" * 70)

    try:
        ref_blocks, _ = decode_jpeg_coefficients(ref_bytes, num_mcus)
    except Exception as e:
        print(f"Error decoding reference: {e}")
        return

    try:
        rtl_blocks, _ = decode_jpeg_coefficients(rtl_bytes, num_mcus)
    except Exception as e:
        print(f"Error decoding RTL: {e}")
        # Try to decode as many blocks as possible
        rtl_blocks = []
        for n in range(num_mcus * 4 - 1, 0, -1):
            try:
                rtl_blocks, _ = decode_jpeg_coefficients(rtl_bytes, (n + 3) // 4)
                print(f"  (decoded {len(rtl_blocks)} blocks before error)")
                break
            except:
                continue

    # Compare block by block
    num_blocks = min(len(ref_blocks), len(rtl_blocks))
    print(f"\nComparing {num_blocks} blocks (ref has {len(ref_blocks)}, rtl has {len(rtl_blocks)})")
    print()

    total_coeff_diff = 0
    max_dc_diff = 0

    for i in range(num_blocks):
        rb = ref_blocks[i]
        tb = rtl_blocks[i]

        dc_match = rb['dc_value'] == tb['dc_value']
        dc_diff_val = abs(rb['dc_value'] - tb['dc_value'])
        max_dc_diff = max(max_dc_diff, dc_diff_val)

        ac_diffs = sum(1 for j in range(63) if rb['ac_coeffs'][j] != tb['ac_coeffs'][j])
        total_coeff_diff += (0 if dc_match else 1) + ac_diffs

        # Find max AC difference
        max_ac_diff = 0
        for j in range(63):
            max_ac_diff = max(max_ac_diff, abs(rb['ac_coeffs'][j] - tb['ac_coeffs'][j]))

        status = "OK" if dc_match and ac_diffs == 0 else "DIFF"
        print(f"Block {i:2d} MCU{rb['mcu']} {rb['type']:3s}: "
              f"DC ref={rb['dc_value']:5d} rtl={tb['dc_value']:5d} "
              f"(diff={rb['dc_diff']:5d}/{tb['dc_diff']:5d}) "
              f"cat={rb['dc_cat']}/{tb['dc_cat']} "
              f"AC_diffs={ac_diffs:2d} max_ac_diff={max_ac_diff:3d} "
              f"bits={rb['bits_used']:3d}/{tb['bits_used']:3d} [{status}]")

        # Show detailed AC diffs for blocks with large differences
        if ac_diffs > 0 and (dc_diff_val > 2 or max_ac_diff > 5):
            print(f"         AC ref: {rb['ac_coeffs'][:16]}")
            print(f"         AC rtl: {tb['ac_coeffs'][:16]}")

    print(f"\nTotal coefficient differences: {total_coeff_diff}")
    print(f"Max DC difference: {max_dc_diff}")


if __name__ == '__main__':
    if len(sys.argv) < 3:
        # Default paths for our project
        ref_path = os.path.join(os.path.dirname(__file__), '..', 'sim', 'test_vectors', 'reference_4mcu.jpg')
        rtl_path = os.path.join(os.path.dirname(__file__), '..', 'sim', 'sim_output.jpg')
        if not os.path.exists(rtl_path):
            print(f"Usage: {sys.argv[0]} <reference.jpg> <rtl_output.jpg> [num_mcus]")
            print(f"  (default: looking for {ref_path} and {rtl_path})")
            sys.exit(1)
    else:
        ref_path = sys.argv[1]
        rtl_path = sys.argv[2]

    num_mcus = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    compare_files(ref_path, rtl_path, num_mcus)
