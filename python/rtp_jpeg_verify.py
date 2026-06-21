#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# RTP/JPEG (RFC 2435) verification for the jpeg_rtp_tx packetizer (M1).
#
#   prep  <input.jpg> <outdir>
#       Validate the JPEG has the encoder's fixed 623-byte header, write the
#       buffer image as 32-bit LE words for $readmemh, and report the byte count.
#
#   check <outdir> <captured.txt> <input.jpg>
#       Depacketize the captured Eth/IP/UDP/RTP/JPEG byte stream and verify:
#         G1  reassembled scan == original scan bytes [623 : size-2]   (byte-exact)
#         G2  in-band quant tables == original DQT data (offs 25 / 94)  (byte-exact)
#         G3  RTP/JPEG structural sanity (PT, version, seq, marker, frag, w/h/type/q)
#         G4  reconstructed JPEG (DQT from the wire) decodes pixel-identical to the
#             original (skipped if Pillow is unavailable)
#
# Exit code 0 = all gates pass.

import os
import sys
import json
import struct

# Fixed layout of this encoder's JFIF header (LITE_MODE=1 / full mode, no DRI/EXIF)
HDR_SIZE      = 623
SCAN_OFF      = 623
EOI_BYTES     = 2
QT_LUMA_OFF   = 25
QT_CHROMA_OFF = 94
QT_LEN        = 64
SOF0_OFF      = 158   # FF C0 .. ; height@163, width@165 (big-endian)


def _err(msg):
    print("  FAIL: " + msg)
    return False


def dims_from_sof0(data):
    """Return (width, height) read from the SOF0 segment."""
    height = (data[SOF0_OFF + 5] << 8) | data[SOF0_OFF + 6]
    width  = (data[SOF0_OFF + 7] << 8) | data[SOF0_OFF + 8]
    return width, height


# ---------------------------------------------------------------------------
# prep
# ---------------------------------------------------------------------------
def validate_header(data):
    ok = True
    def chk(off, b0, b1, what):
        if not (data[off] == b0 and data[off + 1] == b1):
            print("  WARN: expected %s (%02X %02X) at offset %d, got %02X %02X"
                  % (what, b0, b1, off, data[off], data[off + 1]))
            return False
        return True
    ok &= chk(0,   0xFF, 0xD8, "SOI")
    ok &= chk(2,   0xFF, 0xE0, "APP0")
    ok &= chk(20,  0xFF, 0xDB, "DQT-luma")
    ok &= chk(89,  0xFF, 0xDB, "DQT-chroma")
    ok &= chk(158, 0xFF, 0xC0, "SOF0")
    ok &= chk(177, 0xFF, 0xC4, "DHT")
    ok &= chk(609, 0xFF, 0xDA, "SOS")
    ok &= chk(len(data) - 2, 0xFF, 0xD9, "EOI")
    return ok


