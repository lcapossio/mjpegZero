#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Back-to-back multi-frame stream verification (Verilog and VHDL).

Feeds N *different* frames (multi-row crops of the test image) into the
encoder back to back — the next frame's start-of-frame arrives right after
the previous frame's last pixel, while that frame is still being encoded —
and checks every JPEG independently:

  * structure : SOI/EOI, SOF0 dimensions, DRI value
  * headers   : DQT and DHT segments byte-identical to the Python reference
                encoder at the quality that frame must use
  * scan      : restart-aware entropy decode (RSTn sequence checked mod 8,
                DC predictors reset per interval), every coefficient within
                +/-1 of the reference encode of the same frame
  * libjpeg   : Pillow decodes the frame

Optional stress knobs:
  --quality2 Q   write QUALITY=Q halfway through frame 0's input. Frame 0 must
                 keep --quality (per-frame latch); later frames use Q clamped
                 to 1..100 (full mode; lite ignores the write)
  --toggle-enable  clear CTRL.enable for 3000 cycles mid-frame 0 (the input
                 must stall, not drop pixels)
  --restart N    restart interval in MCUs (use enough MCUs to wrap RST7->RST0)
  --gaps         random input valid gaps
  --huff-banks N HUFF_BANKS=2/4/8
  --rgb          RGB_INPUT=1 (24-bit RGB stream through rgb_to_ycbcr)
  --exif         EXIF_ENABLE=1 (every frame must carry the APP1/Exif segment)

Simulator (--sim):
  iverilog        sim/tb_iverilog.sv STREAM mode (default)
  cocotb-verilog  sim/cocotb/test_stream.py on Icarus
  cocotb-vhdl     sim/cocotb/test_stream.py on GHDL (the VHDL port)
  --xcheck        also run the iverilog testbench and require every frame to be
                  byte-identical (use with cocotb-vhdl: VHDL vs Verilog)

Examples:
  python python/verify_stream.py                          # 128x24, 3 frames
  python python/verify_stream.py --quality2 120 --restart 2
  python python/verify_stream.py --lite --toggle-enable --huff-banks 2
  python python/verify_stream.py --width 4096 --height 8 --frames 1
  python python/verify_stream.py --sim cocotb-vhdl --xcheck --restart 3 --gaps
