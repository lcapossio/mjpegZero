# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# Shared cocotb test for mjpegzero_enc_top. The SAME test runs against the
# Verilog port (Icarus) and the VHDL port (GHDL) - the encoder's top-level AXI
# ports are identical in both, so this is a black-box drive/capture test.
#
# Mirrors the golden-vector stimulus of sim/tb_iverilog.sv: reset, CTRL enable +
# QUALITY over AXI4-Lite, feed N frames of YUYV from yuyv_input.hex on the AXIS
# slave, capture the JPEG bytes on the AXIS master, then compare coefficients
# against the committed Python golden reference (reused from verify_rtl_sim).
#
# Config comes from env (set by test_runner.py) so this file is location- and
# OS-independent: ENC_TV_DIR, ENC_PY_DIR, ENC_REF, ENC_QUALITY, ENC_FRAMES.

import os
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

TV_DIR = Path(os.environ["ENC_TV_DIR"])
REF = Path(os.environ["ENC_REF"])
QUALITY = int(os.environ.get("ENC_QUALITY", "95"))
FRAMES = int(os.environ.get("ENC_FRAMES", "1"))

IMG_W, IMG_H = 64, 8
NUM_MCUS = (IMG_W // 16) * (IMG_H // 8)  # 4:2:2 MCU is 16x8 -> 4 MCUs

sys.path.insert(0, os.environ["ENC_PY_DIR"])
from verify_rtl_sim import compare_jpegs  # noqa: E402  (reuse the golden checker)


def _i(sig):
    """Read a signal as int, treating X/Z as 0 (only used post-reset)."""
    try:
        return int(sig.value)
    except Exception:
        return 0


async def axi_write(dut, addr, data):
    await RisingEdge(dut.clk)
    dut.s_axi_awaddr.value = addr
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wdata.value = data
    dut.s_axi_wstrb.value = 0xF
    dut.s_axi_wvalid.value = 1
    dut.s_axi_bready.value = 1
    aw = w = False
    for _ in range(200):
        await RisingEdge(dut.clk)
        if not aw and _i(dut.s_axi_awready):
            aw = True
            dut.s_axi_awvalid.value = 0
        if not w and _i(dut.s_axi_wready):
            w = True
            dut.s_axi_wvalid.value = 0
        if aw and w:
            break
    for _ in range(200):
        if _i(dut.s_axi_bvalid):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_axi_bready.value = 0


async def feed_frame(dut, vid):
    idx = 0
    for y in range(IMG_H):
        for x in range(IMG_W):
            await FallingEdge(dut.clk)
            dut.s_axis_vid_tvalid.value = 1
            dut.s_axis_vid_tuser.value = 1 if (x == 0 and y == 0) else 0
            dut.s_axis_vid_tlast.value = 1 if (x == IMG_W - 1) else 0
            dut.s_axis_vid_tdata.value = vid[idx]
            idx += 1
            while _i(dut.s_axis_vid_tready) == 0:
                await FallingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_axis_vid_tvalid.value = 0
    dut.s_axis_vid_tlast.value = 0
    dut.s_axis_vid_tuser.value = 0


@cocotb.test()
async def golden(dut):
    frames = []

    async def capture():
        cur = bytearray()
        while True:
            await RisingEdge(dut.clk)
            if _i(dut.m_axis_jpg_tvalid):
                cur.append(_i(dut.m_axis_jpg_tdata) & 0xFF)
                if _i(dut.m_axis_jpg_tlast):
                    frames.append(bytes(cur))
                    cur = bytearray()

    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())

    dut.rst_n.value = 0
    for s in ("s_axis_vid_tvalid", "s_axis_vid_tlast", "s_axis_vid_tuser",
              "s_axi_awvalid", "s_axi_wvalid", "s_axi_bready",
              "s_axi_arvalid", "s_axi_rready"):
        getattr(dut, s).value = 0
    for s in ("s_axis_vid_tdata", "s_axi_awaddr", "s_axi_wdata", "s_axi_wstrb",
              "s_axi_araddr"):
        getattr(dut, s).value = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)

    dut._log.info("reset released")
    cocotb.start_soon(capture())
    await axi_write(dut, 0x00, 0x1)      # CTRL: enable
    await axi_write(dut, 0x0C, QUALITY)  # QUALITY (full mode; ignored in lite)
    for _ in range(600):
        await RisingEdge(dut.clk)
    dut._log.info(f"AXI configured; vid tready={_i(dut.s_axis_vid_tready)}")

    vid = [int(tok, 16) for tok in TV_DIR.joinpath("yuyv_input.hex").read_text().split()]

    for f in range(FRAMES):
        await feed_frame(dut, vid)
        dut._log.info(f"frame {f} fed ({len(vid)} px); waiting for JPEG ...")
        for _ in range(40000):
            if len(frames) > f:
                break
            await RisingEdge(dut.clk)
        assert len(frames) > f, f"frame {f} produced no JPEG output"
        dut._log.info(f"frame {f} captured: {len(frames[-1])} bytes")
        for _ in range(20):
            await RisingEdge(dut.clk)

    out = Path.cwd() / "cocotb_output.jpg"
    out.write_bytes(frames[-1])
    passed, max_dc, max_ac = compare_jpegs(str(REF), str(out), NUM_MCUS)
    dut._log.info(
        f"frames={len(frames)} last={len(frames[-1])}B "
        f"vs {REF.name}: max_dc={max_dc} max_ac={max_ac}"
    )
    assert passed, f"golden mismatch vs {REF.name}: max_dc={max_dc} max_ac={max_ac}"