def cmd_prep(inp, outdir):
    with open(inp, "rb") as f:
        data = f.read()
    os.makedirs(outdir, exist_ok=True)
    print("[prep] %s  (%d bytes)" % (inp, len(data)))
    if len(data) <= HDR_SIZE + EOI_BYTES:
        print("  ERROR: file too small to contain scan data")
        return 1
    if not validate_header(data):
        print("  ERROR: header does not match the expected 623-byte layout "
              "(need a LITE/full-mode JPEG with no DRI/EXIF). Pick another file.")
        return 1

    # pack into 32-bit little-endian words
    pad = (-len(data)) % 4
    padded = data + b"\x00" * pad
    words = struct.unpack("<%dI" % (len(padded) // 4), padded)
    hexpath = os.path.join(outdir, "jpeg_words.hex")
    with open(hexpath, "w") as f:
        for w in words:
            f.write("%08x\n" % w)

    width, height = dims_from_sof0(data)
    meta = {"input": os.path.abspath(inp), "size": len(data),
            "words": len(words), "width": width, "height": height}
    with open(os.path.join(outdir, "meta.json"), "w") as f:
        json.dump(meta, f)

    print("  wrote %s (%d words), image %dx%d" % (hexpath, len(words), width, height))
    print("JPEG_BYTES=%d" % len(data))   # parsed by the runner
    print("IMG_W=%d" % width)
    print("IMG_H=%d" % height)
    return 0


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------
def parse_packets(path):
    pkts = []
    with open(path) as f:
        for line in f:
            toks = line.split()
            if toks:
                pkts.append(bytes(int(t, 16) for t in toks))
    return pkts


def be16(b, o):
    return (b[o] << 8) | b[o + 1]


def be24(b, o):
    return (b[o] << 16) | (b[o + 1] << 8) | b[o + 2]


def cmd_check(outdir, captured, inp, expect=None):
    with open(inp, "rb") as f:
        orig = f.read()
    pkts = parse_packets(captured)
    print("[check] %d packets, source %s (%d bytes)" % (len(pkts), inp, len(orig)))
    if not pkts:
        return 1 if _err("no packets captured") is False else 1
    rx_dst_mac = rx_dst_ip = rx_dst_port = None

    orig_scan = orig[SCAN_OFF:len(orig) - EOI_BYTES]
    orig_lqt  = orig[QT_LUMA_OFF:QT_LUMA_OFF + QT_LEN]
    orig_cqt  = orig[QT_CHROMA_OFF:QT_CHROMA_OFF + QT_LEN]
    exp_w, exp_h = dims_from_sof0(orig)
    exp_w8, exp_h8 = exp_w // 8, exp_h // 8

    frags = {}            # frag_offset -> payload bytes
    rx_lqt = rx_cqt = None
    g3 = True
    prev_seq = None
    n = len(pkts)

    for i, p in enumerate(pkts):
        # ---- Ethernet ----
        if len(p) < 14 + 20 + 8 + 12 + 8:
            g3 = _err("packet %d too short (%d B)" % (i, len(p))) and g3
            continue
        ethertype = be16(p, 12)
        if ethertype != 0x0800:
            g3 = _err("packet %d ethertype 0x%04X != 0x0800" % (i, ethertype)) and g3
        # ---- IPv4 ----
        ihl = (p[14] & 0x0F) * 4
        proto = p[14 + 9]
        if proto != 17:
            g3 = _err("packet %d IP proto %d != UDP" % (i, proto)) and g3
        o = 14 + ihl                      # UDP start
        udp_len = be16(p, o + 4)
        if i == 0:
            rx_dst_mac  = p[0:6]
            rx_dst_ip   = p[14 + 16:14 + 20]
            rx_dst_port = be16(p, o + 2)
        # IP total length / UDP length consistency + IP header checksum
        ip_total = be16(p, 16)
        if ip_total != ihl + udp_len:
            g3 = _err("pkt %d ip_total %d != ihl(%d)+udp_len(%d)"
                      % (i, ip_total, ihl, udp_len)) and g3
        ipsum = 0
        for j in range(14, 14 + ihl, 2):
            ipsum += (p[j] << 8) | p[j + 1]
        ipsum = (ipsum & 0xFFFF) + (ipsum >> 16)
        ipsum = (ipsum & 0xFFFF) + (ipsum >> 16)
        if ipsum != 0xFFFF:
            g3 = _err("pkt %d bad IP header checksum (fold=0x%04x)" % (i, ipsum)) and g3
        o += 8                            # RTP start
        # ---- RTP ----
        v = (p[o] >> 6) & 0x3
        marker = (p[o + 1] >> 7) & 0x1
        pt = p[o + 1] & 0x7F
        seq = be16(p, o + 2)
        if v != 2:
            g3 = _err("packet %d RTP version %d != 2" % (i, v)) and g3
        if pt != 26:
            g3 = _err("packet %d RTP PT %d != 26 (JPEG)" % (i, pt)) and g3
        if prev_seq is not None and ((prev_seq + 1) & 0xFFFF) != seq:
            g3 = _err("packet %d seq %d not contiguous (prev %d)"
                      % (i, seq, prev_seq)) and g3
        prev_seq = seq
        want_marker = 1 if i == n - 1 else 0
        if marker != want_marker:
            g3 = _err("packet %d marker %d (expected %d)"
                      % (i, marker, want_marker)) and g3
        o += 12                           # RTP/JPEG main header
        # ---- RTP/JPEG main header ----
        frag = be24(p, o + 1)
        jtype = p[o + 4]
        q = p[o + 5]
        w8 = p[o + 6]
        h8 = p[o + 7]
        if jtype != 0:
            g3 = _err("packet %d JPEG type %d != 0" % (i, jtype)) and g3
        if q != 255:
            g3 = _err("packet %d Q %d != 255" % (i, q)) and g3
        if w8 != exp_w8 or h8 != exp_h8:
            g3 = _err("packet %d dims %d/%d != %d/%d"
                      % (i, w8, h8, exp_w8, exp_h8)) and g3
        o += 8
        # ---- quant-table header on the first fragment ----
        if frag == 0:
            if q < 128:
                g3 = _err("first packet Q<128 but no inline tables") and g3
            qlen = be16(p, o + 2)
            if qlen != 128:
                g3 = _err("quant-table length %d != 128" % qlen) and g3
            o += 4
            rx_lqt = p[o:o + 64]
            rx_cqt = p[o + 64:o + 128]
            o += 128
        # ---- payload (scan fragment) ----
        # trim to the UDP-declared length in case the MAC padded the frame
        udp_end = (14 + ihl) + udp_len
        payload = p[o:udp_end] if udp_end <= len(p) else p[o:]
        frags[frag] = payload

    # ---- reassemble scan ----
    scan = bytearray()
    for off in sorted(frags):
        if off != len(scan):
            print("  WARN: fragment gap: have %d, next offset %d" % (len(scan), off))
        scan += frags[off]
    scan = bytes(scan)

    # ---- Gate 1: scan byte-exact ----
    g1 = (scan == orig_scan)
    if g1:
        print("  G1 PASS: scan byte-exact (%d bytes)" % len(scan))
    else:
        _err("scan mismatch: got %d B, expected %d B" % (len(scan), len(orig_scan)))
        for k in range(min(len(scan), len(orig_scan))):
            if scan[k] != orig_scan[k]:
                print("        first diff at scan byte %d: got %02X exp %02X"
                      % (k, scan[k], orig_scan[k]))
                break

    # ---- Gate 2: quant tables byte-exact ----
    g2 = (rx_lqt == orig_lqt and rx_cqt == orig_cqt)
    print("  G2 %s: in-band quant tables vs original DQT"
          % ("PASS" if g2 else "FAIL"))
    if not g2:
        _err("luma match=%s chroma match=%s"
             % (rx_lqt == orig_lqt, rx_cqt == orig_cqt))

    # ---- Gate 3 ----
    print("  G3 %s: RTP/JPEG structural sanity" % ("PASS" if g3 else "FAIL"))

    # ---- Gate 4: reconstruct (DQT from wire) and decode-compare ----
    g4 = check_decode(orig, scan, rx_lqt, rx_cqt, outdir)

    # ---- Gate 5: captured destination address (M2 only) ----
    g5 = True
    if expect:
        g5 = (rx_dst_mac == expect["mac"] and rx_dst_ip == expect["ip"]
              and rx_dst_port == expect["port"])
        print("  G5 %s: emitted dst = %s / %s / %d (expected %s / %s / %d)"
              % ("PASS" if g5 else "FAIL",
                 rx_dst_mac.hex(), ".".join(str(b) for b in rx_dst_ip), rx_dst_port,
                 expect["mac"].hex(), ".".join(str(b) for b in expect["ip"]),
                 expect["port"]))

    ok = g1 and g2 and g3 and (g4 is not False) and g5
    print("[check] %s" % ("ALL GATES PASS" if ok else "FAILED"))
    return 0 if ok else 1


def check_decode(orig, scan, rx_lqt, rx_cqt, outdir):
    # Rebuild a JFIF using the quant tables carried on the wire and the known-good
    # SOF/DHT/SOS/APP0 from the original; this isolates the wire-carried tables.
    if rx_lqt is None or rx_cqt is None:
        return _err("no inline quant tables to reconstruct from")
    recon = bytearray()
    recon += orig[0:20]                                   # SOI + APP0
    recon += bytes([0xFF, 0xDB, 0x00, 0x43, 0x00]) + rx_lqt
    recon += bytes([0xFF, 0xDB, 0x00, 0x43, 0x01]) + rx_cqt
    recon += orig[158:177]                                # SOF0
    recon += orig[177:609]                                # DHT
    recon += orig[609:623]                                # SOS
    recon += scan
    recon += bytes([0xFF, 0xD9])                          # EOI
    recon = bytes(recon)
    rpath = os.path.join(outdir, "reconstructed.jpg")
    with open(rpath, "wb") as f:
        f.write(recon)
    print("  G4 wrote %s (%d bytes)" % (rpath, len(recon)))

    try:
        from PIL import Image
        import numpy as np
    except Exception:
        print("  G4 SKIP: Pillow/numpy unavailable (byte-checks G1/G2 still hold)")
        return None

    import io
    a = np.asarray(Image.open(io.BytesIO(orig)).convert("YCbCr"), dtype=np.int32)
    b = np.asarray(Image.open(rpath).convert("YCbCr"), dtype=np.int32)
    if a.shape != b.shape:
        return _err("decoded shape %s != %s" % (a.shape, b.shape))
    diff = int(np.abs(a - b).max())
    if diff == 0:
        print("  G4 PASS: reconstructed decodes pixel-identical to original")
        return True
    return _err("decoded pixels differ (max abs %d)" % diff)


def parse_expect(args):
    """Parse optional dstmac=.. dstip=a.b.c.d dstport=N into an expect dict."""
    kv = {}
    for a in args:
        if "=" in a:
            k, v = a.split("=", 1)
            kv[k] = v
    if not ("dstmac" in kv and "dstip" in kv and "dstport" in kv):
        return None
    return {
        "mac": bytes.fromhex(kv["dstmac"]),
        "ip": bytes(int(x) for x in kv["dstip"].split(".")),
        "port": int(kv["dstport"]),
    }


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "prep" and len(sys.argv) == 4:
        return cmd_prep(sys.argv[2], sys.argv[3])
    if len(sys.argv) >= 2 and sys.argv[1] == "check" and len(sys.argv) >= 5:
        expect = parse_expect(sys.argv[5:])
        return cmd_check(sys.argv[2], sys.argv[3], sys.argv[4], expect)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
