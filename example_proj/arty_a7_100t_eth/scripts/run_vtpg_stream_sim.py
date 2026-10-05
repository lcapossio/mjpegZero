#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# ============================================================================
# run_vtpg_stream_sim.py - full streaming datapath of demo_top_vtpg_eth at 720p
# ============================================================================
# Builds sim/tb_vtpg_stream.v (the real VTPG, encoder, axi_init, capture,
# buffer, RTP packetizer, frame buffer and vtpg_stream_control; no MAC) and
# replays host control: start, stop while frame 3 encodes, then single.
#
# Checks, per encoded frame:
#   * the JPEG equals the Python reference encode of the exact pixels the
#     encoder accepted, at the QUALITY rate control wrote for that frame
#     (DQT/DHT byte-identical, every coefficient within +/-1, Pillow decodes)
#   * consecutive frames differ (the box moves) and QUALITY changes per frame
# and, per streamed frame:
#   * RTP/JPEG (RFC 2435) headers: type 0, 160x90, Q=255 with the frame's own
#     quant tables in band, contiguous fragment offsets, marker on the last
#     packet, one timestamp per frame, sequence numbers without gaps
#   * the reassembled scan is byte-identical to the encoder's scan
#   * IPv4 header checksums
# and the control sequence: 4 frames encoded and streamed, nothing kicked
# after stop, exactly one frame for single.
#
# Usage: python run_vtpg_stream_sim.py [--sim verilator|iverilog]
# ============================================================================

import argparse
import os
import re
import shutil
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
EX_DIR = os.path.normpath(os.path.join(HERE, '..'))
REPO = os.path.normpath(os.path.join(EX_DIR, '..', '..'))
BUILD = os.path.join(REPO, 'build', 'vtpg_stream_sim')
sys.path.insert(0, os.path.join(REPO, 'python'))

from jpeg_encoder import encode_jpeg_from_planes  # noqa: E402
from verify_stream import JpegError, decode, words_to_planes  # noqa: E402

W, H = 1280, 720
SCAN_OFF = 623
FRAMES = 4

SOURCES = (
    [os.path.join(REPO, 'rtl', f) for f in (
        'bram_sdp.v', 'dct_1d.v', 'dct_2d.v', 'input_buffer.v', 'quantizer.v',
        'zigzag_reorder.v', 'huffman_encoder.v', 'bitstream_packer.v',
        'jfif_writer.v', 'axi4_lite_regs.v', 'rgb_to_ycbcr.v', 'mjpegzero_enc_top.v')]
    + [os.path.join(REPO, 'example_proj', 'common', 'rtl', f) for f in (
        'axi_init.v', 'demo_jpeg_buffer.v', 'jpeg_capture.v')]
    + [os.path.join(EX_DIR, 'rtl', f) for f in (
        'vtpg_udp_control.v', 'vtpg_stream_control.v')]
    + [os.path.join(REPO, 'vtpgzero', 'rtl', 'vtpgz_core.v')]
    + [os.path.join(REPO, 'rtl', 'eth', f) for f in (
        'jpeg_rtp_tx.v', 'axis_frame_buffer.v')]
    + [os.path.join(EX_DIR, 'sim', 'tb_vtpg_stream.v')]
)
MEM_FILES = ('mandrill_128x128_ycbcr.mem', 'banana_32x32_ycbcr.mem')


def simulate(sim):
    if os.path.isdir(BUILD):
        shutil.rmtree(BUILD)
    os.makedirs(BUILD)
    for m in MEM_FILES:
        shutil.copy2(os.path.join(EX_DIR, 'data', m), BUILD)
    inc = os.path.join(REPO, 'vtpgzero', 'rtl')
    if sim == 'verilator':
        cmd = (['verilator', '--binary', '--timing', '-j', '0', '-O3',
                '-Wno-fatal', '-Wno-lint', '-Wno-style', '-Wno-TIMESCALEMOD',
                '--top-module', 'tb_vtpg_stream', f'-I{inc}',
                '--Mdir', os.path.join(BUILD, 'obj')] + SOURCES)
        run = [os.path.join(BUILD, 'obj', 'Vtb_vtpg_stream')]
    else:
        out = os.path.join(BUILD, 'sim.vvp')
        cmd = ['iverilog', '-g2012', f'-I{inc}', '-o', out] + SOURCES
        run = ['vvp', out]
    print('compile:', sim)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-4000:] + r.stderr[-4000:])
        sys.exit('ERROR: compile failed')
    print('run ...')
    r = subprocess.run(run, capture_output=True, text=True, cwd=BUILD)
    log = r.stdout + r.stderr
    with open(os.path.join(BUILD, 'sim.log'), 'w') as f:
        f.write(log)
    for line in log.splitlines():
        if any(k in line for k in ('kick', 'captured', 'host:', 'DONE', 'FAIL')):
            print('  ' + line)
    return 'DONE' in log and 'FAIL' not in log


