# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# cocotb test for the demo JPEG output path: jpeg_capture -> demo_jpeg_buffer ->
# jpeg_rtp_tx. Pushes a synthetic JPEG in and checks the RTP/JPEG bytes out,
# locking down the capture<->RTP contract that two real bugs violated:
#   1. cap_done must assert only on the encoder's tlast, never early (an early
#      cap_done on overflow desynced the next frame).
#   2. The streamed scan must equal the buffer scan; the RFC 2435 packetizer
#      drops the trailing EOI and the receiver re-adds it (so a FPGA-written EOI
#      in the last 2 bytes is silently stripped - a no-op that this catches).

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly

SCAN_OFF = 623
EOI_BYTES = 2
QT_LUMA_OFF = 25
QT_CHROMA_OFF = 94
HDRS = 14 + 20 + 8 + 12 + 8      # eth+ip+udp+rtp+jhdr = 62
QT_TOTAL = 4 + 128               # qt header + qt data on the first packet
JPEG_WORDS = 512                 # must match the runner's parameter
JPEG_BYTES = JPEG_WORDS * 4


def _build_jpeg(scan_len):
    header = bytes((i * 7 + 3) & 0xFF for i in range(SCAN_OFF))
    scan = bytes((i * 13 + 5) & 0xFF for i in range(scan_len))
    return header, scan, header + scan + b"\xff\xd9"


async def _reset(dut):
    dut.rst_n.value = 0
    dut.cap_reset.value = 0
    dut.jpg_tvalid.value = 0
    dut.jpg_tdata.value = 0
    dut.jpg_tlast.value = 0
    dut.start.value = 0
    dut.tx_ready.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def _cap_reset(dut):
    dut.cap_reset.value = 1
    await RisingEdge(dut.clk)
    dut.cap_reset.value = 0
    await RisingEdge(dut.clk)


async def _feed(dut, data):
    """Feed bytes 1/cycle; assert cap_done never asserts before tlast."""
    n = len(data)
    for i, b in enumerate(data):
        dut.jpg_tvalid.value = 1
        dut.jpg_tdata.value = b
        dut.jpg_tlast.value = 1 if i == n - 1 else 0
        await ReadOnly()
        assert int(dut.cap_done.value) == 0, \
            f"cap_done asserted early at byte {i}/{n} (must wait for tlast)"
        await RisingEdge(dut.clk)
    dut.jpg_tvalid.value = 0
    dut.jpg_tlast.value = 0
    await RisingEdge(dut.clk)   # cap_done registers here


async def _collect_rtp(dut, timeout=40000):
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    packets, cur, cycles = [], [], 0
    while cycles < timeout:
        await ReadOnly()
        took = int(dut.tx_valid.value) and int(dut.tx_ready.value)
        if took:
            cur.append(int(dut.tx_data.value))
            last = int(dut.tx_last.value)
        done = int(dut.done_pulse.value)
        await RisingEdge(dut.clk)
        cycles += 1
        if took and last:
            packets.append(cur)
            cur = []
        if done and not cur:
            return packets
    raise TimeoutError("RTP did not finish")


def _parse(packets):
    parsed, qt = [], None
    for p in packets:
        frag = (p[55] << 16) | (p[56] << 8) | p[57]
        marker = (p[43] >> 7) & 1
        off = HDRS
        if frag == 0:
            qt = bytes(p[off + 4: off + 4 + 128])
            off += QT_TOTAL
        parsed.append((frag, bytes(p[off:]), marker))
    parsed.sort(key=lambda x: x[0])
    scan = b"".join(payload for _, payload, _ in parsed)
    markers = [m for _, _, m in parsed]
    return scan, qt, markers


@cocotb.test()
async def test_normal_frame(dut):
    """End-to-end: capture a JPEG, stream it, check QT + scan reconstruct."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await _reset(dut)
    await _cap_reset(dut)

    header, scan, jpeg = _build_jpeg(1300)   # 623 + 1300 + 2 = 1925 B, 2 packets
    assert len(jpeg) < JPEG_BYTES
    await _feed(dut, jpeg)

    await ReadOnly()
    assert int(dut.cap_done.value) == 1, "cap_done not set after tlast"
    assert int(dut.overflow.value) == 0, "spurious overflow on a fitting frame"
    assert int(dut.jpeg_size.value) == len(jpeg), \
        f"jpeg_size {int(dut.jpeg_size.value)} != {len(jpeg)}"
    await RisingEdge(dut.clk)

    packets = await _collect_rtp(dut)
    rx_scan, rx_qt, markers = _parse(packets)

    exp_scan = jpeg[SCAN_OFF: len(jpeg) - EOI_BYTES]
    assert rx_scan == exp_scan, \
        f"scan mismatch: got {len(rx_scan)} B, expected {len(exp_scan)} B; " \
        f"tail got {rx_scan[-4:].hex()} exp {exp_scan[-4:].hex()}"
    exp_qt = jpeg[QT_LUMA_OFF:QT_LUMA_OFF + 64] + jpeg[QT_CHROMA_OFF:QT_CHROMA_OFF + 64]
    assert rx_qt == exp_qt, "in-band quant tables mismatch"
    assert markers[-1] == 1 and all(m == 0 for m in markers[:-1]), \
        f"RTP marker bit wrong: {markers}"
    dut._log.info(f"normal: {len(packets)} packets, scan {len(rx_scan)} B OK")


@cocotb.test()
async def test_overflow_partial(dut):
    """Oversized frame: overflow latches, size caps, cap_done still on tlast."""
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await _reset(dut)
    await _cap_reset(dut)

    big = bytes((i * 5 + 1) & 0xFF for i in range(JPEG_BYTES + 500))
    await _feed(dut, big)   # _feed asserts cap_done stays low until tlast

    await ReadOnly()
    assert int(dut.cap_done.value) == 1, "cap_done not set after tlast"
    assert int(dut.overflow.value) == 1, "overflow not latched on oversized frame"
    assert int(dut.jpeg_size.value) == JPEG_BYTES, \
        f"jpeg_size {int(dut.jpeg_size.value)} not capped at {JPEG_BYTES}"
    dut._log.info("overflow: latched, size capped, cap_done synced OK")
