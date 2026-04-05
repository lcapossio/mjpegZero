#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
RTL simulation + golden verification using iverilog / vvp.

Compiles the mjpegZero RTL with the behavioral bram_sdp, runs the
CI testbench (sim/tb_iverilog.sv), captures sim_output.jpg, and compares
it coefficient-by-coefficient against the Python reference JPEG.

Tests run per mode:
  Full mode (LITE_MODE=0):  Q=50, Q=75, Q=95  — runtime AXI quality write
  Lite mode (LITE_MODE=1):  LITE_QUALITY=50, 75, 95 — compile-time tables

Pass criterion (per quality):
  - All 4 structural checks pass (SOI, EOI, size, output present)
  - All 16 DCT blocks decoded (4 MCUs x 4 blocks each)
  - Max coefficient difference <= 1  (expected fixed-point rounding tolerance)

Exit code: 0 = all PASS, 1 = any FAIL
"""

import argparse
import os
import sys
import shutil
import subprocess

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR   = os.path.dirname(SCRIPT_DIR)
RTL_DIR    = os.path.join(PROJ_DIR, 'rtl')
SIM_DIR    = os.path.join(PROJ_DIR, 'sim')
BUILD_DIR  = os.path.join(PROJ_DIR, 'build', 'sim_iverilog')
TV_DIR     = os.path.join(SIM_DIR, 'test_vectors')

NUM_MCUS       = 4
MAX_COEFF_DIFF = 1   # JPEG fixed-point rounding tolerance

# Quality levels to exercise; Q=95 reference is the committed file,
# others are also committed under reference_4mcu_q<Q>.jpg
TEST_QUALITIES = [50, 75, 95]


def reference_path(quality):
    if quality == 95:
        return os.path.join(TV_DIR, 'reference_4mcu.jpg')
    return os.path.join(TV_DIR, f'reference_4mcu_q{quality}.jpg')


# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------
def find_tool(name):
    exe = shutil.which(name)
    if exe:
        return exe
    for prefix in ('/usr/bin', '/usr/local/bin'):
        cand = os.path.join(prefix, name)
        if os.path.isfile(cand):
            return cand
    return None


def find_vivado_unisims():
    """
    Return (glbl_v, unisims_dir) if a Vivado installation can be found, else
    (None, None).  Searches PATH first, then common install roots on Windows
    and Linux.
    """
    import platform

    # Try PATH first
    vivado_exe = shutil.which('vivado') or shutil.which('vivado.bat')

    if not vivado_exe:
        # Common roots, newest-version-first heuristic
        if platform.system() == 'Windows':
            roots = [r'C:\AMDDesignTools', r'C:\Xilinx',
                     r'C:\Program Files\Xilinx', r'D:\AMDDesignTools']
        else:
            roots = ['/tools/Xilinx', '/opt/Xilinx', '/opt/AMD', '/tools/AMD']
        for root in roots:
            if not os.path.isdir(root):
                continue
            for ver in sorted(os.listdir(root), reverse=True):
                for sub in ('Vivado', ''):
                    cand = os.path.join(root, ver, sub, 'bin', 'vivado')
                    if os.path.isfile(cand) or os.path.isfile(cand + '.bat'):
                        vivado_exe = cand
                        break
                if vivado_exe:
                    break
            if vivado_exe:
                break

    if not vivado_exe:
        return None, None

    vivado_root = os.path.dirname(os.path.dirname(
        os.path.realpath(vivado_exe.rstrip('.bat'))))
    glbl     = os.path.join(vivado_root, 'data', 'verilog', 'src', 'glbl.v')
    unisims  = os.path.join(vivado_root, 'data', 'verilog', 'src', 'unisims')
    if os.path.isfile(glbl) and os.path.isdir(unisims):
        return glbl, unisims
    return None, None


# ---------------------------------------------------------------------------
# RTL source list builders
# ---------------------------------------------------------------------------
_CORE_RTL = [
    'dct_1d.v', 'dct_2d.v', 'input_buffer.v', 'quantizer.v',
    'zigzag_reorder.v', 'huffman_encoder.v', 'bitstream_packer.v',
    'jfif_writer.v', 'axi4_lite_regs.v', 'rgb_to_ycbcr.v',
    'mjpegzero_enc_top.v',
]


def build_rtl_filelist(unisims_dir=None):
    """
    Return the ordered list of source files for iverilog.

    unisims_dir=None  → use the behavioural sim BRAM wrapper (default / CI)
    unisims_dir=<dir> → prepend glbl.v + RAMB36E1.v and use the AMD BRAM
                        wrapper (real Xilinx primitive model, local only)
    """
    files = []
    if unisims_dir:
        glbl_v = os.path.join(os.path.dirname(unisims_dir), 'glbl.v')
        ramb   = os.path.join(unisims_dir, 'RAMB36E1.v')
        files += [glbl_v, ramb,
                  os.path.join(RTL_DIR, 'vendor', 'amd', 'bram_sdp.v')]
    else:
        files.append(os.path.join(RTL_DIR, 'vendor', 'sim', 'bram_sdp.v'))
    files += [os.path.join(RTL_DIR, f) for f in _CORE_RTL]
    files.append(os.path.join(SIM_DIR, 'tb_iverilog.sv'))
    return files


def compile_rtl(iverilog, vvp_out, defines, unisims_dir=None):
    """Compile RTL with given preprocessor defines. Returns True on success."""
    rtl_files = build_rtl_filelist(unisims_dir)
    def_flags = [f'-D{k}={v}' for k, v in defines.items()]
    cmd = [iverilog, '-g2012', '-o', vvp_out] + def_flags + rtl_files
    bram_tag = 'amd-primitive' if unisims_dir else 'sim-behavioural'
    print(f'  iverilog [{bram_tag}] ' + ' '.join(def_flags) + ' ...')
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr)
    if result.returncode != 0:
        print(f'  ERROR: compilation failed (exit {result.returncode})')
        return False
    return True


def run_simulation(vvp, vvp_out, run_dir):
    """Run vvp simulation. Returns (success, stdout)."""
    result = subprocess.run([vvp, vvp_out], capture_output=True, text=True, cwd=run_dir)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    if 'WATCHDOG TIMEOUT' in result.stdout:
        print('  ERROR: simulation watchdog triggered')
        return False, result.stdout
    if 'SOME TESTS FAILED' in result.stdout:
        print('  ERROR: structural checks failed in testbench')
        return False, result.stdout
    if 'ALL TESTS PASSED' not in result.stdout:
        print('  ERROR: testbench did not print ALL TESTS PASSED')
        print(result.stdout[-2000:])
        return False, result.stdout
    return True, result.stdout


# ---------------------------------------------------------------------------
# JPEG coefficient comparison
# ---------------------------------------------------------------------------
sys.path.insert(0, SCRIPT_DIR)
from jpeg_common import (
    DC_LUMA_BITS, DC_LUMA_VALS, DC_CHROMA_BITS, DC_CHROMA_VALS,
    AC_LUMA_BITS, AC_LUMA_VALS, AC_CHROMA_BITS, AC_CHROMA_VALS,
)


def _build_decode_table(bits, vals):
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


class _BitReader:
    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.buf = 0
        self.left = 0
        self.total = 0

    def read_bit(self):
        if self.left == 0:
            if self.pos >= len(self.data):
                raise EOFError('scan data exhausted')
            b = self.data[self.pos]; self.pos += 1
            if b == 0xFF:
                nxt = self.data[self.pos]; self.pos += 1
                if nxt != 0x00:
                    raise EOFError(f'marker FF{nxt:02X}')
            self.buf = b; self.left = 8
        self.left -= 1; self.total += 1
        return (self.buf >> self.left) & 1

    def read_bits(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | self.read_bit()
        return v

    def decode_huff(self, table):
        code = 0
        for length in range(1, 17):
            code = (code << 1) | self.read_bit()
            if (length, code) in table:
                return table[(length, code)]
        raise ValueError('bad huffman code')


def _decode_val(br, cat):
    if cat == 0:
        return 0
    bits = br.read_bits(cat)
    return bits if bits >= (1 << (cat - 1)) else bits - (1 << cat) + 1


def _extract_scan(data):
    i = 0
    while i < len(data) - 1:
        if data[i] == 0xFF:
            m = data[i + 1]
            if m == 0xDA:
                ln = (data[i + 2] << 8) | data[i + 3]
                j = i + 2 + ln
                scan = bytearray()
                while j < len(data) - 1:
                    if data[j] == 0xFF and data[j + 1] != 0x00:
                        if data[j + 1] == 0xD9:
                            break
                        elif 0xD0 <= data[j + 1] <= 0xD7:
                            j += 2; continue
                    scan.append(data[j]); j += 1
                return bytes(scan)
            elif m in (0x00, 0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
                i += 2
            else:
                i += 2 + ((data[i + 2] << 8) | data[i + 3]) if i + 3 < len(data) else 2
        else:
            i += 1
    raise ValueError('SOS not found')


def _decode_coefficients(jpeg_bytes, num_mcus):
    dc_luma = _build_decode_table(DC_LUMA_BITS, DC_LUMA_VALS)
    dc_chr  = _build_decode_table(DC_CHROMA_BITS, DC_CHROMA_VALS)
    ac_luma = _build_decode_table(AC_LUMA_BITS, AC_LUMA_VALS)
    ac_chr  = _build_decode_table(AC_CHROMA_BITS, AC_CHROMA_VALS)

    scan = _extract_scan(jpeg_bytes)
    br = _BitReader(scan)
    blocks = []
    prev_y = prev_cb = prev_cr = 0

    for _ in range(num_mcus):
        for bt in ('Y0', 'Y1', 'Cb', 'Cr'):
            is_luma = bt.startswith('Y')
            dc_cat  = br.decode_huff(dc_luma if is_luma else dc_chr)
            dc_diff = _decode_val(br, dc_cat)
            if is_luma:
                dc_val = prev_y  + dc_diff; prev_y  = dc_val
            elif bt == 'Cb':
                dc_val = prev_cb + dc_diff; prev_cb = dc_val
            else:
                dc_val = prev_cr + dc_diff; prev_cr = dc_val

            ac = [0] * 63; ai = 0
            while ai < 63:
                sym = br.decode_huff(ac_luma if is_luma else ac_chr)
                if sym == 0x00:
                    break
                elif sym == 0xF0:
                    ai += 16
                else:
                    run = (sym >> 4); cat = sym & 0xF; ai += run
                    if ai < 63:
                        ac[ai] = _decode_val(br, cat)
                    ai += 1
            blocks.append({'type': bt, 'dc': dc_val, 'ac': ac})

    return blocks


def compare_jpegs(ref_path, rtl_path):
    """Compare RTL JPEG output vs Python reference. Returns (passed, max_dc, max_ac)."""
    with open(ref_path, 'rb') as f:
        ref_bytes = f.read()
    with open(rtl_path, 'rb') as f:
        rtl_bytes = f.read()

    try:
        ref_blocks = _decode_coefficients(ref_bytes, NUM_MCUS)
        rtl_blocks = _decode_coefficients(rtl_bytes, NUM_MCUS)
    except Exception as e:
        print(f'    ERROR decoding coefficients: {e}')
        return False, 999, 999

    expected = NUM_MCUS * 4
    if len(ref_blocks) != expected or len(rtl_blocks) != expected:
        print(f'    ERROR: expected {expected} blocks, got ref={len(ref_blocks)} rtl={len(rtl_blocks)}')
        return False, 999, 999

    max_dc = max_ac = total_diffs = 0
    for rb, tb in zip(ref_blocks, rtl_blocks):
        dc_d = abs(rb['dc'] - tb['dc'])
        ac_d = max(abs(rb['ac'][j] - tb['ac'][j]) for j in range(63))
        max_dc = max(max_dc, dc_d)
        max_ac = max(max_ac, ac_d)
        n_diff = (1 if dc_d else 0) + sum(1 for j in range(63) if rb['ac'][j] != tb['ac'][j])
        total_diffs += n_diff

    passed = max_dc <= MAX_COEFF_DIFF and max_ac <= MAX_COEFF_DIFF
    print(f'    Total coeff diffs: {total_diffs}  '
          f'max_DC={max_dc}  max_AC={max_ac}  '
          f'(tolerance ={MAX_COEFF_DIFF})')
    return passed, max_dc, max_ac


# ---------------------------------------------------------------------------
# Single test run: compile + simulate + compare
# ---------------------------------------------------------------------------
def run_one(iverilog, vvp, build_dir, lite_mode, quality,
            dump_vcd=False, unisims_dir=None, rgb_input=False):
    """
    Compile + simulate + compare for one (mode, quality) combination.
    Returns True if PASS.
    """
    rgb_sfx = '_rgb' if rgb_input else ''
    tag = f'lite_q{quality}{rgb_sfx}' if lite_mode else f'full_q{quality}{rgb_sfx}'
    vvp_out    = os.path.join(build_dir, f'sim_{tag}.vvp')
    output_jpg = os.path.join(build_dir, f'sim_output_{tag}.jpg')

    # Preprocessor defines
    defines = {'TEST_QUALITY': quality}
    if lite_mode:
        defines['LITE_MODE']    = 1
        defines['LITE_QUALITY'] = quality
    if rgb_input:
        defines['RGB_INPUT'] = 1
    if dump_vcd:
        defines['DUMP_VCD'] = 1
        defines['VCD_FILE'] = f'"tb_iverilog_{tag}.vcd"'

    # 1. Compile
    if not compile_rtl(iverilog, vvp_out, defines, unisims_dir=unisims_dir):
        return False

    # 2. Simulate (testbench always writes sim_output.jpg in cwd)
    sim_ok, stdout = run_simulation(vvp, vvp_out, build_dir)
    print(stdout.strip().split('\n')[-3] if stdout.strip() else '')
    if not sim_ok:
        return False

    # Rename the default output to the tagged filename
    default_out = os.path.join(build_dir, 'sim_output.jpg')
    if os.path.exists(default_out):
        os.replace(default_out, output_jpg)

    if not os.path.exists(output_jpg):
        print(f'    ERROR: output JPEG not found: {output_jpg}')
        return False

    sz = os.path.getsize(output_jpg)
    print(f'    Output: {os.path.basename(output_jpg)} ({sz} bytes)')

    # 3. Compare vs reference
    if rgb_input:
        # RGB path: color conversion is internal to the DUT, so coefficients won't
        # match the YUYV-path Python reference. Structural checks (SOI, EOI, size)
        # from the testbench are sufficient; verify the JPEG decodes with Pillow.
        try:
            from PIL import Image
            import io
            with open(output_jpg, 'rb') as f:
                Image.open(io.BytesIO(f.read())).verify()
            print(f'    RGB_INPUT: Pillow decode OK')
            return True
        except ImportError:
            print(f'    RGB_INPUT: Pillow not available — structural pass only')
            return True
        except Exception as e:
            print(f'    ERROR: RGB_INPUT JPEG decode failed: {e}')
            return False

    ref = reference_path(quality)
    if not os.path.exists(ref):
        print(f'    ERROR: reference not found: {ref}')
        return False

    passed, _, _ = compare_jpegs(ref, output_jpg)
    return passed


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description='RTL sim + golden verification (iverilog)')
    parser.add_argument('--lite', action='store_true',
                        help='Test LITE_MODE=1 (fixed Q-tables, no AXI quality register)')
    parser.add_argument('--rgb', action='store_true',
                        help='Test RGB_INPUT=1 (24-bit RGB path through rgb_to_ycbcr)')
    parser.add_argument('--dump-vcd', action='store_true',
                        help='Enable VCD dump (build/sim_iverilog/tb_iverilog_<tag>.vcd)')
    parser.add_argument('--unisims', metavar='DIR', default=None,
                        help='Path to Vivado unisims directory; uses real RAMB36E1 primitive '
                             'instead of the behavioural sim wrapper. '
                             'Auto-discovered when --unisims=auto.')
    args = parser.parse_args()

    # Resolve --unisims auto-discovery
    unisims_dir = None
    if args.unisims == 'auto':
        _, unisims_dir = find_vivado_unisims()
        if not unisims_dir:
            print('ERROR: --unisims=auto: Vivado installation not found.')
            return 1
        print(f'  unisims: {unisims_dir}')
    elif args.unisims:
        unisims_dir = args.unisims
        if not os.path.isdir(unisims_dir):
            print(f'ERROR: --unisims dir not found: {unisims_dir}')
            return 1

    mode_str = 'LITE_MODE=1 (fixed tables)' if args.lite else 'LITE_MODE=0 (full, runtime AXI)'
    bram_str = f'AMD primitive ({unisims_dir})' if unisims_dir else 'behavioural sim wrapper'
    print('=' * 65)
    print(f'RTL Simulation + Golden Verification  [{mode_str}]')
    print(f'BRAM model:  {bram_str}')
    print(f'Testing qualities: {TEST_QUALITIES}')
    print('=' * 65)

    iverilog = find_tool('iverilog')
    vvp      = find_tool('vvp')
    if not iverilog or not vvp:
        missing = [t for t in ('iverilog', 'vvp') if not find_tool(t)]
        print(f"ERROR: {', '.join(missing)} not found.")
        print('  apt-get install iverilog   (Debian/Ubuntu)')
        return 1

    print(f'iverilog: {iverilog}')
    print(f'vvp:      {vvp}')

    os.makedirs(BUILD_DIR, exist_ok=True)

    # Auto-generate test vectors if any key file is missing
    _key_vectors = [
        os.path.join(TV_DIR, 'yuyv_input.hex'),
        os.path.join(TV_DIR, 'reference_4mcu.jpg'),
        os.path.join(TV_DIR, 'reference_4mcu_q50.jpg'),
        os.path.join(TV_DIR, 'reference_4mcu_q75.jpg'),
    ]
    if not all(os.path.isfile(f) for f in _key_vectors):
        print('  Test vectors missing — running generate_test_vectors.py ...')
        gen = os.path.join(SCRIPT_DIR, 'generate_test_vectors.py')
        r = subprocess.run([sys.executable, gen], capture_output=True, text=True)
        if r.stdout:
            print(r.stdout)
        if r.returncode != 0:
            print(f'ERROR: generate_test_vectors.py failed:\n{r.stderr}')
            return 1

    # Sync test vectors into build dir (testbench reads relative paths)
    tv_dst = os.path.join(BUILD_DIR, 'test_vectors')
    if not os.path.isdir(tv_dst):
        shutil.copytree(TV_DIR, tv_dst)
    else:
        for f in os.listdir(TV_DIR):
            src = os.path.join(TV_DIR, f)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(tv_dst, f))

    results = {}
    test_quals = TEST_QUALITIES if not args.rgb else [95]  # RGB: single quality is sufficient
    for q in test_quals:
        rgb_sfx = ' RGB_INPUT=1' if args.rgb else ''
        label = f'{"LITE" if args.lite else "FULL"} Q={q}{rgb_sfx}'
        print(f'\n{"-" * 65}')
        print(f'  Test: {label}')
        print(f'{"-" * 65}')
        passed = run_one(iverilog, vvp, BUILD_DIR, args.lite, q,
                         dump_vcd=args.dump_vcd, unisims_dir=unisims_dir,
                         rgb_input=args.rgb)
        results[label] = passed
        print(f'  >> {"PASS" if passed else "FAIL"}  [{label}]')

    # Summary
    print(f'\n{"=" * 65}')
    print('SUMMARY')
    print(f'{"=" * 65}')
    all_pass = True
    for label, passed in results.items():
        status = 'PASS' if passed else 'FAIL'
        print(f'  {status}  {label}')
        if not passed:
            all_pass = False

    print(f'{"-" * 65}')
    print(f'OVERALL RESULT: {"PASS" if all_pass else "FAIL"}')
    print(f'{"=" * 65}')
    return 0 if all_pass else 1


if __name__ == '__main__':
    sys.exit(main())