def read_hex(path):
    with open(path) as f:
        return [int(t, 16) for t in f.read().split()]


def ip_checksum_ok(hdr):
    s = sum((hdr[i] << 8) | hdr[i + 1] for i in range(0, 20, 2))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return s == 0xFFFF


def parse_rtp(path):
    """rtp.txt -> list of streamed frames, each a list of packet byte strings.

    Frames are split on the RTP marker bit. The TB's "# FRAME" notes are
    dropped: rtp_done fires while the frame buffer still drains the last
    packet, so a note can land in the middle of a packet's line."""
    with open(path) as f:
        text = re.sub(r'# FRAME \d+ size=\d+\n?', '', f.read())
    frames, cur = [], []
    for line in text.splitlines():
        if not line.strip():
            continue
        pkt = bytes(int(t, 16) for t in line.split())
        cur.append(pkt)
        if len(pkt) > 43 and pkt[43] & 0x80:      # RTP marker: last packet
            frames.append(cur)
            cur = []
    if cur:
        frames.append(cur)
    return frames


def check_rtp(pkts, jpeg, seq_prev):
    """Return (errors, last_seq, timestamp) for one streamed frame."""
    errs = []
    scan = bytearray()
    ts = None
    seq = seq_prev
    # The in-band tables are the DQT tables in order, without the Pq/Tq bytes.
    want_qt = bytearray()
    i = 2
    while jpeg[i:i + 2] != b'\xff\xda':
        m, ln = jpeg[i + 1], (jpeg[i + 2] << 8) | jpeg[i + 3]
        if m == 0xDB:
            seg = jpeg[i + 4:i + 2 + ln]
            for t in range(0, len(seg), 65):
                want_qt += seg[t + 1:t + 65]
        i += 2 + ln
    want_qt = bytes(want_qt)
    for n, p in enumerate(pkts):
        if p[12:14] != b'\x08\x00' or p[23] != 17:
            errs.append(f'pkt {n}: not IPv4/UDP')
            continue
        if not ip_checksum_ok(p[14:34]):
            errs.append(f'pkt {n}: bad IP checksum')
        rtp = p[42:]
        if rtp[0] >> 6 != 2 or (rtp[1] & 0x7F) != 26:
            errs.append(f'pkt {n}: not RTP v2 / PT 26')
        marker = rtp[1] >> 7
        s = (rtp[2] << 8) | rtp[3]
        if seq is not None and s != (seq + 1) & 0xFFFF:
            errs.append(f'pkt {n}: seq {s} after {seq}')
        seq = s
        t = int.from_bytes(rtp[4:8], 'big')
        if ts is None:
            ts = t
        elif t != ts:
            errs.append(f'pkt {n}: timestamp changed within the frame')
        jh = rtp[12:20]
        off = int.from_bytes(jh[1:4], 'big')
        typ, q, w8, h8 = jh[4], jh[5], jh[6], jh[7]
        if (typ, q, w8, h8) != (0, 255, W // 8, H // 8):
            errs.append(f'pkt {n}: JPEG hdr type={typ} Q={q} {w8}x{h8}')
        body = rtp[20:]
        if off == 0:
            qlen = (body[2] << 8) | body[3]
            if body[4:4 + qlen] != want_qt:
                errs.append('in-band quant tables differ from the JPEG DQT')
            body = body[4 + qlen:]
        if off != len(scan):
            errs.append(f'pkt {n}: fragment offset {off}, expected {len(scan)}')
        scan += body
        if marker != (n == len(pkts) - 1):
            errs.append(f'pkt {n}: marker bit {marker}')
    if bytes(scan) != jpeg[SCAN_OFF:-2]:
        errs.append(f'reassembled scan ({len(scan)} B) differs from the encoder scan '
                    f'({len(jpeg) - SCAN_OFF - 2} B)')
    return errs, seq, ts


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--sim', choices=('verilator', 'iverilog'), default='verilator')
    ap.add_argument('--check-only', action='store_true',
                    help='re-check an existing build/vtpg_stream_sim run')
    args = ap.parse_args()

    ok = True
    if not args.check_only:
        ok = simulate(args.sim)
        if not ok:
            print('RESULT: FAIL (simulation)')
            return 1

    from PIL import Image
    import io

    jpegs, qs, prev_pix = [], [], None
    for k in range(FRAMES):
        enc = os.path.join(BUILD, f'enc_f{k}.hex')
        pix = os.path.join(BUILD, f'pix_f{k}.hex')
        if not (os.path.exists(enc) and os.path.exists(pix)):
            print(f'  frame {k}: FAIL - missing dump')
            ok = False
            continue
        rtl = bytes(read_hex(enc))
        words = read_hex(pix)
        q = int(open(os.path.join(BUILD, f'q_f{k}.txt')).read())
        jpegs.append(rtl)
        qs.append(q)
        errs = []
        if len(words) != W * H:
            errs.append(f'{len(words)} pixels accepted, expected {W * H}')
        else:
            if prev_pix is not None and words == prev_pix:
                errs.append('identical to the previous frame (box did not move)')
            prev_pix = words
            ref = encode_jpeg_from_planes(*words_to_planes(words, W, H), quality=q)
            try:
                got, exp = decode(rtl), decode(ref)
                if (got['w'], got['h']) != (W, H):
                    errs.append(f"SOF {got['w']}x{got['h']}")
                if got['dqt'] != exp['dqt']:
                    errs.append(f'DQT differs from reference at Q={q}')
                if got['dht'] != exp['dht']:
                    errs.append('DHT differs from reference')
                maxd = 0
                for (dg, ag), (de, ae) in zip(got['blocks'], exp['blocks']):
                    maxd = max(maxd, abs(dg - de), max(abs(a - b) for a, b in zip(ag, ae)))
                if len(got['blocks']) != len(exp['blocks']):
                    errs.append(f"{len(got['blocks'])} blocks, expected {len(exp['blocks'])}")
                if maxd > 1:
                    errs.append(f'coefficient max |diff| = {maxd} (> 1)')
            except (JpegError, IndexError, KeyError) as e:
                errs.append(f'decode error: {e}')
                maxd = -1
            try:
                Image.open(io.BytesIO(rtl)).load()
            except Exception as e:
                errs.append(f'Pillow: {e}')
        print(f"  frame {k}: {'PASS' if not errs else 'FAIL'}  Q={q}  {len(rtl)} bytes"
              f"  max|dcoef|={maxd}" + ('' if not errs else '  <- ' + '; '.join(errs)))
        ok &= not errs

    if len(set(qs)) != len(qs):
        print(f'  QUALITY per frame {qs}: FAIL - rate control did not change it every frame')
        ok = False
    else:
        print(f'  QUALITY per frame {qs}: PASS (latched per frame)')

    streamed = parse_rtp(os.path.join(BUILD, 'rtp.txt'))
    if len(streamed) != FRAMES:
        print(f'  RTP: FAIL - {len(streamed)} frames streamed, expected {FRAMES}')
        ok = False
    seq, stamps = None, []
    for k, (pkts, jpeg) in enumerate(zip(streamed, jpegs)):
        errs, seq, ts = check_rtp(pkts, jpeg, seq)
        stamps.append(ts)
        print(f"  RTP frame {k}: {'PASS' if not errs else 'FAIL'}  {len(pkts)} packets"
              + ('' if not errs else '  <- ' + '; '.join(errs[:4])))
        ok &= not errs
    if len(set(stamps)) != len(stamps):
        print('  RTP timestamps: FAIL - repeated across frames')
        ok = False

    print(f"RESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
