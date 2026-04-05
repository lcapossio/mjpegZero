# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Generate test vectors for RTL verification.
Exports intermediate pipeline values as hex files readable by $readmemh.
"""

import os
import sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from jpeg_common import (
    STD_QUANT_TABLE_LUMA, STD_QUANT_TABLE_CHROMA, scale_quant_table,
    ZIGZAG_ORDER, DCT_MATRIX,
    DC_LUMA_TABLE, DC_CHROMA_TABLE, AC_LUMA_TABLE, AC_CHROMA_TABLE,
    get_bit_category, encode_dc_value,
)
from jpeg_encoder import rgb_to_ycbcr, subsample_422, forward_dct_block, quantize_block, zigzag_scan
from yuyv_convert import rgb_array_to_yuyv_words, write_yuyv_hex


def to_signed_hex(val, bits=16):
    """Convert signed integer to hex string (two's complement)."""
    if val < 0:
        val = val + (1 << bits)
    return f"{val & ((1 << bits) - 1):0{bits // 4}X}"


def write_hex_file(filename, data, bits=16):
    """Write array of integers as hex file for $readmemh."""
    with open(filename, 'w') as f:
        for val in data:
            f.write(to_signed_hex(int(val), bits) + '\n')


def write_block_hex(filename, blocks, bits=16):
    """Write list of 8x8 blocks as hex file (each block = 64 values)."""
    with open(filename, 'w') as f:
        for block in blocks:
            flat = block.flatten()
            for val in flat:
                f.write(to_signed_hex(int(val), bits) + '\n')


def main():
    quality = 95
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sim', 'test_vectors')
    os.makedirs(out_dir, exist_ok=True)

    # Load test image
    img_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_images', 'mandrill_720p.png')
    if not os.path.exists(img_path):
        print(f"ERROR: Test image not found at {img_path}")
        print("Run test_encoder.py first to download it.")
        sys.exit(1)

    img_rgb = np.array(Image.open(img_path).convert('RGB'))
    height, width = img_rgb.shape[:2]
    print(f"Image: {width}x{height}")

    # Scale quant tables
    quant_luma = scale_quant_table(STD_QUANT_TABLE_LUMA, quality)
    quant_chroma = scale_quant_table(STD_QUANT_TABLE_CHROMA, quality)

    # Export quantization tables
    write_hex_file(os.path.join(out_dir, 'quant_luma.hex'), quant_luma.flatten(), bits=8)
    write_hex_file(os.path.join(out_dir, 'quant_chroma.hex'), quant_chroma.flatten(), bits=8)
    print("Exported quantization tables")

    # Color conversion
    ycbcr = rgb_to_ycbcr(img_rgb)
    Y, Cb, Cr = subsample_422(ycbcr)

    # Process first few MCUs for test vectors (not entire frame)
    num_test_mcus = 4  # First 4 MCUs for tractable test vector size
    mcu_cols = width // 16

    y_blocks_raw = []      # Level-shifted 8x8 blocks (input to DCT)
    cb_blocks_raw = []
    cr_blocks_raw = []
    dct_blocks_y = []      # DCT output
    dct_blocks_cb = []
    dct_blocks_cr = []
    quant_blocks_y = []    # Quantized
    quant_blocks_cb = []
    quant_blocks_cr = []
    zigzag_y = []          # Zigzag-scanned
    zigzag_cb = []
    zigzag_cr = []

    mcu_count = 0
    for mcu_row in range(height // 8):
        for mcu_col in range(mcu_cols):
            if mcu_count >= num_test_mcus:
                break

            y_row = mcu_row * 8
            y_col = mcu_col * 16
            cb_col = mcu_col * 8

            # Y blocks (2 per MCU)
            for blk_offset in [0, 8]:
                block = Y[y_row:y_row+8, y_col+blk_offset:y_col+blk_offset+8] - 128.0
                y_blocks_raw.append(block.copy())
                dct = forward_dct_block(block)
                dct_blocks_y.append(dct.copy())
                q = quantize_block(dct, quant_luma)
                quant_blocks_y.append(q.copy())
                zz = zigzag_scan(q)
                zigzag_y.append(zz.copy())

            # Cb block
            block = Cb[y_row:y_row+8, cb_col:cb_col+8] - 128.0
            cb_blocks_raw.append(block.copy())
            dct = forward_dct_block(block)
            dct_blocks_cb.append(dct.copy())
            q = quantize_block(dct, quant_chroma)
            quant_blocks_cb.append(q.copy())
            zz = zigzag_scan(q)
            zigzag_cb.append(zz.copy())

            # Cr block
            block = Cr[y_row:y_row+8, cb_col:cb_col+8] - 128.0
            cr_blocks_raw.append(block.copy())
            dct = forward_dct_block(block)
            dct_blocks_cr.append(dct.copy())
            q = quantize_block(dct, quant_chroma)
            quant_blocks_cr.append(q.copy())
            zz = zigzag_scan(q)
            zigzag_cr.append(zz.copy())

            mcu_count += 1

        if mcu_count >= num_test_mcus:
            break

    # Write test vectors
    # Input pixels (8-bit unsigned, before level shift, so +128)
    write_block_hex(os.path.join(out_dir, 'input_y_blocks.hex'),
                    [b + 128 for b in y_blocks_raw], bits=8)
    write_block_hex(os.path.join(out_dir, 'input_cb_blocks.hex'),
                    [b + 128 for b in cb_blocks_raw], bits=8)
    write_block_hex(os.path.join(out_dir, 'input_cr_blocks.hex'),
                    [b + 128 for b in cr_blocks_raw], bits=8)
    print(f"Exported {len(y_blocks_raw)} Y blocks, {len(cb_blocks_raw)} Cb/Cr blocks (input)")

    # DCT output (16-bit signed, scaled to fixed point)
    # RTL will use fixed-point with ~3 fractional bits, so scale DCT by 8
    write_block_hex(os.path.join(out_dir, 'dct_y_blocks.hex'),
                    [np.round(b).astype(np.int32) for b in dct_blocks_y], bits=16)
    write_block_hex(os.path.join(out_dir, 'dct_cb_blocks.hex'),
                    [np.round(b).astype(np.int32) for b in dct_blocks_cb], bits=16)
    write_block_hex(os.path.join(out_dir, 'dct_cr_blocks.hex'),
                    [np.round(b).astype(np.int32) for b in dct_blocks_cr], bits=16)
    print(f"Exported DCT blocks")

    # Quantized (16-bit signed)
    write_block_hex(os.path.join(out_dir, 'quant_y_blocks.hex'), quant_blocks_y, bits=16)
    write_block_hex(os.path.join(out_dir, 'quant_cb_blocks.hex'), quant_blocks_cb, bits=16)
    write_block_hex(os.path.join(out_dir, 'quant_cr_blocks.hex'), quant_blocks_cr, bits=16)
    print(f"Exported quantized blocks")

    # Zigzag (16-bit signed, 64 values per block in zigzag order)
    write_block_hex(os.path.join(out_dir, 'zigzag_y.hex'), [z.reshape(8,8) for z in zigzag_y], bits=16)
    write_block_hex(os.path.join(out_dir, 'zigzag_cb.hex'), [z.reshape(8,8) for z in zigzag_cb], bits=16)
    write_block_hex(os.path.join(out_dir, 'zigzag_cr.hex'), [z.reshape(8,8) for z in zigzag_cr], bits=16)
    print(f"Exported zigzag blocks")

    # Export DCT matrix coefficients (for RTL fixed-point implementation)
    # Scale by 2^12 = 4096 for 12-bit fixed point
    DCT_SCALE = 12
    dct_fixed = np.round(DCT_MATRIX * (1 << DCT_SCALE)).astype(np.int32)
    write_block_hex(os.path.join(out_dir, 'dct_matrix.hex'), [dct_fixed], bits=16)
    print(f"Exported DCT matrix (fixed point, scale=2^{DCT_SCALE})")

    # Export quantization reciprocals for RTL (multiply instead of divide)
    # reciprocal = round(2^16 / Q)
    RECIP_SCALE = 16
    recip_luma = np.round((1 << RECIP_SCALE) / quant_luma.astype(np.float64)).astype(np.int32)
    recip_chroma = np.round((1 << RECIP_SCALE) / quant_chroma.astype(np.float64)).astype(np.int32)
    write_hex_file(os.path.join(out_dir, 'quant_recip_luma.hex'), recip_luma.flatten(), bits=16)
    write_hex_file(os.path.join(out_dir, 'quant_recip_chroma.hex'), recip_chroma.flatten(), bits=16)
    print(f"Exported quantization reciprocals (scale=2^{RECIP_SCALE})")

    # Export the full encoded JPEG for the test MCUs (golden reference bitstream)
    from jpeg_encoder import encode_jpeg
    # Use a small test crop (first 4 MCUs = 64x8 pixels) for bitstream comparison
    crop = img_rgb[0:8, 0:64, :]  # 4 MCUs wide, 1 MCU tall
    jpeg_data = encode_jpeg(crop, quality=quality, output_path=os.path.join(out_dir, 'reference_4mcu.jpg'))
    # Write as hex bytes
    with open(os.path.join(out_dir, 'reference_4mcu_bytes.hex'), 'w') as f:
        for b in jpeg_data:
            f.write(f"{b:02X}\n")
    print(f"Exported reference JPEG for {num_test_mcus} MCUs ({len(jpeg_data)} bytes)")

    # Generate reference JPEGs for other quality levels used by verify_rtl_sim.py
    for extra_q in [50, 75]:
        extra_data = encode_jpeg(crop, quality=extra_q,
                                 output_path=os.path.join(out_dir, f'reference_4mcu_q{extra_q}.jpg'))
        print(f"Exported reference JPEG Q={extra_q} ({len(extra_data)} bytes)")

    # Export zigzag order lookup for RTL
    write_hex_file(os.path.join(out_dir, 'zigzag_lut.hex'), ZIGZAG_ORDER, bits=8)
    print("Exported zigzag LUT")

    # ========================================================================
    # Export YUYV scanline data for RTL testbench (shared conversion)
    # ========================================================================
    crop_rgb = img_rgb[0:8, 0:64, :]
    crop_words, _, _ = rgb_array_to_yuyv_words(crop_rgb)
    write_yuyv_hex(crop_words, os.path.join(out_dir, 'yuyv_input.hex'))
    print(f"Exported YUYV input data ({len(crop_words)} words) for 64x8 crop")

    # Full 720p YUYV for tb_mjpegzero_enc.sv (Vivado xsim Tier 3 sim)
    full_words, fh, fw = rgb_array_to_yuyv_words(img_rgb)
    write_yuyv_hex(full_words, os.path.join(out_dir, 'yuyv_720p.hex'))
    print(f"Exported 720p YUYV ({len(full_words)} words = {fw}x{fh})")

    # ========================================================================
    # Synthetic test vectors for coverage improvement
    # ========================================================================

    # Flat gray 64x8 — all pixels Y=128, Cb=128, Cr=128.
    # After level-shift and DCT: only DC coefficient is non-zero, all 63 AC
    # coefficients are 0 → Huffman emits EOB immediately, exercising the
    # DC-only / EOB-only path in huffman_encoder.
    flat_rgb = np.full((8, 64, 3), 128, dtype=np.uint8)
    flat_words, _, _ = rgb_array_to_yuyv_words(flat_rgb)
    write_yuyv_hex(flat_words, os.path.join(out_dir, 'yuyv_flat.hex'))
    print(f"Exported flat-gray YUYV ({len(flat_words)} words) for DC/EOB coverage")

    # Checkerboard 64x8 — Y alternates 0/255 per pixel, Cb=128, Cr=128.
    # After DCT + quantization the energy lands at zigzag position 63
    # (highest-frequency coefficient), leaving 62 leading zero ACs.
    # Huffman emits 3× ZRL (0xF0) codes followed by 1 non-zero, exercising
    # the ZRL emission path in huffman_encoder.
    checker_rgb = np.zeros((8, 64, 3), dtype=np.uint8)
    for row in range(8):
        for col in range(64):
            luma = 255 if (row + col) % 2 == 0 else 0
            checker_rgb[row, col] = [luma, 128, 128]
    checker_words, _, _ = rgb_array_to_yuyv_words(checker_rgb)
    write_yuyv_hex(checker_words, os.path.join(out_dir, 'yuyv_checker.hex'))
    print(f"Exported checkerboard YUYV ({len(checker_words)} words) for ZRL coverage")

    # ========================================================================
    # RGB 24-bit hex for RGB_INPUT=1 testbench path
    # ========================================================================
    # One 24-bit word per pixel: {R[23:16], G[15:8], B[7:0]}
    def write_rgb_hex(rgb_array, out_path):
        """Write RGB uint8 array as 24-bit hex file for $readmemh."""
        h, w = rgb_array.shape[:2]
        with open(out_path, 'w') as f:
            for row in range(h):
                for col in range(w):
                    r, g, b = int(rgb_array[row, col, 0]), int(rgb_array[row, col, 1]), int(rgb_array[row, col, 2])
                    f.write(f"{(r << 16) | (g << 8) | b:06X}\n")
        return h * w

    n = write_rgb_hex(crop_rgb, os.path.join(out_dir, 'rgb_input.hex'))
    print(f"Exported RGB input data ({n} words) for 64x8 crop (RGB_INPUT=1 path)")

    # ========================================================================
    # Minimum-width 16x8 crop (1 MCU) — corner case for MCU column counter
    # ========================================================================
    min_crop_rgb = img_rgb[0:8, 0:16, :]
    min_words, _, _ = rgb_array_to_yuyv_words(min_crop_rgb)
    write_yuyv_hex(min_words, os.path.join(out_dir, 'yuyv_16x8.hex'))
    print(f"Exported 16x8 YUYV ({len(min_words)} words) for minimum-width corner case")

    # Reference JPEG for the 16x8 crop
    min_jpeg = encode_jpeg(min_crop_rgb, quality=quality,
                           output_path=os.path.join(out_dir, 'reference_1mcu.jpg'))
    with open(os.path.join(out_dir, 'reference_1mcu_bytes.hex'), 'w') as f:
        for b in min_jpeg:
            f.write(f"{b:02X}\n")
    print(f"Exported reference JPEG for 1 MCU ({len(min_jpeg)} bytes)")

    print(f"\nAll test vectors written to: {out_dir}")
    print(f"Total MCUs: {mcu_count}")


if __name__ == "__main__":
    main()