"""

import argparse
import os
import shutil
import subprocess
import sys

import numpy as np

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR = os.path.dirname(SCRIPT_DIR)
RTL_DIR = os.path.join(PROJ_DIR, 'rtl')
SIM_DIR = os.path.join(PROJ_DIR, 'sim')
BUILD_ROOT = os.path.join(PROJ_DIR, 'build', 'sim_stream')
IMG_PATH = os.path.join(SCRIPT_DIR, 'test_images', 'mandrill_720p.png')

sys.path.insert(0, SCRIPT_DIR)
from jpeg_encoder import encode_jpeg_from_planes  # noqa: E402
from yuyv_convert import rgb_array_to_yuyv_words, rtl_rgb_to_ycbcr_planes  # noqa: E402

VHDL_FILES = ['mjpegzero_pkg.vhd', 'axi4_lite_regs.vhd', 'bram_sdp.vhd',
              'input_buffer.vhd', 'dct_1d.vhd', 'dct_2d.vhd', 'quantizer.vhd',
              'huffman_encoder.vhd', 'bitstream_packer.vhd', 'rgb_to_ycbcr.vhd',
              'zigzag_reorder.vhd', 'jfif_writer.vhd', 'mjpegzero_enc_top.vhd']
RTL_FILES = ['bram_sdp.v', 'dct_1d.v', 'dct_2d.v', 'input_buffer.v', 'quantizer.v',
             'zigzag_reorder.v', 'huffman_encoder.v', 'bitstream_packer.v',
             'jfif_writer.v', 'axi4_lite_regs.v', 'rgb_to_ycbcr.v',
             'mjpegzero_enc_top.v']


def find_tool(name):
    exe = shutil.which(name)
    if exe:
        return exe
    for prefix in ('/usr/bin', '/usr/local/bin', 'C:/iverilog/bin'):
        for cand in (os.path.join(prefix, name), os.path.join(prefix, name + '.exe')):
            if os.path.isfile(cand):
                return cand
    return None


# ---------------------------------------------------------------------------
# Test frames
# ---------------------------------------------------------------------------
def source_image():
    if os.path.isfile(IMG_PATH):
        from PIL import Image
        return np.array(Image.open(IMG_PATH).convert('RGB'))
    # Deterministic synthetic fallback: smooth gradients + texture
    print('  NOTE: mandrill_720p.png missing - using a synthetic image')
    yy, xx = np.mgrid[0:720, 0:1280]
    rng = np.random.default_rng(1234)
    noise = rng.integers(0, 64, (720, 1280))
    r = (xx * 255 // 1279 + noise) % 256
    g = (yy * 255 // 719 + noise // 2) % 256
    b = ((xx + yy) * 3 + noise) % 256
    return np.stack([r, g, b], axis=-1).astype(np.uint8)


def words_to_planes(words, width, height):
    """Unpack the exact 8-bit YUYV samples fed to the RTL into Y/Cb/Cr planes,
    so the reference encodes the same rounded input (float planes differ by
    rounding, which shows through at quantizer step 1)."""
    a = np.array(words, dtype=np.uint16).reshape(height, width)
    Y = (a & 0xFF).astype(np.float64)
    Cb = (a[:, 0::2] >> 8).astype(np.float64)
    Cr = (a[:, 1::2] >> 8).astype(np.float64)
    return Y, Cb, Cr


def make_frames(img, width, height, n):
    """n different width x height crops (tiled if the source is too small)."""
    h_img, w_img = img.shape[:2]
    reps_x = -(-width // w_img) + 1
    reps_y = -(-height // h_img) + 1
    big = np.tile(img, (reps_y, reps_x, 1))
    frames = []
    for k in range(n):
        oy = (k * 37 * 8) % (big.shape[0] - height + 1)
        ox = (k * 53 * 16) % (big.shape[1] - width + 1)
        oy -= oy % 8
        ox -= ox % 16
        crop = big[oy:oy + height, ox:ox + width, :].copy()
        if k % 2 == 1:
            crop = 255 - crop          # make consecutive frames clearly different
        frames.append(crop)
    return frames


# ---------------------------------------------------------------------------
# JPEG parsing / restart-aware decoding
# ---------------------------------------------------------------------------
class JpegError(Exception):
    pass


def parse_segments(data):
    """Return (segments, scan_start). segments: list of (marker, payload)."""
    if data[:2] != b'\xff\xd8':
        raise JpegError('missing SOI')
    i = 2
    segs = []
    while i < len(data):
        if data[i] != 0xFF:
            raise JpegError(f'expected marker at {i}')
        m = data[i + 1]
        ln = (data[i + 2] << 8) | data[i + 3]
        payload = data[i + 4:i + 2 + ln]
        segs.append((m, payload))
        i += 2 + ln
        if m == 0xDA:
            return segs, i
    raise JpegError('SOS not found')


def build_tables(dht_payloads):
    tables = {}
    for p in dht_payloads:
        j = 0
        while j < len(p):
            tc_th = p[j]
            bits = list(p[j + 1:j + 17])
            nvals = sum(bits)
            vals = list(p[j + 17:j + 17 + nvals])
            j += 17 + nvals
            t = {}
            code = 0
            vi = 0
            for ln in range(1, 17):
                for _ in range(bits[ln - 1]):
                    t[(ln, code)] = vals[vi]
                    code += 1
                    vi += 1
                code <<= 1
            tables[tc_th] = t
    return tables


class BitReader:
    def __init__(self, data, pos):
        self.data = data
        self.pos = pos
        self.cur = 0
        self.left = 0

    def bit(self):
        if self.left == 0:
            b = self.data[self.pos]
            if b == 0xFF:
                nxt = self.data[self.pos + 1]
                if nxt != 0x00:
                    raise JpegError(f'unexpected marker FF{nxt:02X} inside entropy data')
                self.pos += 2
            else:
                self.pos += 1
            self.cur = b
            self.left = 8
        self.left -= 1
        return (self.cur >> self.left) & 1

    def bits(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | self.bit()
        return v

    def huff(self, table):
        code = 0
        for ln in range(1, 17):
            code = (code << 1) | self.bit()
            if (ln, code) in table:
                return table[(ln, code)]
        raise JpegError('bad Huffman code')

    def align_and_marker(self):
        """Drop pad bits (must be 1s), then read a marker; return its code."""
        if self.left:
            pad = self.cur & ((1 << self.left) - 1)
            if pad != (1 << self.left) - 1:
                raise JpegError('restart pad bits are not all 1s')
            self.left = 0
        if self.data[self.pos] != 0xFF:
            raise JpegError(f'expected marker at byte {self.pos}')
        m = self.data[self.pos + 1]
        self.pos += 2
        return m


def extend(v, cat):
    if cat == 0:
        return 0
    return v if v >= (1 << (cat - 1)) else v - (1 << cat) + 1


def decode(data):
    """Decode a 4:2:2 baseline JPEG. Returns dict with header info + blocks."""
    segs, pos = parse_segments(data)
    info = {'dqt': b'', 'dht': b'', 'dri': 0, 'w': None, 'h': None, 'exif': False}
    dht = []
    for m, p in segs:
        if m == 0xDB:
            info['dqt'] += bytes(p)
        elif m == 0xC4:
            info['dht'] += bytes(p)
            dht.append(p)
        elif m == 0xC0:
            info['h'] = (p[1] << 8) | p[2]
            info['w'] = (p[3] << 8) | p[4]
        elif m == 0xDD:
            info['dri'] = (p[0] << 8) | p[1]
        elif m == 0xE1 and bytes(p[:6]) == b'Exif\x00\x00':
            info['exif'] = True
    t = build_tables(dht)
    dc_l, ac_l, dc_c, ac_c = t[0x00], t[0x10], t[0x01], t[0x11]
    n_mcus = (info['w'] // 16) * (info['h'] // 8)
    br = BitReader(data, pos)
    blocks = []
    pred = [0, 0, 0]
    rst_seq = 0
    rst_count = 0
    for mcu in range(n_mcus):
        if info['dri'] and mcu and mcu % info['dri'] == 0:
            m = br.align_and_marker()
            if m != 0xD0 + (rst_seq % 8):
                raise JpegError(f'MCU {mcu}: expected RST{rst_seq % 8}, got FF{m:02X}')
            rst_seq += 1
            rst_count += 1
            pred = [0, 0, 0]
        for comp in (0, 0, 1, 2):
            luma = comp == 0
            cat = br.huff(dc_l if luma else dc_c)
            pred[comp] += extend(br.bits(cat), cat)
            ac = [0] * 63
            k = 0
            while k < 63:
                sym = br.huff(ac_l if luma else ac_c)
                if sym == 0x00:
                    break
                if sym == 0xF0:
                    k += 16
                    continue
                k += sym >> 4
                if k >= 63:
                    raise JpegError('AC index overflow')
                ac[k] = extend(br.bits(sym & 15), sym & 15)
                k += 1
            blocks.append((pred[comp], ac))
    if br.align_and_marker() != 0xD9:
        raise JpegError('scan not followed by EOI')
    if br.pos != len(data):
        raise JpegError(f'{len(data) - br.pos} trailing bytes after EOI')
    info['blocks'] = blocks
    info['rst_count'] = rst_count
    return info


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def run_iverilog(args, build, rtl_dir):
    """sim/tb_iverilog.sv in STREAM mode. Returns True if the TB passed."""
    iverilog, vvp = find_tool('iverilog'), find_tool('vvp')
    if not iverilog or not vvp:
        sys.exit('ERROR: iverilog/vvp not found')
    defines = {
        'STREAM': 1, 'NUM_FRAMES': args.frames,
        'TB_IMG_WIDTH': args.width, 'TB_IMG_HEIGHT': args.height,
        'TV_HEX_FILE': '"test_vectors/stream.hex"',
        'TEST_QUALITY': args.quality, 'HUFF_BANKS': args.huff_banks,
    }
    if args.lite:
        defines['LITE_MODE'] = 1
        defines['LITE_QUALITY'] = args.quality
    if args.quality2 is not None:
        defines['QUALITY_2'] = args.quality2
    if args.restart:
        defines['RESTART_INTERVAL'] = args.restart
    if args.gaps:
        defines['RANDOM_GAPS'] = 1
    if args.toggle_enable:
        defines['TOGGLE_ENABLE'] = 1
    if args.rgb:
        defines['RGB_INPUT'] = 1
    if args.exif:
        defines['EXIF_ENABLE'] = 1

    vvp_out = os.path.join(build, 'sim.vvp')
    cmd = ([iverilog, '-g2012', '-o', vvp_out]
           + [f'-D{k}={v}' for k, v in defines.items()]
           + [os.path.join(rtl_dir, f) for f in RTL_FILES]
           + [os.path.join(SIM_DIR, 'tb_iverilog.sv')])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit('ERROR: compile failed')
    r = subprocess.run([vvp, vvp_out], capture_output=True, text=True, cwd=build)
    out = r.stdout
    for line in out.splitlines():
        if 'complete' in line or 'Mid-frame' in line or 'ASSERT' in line or 'WATCHDOG' in line:
            print('  ' + line)
    ok = (r.returncode == 0 and 'ALL TESTS PASSED' in out and 'WATCHDOG' not in out
          and 'ASSERT FAIL' not in out)
    if not ok:
        print(out[-3000:])
    return ok


def run_cocotb(args, build, lang):
    """sim/cocotb/test_stream.py on Icarus (verilog) or GHDL (vhdl)."""
    cocotb_dir = os.path.join(SIM_DIR, 'cocotb')
    sys.path.insert(0, cocotb_dir)
    from cocotb_tools.runner import get_runner, get_results
    from test_runner import augment_path_for_ghdl

    # GHDL's work library is cwd-relative and cocotb runs the test in
    # test_dir, so build and test share one dir holding the test module.
    shutil.copy2(os.path.join(cocotb_dir, 'test_stream.py'),
                 os.path.join(build, 'test_stream.py'))
    env = {
        'STREAM_HEX': os.path.join(build, 'test_vectors', 'stream.hex'),
        'STREAM_OUT': build, 'STREAM_W': args.width, 'STREAM_H': args.height,
        'STREAM_FRAMES': args.frames, 'STREAM_QUALITY': args.quality,
        'STREAM_RESTART': args.restart, 'STREAM_GAPS': int(args.gaps),
        'STREAM_TOGGLE_EN': int(args.toggle_enable),
    }
    if args.quality2 is not None:
        env['STREAM_QUALITY2'] = args.quality2
    os.environ.update({k: str(v) for k, v in env.items()})
    params = {
        'IMG_WIDTH': args.width, 'IMG_HEIGHT': args.height,
        'LITE_MODE': int(args.lite), 'LITE_QUALITY': args.quality,
        'RGB_INPUT': int(args.rgb), 'HUFF_BANKS': args.huff_banks,
        'EXIF_ENABLE': int(args.exif),
    }
    if lang == 'vhdl':
        augment_path_for_ghdl()
        runner = get_runner('ghdl')
        ghdl_args = ['--std=93', '--syn-binding']
        runner.build(vhdl_sources=[os.path.join(RTL_DIR, 'vhdl', f) for f in VHDL_FILES],
                     hdl_toplevel='mjpegzero_enc_top', parameters=params,
                     build_args=ghdl_args, build_dir=build, always=True)
        test_args = ghdl_args
    else:
        runner = get_runner('icarus')
        runner.build(verilog_sources=[os.path.join(RTL_DIR, f) for f in RTL_FILES],
                     hdl_toplevel='mjpegzero_enc_top', parameters=params,
                     timescale=('1ns', '1ps'), build_dir=build, always=True)
        test_args = []
    xml = runner.test(hdl_toplevel='mjpegzero_enc_top', test_module='test_stream',
                      test_dir=build, build_dir=build, parameters=params,
                      test_args=test_args)
    n, failed = get_results(xml)
    return n > 0 and failed == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--lite', action='store_true')
    ap.add_argument('--width', type=int, default=128)
    ap.add_argument('--height', type=int, default=24)
    ap.add_argument('--frames', type=int, default=3)
    ap.add_argument('--quality', type=int, default=75)
    ap.add_argument('--quality2', type=int, default=None)
    ap.add_argument('--restart', type=int, default=0)
    ap.add_argument('--gaps', action='store_true')
    ap.add_argument('--toggle-enable', action='store_true')
    ap.add_argument('--huff-banks', type=int, default=8)
    ap.add_argument('--rgb', action='store_true')
    ap.add_argument('--exif', action='store_true')
    ap.add_argument('--sim', default='iverilog',
                    choices=['iverilog', 'cocotb-verilog', 'cocotb-vhdl'])
    ap.add_argument('--xcheck', action='store_true',
                    help='also run the iverilog testbench; frames must be byte-identical')
    ap.add_argument('--rtl-dir', default=RTL_DIR,
                    help='Verilog source directory for --sim iverilog '
                         '(e.g. an older checkout, to show a bug)')
    args = ap.parse_args()

    if args.width % 16 or args.height % 8:
        sys.exit('ERROR: width must be a multiple of 16, height a multiple of 8')
    if (args.quality2 is not None or args.toggle_enable) and args.height < 16:
        sys.exit('ERROR: --quality2/--toggle-enable need --height >= 16 so the '
                 'mid-frame write lands after frame 0 has latched its settings')

    tag = (f"{args.sim}_{'lite' if args.lite else 'full'}_{args.width}x{args.height}"
           f"_f{args.frames}_q{args.quality}"
           + (f"_q2-{args.quality2}" if args.quality2 is not None else '')
           + (f"_rst{args.restart}" if args.restart else '')
           + ('_gaps' if args.gaps else '') + ('_en' if args.toggle_enable else '')
           + (f"_hb{args.huff_banks}" if args.huff_banks != 8 else '')
           + ('_rgb' if args.rgb else '') + ('_exif' if args.exif else ''))
    build = os.path.join(BUILD_ROOT, tag)
    os.makedirs(os.path.join(build, 'test_vectors'), exist_ok=True)

    print('=' * 70)
    print(f'Stream test [{tag}]')
    print('=' * 70)

    frames = make_frames(source_image(), args.width, args.height, args.frames)
    words, planes = [], []
    for f in frames:
        if args.rgb:
            rgb = f.astype(np.int64)
            words.extend(((rgb[:, :, 0] << 16) | (rgb[:, :, 1] << 8) | rgb[:, :, 2])
                         .flatten().tolist())
            planes.append(tuple(p.astype(np.float64) for p in rtl_rgb_to_ycbcr_planes(f)))
        else:
            w, _, _ = rgb_array_to_yuyv_words(f)
            words.extend(w)
            planes.append(words_to_planes(w, args.width, args.height))
    fmt = '{:06X}' if args.rgb else '{:04X}'
    with open(os.path.join(build, 'test_vectors', 'stream.hex'), 'w') as fh:
        fh.write('\n'.join(fmt.format(w) for w in words) + '\n')

    def clamp(q):
        return min(max(q, 1), 100)

    exp_q = []
    for k in range(args.frames):
        if args.lite or args.quality2 is None or k == 0:
            exp_q.append(args.quality)
        else:
            exp_q.append(clamp(args.quality2))

    def clear_outputs(d):
        for k in range(args.frames + 1):
            stale = os.path.join(d, f'sim_output_f{k}.jpg')
            if os.path.exists(stale):
                os.remove(stale)

    clear_outputs(build)
    if args.sim == 'iverilog':
        ok = run_iverilog(args, build, args.rtl_dir)
    else:
        ok = run_cocotb(args, build, args.sim.split('-')[1])
    if not ok:
        print('RESULT: FAIL (simulation)')
        return 1

    from PIL import Image
    import io
    all_ok = True
    for k, (pl, q) in enumerate(zip(planes, exp_q)):
        path = os.path.join(build, f'sim_output_f{k}.jpg')
        if not os.path.exists(path):
            print(f'  frame {k}: FAIL - no output file')
            all_ok = False
            continue
        rtl = open(path, 'rb').read()
        ref = encode_jpeg_from_planes(*pl, quality=q)
        errs = []
        try:
            got = decode(rtl)
            exp = decode(ref)
        except (JpegError, IndexError, KeyError) as e:
            print(f'  frame {k}: FAIL - decode error: {e}')
            all_ok = False
            continue
        if (got['w'], got['h']) != (args.width, args.height):
            errs.append(f"SOF {got['w']}x{got['h']}")
        if got['dri'] != args.restart:
            errs.append(f"DRI {got['dri']} != {args.restart}")
        if got['exif'] != args.exif:
            errs.append(f"APP1/Exif {'missing' if args.exif else 'unexpected'}")
        if got['dqt'] != exp['dqt']:
            errs.append(f'DQT differs from reference at Q={q}')
        if got['dht'] != exp['dht']:
            errs.append('DHT differs from reference')
        if args.restart:
            n_mcus = (args.width // 16) * (args.height // 8)
            want = (n_mcus - 1) // args.restart
            if got['rst_count'] != want:
                errs.append(f"{got['rst_count']} RST markers, expected {want}")
        maxd = 0
        for (dg, ag), (de, ae) in zip(got['blocks'], exp['blocks']):
            maxd = max(maxd, abs(dg - de), max(abs(a - b) for a, b in zip(ag, ae)))
        if maxd > 1:
            errs.append(f'coefficient max |diff| = {maxd} (> 1)')
        try:
            im = Image.open(io.BytesIO(rtl))
            im.load()
            if im.size != (args.width, args.height):
                errs.append(f'libjpeg size {im.size}')
        except Exception as e:
            errs.append(f'libjpeg decode error: {e}')
        status = 'PASS' if not errs else 'FAIL'
        extra = f", {got['rst_count']} RST" if args.restart else ''
        print(f'  frame {k}: {status}  Q={q}  {len(rtl)} bytes  max|dcoef|={maxd}{extra}'
              + ('' if not errs else '  <- ' + '; '.join(errs)))
        all_ok &= not errs

    if args.xcheck and args.sim != 'iverilog':
        # The encoder output does not depend on input timing, so the other
        # simulator's frames must match byte for byte.
        xbuild = build + '_xcheck_iverilog'
        os.makedirs(os.path.join(xbuild, 'test_vectors'), exist_ok=True)
        shutil.copy2(os.path.join(build, 'test_vectors', 'stream.hex'),
                     os.path.join(xbuild, 'test_vectors', 'stream.hex'))
        clear_outputs(xbuild)
        print('  cross-check: iverilog testbench ...')
        if not run_iverilog(args, xbuild, RTL_DIR):
            print('  cross-check: FAIL (iverilog simulation)')
            all_ok = False
        else:
            for k in range(args.frames):
                a = os.path.join(build, f'sim_output_f{k}.jpg')
                b = os.path.join(xbuild, f'sim_output_f{k}.jpg')
                same = (os.path.exists(a) and os.path.exists(b)
                        and open(a, 'rb').read() == open(b, 'rb').read())
                print(f"  cross-check frame {k}: {'IDENTICAL' if same else 'DIFFER'} "
                      f'({args.sim} vs iverilog)')
                all_ok &= same

    print(f"RESULT: {'PASS' if all_ok else 'FAIL'}")
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())
