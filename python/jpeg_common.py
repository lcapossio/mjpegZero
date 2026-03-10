# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
JPEG Common Constants, Tables, and Utilities
Based on ITU-T T.81 (JPEG standard) Annex K
"""

import numpy as np

# ============================================================================
# Standard Quantization Tables (ITU-T T.81 Annex K, Table K.1 and K.2)
# ============================================================================

# Luminance quantization table (Table K.1)
STD_QUANT_TABLE_LUMA = np.array([
    [16, 11, 10, 16,  24,  40,  51,  61],
    [12, 12, 14, 19,  26,  58,  60,  55],
    [14, 13, 16, 24,  40,  57,  69,  56],
    [14, 17, 22, 29,  51,  87,  80,  62],
    [18, 22, 37, 56,  68, 109, 103,  77],
    [24, 35, 55, 64,  81, 104, 113,  92],
    [49, 64, 78, 87, 103, 121, 120, 101],
    [72, 92, 95, 98, 112, 100, 103,  99],
], dtype=np.float64)

# Chrominance quantization table (Table K.2)
STD_QUANT_TABLE_CHROMA = np.array([
    [17, 18, 24, 47, 99, 99, 99, 99],
    [18, 21, 26, 66, 99, 99, 99, 99],
    [24, 26, 56, 99, 99, 99, 99, 99],
    [47, 66, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
    [99, 99, 99, 99, 99, 99, 99, 99],
], dtype=np.float64)


def scale_quant_table(base_table, quality):
    """Scale quantization table by quality factor (1-100).
    Quality 50 = use table as-is. Higher = less quantization = better quality.
    """
    if quality <= 0:
        quality = 1
    if quality > 100:
        quality = 100
    if quality < 50:
        scale = 5000 // quality
    else:
        scale = 200 - 2 * quality
    table = np.floor((base_table * scale + 50) / 100).astype(np.int32)
    table = np.clip(table, 1, 255)
    return table


# ============================================================================
# Zigzag scan order (ITU-T T.81 Figure A.6)
# ============================================================================

ZIGZAG_ORDER = np.array([
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63
], dtype=np.int32)

# Inverse zigzag: maps zigzag position -> raster position
ZIGZAG_ORDER_INV = np.zeros(64, dtype=np.int32)
for _i, _v in enumerate(ZIGZAG_ORDER):
    ZIGZAG_ORDER_INV[_v] = _i


# ============================================================================
# Standard Huffman Tables (ITU-T T.81 Annex K, Tables K.3-K.6)
# ============================================================================

# Format: {symbol: (code_length, code_value)}
# DC tables map category (0-11) to Huffman code
# AC tables map (run_length, category) packed as (run<<4)|size to Huffman code

# --- DC Luminance (Table K.3) ---
# Bits counts per code length (1-16)
DC_LUMA_BITS = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
DC_LUMA_VALS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

# --- DC Chrominance (Table K.4) ---
DC_CHROMA_BITS = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
DC_CHROMA_VALS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]

# --- AC Luminance (Table K.5) ---
AC_LUMA_BITS = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d]
AC_LUMA_VALS = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
    0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
    0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
    0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
    0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
    0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
    0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
]

# --- AC Chrominance (Table K.6) ---
AC_CHROMA_BITS = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
AC_CHROMA_VALS = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
    0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
    0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
    0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
    0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
    0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
    0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
]


def build_huffman_table(bits, vals):
    """Build Huffman lookup table from BITS and VALS arrays.
    Returns dict: {symbol: (code_length, code_value)}
    """
    table = {}
    code = 0
    val_idx = 0
    for bit_len in range(1, 17):
        count = bits[bit_len - 1]
        for _ in range(count):
            table[vals[val_idx]] = (bit_len, code)
            code += 1
            val_idx += 1
        code <<= 1
    return table


# Pre-built Huffman tables
DC_LUMA_TABLE = build_huffman_table(DC_LUMA_BITS, DC_LUMA_VALS)
DC_CHROMA_TABLE = build_huffman_table(DC_CHROMA_BITS, DC_CHROMA_VALS)
AC_LUMA_TABLE = build_huffman_table(AC_LUMA_BITS, AC_LUMA_VALS)
AC_CHROMA_TABLE = build_huffman_table(AC_CHROMA_BITS, AC_CHROMA_VALS)


def get_bit_category(value):
    """Get the number of bits needed to represent a value (JPEG category/size).
    Category 0: value 0
    Category 1: values -1, 1
    Category 2: values -3..-2, 2..3
    ...etc
    """
    if value == 0:
        return 0
    abs_val = abs(value)
    category = 0
    tmp = abs_val
    while tmp > 0:
        category += 1
        tmp >>= 1
    return category


def encode_dc_value(value):
    """Encode a DC coefficient value into (category, bit_pattern).
    For negative values, bit_pattern = value - 1 (one's complement).
    """
    category = get_bit_category(value)
    if value < 0:
        bit_pattern = value + (1 << category) - 1
    else:
        bit_pattern = value
    return category, bit_pattern


# ============================================================================
# DCT Matrix (for reference/verification)
# ============================================================================

def make_dct_matrix():
    """Create the 8x8 DCT transformation matrix."""
    C = np.zeros((8, 8), dtype=np.float64)
    for i in range(8):
        for j in range(8):
            if i == 0:
                C[i, j] = 1.0 / np.sqrt(8.0)
            else:
                C[i, j] = np.sqrt(2.0 / 8.0) * np.cos((2 * j + 1) * i * np.pi / 16.0)
    return C

DCT_MATRIX = make_dct_matrix()
