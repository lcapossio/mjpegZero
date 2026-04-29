# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies - commercial use requires written permission.
# Copyright (c) 2026 Leonardo Capossio - bard0 design

"""LiteX integration helpers for mjpegZero.

The wrapper intentionally stays thin: it instantiates the existing Verilog
top-level and exposes LiteX stream endpoints plus an AXI-Lite control bus.
JPEG output from the core has no ready signal, so the wrapper can insert a
small LiteX FIFO before presenting a normal ready/valid source.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Union


_ROOT = Path(__file__).resolve().parents[2]
_RTL_DIR = _ROOT / "rtl"

_COMMON_SOURCES = (
    "input_buffer.v",
    "dct_1d.v",
    "dct_2d.v",
    "quantizer.v",
    "zigzag_reorder.v",
    "huffman_encoder.v",
    "bitstream_packer.v",
    "jfif_writer.v",
    "axi4_lite_regs.v",
    "rgb_to_ycbcr.v",
    "mjpegzero_enc_top.v",
)

_VENDOR_BRAM_SOURCES: dict[str, str] = {
    "amd": "vendor/amd/bram_sdp.v",
    "xilinx": "vendor/amd/bram_sdp.v",
    "xilinx7": "vendor/amd/bram_sdp.v",
    "altera": "vendor/altera/bram_sdp.v",
    "intel": "vendor/altera/bram_sdp.v",
    "lattice": "vendor/lattice/bram_sdp.v",
    "microchip": "vendor/microchip/bram_sdp.v",
    "efinix": "vendor/efinix/bram_sdp.v",
    "gowin": "vendor/gowin/bram_sdp.v",
    "sim": "vendor/sim/bram_sdp.v",
}


@dataclass(frozen=True)
class MjpegZeroConfig:
    """Synthesis parameters for ``mjpegzero_enc_top``."""

    lite_mode: int = 1
    lite_quality: int = 95
    img_width: int = 1280
    img_height: int = 720
    exif_enable: int = 0
    exif_x_res: int = 72
    exif_y_res: int = 72
    exif_res_unit: int = 2
    rgb_input: int = 0

    @property
    def video_data_width(self) -> int:
        return 24 if int(self.rgb_input) else 16


def rtl_sources(vendor: str = "amd", rtl_dir: Optional[Union[str, Path]] = None) -> list[Path]:
    """Return the RTL files needed for a LiteX instance."""

    vendor_key = vendor.lower()
    if vendor_key not in _VENDOR_BRAM_SOURCES:
        known = ", ".join(sorted(_VENDOR_BRAM_SOURCES))
        raise ValueError(f"unsupported BRAM vendor {vendor!r}; expected one of: {known}")

    base = Path(rtl_dir) if rtl_dir is not None else _RTL_DIR
    rel_paths = (*_COMMON_SOURCES, _VENDOR_BRAM_SOURCES[vendor_key])
    return [base / rel_path for rel_path in rel_paths]


def add_sources(
    platform: Any,
    vendor: str = "amd",
    rtl_dir: Optional[Union[str, Path]] = None,
) -> None:
    """Add all mjpegZero RTL sources to a LiteX platform."""

    for source in rtl_sources(vendor=vendor, rtl_dir=rtl_dir):
        platform.add_source(str(source))


def _require_litex() -> tuple[Any, Any, Any, Any, Any, Any, type[Any]]:
    try:
        from migen import Cat, ClockSignal, Instance, ResetSignal, Signal
        from litex.gen import LiteXModule
        from litex.soc.interconnect import stream
    except ImportError as exc:
        raise ImportError(
            "mjpegzero LiteX integration requires LiteX/Migen. Install LiteX "
            "in your SoC environment before instantiating MjpegZero."
        ) from exc
    return Cat, ClockSignal, Instance, ResetSignal, Signal, stream, LiteXModule


def _require_axi_lite_interface() -> type[Any]:
    try:
        from litex.soc.interconnect.axi import AXILiteInterface
    except ImportError as exc:
        raise ImportError(
            "AXI-Lite control requires litex.soc.interconnect.axi.AXILiteInterface."
        ) from exc
    return AXILiteInterface


class MjpegZero:
    """LiteX module wrapper around ``mjpegzero_enc_top``.

    Attributes:
        video_sink: LiteX stream sink. Payload has ``data`` and ``user`` fields;
            ``last`` marks end-of-line, ``user`` marks start-of-frame.
        jpeg_source: LiteX stream source carrying JPEG bytes. ``last`` marks EOI.
        axi_lite: AXI-Lite control/status bus for the core register file.
        jpeg_overflow: Sticky indicator that the optional output FIFO filled.

    The encoder itself cannot be backpressured on JPEG output. Keep
    ``jpeg_fifo_depth`` comfortably larger than the worst expected downstream
    stall, or set it to 0 only when the consumer is known to be always-ready.
    """

    def __new__(cls, *args: Any, **kwargs: Any) -> Any:
        *_, LiteXModule = _require_litex()
        if cls is MjpegZero:
            runtime_cls = type("_MjpegZeroLiteX", (MjpegZero, LiteXModule), {})
            return object.__new__(runtime_cls)
        return object.__new__(cls)

    def __init__(
        self,
        platform: Any,
        *,
        config: Optional[MjpegZeroConfig] = None,
        vendor: str = "amd",
        rtl_dir: Optional[Union[str, Path]] = None,
        clock: Optional[Any] = None,
        reset: Optional[Any] = None,
        axi_lite: Optional[Any] = None,
        jpeg_fifo_depth: int = 512,
    ) -> None:
        cat, clock_signal, instance, reset_signal, signal, stream, _ = _require_litex()
        if hasattr(super(), "__init__"):
            super().__init__()

        cfg = config if config is not None else MjpegZeroConfig()
        add_sources(platform, vendor=vendor, rtl_dir=rtl_dir)

        self.config = cfg
        self.vendor = vendor.lower()
        self.video_sink = stream.Endpoint([("data", cfg.video_data_width), ("user", 1)])
        self.jpeg_source = stream.Endpoint([("data", 8)])
        self.jpeg_overflow = signal(reset=0)

        if axi_lite is None:
            axi_lite = _require_axi_lite_interface()(data_width=32, address_width=5)
        self.axi_lite = axi_lite

        jpg_valid = signal()
        jpg_data = signal(8)
        jpg_last = signal()
        jpg_ready = signal(reset=1)

        rst_sig = reset if reset is not None else reset_signal()
        rst_n = signal()
        self.comb += rst_n.eq(~rst_sig)

        self.specials += instance(
            "mjpegzero_enc_top",
            p_LITE_MODE=int(cfg.lite_mode),
            p_LITE_QUALITY=int(cfg.lite_quality),
            p_IMG_WIDTH=int(cfg.img_width),
            p_IMG_HEIGHT=int(cfg.img_height),
            p_EXIF_ENABLE=int(cfg.exif_enable),
            p_EXIF_X_RES=int(cfg.exif_x_res),
            p_EXIF_Y_RES=int(cfg.exif_y_res),
            p_EXIF_RES_UNIT=int(cfg.exif_res_unit),
            p_RGB_INPUT=int(cfg.rgb_input),
            i_clk=clock if clock is not None else clock_signal(),
            i_rst_n=rst_n,
            i_s_axis_vid_tdata=self.video_sink.data,
            i_s_axis_vid_tvalid=self.video_sink.valid,
            o_s_axis_vid_tready=self.video_sink.ready,
            i_s_axis_vid_tlast=self.video_sink.last,
            i_s_axis_vid_tuser=self.video_sink.user,
            o_m_axis_jpg_tvalid=jpg_valid,
            o_m_axis_jpg_tdata=jpg_data,
            o_m_axis_jpg_tlast=jpg_last,
            i_s_axi_awaddr=axi_lite.aw.addr[:5],
            i_s_axi_awvalid=axi_lite.aw.valid,
            o_s_axi_awready=axi_lite.aw.ready,
            i_s_axi_wdata=axi_lite.w.data,
            i_s_axi_wstrb=axi_lite.w.strb,
            i_s_axi_wvalid=axi_lite.w.valid,
            o_s_axi_wready=axi_lite.w.ready,
            o_s_axi_bresp=axi_lite.b.resp,
            o_s_axi_bvalid=axi_lite.b.valid,
            i_s_axi_bready=axi_lite.b.ready,
            i_s_axi_araddr=axi_lite.ar.addr[:5],
            i_s_axi_arvalid=axi_lite.ar.valid,
            o_s_axi_arready=axi_lite.ar.ready,
            o_s_axi_rdata=axi_lite.r.data,
            o_s_axi_rresp=axi_lite.r.resp,
            o_s_axi_rvalid=axi_lite.r.valid,
            i_s_axi_rready=axi_lite.r.ready,
        )

        if int(jpeg_fifo_depth) > 0:
            fifo = stream.SyncFIFO([("data", 8)], depth=int(jpeg_fifo_depth))
            self.submodules.jpeg_fifo = fifo
            self.comb += [
                fifo.sink.valid.eq(jpg_valid),
                fifo.sink.data.eq(jpg_data),
                fifo.sink.last.eq(jpg_last),
                self.jpeg_source.connect(fifo.source),
                jpg_ready.eq(fifo.sink.ready),
            ]
        else:
            self.comb += [
                self.jpeg_source.valid.eq(jpg_valid),
                self.jpeg_source.data.eq(jpg_data),
                self.jpeg_source.last.eq(jpg_last),
                jpg_ready.eq(self.jpeg_source.ready),
            ]

        self.sync += [
            self.jpeg_overflow.eq(self.jpeg_overflow | (jpg_valid & ~jpg_ready)),
        ]


__all__ = [
    "MjpegZero",
    "MjpegZeroConfig",
    "add_sources",
    "rtl_sources",
]
