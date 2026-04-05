# Changelog

All notable changes to mjpegZero are documented here.

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

[0.2.0]: https://github.com/bard0-design/mjpegZero/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bard0-design/mjpegZero/releases/tag/v0.1.0
