# Changelog

All notable changes to mjpegZero are documented here.

---

## [Unreleased]

### Added
- **fpgacapZero submodule** (`fcapz/`, pinned to `main`) — vendor-agnostic
  EJTAG-AXI bridge and ELA used by the board demos. The Xilinx `jtag_axi_0`
  Vivado IP is gone; `fcapz_ejtagaxi_xilinx7` (USER4, FIFO_DEPTH=256) and
  `fcapz_ela_xilinx7` (USER1/USER2) take its place.
- **Arty A7-100T post-fcapz build** — `LITE_MODE=1, LITE_QUALITY=75,
  IMG_WIDTH=1280, IMG_HEIGHT=720, JPEG_WORDS=65536`. Closes timing at 150 MHz
  (WNS +0.108 ns post-route). Final ELA config: `SAMPLE_W=16, DEPTH=512,
  INPUT_PIPE=1, no decimation, no timestamps`.
- **Arty S7-50 example project scaffold** — `example_proj/arty_s7_50/` with
  shared `demo_top.v`, board-specific XDC, and `pre_write_bitstream.tcl`
  UCIO-1 hook. Bitstream rebuild + HW verification still pending.
- **AXI4 SLVERR responses** in `demo_top.v` for invalid sizes, non-INCR bursts,
  unaligned addresses, and reads/writes to read-only/write-only ports.
- **Sticky `axi_error` flag** observable via STATUS bit; set from both AXI
  read and write FSMs through a single-driver pulse register
  (`axi_rd_error_pulse`).
- **`armed` STATUS bit and pre-fill arming** — writing CTRL[0] no longer
  starts the encoder immediately; the RTL waits until `pix_count >= 32` and
  reports the intermediate `armed` state via STATUS[4].
- **`jpeg_overflow` flag and write clamps** — JPEG capture writes are gated
  by `jpeg_word_room`/`jpeg_byte_room` and surface as STATUS[1]; `jp_wptr`
  widened to 17 bits, `jpeg_byte_cnt` to 19 bits.
- **JPEG_CAPACITY register** at `0x0200_0008` returning `JPEG_WORDS * 4` so
  the host can size buffers without per-board hardcoded constants.
- **`FcapzHW` host class** in `example_proj/common/python/demo.py` driving the
  board directly via `fcapz.transport.XilinxHwServerTransport` +
  `EjtagAxiController`. No more Vivado-batch subprocess; needs `hw_server` +
  `xsdb` on PATH.
- **Capacity discovery + status decoding** in `demo.py`: reads `JPEG_CAPACITY`
  on connect, lifts overflow/axi_error to Python `RuntimeError` during
  encode polling.
- **Testbench coverage uplift** in `sim/tb_demo_top.sv`: `axi_*_word_resp`
  tasks expose BRESP/RRESP, explicit checks for SLVERR + sticky axi_error,
  STATUS bit sequencing through ARMED → RUNNING → DONE, and `JPEG_CAPACITY`
  vs `JPEG_WORDS_P * 4`.
- **Param-validation `initial begin … $finish`** in `input_buffer.v`,
  `mjpegzero_enc_top.v`, `demo_top.v`, and `demo_top_bare.v` (sim-only) for
  `IMG_WIDTH % 16`, `IMG_HEIGHT % 8`, `LITE_QUALITY ∈ 1..100`, `EXIF_RES_UNIT`
  range, and `JPEG_WORDS` bounds.
- **`hw_test_mandrill.py` rewired** through `FcapzHW` directly — no
  `find_vivado()`, no `host.tcl` round-trip; gains `--bit/--program/--fpga/
  --hw-host/--hw-port/--jpeg-max-bytes` flags.

### Changed
- `demo_top.v` now drives the encoder via `fcapz_ejtagaxi_xilinx7` instead of
  `jtag_axi_0`; reset is active-high (`~rst_n`) on `axi_rst`/`sample_rst`.
- AW_RESP no longer assert+clear `m_bvalid` in the same evaluation step;
  asserts once and holds until `m_bready` (matches AXI4 protocol).
- `m_bvalid` / `m_rresp` now reflect SLVERR for invalid transactions instead
  of always 2'b00.
