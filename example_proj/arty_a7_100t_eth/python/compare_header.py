#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Isolate whether build_jfif faithfully reproduces the encoder's bitstream:
# parse an encoder-produced full JFIF, compare its DHT/DQT/SOF/SOS to build_jfif,
# then re-wrap its scan with build_jfif and check the decode matches the original.
import sys
import io
from pathlib import Path
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rtp_jpeg_recv import build_jfif, dht_segment   # noqa: E402


def parse(jpg):
    segs = {}
    scan = None
    i = 2  # skip SOI
    while i < len(jpg) - 1:
        if jpg[i] != 0xFF:
            i += 1
            continue
        m = jpg[i + 1]
        if m in (0xD8,):
            i += 2
            continue
        if m == 0xD9:
            break
        ln = (jpg[i + 2] << 8) | jpg[i + 3]
        seg = jpg[i:i + 2 + ln]
        name = {0xC0: "SOF0", 0xC4: "DHT", 0xDB: "DQT", 0xE0: "APP0",
                0xDD: "DRI", 0xDA: "SOS"}.get(m, "M%02X" % m)
        segs.setdefault(name, []).append(seg)
        if m == 0xDA:
            start = i + 2 + ln
            j = start
            while not (jpg[j] == 0xFF and jpg[j + 1] == 0xD9):
                j += 1
            scan = jpg[start:j]
            return segs, scan
        i += 2 + ln
    return segs, scan


ref_path = sys.argv[1]
ref = Path(ref_path).read_bytes()
segs, scan = parse(ref)
print("file:", ref_path, "size", len(ref))
print("segments:", {k: len(v) for k, v in segs.items()})
print("DRI present:", "DRI" in segs, " scan bytes:", len(scan) if scan else 0)

# DQT tables (skip 5-byte marker+len+precision/id header -> 64 bytes each)
dqt_tables = {}
for seg in segs.get("DQT", []):
    o = 4
    while o < len(seg):
        pq_tq = seg[o]
        tq = pq_tq & 0x0F
        dqt_tables[tq] = seg[o + 1:o + 65]
        o += 65
print("DQT table ids:", sorted(dqt_tables.keys()))
lqt = dqt_tables.get(0)
cqt = dqt_tables.get(1, dqt_tables.get(0))

# DHT comparison: encoder DHT content vs build_jfif standard tables
enc_dht = b"".join(segs.get("DHT", []))
my_dht = dht_segment()


def dht_tables(blob):
    """Return {(cls,id): (bits16, vals)} from concatenated DHT segments."""
    out = {}
    i = 0
    while i < len(blob):
        # each segment: FF C4 LEN ... ; iterate tables inside
        assert blob[i] == 0xFF and blob[i + 1] == 0xC4
        ln = (blob[i + 2] << 8) | blob[i + 3]
        o = i + 4
        end = i + 2 + ln
        while o < end:
            tc_th = blob[o]
            bits = blob[o + 1:o + 17]
            nv = sum(bits)
            vals = blob[o + 17:o + 17 + nv]
            out[(tc_th >> 4, tc_th & 0xF)] = (bits, vals)
            o += 17 + nv
        i = end
    return out


enc_t = dht_tables(enc_dht)
my_t = dht_tables(my_dht)
print("\nHuffman tables (cls,id): enc=%s  mine=%s" % (sorted(enc_t), sorted(my_t)))
for k in sorted(set(enc_t) | set(my_t)):
    e = enc_t.get(k)
    mm = my_t.get(k)
    same = (e == mm)
    print("  table %s: %s" % (k, "IDENTICAL" if same else "*** DIFFERENT ***"))
    if not same and e and mm:
        print("     enc bits:", list(e[0]))
        print("     std bits:", list(mm[0]))

# SOF/SOS raw
for nm in ("SOF0", "SOS"):
    print("%s: %s" % (nm, segs.get(nm, [b""])[0].hex()))

# Re-wrap encoder scan with build_jfif and compare decoded pixels
sof = segs["SOF0"][0]
height = (sof[5] << 8) | sof[6]
width = (sof[7] << 8) | sof[8]
print("\nwidth=%d height=%d" % (width, height))
orig_img = np.asarray(Image.open(io.BytesIO(ref)).convert("RGB"))
dri = 0
if "DRI" in segs:
    d = segs["DRI"][0]
    dri = (d[4] << 8) | d[5]
print("DRI interval =", dri)
rewrap = build_jfif(width, height, lqt, cqt, scan, dri=dri)
try:
    rw_img = np.asarray(Image.open(io.BytesIO(rewrap)).convert("RGB"))
    diff = np.abs(orig_img.astype(int) - rw_img.astype(int))
    print("re-wrap decode: meandiff=%.3f maxdiff=%d  %s"
          % (diff.mean(), diff.max(),
             "IDENTICAL" if diff.max() == 0 else "DIFFERS"))
except Exception as e:
    print("re-wrap decode FAILED:", e)
