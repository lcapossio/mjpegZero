# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# Back-to-back multi-frame stream test for mjpegzero_enc_top, shared by the
# Verilog port (Icarus) and the VHDL port (GHDL). The cocotb counterpart of
# sim/tb_iverilog.sv's STREAM mode, driven by python/verify_stream.py, which
# generates the input, runs this test and checks every frame's JPEG.
#
# Config (env, set by verify_stream.py):
#   STREAM_HEX       input words, one pixel per line (YUYV 16-bit or RGB 24-bit)
#   STREAM_OUT       directory for sim_output_f<k>.jpg
#   STREAM_W/H       frame size;  STREAM_FRAMES  number of frames
#   STREAM_QUALITY   QUALITY written before frame 0
#   STREAM_QUALITY2  (optional) QUALITY written halfway through frame 0's input
#   STREAM_RESTART   RESTART interval (MCUs)
#   STREAM_GAPS      1 = random input valid gaps
#   STREAM_TOGGLE_EN 1 = clear CTRL.enable for 3000 cycles mid-frame 0

import os
import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

W = int(os.environ["STREAM_W"])
H = int(os.environ["STREAM_H"])
FRAMES = int(os.environ["STREAM_FRAMES"])
QUALITY = int(os.environ.get("STREAM_QUALITY", "95"))
QUALITY2 = os.environ.get("STREAM_QUALITY2")
RESTART = int(os.environ.get("STREAM_RESTART", "0"))
GAPS = os.environ.get("STREAM_GAPS", "0") == "1"
TOGGLE_EN = os.environ.get("STREAM_TOGGLE_EN", "0") == "1"
OUT = Path(os.environ["STREAM_OUT"])
HEX = Path(os.environ["STREAM_HEX"])


def _i(sig):
    """Read a signal as int, treating X/Z as 0 (only used post-reset)."""
    try:
        return int(sig.value)
    except Exception:
        return 0


class Axi:
    """AXI4-Lite master: drive on the falling edge, sample handshakes at the
    rising edge (readies are combinational in the DUT). Serialized by a flag
    because the mid-frame writes run concurrently with the main sequence."""

    def __init__(self, dut):
        self.dut = dut
        self.busy = False

    async def _acquire(self):
        while self.busy:
            await RisingEdge(self.dut.clk)
        self.busy = True

    async def write(self, addr, data, strb=0xF):
        d = self.dut
        await self._acquire()
        await FallingEdge(d.clk)
        d.s_axi_awaddr.value = addr
        d.s_axi_awvalid.value = 1
        d.s_axi_wdata.value = data
        d.s_axi_wstrb.value = strb
        d.s_axi_wvalid.value = 1
        # (cocotb applies writes later in the timestep, so our own valids are
        # tracked here rather than read back from the signals)
        aw = w = False
        for _ in range(1000):
            aw_hs = not aw and _i(d.s_axi_awready)
            w_hs = not w and _i(d.s_axi_wready)
            await RisingEdge(d.clk)
            aw |= bool(aw_hs)
            w |= bool(w_hs)
            await FallingEdge(d.clk)
            if aw:
                d.s_axi_awvalid.value = 0
            if w:
                d.s_axi_wvalid.value = 0
            if aw and w:
                break
        assert aw and w, f"AXI write 0x{addr:02X}: no AW/W handshake"
        for _ in range(1000):
            if _i(d.s_axi_bvalid):
                break
            await FallingEdge(d.clk)
        assert _i(d.s_axi_bvalid), f"AXI write 0x{addr:02X}: no B response"
        d.s_axi_bready.value = 1
        await FallingEdge(d.clk)
        d.s_axi_bready.value = 0
        self.busy = False

    async def read(self, addr):
        d = self.dut
        await self._acquire()
        await FallingEdge(d.clk)
        d.s_axi_araddr.value = addr
        d.s_axi_arvalid.value = 1
        for _ in range(1000):
            hs = _i(d.s_axi_arready)
            await RisingEdge(d.clk)
            await FallingEdge(d.clk)
            if hs:
                break
        d.s_axi_arvalid.value = 0
        for _ in range(1000):
            if _i(d.s_axi_rvalid):
                break
            await FallingEdge(d.clk)
        assert _i(d.s_axi_rvalid), f"AXI read 0x{addr:02X}: no R response"
        val = _i(d.s_axi_rdata)
        d.s_axi_rready.value = 1
        await FallingEdge(d.clk)
        d.s_axi_rready.value = 0
        self.busy = False
        return val