- Top-level [`README.md`](README.md) `Resource Usage` section now shows the
  `mjpegzero_enc_top` slice extracted from the post-route A7 demo build,
  with the full demo total + WNS noted alongside.
- Tested-Hardware table in [`README.md`](README.md) and the new-board
  template in [`CONTRIBUTING.md`](CONTRIBUTING.md) reflect the
  `common/` shared layout (each board only contributes constraints + scripts).

### Removed
- `example_proj/common/python/host.tcl` — Vivado Hardware Manager script
  superseded by the fcapz Python host.
- `scripts/hw_test_a7.tcl` — Vivado batch wrapper around `host.tcl`.
- `create_ip -name jtag_axi` block from both boards' `create_project.tcl`;
  the Xilinx JTAG-to-AXI Master IP is no longer instantiated.

### Fixed
- Multi-driver `axi_error` reg in `demo_top.v` / `demo_top_bare.v` — the
  AR FSM and AW FSM both wrote it directly, producing undefined synth
  behavior. Now serialised through `axi_rd_error_pulse`.
- `set_property include_dirs` Windows path-split warning ("Failed to create
  directory 'C'") removed by relying on Verilog's quoted-`include`
  same-directory resolution for `fcapz_version.vh`.

---

## [0.2.0] — 2026-04-05

### Added
- **RGB input path** — `RGB_INPUT=1` parameter enables a built-in BT.601
  `rgb_to_ycbcr` color converter; 24-bit `{R,G,B}` AXI4-Stream input is
  converted to YUYV internally.
- **EXIF metadata** — `EXIF_ENABLE=1` embeds an APP1/EXIF segment with
  XResolution, YResolution, and ResolutionUnit IFD0 tags.
- **AXI register tests** — `verify_axi_regs.py` validates QUALITY, FRAME_CNT,
  FRAME_SIZE, STATUS W1C, and RESTART register behaviour over a 2-frame encode.
- **Multi-frame testbench** — `tb_iverilog.sv` supports `NUM_FRAMES` define for
  multi-frame encode sequences with inter-frame synchronization.
- **AXI protocol assertions** in `tb_iverilog.sv` — checks AR/AW/W/R/B channel
  protocol rules (ready-without-valid, rvalid-without-request, etc.).
- **Coverage improvements** — flat-gray (DC/EOB), checkerboard (ZRL), and
  `EXIF_ENABLE=1` coverage scenarios in `run_coverage.py`.
- **Corner-case tests** — random input backpressure gaps (`--gaps`), minimum
  16×8 frame width (`--min-width`) in `verify_rtl_sim.py` and CI.
- **RGB_INPUT=1 functional simulation** in CI (iverilog, full + lite).
- **Full-mode EXIF test** in CI (previously only tested in lite mode).
- **Vendor BRAM stub lint** — CI now lints all vendor BRAM wrappers.
- **Lint LITE_MODE=0, RGB_INPUT=1** — new CI lint combination.
- **Makefile** — convenience targets for verify, lint, sim, coverage, and clean.
- **`docs/ARCHITECTURE.md`** — design rationale covering subsampling, pipeline
  stages, quality scaling, no-backpressure decision, and full vs. lite mode.
- **`python/requirements.txt`** — declared Python dependencies.
- **FuseSoC** — `EXIF_ENABLE`, `EXIF_X_RES`, `EXIF_Y_RES`, `EXIF_RES_UNIT`,
  `RGB_INPUT` parameters added to all targets; `rgb_to_ycbcr.v` added to RTL
  fileset.

### Changed
- `.gitignore` — replaced blanket `example_proj/arty_s7_50/` ignore with
  pattern-based `example_proj/*/build/` (tracks source, ignores artifacts).
- All Python sim scripts (`verify_rtl_sim.py`, `verify_exif.py`,
  `verify_axi_regs.py`, `run_coverage.py`, `run_verilator_sim.py`) now include
  `rgb_to_ycbcr.v` in their RTL file lists.

### Fixed
- Bare `except:` clause in `compare_jpeg_scan.py` changed to `except Exception:`.

---

## [0.1.0] — 2026-03-09

First public release.

---

[Unreleased]: https://github.com/bard0-design/mjpegZero/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/bard0-design/mjpegZero/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bard0-design/mjpegZero/releases/tag/v0.1.0
