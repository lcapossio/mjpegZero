# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies - commercial use requires written permission.
# Copyright (c) 2026 Leonardo Capossio - bard0 design

from pathlib import Path
import sys
import types

import pytest

from integrations.litex.mjpegzero import MjpegZero, MjpegZeroConfig, add_sources, rtl_sources


class FakePlatform:
    def __init__(self):
        self.sources = []

    def add_source(self, path):
        self.sources.append(Path(path))


def test_config_video_width_tracks_rgb_mode():
    assert MjpegZeroConfig(rgb_input=0).video_data_width == 16
    assert MjpegZeroConfig(rgb_input=1).video_data_width == 24


def test_rtl_sources_include_common_files_and_vendor_bram():
    sources = [path.as_posix() for path in rtl_sources(vendor="xilinx7", rtl_dir="rtl")]

    assert "rtl/mjpegzero_enc_top.v" in sources
    assert "rtl/axi4_lite_regs.v" in sources
    assert "rtl/vendor/amd/bram_sdp.v" in sources


def test_rtl_sources_reject_unknown_vendor():
    with pytest.raises(ValueError, match="unsupported BRAM vendor"):
        rtl_sources(vendor="mystery")


def test_add_sources_adds_manifest_to_platform():
    platform = FakePlatform()

    add_sources(platform, vendor="sim", rtl_dir="rtl")

    source_names = {source.as_posix() for source in platform.sources}
    assert "rtl/input_buffer.v" in source_names
    assert "rtl/vendor/sim/bram_sdp.v" in source_names


def test_wrapper_import_is_lazy_when_litex_is_not_installed():
    pytest.importorskip("litex")
    pytest.importorskip("migen")
    assert MjpegZero is not None


def test_wrapper_instantiates_with_litex_like_modules(monkeypatch):
    class FakeExpr:
        def __and__(self, other):
            return ("and", self, other)

        def __or__(self, other):
            return ("or", self, other)

        def __invert__(self):
            return ("not", self)

        def __getitem__(self, key):
            return ("slice", self, key)

        def eq(self, other):
            return ("eq", self, other)

    class FakeSignal(FakeExpr):
        def __init__(self, width=1, reset=0):
            self.width = width
            self.reset = reset

        def __len__(self):
            return self.width

    class Collector(list):
        def __iadd__(self, other):
            if isinstance(other, list):
                self.extend(other)
            else:
                self.append(other)
            return self

    class FakeLiteXModule:
        def __init__(self):
            self.comb = Collector()
            self.sync = Collector()
            self.specials = Collector()
            self.submodules = types.SimpleNamespace()

    class FakeEndpoint:
        def __init__(self, layout):
            self.layout = layout
            widths = dict(layout)
            self.data = FakeSignal(widths.get("data", 1))
            self.user = FakeSignal(widths.get("user", 1))
            self.valid = FakeSignal()
            self.ready = FakeSignal()
            self.last = FakeSignal()

        def connect(self, other):
            return [("connect", self, other)]

    class FakeSyncFIFO:
        def __init__(self, layout, depth):
            self.layout = layout
            self.depth = depth
            self.sink = FakeEndpoint(layout)
            self.source = FakeEndpoint(layout)

    class FakeAxiChannel:
        def __init__(self):
            self.addr = FakeSignal(5)
            self.valid = FakeSignal()
            self.ready = FakeSignal()
            self.data = FakeSignal(32)
            self.strb = FakeSignal(4)
            self.resp = FakeSignal(2)

    class FakeAXILiteInterface:
        def __init__(self, data_width, address_width):
            self.data_width = data_width
            self.address_width = address_width
            self.aw = FakeAxiChannel()
            self.w = FakeAxiChannel()
            self.b = FakeAxiChannel()
            self.ar = FakeAxiChannel()
            self.r = FakeAxiChannel()

    migen = types.ModuleType("migen")
    migen.Cat = lambda *signals: ("cat", signals)
    migen.ClockSignal = lambda: FakeSignal()
    migen.Instance = lambda name, **kwargs: ("instance", name, kwargs)
    migen.ResetSignal = lambda: FakeSignal()
    migen.Signal = FakeSignal

    litex = types.ModuleType("litex")
    litex_gen = types.ModuleType("litex.gen")
    litex_gen.LiteXModule = FakeLiteXModule
    litex_soc = types.ModuleType("litex.soc")
    litex_interconnect = types.ModuleType("litex.soc.interconnect")
    litex_stream = types.ModuleType("litex.soc.interconnect.stream")
    litex_stream.Endpoint = FakeEndpoint
    litex_stream.SyncFIFO = FakeSyncFIFO
    litex_axi = types.ModuleType("litex.soc.interconnect.axi")
    litex_axi.AXILiteInterface = FakeAXILiteInterface
    litex_interconnect.stream = litex_stream

    monkeypatch.setitem(sys.modules, "migen", migen)
    monkeypatch.setitem(sys.modules, "litex", litex)
    monkeypatch.setitem(sys.modules, "litex.gen", litex_gen)
    monkeypatch.setitem(sys.modules, "litex.soc", litex_soc)
    monkeypatch.setitem(sys.modules, "litex.soc.interconnect", litex_interconnect)
    monkeypatch.setitem(sys.modules, "litex.soc.interconnect.stream", litex_stream)
    monkeypatch.setitem(sys.modules, "litex.soc.interconnect.axi", litex_axi)

    platform = FakePlatform()
    encoder = MjpegZero(
        platform,
        config=MjpegZeroConfig(lite_quality=75, rgb_input=1),
        vendor="sim",
        rtl_dir="rtl",
        jpeg_fifo_depth=16,
    )

    assert encoder.config.video_data_width == 24
    assert encoder.axi_lite.data_width == 32
    assert encoder.submodules.jpeg_fifo.depth == 16
    assert any(item[0] == "instance" and item[1] == "mjpegzero_enc_top" for item in encoder.specials)
    assert Path("rtl/vendor/sim/bram_sdp.v") in platform.sources