@cocotb.test()
async def stream(dut):
    vid = [int(tok, 16) for tok in HEX.read_text().split()]
    assert len(vid) == W * H * FRAMES, f"{HEX}: {len(vid)} words, expected {W * H * FRAMES}"
    frames = []
    rng = random.Random(0x5EED)

    async def capture():
        cur = bytearray()
        while True:
            await RisingEdge(dut.clk)
            if _i(dut.m_axis_jpg_tvalid):
                cur.append(_i(dut.m_axis_jpg_tdata) & 0xFF)
                if _i(dut.m_axis_jpg_tlast):
                    k = len(frames)
                    frames.append(bytes(cur))
                    OUT.joinpath(f"sim_output_f{k}.jpg").write_bytes(bytes(cur))
                    dut._log.info(f"frame {k} complete: {len(cur)} bytes")
                    cur = bytearray()

    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst_n.value = 0
    for s in ("s_axis_vid_tvalid", "s_axis_vid_tlast", "s_axis_vid_tuser",
              "s_axi_awvalid", "s_axi_wvalid", "s_axi_bready",
              "s_axi_arvalid", "s_axi_rready", "s_axis_vid_tdata",
              "s_axi_awaddr", "s_axi_wdata", "s_axi_wstrb", "s_axi_araddr"):
        getattr(dut, s).value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)

    axi = Axi(dut)
    cocotb.start_soon(capture())
    await axi.write(0x0C, QUALITY)       # QUALITY (ignored in lite)
    await axi.write(0x10, RESTART)       # RESTART interval
    await axi.write(0x00, 0x1)           # CTRL: enable

    async def mid_frame():
        if QUALITY2 is not None:
            dut._log.info(f"mid-frame 0: QUALITY <= {QUALITY2}")
            await axi.write(0x0C, int(QUALITY2))
        if TOGGLE_EN:
            dut._log.info("mid-frame 0: ENABLE <= 0 for 3000 cycles")
            await axi.write(0x00, 0x0)
            for _ in range(3000):
                await RisingEdge(dut.clk)
            await axi.write(0x00, 0x1)

    # Feed all frames back to back (next SOF right after the last pixel)
    idx = 0
    for f in range(FRAMES):
        for y in range(H):
            if f == 0 and y == H // 2:
                cocotb.start_soon(mid_frame())
            for x in range(W):
                await FallingEdge(dut.clk)
                if GAPS:
                    while rng.random() < 0.25:
                        dut.s_axis_vid_tvalid.value = 0
                        await FallingEdge(dut.clk)
                dut.s_axis_vid_tvalid.value = 1
                dut.s_axis_vid_tuser.value = 1 if (x == 0 and y == 0) else 0
                dut.s_axis_vid_tlast.value = 1 if x == W - 1 else 0
                dut.s_axis_vid_tdata.value = vid[idx]
                idx += 1
                while _i(dut.s_axis_vid_tready) == 0:
                    await FallingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_axis_vid_tvalid.value = 0
    dut.s_axis_vid_tlast.value = 0
    dut.s_axis_vid_tuser.value = 0

    for _ in range(200 * W * H + 100000):
        if len(frames) >= FRAMES:
            break
        await RisingEdge(dut.clk)
    assert len(frames) == FRAMES, f"only {len(frames)}/{FRAMES} frames produced"
    for _ in range(2000):                # nothing may follow the last frame
        await RisingEdge(dut.clk)
    assert len(frames) == FRAMES, f"{len(frames)} frames produced, expected {FRAMES}"

    # Status registers
    fcnt = await axi.read(0x08)
    fsize = await axi.read(0x14)
    status = await axi.read(0x04)
    assert fcnt == FRAMES, f"FRAME_CNT={fcnt}, expected {FRAMES}"
    assert fsize == len(frames[-1]), f"FRAME_SIZE={fsize}, expected {len(frames[-1])}"
    assert status & 0x2, f"STATUS=0x{status:X}: frame_done not set"
    await axi.write(0x04, 0x2)          # W1C frame_done
    status = await axi.read(0x04)
    assert not status & 0x2, f"STATUS=0x{status:X}: frame_done not cleared by W1C"
    dut._log.info(f"registers OK: FRAME_CNT={fcnt} FRAME_SIZE={fsize}")
