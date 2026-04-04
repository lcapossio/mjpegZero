#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
EXIF metadata RTL simulation test.

Compiles mjpegZero with EXIF_ENABLE=1 via iverilog, runs the simulation,
and validates the APP1/EXIF segment in the output JPEG byte-by-byte.

Checks performed:
  1. SOI marker present (FF D8)
  2. APP0 JFIF marker present (FF E0) at byte 2
  3. APP1 EXIF marker present (FF E1) immediately after APP0 (byte 20)
  4. APP1 "Exif\\0\\0" identifier at correct offset
  5. TIFF little-endian header ("II" + 0x002A)
  6. IFD0 entry count = 3
  7. XResolution tag (0x011A) with correct RATIONAL value = EXIF_X_RES/1
  8. YResolution tag (0x011B) with correct RATIONAL value = EXIF_Y_RES/1
  9. ResolutionUnit tag (0x0128) with correct SHORT value = EXIF_RES_UNIT
 10. EOI marker present (FF D9)

Usage:
    python python/verify_exif.py [--lite] [--x-res N] [--y-res N] [--res-unit N]

Exit code: 0 = PASS, 1 = FAIL
"""

import argparse
import os
import shutil
import struct
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR   = os.path.dirname(SCRIPT_DIR)
RTL_DIR    = os.path.join(PROJ_DIR, 'rtl')
SIM_DIR    = os.path.join(PROJ_DIR, 'sim')
BUILD_DIR  = os.path.join(PROJ_DIR, 'build', 'sim_exif')
TV_DIR     = os.path.join(SIM_DIR, 'test_vectors')

_CORE_RTL = [
    'vendor/sim/bram_sdp.v',
    'dct_1d.v', 'dct_2d.v', 'input_buffer.v', 'quantizer.v',
    'zigzag_reorder.v', 'huffman_encoder.v', 'bitstream_packer.v',
    'jfif_writer.v', 'axi4_lite_regs.v', 'mjpegzero_enc_top.v',
]

APP0_SIZE   = 20   # SOI(2) + marker(2) + length(2) + "JFIF\0"(5) + rest
APP1_OFFSET = APP0_SIZE   # APP1 starts right after APP0


def find_tool(name):
    return shutil.which(name)


def compile_rtl(iverilog, vvp_out, defines):
    rtl_files = [os.path.join(RTL_DIR, f) for f in _CORE_RTL]
    rtl_files.append(os.path.join(SIM_DIR, 'tb_iverilog.sv'))
    def_flags = [f'-D{k}={v}' for k, v in defines.items()]
    cmd = [iverilog, '-g2012', '-o', vvp_out] + def_flags + rtl_files
    print('  Compiling: ' + ' '.join(def_flags))
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=PROJ_DIR)
    if result.stdout:
        print(result.stdout)
    if result.returncode != 0:
        print('ERROR: iverilog compilation failed:')
        print(result.stderr)
        return False
    return True


def run_sim(vvp, vvp_out, build_dir, output_jpg):
    cmd = [vvp, vvp_out]
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=build_dir)
    if result.stdout:
        print(result.stdout)
    if result.returncode != 0:
        print('ERROR: simulation failed:')
        print(result.stderr)
        return False
    # tb_iverilog.sv writes sim_output.jpg in cwd
    src = os.path.join(build_dir, 'sim_output.jpg')
    if not os.path.exists(src):
        print(f'ERROR: simulation did not produce {src}')
        return False
    shutil.copy2(src, output_jpg)
    return True


def u16be(data, off):
    """Big-endian uint16 — used for JPEG marker length fields."""
    return struct.unpack_from('>H', data, off)[0]


def u16le(data, off):
    """Little-endian uint16 — used for TIFF/EXIF fields."""
    return struct.unpack_from('<H', data, off)[0]


def u32le(data, off):
    return struct.unpack_from('<I', data, off)[0]


def validate_exif(jpeg_path, exif_x_res, exif_y_res, exif_res_unit):
    """
    Parse the JPEG and validate the APP1/EXIF segment.
    Returns list of (check_name, passed, detail) tuples.
    """
    results = []

    def check(name, cond, detail=''):
        results.append((name, cond, detail))
        status = 'PASS' if cond else 'FAIL'
        print(f'  [{status}] {name}' + (f': {detail}' if detail else ''))
        return cond

    if not os.path.exists(jpeg_path):
        check('file_exists', False, jpeg_path)
        return results

    with open(jpeg_path, 'rb') as f:
        data = f.read()

    sz = len(data)
    check('file_non_empty', sz > 0, f'{sz} bytes')

    # 1. SOI
    check('SOI_marker', sz >= 2 and data[0] == 0xFF and data[1] == 0xD8,
          f'byte[0:2]={data[0]:02X}{data[1]:02X}' if sz >= 2 else 'truncated')

    # 2. APP0
    ok = sz >= 6 and data[2] == 0xFF and data[3] == 0xE0
    check('APP0_marker', ok,
          f'byte[2:4]={data[2]:02X}{data[3]:02X}' if sz >= 4 else 'truncated')
    if not ok:
        # No APP0 — EXIF tests won't be meaningful
        return results

    # JPEG marker lengths are big-endian and include the 2 length bytes themselves
    app0_len = u16be(data, 4) if sz >= 6 else 0
    actual_app1_offset = 2 + 2 + app0_len   # SOI(2) + marker(2) + APP0_content(app0_len)

    # 3. APP1 marker
    a1 = actual_app1_offset
    ok = sz > a1 + 3 and data[a1] == 0xFF and data[a1 + 1] == 0xE1
    check('APP1_marker', ok,
          f'at byte {a1}: {data[a1]:02X}{data[a1+1]:02X}' if sz > a1 + 1 else 'truncated')
    if not ok:
        return results

    # APP1 length (big-endian, includes 2 bytes for the length field itself)
    app1_len   = u16be(data, a1 + 2)
    app1_end   = a1 + 2 + app1_len   # exclusive end of APP1 content
    check('APP1_length', app1_len == 74, f'got {app1_len}, expected 74')

    # 4. "Exif\0\0" identifier (6 bytes starting at a1+4)
    exif_id = data[a1 + 4: a1 + 10]
    check('Exif_identifier', exif_id == b'Exif\x00\x00',
          f'got {exif_id.hex()}')

    # 5. TIFF LE header at a1+10: "II" + 0x002A + IFD0 offset
    tiff_base = a1 + 10
    check('TIFF_LE_byte_order', data[tiff_base] == 0x49 and data[tiff_base + 1] == 0x49,
          f'got {data[tiff_base]:02X}{data[tiff_base+1]:02X}')
    check('TIFF_magic', u16le(data, tiff_base + 2) == 42,
          f'got {u16le(data, tiff_base+2)}')
    ifd0_offset = u32le(data, tiff_base + 4)
    check('TIFF_IFD0_offset', ifd0_offset == 8, f'got {ifd0_offset}')

    # 6. IFD0 entry count
    ifd0_abs  = tiff_base + ifd0_offset
    entry_cnt = u16le(data, ifd0_abs)
    check('IFD0_entry_count', entry_cnt == 3, f'got {entry_cnt}')

    # Parse IFD0 entries: each is 12 bytes at ifd0_abs+2
    entries = {}
    for i in range(min(entry_cnt, 8)):
        e_off = ifd0_abs + 2 + i * 12
        if e_off + 12 > len(data):
            break
        tag    = u16le(data, e_off)
        etype  = u16le(data, e_off + 2)
        ecount = u32le(data, e_off + 4)
        value_raw = data[e_off + 8: e_off + 12]
        entries[tag] = (etype, ecount, value_raw)

    # 7. XResolution (tag 0x011A)
    if 0x011A in entries:
        etype, ecount, vraw = entries[0x011A]
        check('XResolution_type',  etype  == 5, f'RATIONAL(5) expected, got {etype}')
        check('XResolution_count', ecount == 1, f'got {ecount}')
        rat_off = tiff_base + u32le(data, ifd0_abs + 2 + 0 * 12 + 8)
        if rat_off + 8 <= len(data):
            num = u32le(data, rat_off)
            den = u32le(data, rat_off + 4)
            check('XResolution_value', num == exif_x_res and den == 1,
                  f'got {num}/{den}, expected {exif_x_res}/1')
        else:
            check('XResolution_value', False, 'offset out of range')
    else:
        check('XResolution_present', False, 'tag 0x011A missing')

    # 8. YResolution (tag 0x011B)
    if 0x011B in entries:
        etype, ecount, vraw = entries[0x011B]
        check('YResolution_type',  etype  == 5, f'RATIONAL(5) expected, got {etype}')
        check('YResolution_count', ecount == 1, f'got {ecount}')
        rat_off = tiff_base + u32le(data, ifd0_abs + 2 + 1 * 12 + 8)
        if rat_off + 8 <= len(data):
            num = u32le(data, rat_off)
            den = u32le(data, rat_off + 4)
            check('YResolution_value', num == exif_y_res and den == 1,
                  f'got {num}/{den}, expected {exif_y_res}/1')
        else:
            check('YResolution_value', False, 'offset out of range')
    else:
        check('YResolution_present', False, 'tag 0x011B missing')

    # 9. ResolutionUnit (tag 0x0128)
    if 0x0128 in entries:
        etype, ecount, vraw = entries[0x0128]
        check('ResolutionUnit_type',  etype  == 3, f'SHORT(3) expected, got {etype}')
        check('ResolutionUnit_count', ecount == 1, f'got {ecount}')
        unit_val = u16le(vraw, 0)
        check('ResolutionUnit_value', unit_val == exif_res_unit,
              f'got {unit_val}, expected {exif_res_unit}')
    else:
        check('ResolutionUnit_present', False, 'tag 0x0128 missing')

    # 10. EOI
    check('EOI_marker', sz >= 2 and data[-2] == 0xFF and data[-1] == 0xD9,
          f'last 2 bytes: {data[-2]:02X}{data[-1]:02X}' if sz >= 2 else 'truncated')

    return results


def main():
    parser = argparse.ArgumentParser(description='EXIF metadata RTL simulation test')
    parser.add_argument('--lite',     action='store_true',
                        help='Use LITE_MODE=1 (default: full mode)')
    parser.add_argument('--x-res',   type=int, default=72,
                        help='EXIF X resolution (default: 72)')
    parser.add_argument('--y-res',   type=int, default=72,
                        help='EXIF Y resolution (default: 72)')
    parser.add_argument('--res-unit', type=int, default=2,
                        help='EXIF resolution unit: 1=none 2=inch 3=cm (default: 2)')
    args = parser.parse_args()

    iverilog = find_tool('iverilog')
    vvp      = find_tool('vvp')
    if not iverilog:
        print('ERROR: iverilog not found in PATH')
        return 1
    if not vvp:
        print('ERROR: vvp not found in PATH')
        return 1

    os.makedirs(BUILD_DIR, exist_ok=True)

    # Ensure test vectors exist
    tv_file = os.path.join(TV_DIR, 'yuyv_input.hex')
    if not os.path.isfile(tv_file):
        print('Generating test vectors...')
        gen = os.path.join(SCRIPT_DIR, 'generate_test_vectors.py')
        r = subprocess.run([sys.executable, gen], capture_output=True, text=True)
        if r.returncode != 0:
            print(f'ERROR: generate_test_vectors.py failed:\n{r.stderr}')
            return 1

    # Copy test vectors into build dir (testbench expects relative path)
    tv_dst = os.path.join(BUILD_DIR, 'test_vectors')
    os.makedirs(tv_dst, exist_ok=True)
    src_tv = os.path.join(TV_DIR, 'yuyv_input.hex')
    dst_tv = os.path.join(tv_dst, 'yuyv_input.hex')
    if not os.path.exists(dst_tv):
        shutil.copy2(src_tv, dst_tv)

    mode_str = 'LITE' if args.lite else 'FULL'
    print('=' * 65)
    print(f'EXIF Metadata Test  [EXIF_ENABLE=1, {mode_str}_MODE]')
    print(f'EXIF_X_RES={args.x_res}  EXIF_Y_RES={args.y_res}  EXIF_RES_UNIT={args.res_unit}')
    print('=' * 65)

    defines = {
        'EXIF_ENABLE':   1,
        'EXIF_X_RES':    args.x_res,
        'EXIF_Y_RES':    args.y_res,
        'EXIF_RES_UNIT': args.res_unit,
        'TEST_QUALITY':  95,
    }
    if args.lite:
        defines['LITE_MODE']    = 1
        defines['LITE_QUALITY'] = 95

    vvp_out    = os.path.join(BUILD_DIR, 'sim_exif.vvp')
    output_jpg = os.path.join(BUILD_DIR, 'sim_exif_output.jpg')

    if not compile_rtl(iverilog, vvp_out, defines):
        return 1

    if not run_sim(vvp, vvp_out, BUILD_DIR, output_jpg):
        return 1

    print(f'\nValidating EXIF in {output_jpg} ...')
    checks = validate_exif(output_jpg, args.x_res, args.y_res, args.res_unit)

    total  = len(checks)
    passed = sum(1 for _, ok, _ in checks if ok)
    failed = total - passed

    print(f'\n{"=" * 65}')
    print(f'EXIF validation: {passed}/{total} checks passed')
    if failed:
        print('Failed checks:')
        for name, ok, detail in checks:
            if not ok:
                print(f'  FAIL: {name}: {detail}')
    print(f'{"=" * 65}')
    print(f'RESULT: {"PASS" if failed == 0 else "FAIL"}')
    print(f'{"=" * 65}')

    return 0 if failed == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
