# SPDX-License-Identifier: MIT
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
JPEG Encoder - Reference Implementation
Produces baseline JPEG (ITU-T T.81) with YUV422 subsampling.
Output is a valid JFIF file decodable by FFmpeg, Pillow, etc.
"""

import struct
import numpy as np
from jpeg_common import (
    STD_QUANT_TABLE_LUMA, STD_QUANT_TABLE_CHROMA, scale_quant_table,
    ZIGZAG_ORDER, DCT_MATRIX,
    DC_LUMA_BITS, DC_LUMA_VALS, DC_CHROMA_BITS, DC_CHROMA_VALS,
    AC_LUMA_BITS, AC_LUMA_VALS, AC_CHROMA_BITS, AC_CHROMA_VALS,
    DC_LUMA_TABLE, DC_CHROMA_TABLE, AC_LUMA_TABLE, AC_CHROMA_TABLE,
    get_bit_category, encode_dc_value,
)


# ============================================================================
# Color space conversion
# ============================================================================

def rgb_to_ycbcr(img_rgb):
    """Convert RGB image (H,W,3) uint8 to YCbCr (H,W,3) float64.
    Uses ITU-R BT.601 / JFIF convention:
      Y  =  0.299*R + 0.587*G + 0.114*B
      Cb = -0.168736*R - 0.331264*G + 0.5*B + 128
      Cr =  0.5*R - 0.418688*G - 0.081312*B + 128
    """
    r = img_rgb[:, :, 0].astype(np.float64)
    g = img_rgb[:, :, 1].astype(np.float64)
    b = img_rgb[:, :, 2].astype(np.float64)

    y  =  0.299 * r + 0.587 * g + 0.114 * b
    cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128.0
    cr =  0.5 * r - 0.418688 * g - 0.081312 * b + 128.0

    return np.stack([y, cb, cr], axis=-1)


def subsample_422(ycbcr):
    """Subsample Cb and Cr horizontally by 2 (YUV422).
    Returns (Y, Cb, Cr) where Cb and Cr have half the width.
    """
    Y  = ycbcr[:, :, 0]
    Cb = ycbcr[:, :, 1]
    Cr = ycbcr[:, :, 2]
    # Average adjacent horizontal pairs for chroma
    Cb_sub = (Cb[:, 0::2] + Cb[:, 1::2]) / 2.0
    Cr_sub = (Cr[:, 0::2] + Cr[:, 1::2]) / 2.0
    return Y, Cb_sub, Cr_sub


# ============================================================================
# DCT
# ============================================================================

def forward_dct_block(block):
    """Apply forward 2D DCT to an 8x8 block.
    Uses matrix multiplication: DCT = C * block * C^T
    """
    return DCT_MATRIX @ block @ DCT_MATRIX.T


# ============================================================================
# Quantization
# ============================================================================

def quantize_block(dct_block, quant_table):
    """Quantize DCT coefficients by dividing by quantization table and rounding."""
    return np.round(dct_block / quant_table).astype(np.int32)


# ============================================================================
# Zigzag scan
# ============================================================================

def zigzag_scan(block_8x8):
    """Reorder 8x8 block into 1D zigzag order."""
    flat = block_8x8.flatten()
    return flat[ZIGZAG_ORDER]


# ============================================================================
# Bitstream writer
# ============================================================================

class BitstreamWriter:
    """Accumulates bits and outputs bytes with JPEG byte stuffing."""

    def __init__(self):
        self.data = bytearray()
        self.bit_buffer = 0
        self.bits_in_buffer = 0

    def write_bits(self, value, num_bits):
        """Write num_bits from value (MSB first) into the bitstream."""
        for i in range(num_bits - 1, -1, -1):
            bit = (value >> i) & 1
            self.bit_buffer = (self.bit_buffer << 1) | bit
            self.bits_in_buffer += 1
            if self.bits_in_buffer == 8:
                self._flush_byte()

    def _flush_byte(self):
        """Output one byte, with JPEG byte stuffing (0xFF -> 0xFF 0x00)."""
        byte_val = self.bit_buffer & 0xFF
        self.data.append(byte_val)
        if byte_val == 0xFF:
            self.data.append(0x00)
        self.bit_buffer = 0
        self.bits_in_buffer = 0

    def flush_to_byte(self):
        """Pad remaining bits with 1s to byte boundary (JPEG convention)."""
        if self.bits_in_buffer > 0:
            pad_bits = 8 - self.bits_in_buffer
            self.bit_buffer = (self.bit_buffer << pad_bits) | ((1 << pad_bits) - 1)
            self.bits_in_buffer = 8
            self._flush_byte()

    def get_bytes(self):
        return bytes(self.data)


# ============================================================================
# Huffman encoding of a single 8x8 block
# ============================================================================

def encode_block_dc(dc_diff, dc_table, bw):
    """Encode DC coefficient (differential) using Huffman table."""
    category, bit_pattern = encode_dc_value(dc_diff)
    # Write Huffman code for the category
    code_len, code_val = dc_table[category]
    bw.write_bits(code_val, code_len)
    # Write the actual value bits (if category > 0)
    if category > 0:
        bw.write_bits(bit_pattern, category)


def encode_block_ac(ac_coeffs, ac_table, bw):
    """Encode 63 AC coefficients using run-length + Huffman."""
    zero_run = 0
    for i in range(63):
        coeff = ac_coeffs[i]
        if coeff == 0:
            zero_run += 1
        else:
            # Emit ZRL (0xF0) for runs of 16+ zeros
            while zero_run >= 16:
                code_len, code_val = ac_table[0xF0]
                bw.write_bits(code_val, code_len)
                zero_run -= 16
            # Encode (run, size) symbol
            category = get_bit_category(coeff)
            symbol = (zero_run << 4) | category
            code_len, code_val = ac_table[symbol]
            bw.write_bits(code_val, code_len)
            # Write value bits
            if coeff < 0:
                bit_pattern = coeff + (1 << category) - 1
            else:
                bit_pattern = coeff
            bw.write_bits(bit_pattern, category)
            zero_run = 0

    # If trailing zeros, emit EOB
    if zero_run > 0:
        code_len, code_val = ac_table[0x00]  # EOB
        bw.write_bits(code_val, code_len)


# ============================================================================
# JFIF file structure
# ============================================================================

def write_u8(buf, val):
    buf.append(val & 0xFF)

def write_u16be(buf, val):
    buf.append((val >> 8) & 0xFF)
    buf.append(val & 0xFF)

def write_marker(buf, marker_id):
    buf.append(0xFF)
    buf.append(marker_id)


def build_jfif_header(width, height, quant_luma, quant_chroma):
    """Build JPEG file header bytes (everything before scan data)."""
    buf = bytearray()

    # --- SOI ---
    write_marker(buf, 0xD8)

    # --- APP0 (JFIF) ---
    write_marker(buf, 0xE0)
    app0_data = bytearray()
    write_u16be(app0_data, 16)          # Length
    app0_data.extend(b'JFIF\x00')      # Identifier
    app0_data.extend(b'\x01\x01')      # Version 1.1
    write_u8(app0_data, 0)              # Pixel aspect ratio units (0=no units)
    write_u16be(app0_data, 1)           # X density
    write_u16be(app0_data, 1)           # Y density
    write_u8(app0_data, 0)              # Thumbnail width
    write_u8(app0_data, 0)              # Thumbnail height
    buf.extend(app0_data)

    # --- DQT (Luminance, table 0) ---
    write_marker(buf, 0xDB)
    dqt_data = bytearray()
    write_u16be(dqt_data, 67)           # Length = 2 + 1 + 64
    write_u8(dqt_data, 0x00)            # 8-bit precision, table 0
    # Quantization table in zigzag order
    flat_luma = quant_luma.flatten()
    for idx in ZIGZAG_ORDER:
        write_u8(dqt_data, int(flat_luma[idx]))
    buf.extend(dqt_data)

    # --- DQT (Chrominance, table 1) ---
    write_marker(buf, 0xDB)
    dqt_data = bytearray()
    write_u16be(dqt_data, 67)
    write_u8(dqt_data, 0x01)            # 8-bit precision, table 1
    flat_chroma = quant_chroma.flatten()
    for idx in ZIGZAG_ORDER:
        write_u8(dqt_data, int(flat_chroma[idx]))
    buf.extend(dqt_data)

    # --- SOF0 (Start of Frame, Baseline DCT) ---
    write_marker(buf, 0xC0)
    sof_data = bytearray()
    # Length = 2 + 1 + 2 + 2 + 1 + 3*nComponents = 2+1+2+2+1+9 = 17
    write_u16be(sof_data, 17)
    write_u8(sof_data, 8)               # 8-bit precision
    write_u16be(sof_data, height)
    write_u16be(sof_data, width)
    write_u8(sof_data, 3)               # 3 components
    # Component 1 (Y): ID=1, sampling=2x1 (H=2, V=1), quant table 0
    write_u8(sof_data, 1)               # Component ID
    write_u8(sof_data, 0x21)            # 2 horizontal, 1 vertical
    write_u8(sof_data, 0)               # Quant table 0
    # Component 2 (Cb): ID=2, sampling=1x1, quant table 1
    write_u8(sof_data, 2)
    write_u8(sof_data, 0x11)
    write_u8(sof_data, 1)
    # Component 3 (Cr): ID=3, sampling=1x1, quant table 1
    write_u8(sof_data, 3)
    write_u8(sof_data, 0x11)
    write_u8(sof_data, 1)
    buf.extend(sof_data)

    # --- DHT (Huffman tables) ---
    # DC Luminance (class=0, id=0)
    _write_dht(buf, 0x00, DC_LUMA_BITS, DC_LUMA_VALS)
    # AC Luminance (class=1, id=0)
    _write_dht(buf, 0x10, AC_LUMA_BITS, AC_LUMA_VALS)
    # DC Chrominance (class=0, id=1)
    _write_dht(buf, 0x01, DC_CHROMA_BITS, DC_CHROMA_VALS)
    # AC Chrominance (class=1, id=1)
    _write_dht(buf, 0x11, AC_CHROMA_BITS, AC_CHROMA_VALS)

    # --- SOS (Start of Scan) ---
    write_marker(buf, 0xDA)
    sos_data = bytearray()
    # Length = 2 + 1 + nComponents*2 + 3 = 2+1+6+3 = 12
    write_u16be(sos_data, 12)
    write_u8(sos_data, 3)               # 3 components
    # Y: DC table 0, AC table 0
    write_u8(sos_data, 1)               # Component selector (Y)
    write_u8(sos_data, 0x00)            # DC=0, AC=0
    # Cb: DC table 1, AC table 1
    write_u8(sos_data, 2)
    write_u8(sos_data, 0x11)            # DC=1, AC=1
    # Cr: DC table 1, AC table 1
    write_u8(sos_data, 3)
    write_u8(sos_data, 0x11)
    # Spectral selection and successive approximation
    write_u8(sos_data, 0)               # Ss (start of spectral selection)
    write_u8(sos_data, 63)              # Se (end of spectral selection)
    write_u8(sos_data, 0)               # Ah=0, Al=0
    buf.extend(sos_data)

    return bytes(buf)


def _write_dht(buf, tc_th, bits, vals):
    """Write a DHT marker segment. tc_th = (table_class << 4) | table_id."""
    write_marker(buf, 0xC4)
    dht_data = bytearray()
    length = 2 + 1 + 16 + len(vals)
    write_u16be(dht_data, length)
    write_u8(dht_data, tc_th)
    for b in bits:
        write_u8(dht_data, b)
    for v in vals:
        write_u8(dht_data, v)
    buf.extend(dht_data)


# ============================================================================
# Main encoder function
# ============================================================================

def encode_jpeg(img_rgb, quality=85, output_path=None):
    """Encode an RGB image to JPEG with YUV422 subsampling.

    Args:
        img_rgb: numpy array (H, W, 3) uint8 RGB image
        quality: JPEG quality factor 1-100
        output_path: if set, write JPEG file to this path

    Returns:
        JPEG file bytes
    """
    height, width = img_rgb.shape[:2]
    assert width % 16 == 0, f"Width must be multiple of 16, got {width}"
    assert height % 8 == 0, f"Height must be multiple of 8, got {height}"

    # Scale quantization tables
    quant_luma = scale_quant_table(STD_QUANT_TABLE_LUMA, quality)
    quant_chroma = scale_quant_table(STD_QUANT_TABLE_CHROMA, quality)

    # Color space conversion
    ycbcr = rgb_to_ycbcr(img_rgb)

    # Chroma subsampling (422)
    Y, Cb, Cr = subsample_422(ycbcr)

    # Build JFIF header
    header = build_jfif_header(width, height, quant_luma, quant_chroma)

    # Encode scan data
    bw = BitstreamWriter()

    # Previous DC values for differential coding (one per component)
    prev_dc_y = 0
    prev_dc_cb = 0
    prev_dc_cr = 0

    # Process MCUs: each MCU is 16 pixels wide, 8 pixels tall
    mcu_rows = height // 8
    mcu_cols = width // 16

    for mcu_row in range(mcu_rows):
        for mcu_col in range(mcu_cols):
            # Extract Y blocks (two 8x8 blocks side by side)
            y_row = mcu_row * 8
            y_col = mcu_col * 16

            # Y block 0 (left)
            y_block0 = Y[y_row:y_row+8, y_col:y_col+8] - 128.0
            # Y block 1 (right)
            y_block1 = Y[y_row:y_row+8, y_col+8:y_col+16] - 128.0

            # Cb and Cr blocks (already subsampled, so 8 pixels = one block)
            cb_col = mcu_col * 8
            cb_block = Cb[y_row:y_row+8, cb_col:cb_col+8] - 128.0
            cr_block = Cr[y_row:y_row+8, cb_col:cb_col+8] - 128.0

            # Process Y block 0
            dct0 = forward_dct_block(y_block0)
            quant0 = quantize_block(dct0, quant_luma)
            zz0 = zigzag_scan(quant0)
            dc_diff = int(zz0[0]) - prev_dc_y
            prev_dc_y = int(zz0[0])
            encode_block_dc(dc_diff, DC_LUMA_TABLE, bw)
            encode_block_ac(zz0[1:], AC_LUMA_TABLE, bw)

            # Process Y block 1
            dct1 = forward_dct_block(y_block1)
            quant1 = quantize_block(dct1, quant_luma)
            zz1 = zigzag_scan(quant1)
            dc_diff = int(zz1[0]) - prev_dc_y
            prev_dc_y = int(zz1[0])
            encode_block_dc(dc_diff, DC_LUMA_TABLE, bw)
            encode_block_ac(zz1[1:], AC_LUMA_TABLE, bw)

            # Process Cb block
            dct_cb = forward_dct_block(cb_block)
            quant_cb = quantize_block(dct_cb, quant_chroma)
            zz_cb = zigzag_scan(quant_cb)
            dc_diff = int(zz_cb[0]) - prev_dc_cb
            prev_dc_cb = int(zz_cb[0])
            encode_block_dc(dc_diff, DC_CHROMA_TABLE, bw)
            encode_block_ac(zz_cb[1:], AC_CHROMA_TABLE, bw)

            # Process Cr block
            dct_cr = forward_dct_block(cr_block)
            quant_cr = quantize_block(dct_cr, quant_chroma)
            zz_cr = zigzag_scan(quant_cr)
            dc_diff = int(zz_cr[0]) - prev_dc_cr
            prev_dc_cr = int(zz_cr[0])
            encode_block_dc(dc_diff, DC_CHROMA_TABLE, bw)
            encode_block_ac(zz_cr[1:], AC_CHROMA_TABLE, bw)

    # Flush remaining bits
    bw.flush_to_byte()

    # Assemble final JPEG
    scan_data = bw.get_bytes()
    eoi = bytes([0xFF, 0xD9])
    jpeg_bytes = header + scan_data + eoi

    if output_path:
        with open(output_path, 'wb') as f:
            f.write(jpeg_bytes)
        print(f"JPEG written to {output_path} ({len(jpeg_bytes)} bytes)")

    return jpeg_bytes


if __name__ == "__main__":
    # Quick self-test with a synthetic gradient image
    print("Creating 1280x720 test gradient...")
    img = np.zeros((720, 1280, 3), dtype=np.uint8)
    for y in range(720):
        for x in range(1280):
            img[y, x, 0] = (x * 255 // 1280) & 0xFF
            img[y, x, 1] = (y * 255 // 720) & 0xFF
            img[y, x, 2] = ((x + y) * 255 // 2000) & 0xFF

    encode_jpeg(img, quality=85, output_path="test_gradient.jpg")
    print("Done. Check test_gradient.jpg with any image viewer or FFmpeg.")
