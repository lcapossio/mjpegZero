#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# packer_golden.py — golden model + comparison for the bitstream packer bench
# ============================================================================
# Reads packer_in.log (the codes/events the DUT actually accepted, in order)
# and recomputes the byte stream per ITU-T T.81: MSB-first concatenation,
# 0xFF -> 0xFF 0x00 stuffing, restart = pad-1s + 0xFF + 0xD0+m (m cycles
# 0..7), flush = pad-1s + closing 0x00 byte (stream terminator, uncounted).
# Compares against packer_out.bin. Exit 0 on exact match.
#
# Usage: packer_golden.py <workdir>
# ============================================================================

import sys
import os


def main():
    wd = sys.argv[1]
    bits = ''          # pending bit string
    out = bytearray()  # expected stream
    m = 0              # restart marker modulus

    def drain_full_bytes():
        nonlocal bits
        while len(bits) >= 8:
            byte = int(bits[:8], 2)
            bits = bits[8:]
            out.append(byte)
            if byte == 0xFF:
                out.append(0x00)

    def pad_and_drain():
        nonlocal bits
        if bits:
            bits = bits.ljust((len(bits) + 7) // 8 * 8, '1')
        drain_full_bytes()

    for line in open(os.path.join(wd, 'packer_in.log')):
        parts = line.split()
        if parts[0] == 'C':
            code, length = int(parts[1], 16), int(parts[2])
            bits += format(code >> (32 - length), '0%db' % length)
            drain_full_bytes()
        elif parts[0] == 'R':
            pad_and_drain()
            out += bytes([0xFF, 0xD0 + m])
            m = (m + 1) % 8
        elif parts[0] == 'F':
            pad_and_drain()
            out.append(0x00)   # closing byte carrying out_last

    got = open(os.path.join(wd, 'packer_out.bin'), 'rb').read()
    if bytes(out) == got:
        print('GOLDEN OK: %d bytes match' % len(got))
        return 0
    n = min(len(out), len(got))
    diff = next((i for i in range(n) if out[i] != got[i]), n)
    print('GOLDEN FAIL: expected %d bytes, got %d, first diff at %d '
          '(expected %02x, got %02x)'
          % (len(out), len(got), diff,
             out[diff] if diff < len(out) else 0x100,
             got[diff] if diff < len(got) else 0x100))
    return 1


if __name__ == '__main__':
    sys.exit(main())
