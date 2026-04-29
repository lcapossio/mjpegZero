<a id="top"></a>
# mjpegZero — FPGA Hardware Motion JPEG Encoder

[![CI](https://github.com/lcapossio/mjpegZero/actions/workflows/ci.yml/badge.svg)](https://github.com/lcapossio/mjpegZero/actions/workflows/ci.yml)
[![License: Apache 2.0 + Commons Clause](https://img.shields.io/badge/license-Apache%202.0%20%2B%20Commons%20Clause-blue.svg)](LICENSE)
[![RTL: Verilog 2001](https://img.shields.io/badge/RTL-Verilog%202001-orange.svg)](rtl/)
[![FuseSoC](https://img.shields.io/badge/FuseSoC-compatible-blueviolet.svg)](mjpegzero.core)

**Author:** Leonardo Capossio - [bard0 design](https://www.bard0.com) - <hello@bard0.com>

Synthesizable MJPEG encoder written in behavioral Verilog 2001 with AXI interfaces, up to 1080p30 on low end AMD/Xilinx 7-Series FPGAs. Two operating modes: **Full** encodes with runtime quality control;
**Lite** encodes with ~47% smaller LUT footprint and fixed synthesis-time quality.

A Python reference encoder is included for validation and test vector generation.

<!-- index:start -->
<a id="index"></a>
## Index

- [Architecture](#architecture)
- [Interfaces](#interfaces)
  - [Video Input — AXI4-Stream Slave](#video-input-axi4-stream-slave)
  - [JPEG Output — AXI4-Stream Master (8-bit)](#jpeg-output-axi4-stream-master-8-bit)
  - [Control — AXI4-Lite Slave (32-bit)](#control-axi4-lite-slave-32-bit)
- [Parameters](#parameters)
- [Capabilities](#capabilities)
- [Performance](#performance)
  - [Compression (Mandrill test image)](#compression-mandrill-test-image)
- [Resource Usage](#resource-usage)
- [Pipeline Modules](#pipeline-modules)
- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [Verification](#verification)
    - [Tier 1 — Python-only (no simulator, no Vivado)](#tier-1-python-only-no-simulator-no-vivado)
    - [Tier 2 — RTL simulation with iverilog  ← CI path](#tier-2-rtl-simulation-with-iverilog-ci-path)
    - [Verilator code coverage (optional, requires Verilator ≥ 4.2)](#verilator-code-coverage-optional-requires-verilator-4-2)
    - [Tier 3 — Full 720p Vivado simulation  (local only, requires Vivado)](#tier-3-full-720p-vivado-simulation-local-only-requires-vivado)
  - [FuseSoC](#fusesoc)
  - [LiteX Integration](#litex-integration)
  - [Run Synthesis](#run-synthesis)
  - [Run Implementation (Place & Route)](#run-implementation-place-route)
  - [Utility Scripts](#utility-scripts)
- [Integration Example](#integration-example)
- [Tested Hardware](#tested-hardware)
- [Applications](#applications)
- [Directory Structure](#directory-structure)
- [Contributing](#contributing)
- [License](#license)

<!-- index:end -->

<a id="architecture"></a>
## Architecture <sub>[↑ Top](#top)</sub>


```
                  +----------------------------------------------------------+
                  |                  mjpegzero_enc_top                        |
                  |                                                          |
  AXI4-Stream  -->| Input    --> 2D  --> Quant --> Zigzag --> Huffman -->     |
  16-bit YUYV     | Buffer      DCT     izer      Reorder    Encoder         |
                  |                                                          |
                  |    --> Bitstream --> JFIF    -->  AXI4-Stream 8-bit JPEG  |
                  |       Packer        Writer                               |
                  |                                                          |
  AXI4-Lite    <->| Register File (ctrl, status, quality, frame count)       |
                  +----------------------------------------------------------+
```

<a id="interfaces"></a>
## Interfaces <sub>[↑ Top](#top)</sub>


<a id="video-input-axi4-stream-slave"></a>
### Video Input — AXI4-Stream Slave <sub>[↑ Top](#top)</sub>


| Signal               | Width | Direction | Description                        |
|----------------------|-------|-----------|------------------------------------|
| `s_axis_vid_tdata`   | 16/24 | In        | YUYV (16-bit) or RGB (24-bit, when `RGB_INPUT=1`) |
| `s_axis_vid_tvalid`  | 1     | In        | Data valid                         |
| `s_axis_vid_tready`  | 1     | Out       | Backpressure                       |
| `s_axis_vid_tlast`   | 1     | In        | End of scanline                    |
| `s_axis_vid_tuser`   | 1     | In        | Start of frame (first pixel)       |

**YUYV mode** (`RGB_INPUT=0`, default): 16-bit words. Even-indexed words carry
`{Cb, Y}`, odd-indexed carry `{Cr, Y}`. One word per pixel.

**RGB mode** (`RGB_INPUT=1`): 24-bit words `{R[23:16], G[15:8], B[7:0]}`. One
word per pixel. An internal BT.601 color converter produces YUYV for the pipeline.

<a id="jpeg-output-axi4-stream-master-8-bit"></a>
### JPEG Output — AXI4-Stream Master (8-bit) <sub>[↑ Top](#top)</sub>


| Signal               | Width | Direction | Description                  |
|----------------------|-------|-----------|------------------------------|
| `m_axis_jpg_tdata`   | 8     | Out       | JPEG byte                    |
| `m_axis_jpg_tvalid`  | 1     | Out       | Byte valid                   |
| `m_axis_jpg_tlast`   | 1     | Out       | End of JPEG frame            |

Output is a complete JFIF file (SOI through EOI) per frame.
Byte stuffing (0xFF → 0xFF 0x00) is handled internally.

**No backpressure.** The output has no `tready` signal — the consumer must always
accept data when `tvalid` is asserted. This is safe because compression reduces
the data rate well below the input rate. If the downstream sink may stall
(e.g., shared DMA bus), place a small FIFO (256–512 bytes) between the encoder
output and the sink.

<a id="control-axi4-lite-slave-32-bit"></a>
### Control — AXI4-Lite Slave (32-bit) <sub>[↑ Top](#top)</sub>


| Offset | Name       | Access | Description                            |
|--------|------------|--------|----------------------------------------|
| 0x00   | CTRL       | R/W    | `[0]` enable, `[1]` soft_reset        |
| 0x04   | STATUS     | R/W1C  | `[0]` busy, `[1]` frame_done          |
| 0x08   | FRAME_CNT  | RO     | Completed frame count                  |
| 0x0C   | QUALITY    | R/W    | JPEG quality factor (1–100, default 95)|
| 0x10   | RESTART    | R/W    | Restart interval in MCUs (0 = disabled)|
| 0x14   | FRAME_SIZE | RO     | Byte count of last completed frame     |

<a id="parameters"></a>
## Parameters <sub>[↑ Top](#top)</sub>


| Parameter       | Default | Description                                                      |
|-----------------|---------|------------------------------------------------------------------|
| `LITE_MODE`     | 1       | 0 = full (1080p30, runtime quality), 1 = lite (720p60)          |
| `LITE_QUALITY`  | 95      | Synthesis-time quality 1–100, used when LITE_MODE=1             |
| `IMG_WIDTH`     | 1280    | Input image width in pixels (multiple of 16)                    |
| `IMG_HEIGHT`    | 720     | Input image height in pixels (multiple of 8)                    |
| `EXIF_ENABLE`   | 0       | 1 = embed APP1/EXIF segment immediately after APP0              |
| `EXIF_X_RES`    | 72      | EXIF XResolution numerator (DPI when `EXIF_RES_UNIT=2`)         |
| `EXIF_Y_RES`    | 72      | EXIF YResolution numerator                                      |
| `EXIF_RES_UNIT` | 2       | EXIF ResolutionUnit: 1 = no unit, 2 = inch, 3 = cm             |
| `RGB_INPUT`     | 0       | 1 = 24-bit `{R,G,B}` AXI4-Stream input; 0 = 16-bit YUYV (default) |

<a id="capabilities"></a>
## Capabilities <sub>[↑ Top](#top)</sub>


- **Standard**: Baseline JPEG (ITU-T T.81), JFIF 1.01 container
- **Chroma**: YUV 4:2:2 (H=2, V=1 subsampling)
- **Tables**: Standard Huffman tables (Annex K), standard quantization tables
- **Quality**: Runtime via AXI4-Lite register (1–100) in full mode; synthesis-time via `LITE_QUALITY` (1–100, default 95) in lite mode
- **Resolution**: Parameterizable; validated at 1920×1080, 1280×720, and 640×480
- **Frame rate**: 1080p30 (full mode), 720p60 (lite mode), both at 150 MHz
- **Output**: Complete JFIF files with SOI, APP0, [APP1/EXIF], DQT, SOF0, DHT, SOS, DRI/RST, EOI
- **EXIF**: Optional APP1/EXIF segment (`EXIF_ENABLE=1`) with XResolution, YResolution, ResolutionUnit IFD0 tags
- **RGB input**: Optional built-in BT.601 color converter (`RGB_INPUT=1`) accepts 24-bit `{R,G,B}` and produces YUYV internally

<a id="performance"></a>
## Performance <sub>[↑ Top](#top)</sub>


Both modes run at 150 MHz, delivering 2,343,750 blocks/sec with ~1 MCU row latency (8 lines).

| Metric              | Full Mode                  | Lite Mode                       |
|---------------------|----------------------------|---------------------------------|
| Use case            | HD capture, quality tuning | Cost-sensitive streaming        |
| Target resolution   | 1920×1080 (1080p30)        | 1280×720 (720p60)               |
| Quality             | Runtime adjustable (1–100) | Synthesis-time (1–100, Q95 default) |
| Pipeline headroom   | 1080p30: 83%               | 720p60: 74%                     |

<a id="compression-mandrill-test-image"></a>
### Compression (Mandrill test image) <sub>[↑ Top](#top)</sub>


| Image    | Quality | Uncompressed (RGB) | JPEG Output | Ratio  | Bits/pixel | PSNR vs original |
|----------|---------|--------------------|-------------|--------|------------|------------------|
| 512×512  | Q95     | 768 KB             | 211 KB      |  3.6:1 | 5.29       | 42.38 dB¹        |
| 1280×720 | Q95     | 2,700 KB           | 569 KB      |  4.7:1 | 4.93       | 37.77 dB         |
| 1280×720 | Q75     | 2,700 KB           | 230 KB      | 11.8:1 | 2.04       | 38.45 dB         |

¹ 42.38 dB is the coefficient-level PSNR of the RTL output vs the Python reference (measures
how closely the RTL matches the reference encoder, not the original image).

**Hardware verification — Mandrill 1280×720, Q75** (Original | HW output | RTL sim | Diff×8):

![HW vs Sim comparison](assets/hw_comparison.png)

HW and RTL simulation outputs are byte-exact (PSNR = ∞ dB, Y-PSNR 49.56 dB vs original).

<a id="resource-usage"></a>
## Resource Usage <sub>[↑ Top](#top)</sub>

The numbers below are for the MJPEG encoder core (`mjpegzero_enc_top`) only.
They exclude the Arty demo wrapper, fcapz EJTAG-AXI debug bridge, fcapz ELA,
and the large on-chip JPEG readback buffer used by the hardware demo.

Current hardware-verified configuration: Lite mode, 1280x720, Q75, extracted
from the post-route hierarchy of the Arty A7-100T demo build. This row is the
`mjpegzero_enc_top` instance only.

| Configuration | LUTs | LUTRAM | FFs | BRAM | DSP48E1 |
|---------------|-----:|-------:|----:|------|--------:|
| Lite 720p Q75, 150 MHz | 2,045 | 136 | 1,895 | 11 RAMB36 + 1 RAMB18 | 21 |

The 11 RAMB36 blocks are the 720p Y/Cb/Cr input line buffers. The extra RAMB18
is inferred inside the core for small ROM/storage structures in the placed
design. The full Arty demo build, including fcapz and the JPEG readback buffer,
closes timing at WNS +0.108 ns.

<a id="pipeline-modules"></a>
## Pipeline Modules <sub>[↑ Top](#top)</sub>


| Module              | File                         | Description                                               |
|---------------------|------------------------------|-----------------------------------------------------------|
| RGB→YUYV Converter  | `rtl/rgb_to_ycbcr.v`         | Optional BT.601 3-stage pipeline; enabled by `RGB_INPUT=1` |
| Input Buffer        | `rtl/input_buffer.v`         | YUYV de-interleave, 8-line BRAM buffer, MCU-order output  |
| 1D DCT              | `rtl/dct_1d.v`               | 8-point forward DCT, matrix multiply with 13-bit cosine ROM |
| 2D DCT              | `rtl/dct_2d.v`               | Row-column decomposition with transpose buffer            |
| Quantizer           | `rtl/quantizer.v`            | Multiply-by-reciprocal, 4-stage pipeline                  |
| Zigzag Reorder      | `rtl/zigzag_reorder.v`       | ROM-based address remap, double-buffered                  |
| Huffman Encoder     | `rtl/huffman_encoder.v`      | Multi-cycle FSM, full DC/AC standard tables               |
| Bitstream Packer    | `rtl/bitstream_packer.v`     | 64-bit accumulator, byte stuffing                         |
| JFIF Writer         | `rtl/jfif_writer.v`          | Header ROM, SOI/APP0/[APP1-EXIF]/DQT…EOI state machine   |
| AXI4-Lite Regs      | `rtl/axi4_lite_regs.v`       | Control/status register file                              |
| SDP BRAM            | `rtl/bram_sdp.v`             | Behavioural wrapper; vendor-specific primitives in `rtl/vendor/` |
| Top-Level           | `rtl/mjpegzero_enc_top.v`    | Pipeline integration and frame control                    |
| Timing Wrapper      | `rtl/synth_timing_wrapper.v` | I/O flip-flops for synthesis timing analysis              |

All pipeline modules are written in behavioural Verilog 2001. The only vendor-specific
file is `rtl/bram_sdp.v`, which instantiates the AMD `RAMB36E1` primitive. Equivalents
for other vendors are provided as stubs under `rtl/vendor/` and are drop-in replacements.

<a id="quick-start"></a>
## Quick Start <sub>[↑ Top](#top)</sub>


<a id="prerequisites"></a>
### Prerequisites <sub>[↑ Top](#top)</sub>


- AMD/Xilinx Vivado 2020.2+ (tested with 2025.2)
- Python 3.8+ with NumPy, SciPy, Pillow (for reference encoder)
- FFmpeg (for validation)

```bash
pip install -r python/requirements.txt
```

<a id="verification"></a>
### Verification <sub>[↑ Top](#top)</sub>


The verification suite is split into three tiers. The first two tiers require
only Python and iverilog — they are what GitHub Actions CI runs on every push.
The third tier requires Vivado and is for local full-frame validation.

<a id="tier-1-python-only-no-simulator-no-vivado"></a>
#### Tier 1 — Python-only (no simulator, no Vivado) <sub>[↑ Top](#top)</sub>


```bash
# Huffman ROM tables match ITU-T T.81 Annex K
python python/verify_huffman_rom.py

# LITE_QUALITY quantisation & reciprocal tables match Python reference
python python/verify_lite_quality.py

# Python reference encoder: encode 720p mandrill, decode, report PSNR
python python/test_encoder.py

# Visual quality check: side-by-side Original | JPEG decoded | Difference×8
python python/mandrill_compare.py --quality 95
python python/mandrill_compare.py --quality 75 --out compare_q75.png
```

<a id="tier-2-rtl-simulation-with-iverilog-ci-path"></a>
#### Tier 2 — RTL simulation with iverilog  ← CI path <sub>[↑ Top](#top)</sub>


Compiles all RTL with iverilog, runs the CI testbench, and compares output
JPEG coefficients block-by-block against Python reference files for Q=50, 75, 95.
Pass criterion: max coefficient difference ≤ 1 (fixed-point rounding tolerance).

```bash
# Full mode (LITE_MODE=0, runtime quality via AXI4-Lite)
python python/verify_rtl_sim.py

# Lite mode (LITE_MODE=1, synthesis-time quality tables)
python python/verify_rtl_sim.py --lite

# With VCD dump
python python/verify_rtl_sim.py --dump-vcd

# Optionally simulate with the real Xilinx RAMB36E1 primitive (requires Vivado)
python python/verify_rtl_sim.py --unisims auto

# RGB_INPUT=1 functional test (24-bit RGB through built-in color converter)
python python/verify_rtl_sim.py --rgb
python python/verify_rtl_sim.py --lite --rgb

# Random input backpressure gaps (tests input_buffer gap handling)
python python/verify_rtl_sim.py --gaps

# Minimum-width 16×8 frame (1 MCU — corner case for MCU column counter)
python python/verify_rtl_sim.py --min-width

# EXIF APP1 segment validation (full mode, 72 DPI default)
python python/verify_exif.py
python python/verify_exif.py --lite --x-res 96 --y-res 96 --res-unit 2

# AXI4-Lite register coverage (2-frame encode, reads back QUALITY/FRAME_CNT/FRAME_SIZE/STATUS)
python python/verify_axi_regs.py
python python/verify_axi_regs.py --lite
```

Requires: `iverilog` / `vvp` on PATH, Python ≥ 3.8 with NumPy.
Without `--unisims`, a portable behavioural BRAM model is used (default, CI path).

<a id="verilator-code-coverage-optional-requires-verilator-4-2"></a>
#### Verilator code coverage (optional, requires Verilator ≥ 4.2) <sub>[↑ Top](#top)</sub>


Compiles the RTL with `--coverage`, runs six scenarios designed to hit all major
code paths (Q=50/75/95, flat-gray image for DC/EOB paths, checkerboard image for
ZRL paths, and an `EXIF_ENABLE=1` build for EXIF state coverage), merges the
coverage data, and generates an LCOV report.

```bash
# Full mode — Q=50/75/95 + flat + checkerboard + EXIF run
python python/run_coverage.py

# Lite mode
python python/run_coverage.py --lite

# With HTML report (requires lcov/genhtml)
python python/run_coverage.py --html

# Custom quality set
python python/run_coverage.py --qualities 75,95
```

Coverage data is written to `build/coverage/`. LCOV info at
`build/coverage/coverage.info`; HTML report (if `--html`) at
`build/coverage/html/index.html`.

<a id="tier-3-full-720p-vivado-simulation-local-only-requires-vivado"></a>
#### Tier 3 — Full 720p Vivado simulation  (local only, requires Vivado) <sub>[↑ Top](#top)</sub>


```bash
python scripts/run_sim.py 720p           # no waveforms
python scripts/run_sim.py 720p vcd       # + VCD dump → build/sim/tb_mjpegzero_enc.vcd
python scripts/run_sim.py lite vcd       # lite mode with VCD
```

Output JPEG is written to `build/sim/sim_output.jpg`. Verified PSNR vs original: **37.77 dB**.

<a id="fusesoc"></a>
### FuseSoC <sub>[↑ Top](#top)</sub>


The core is described in [`mjpegzero.core`](mjpegzero.core) (CAPI2 format).

```bash
# Add core to local library
fusesoc library add mjpegzero .

# Run simulation (icarus, full mode)
fusesoc run --target sim bard0-design:mjpegzero:mjpegzero_enc

# Run simulation (lite mode)
fusesoc run --target sim_lite bard0-design:mjpegzero:mjpegzero_enc

# Lint with Verilator
fusesoc run --target lint bard0-design:mjpegzero:mjpegzero_enc

# Synthesize for AMD/Xilinx Arty A7-100T
fusesoc run --target synth_amd bard0-design:mjpegzero:mjpegzero_enc

# Override parameters
fusesoc run --target sim bard0-design:mjpegzero:mjpegzero_enc \
  --LITE_MODE 0 --IMG_WIDTH 1920 --IMG_HEIGHT 1080
```

Available targets: `sim`, `sim_lite`, `lint`, `synth_amd`, `synth_amd_lite`.

To use mjpegZero as a dependency in your own FuseSoC project, add to your `.core` file:
```yaml
depend:
  - bard0-design:mjpegzero:mjpegzero_enc:0.1.0
```

<a id="litex-integration"></a>
### LiteX Integration <sub>[↑ Top](#top)</sub>

A project-local LiteX wrapper is provided in
[`integrations/litex/mjpegzero.py`](integrations/litex/mjpegzero.py). It adds
the Verilog sources to a LiteX platform, instantiates `mjpegzero_enc_top`,
exposes a LiteX video stream sink, exposes a JPEG byte stream source, and keeps
the core register file on AXI-Lite.

```python
from integrations.litex.mjpegzero import MjpegZero, MjpegZeroConfig

encoder = MjpegZero(
    platform,
    config=MjpegZeroConfig(
        lite_mode=1,
        lite_quality=75,
        img_width=1280,
        img_height=720,
        rgb_input=0,
    ),
    vendor="xilinx7",
    jpeg_fifo_depth=512,
)

# encoder.video_sink:  data/valid/ready/last/user input stream
# encoder.jpeg_source: data/valid/ready/last JPEG byte stream
# encoder.axi_lite:    AXI-Lite control/status register bus
```

The encoder's native JPEG output has no `tready`. The LiteX wrapper therefore
inserts an optional stream FIFO and exposes `jpeg_overflow` as a sticky
indicator if the downstream consumer stalls longer than the FIFO can absorb.

<a id="run-synthesis"></a>
### Run Synthesis <sub>[↑ Top](#top)</sub>


```bash
# Using the master runner (recommended):
python scripts/run_all.py synth               # Full mode, AMD/Xilinx (default)
python scripts/run_all.py synth --vendor amd
python scripts/run_all.py impl  --vendor amd

# Direct Vivado invocation:
# Full mode (1920×1080, 150 MHz, runtime quality)
vivado -mode batch -source scripts/synth/amd/run_synth.tcl

# Lite mode (1280×720, 150 MHz, default Q95)
vivado -mode batch -source scripts/synth/amd/run_synth.tcl -tclargs lite

# Lite mode with custom quality (e.g., Q80)
vivado -mode batch -source scripts/synth/amd/run_synth.tcl -tclargs lite 80
```

Reports are written to `build/synth/` or `build/synth_lite/`.

AMD/Vivado and Altera/Quartus scripts are fully implemented.
Synthesis scripts for Lattice Radiant, Microchip Libero, Efinix Efinity, and GoWin EDA
are scaffolded in `scripts/synth/<vendor>/` — implement the tool-specific Tcl flow and
replace `rtl/bram_sdp.v` with the matching `rtl/vendor/<vendor>/bram_sdp.v`.
Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

<a id="run-implementation-place-route"></a>
### Run Implementation (Place & Route) <sub>[↑ Top](#top)</sub>


```bash
python scripts/run_all.py impl
```

Reports are written to `build/impl/`.

<a id="utility-scripts"></a>
### Utility Scripts <sub>[↑ Top](#top)</sub>


| Script | Purpose |
|--------|---------|
| `python/mandrill_compare.py` | Encode/decode the mandrill image and produce a side-by-side PNG: Original \| JPEG decoded \| Difference×8. |
| `python/compare_jpeg_scan.py` | Block-by-block DCT coefficient comparison between two JPEG files. |
| `python/verify_exif.py` | RTL simulation test for the APP1/EXIF segment; validates all IFD0 fields byte-by-byte. |
| `python/verify_axi_regs.py` | AXI4-Lite register coverage test: QUALITY, FRAME_CNT, FRAME_SIZE, STATUS W1C, RESTART (2-frame encode). |
| `python/run_coverage.py` | Verilator `--coverage` driver: compiles RTL, runs Q=50/75/95 + flat/checker/EXIF scenarios, merges `.dat` files, produces LCOV report. |
| `python/generate_test_vectors.py` | Generates all simulation test vectors including `yuyv_input.hex`, `yuyv_flat.hex` (DC/EOB coverage), and `yuyv_checker.hex` (ZRL coverage). |
| `python/gen_huffman_rom.py` | Regenerate the Huffman ROM `initial` block in `rtl/huffman_encoder.v` from the standard BITS/VALS arrays. |
| `python/gen_lite_tables.py` | Regenerate the LITE_QUALITY quantisation table `initial` blocks in `rtl/quantizer.v`. |
| `python/yuyv_convert.py` | Shared RGB-to-YUYV conversion for RTL simulation and hardware tests. |
| `scripts/hw_test_mandrill.py` | End-to-end hardware verification through fcapz: converts mandrill 720p, runs RTL sim + HW encode, compares outputs. |

<a id="integration-example"></a>
## Integration Example <sub>[↑ Top](#top)</sub>


```verilog
mjpegzero_enc_top #(
    .IMG_WIDTH    (1920),
    .IMG_HEIGHT   (1080),
    .LITE_MODE    (0),         // 1 = fixed quality, 720p, ~47% fewer LUTs
    .LITE_QUALITY (95),        // Synthesis-time quality (1-100), lite mode only
    // Optional: EXIF APP1 segment
    .EXIF_ENABLE  (1),         // 0 = no EXIF (default)
    .EXIF_X_RES   (72),        // XResolution numerator (DPI)
    .EXIF_Y_RES   (72),        // YResolution numerator
    .EXIF_RES_UNIT(2),         // 2 = inch
    // Optional: RGB input path (set to 0 for standard YUYV input)
    .RGB_INPUT    (0)          // 1 = 24-bit {R,G,B} AXI4-Stream input
) u_mjpeg (
    .clk               (pixel_clk),        // 150 MHz
    .rst_n             (sys_rst_n),

    // Connect to video source (camera, framebuffer, etc.)
    .s_axis_vid_tdata  (video_tdata),       // 16-bit YUYV
    .s_axis_vid_tvalid (video_tvalid),
    .s_axis_vid_tready (video_tready),
    .s_axis_vid_tlast  (video_tlast),       // End of line
    .s_axis_vid_tuser  (video_tuser),       // Start of frame

    // Connect to DMA or output FIFO (no backpressure — always accept)
    .m_axis_jpg_tdata  (jpeg_tdata),        // 8-bit JPEG bytes
    .m_axis_jpg_tvalid (jpeg_tvalid),
    .m_axis_jpg_tlast  (jpeg_tlast),        // End of JPEG frame

    // Connect to AXI interconnect or tie off
    .s_axi_awaddr      (axi_awaddr),
    .s_axi_awvalid     (axi_awvalid),
    .s_axi_awready     (axi_awready),
    .s_axi_wdata       (axi_wdata),
    .s_axi_wstrb       (axi_wstrb),
    .s_axi_wvalid      (axi_wvalid),
    .s_axi_wready      (axi_wready),
    .s_axi_bresp       (axi_bresp),
    .s_axi_bvalid      (axi_bvalid),
    .s_axi_bready      (axi_bready),
    .s_axi_araddr      (axi_araddr),
    .s_axi_arvalid     (axi_arvalid),
    .s_axi_arready     (axi_arready),
    .s_axi_rdata       (axi_rdata),
    .s_axi_rresp       (axi_rresp),
    .s_axi_rvalid      (axi_rvalid),
    .s_axi_rready      (axi_rready)
);
```

<a id="tested-hardware"></a>
## Tested Hardware <sub>[↑ Top](#top)</sub>


| Board | Part | Example project | Status |
|-------|------|-----------------|--------|
| Digilent Arty A7-100T | XC7A100TCSG324-1 | [`example_proj/arty_a7_100t/`](example_proj/arty_a7_100t/) | HW verified |

Any AMD/Xilinx 7-Series device is a straightforward port — swap the XDC and adjust `JPEG_WORDS`
for available BRAM. Vendor BRAM wrappers for Altera, Lattice, Microchip, Efinix, and Gowin are
provided as stubs in `rtl/vendor/`.

<a id="applications"></a>
## Applications <sub>[↑ Top](#top)</sub>


- **Drone / UAV cameras** — lightweight MJPEG stream over a low-bandwidth radio link
- **IP security cameras** — per-frame JPEG over Ethernet, no inter-frame dependency
- **Machine vision** — on-FPGA compression before USB/GigE transfer to host
- **Medical imaging** — lossless-adjacent quality (Q95+) with intra-frame-only coding
- **Automotive** — dashcam and surround-view recording with frame-accurate random access
- **Industrial inspection** — compress high-speed line-scan data in real time
- **Broadcast contribution** — MJPEG-over-RTP for low-latency studio feeds
- **Frame grabbers** — capture and compress SDI/HDMI input on an FPGA capture card

<a id="directory-structure"></a>
## Directory Structure <sub>[↑ Top](#top)</sub>


```
mjpegZero/
  rtl/              Synthesizable Verilog 2001 source
    vendor/         Board-specific BRAM wrappers (AMD, Altera, Lattice, …)
  sim/              SystemVerilog testbench and test vectors
  python/           Reference encoder, verification, test vector generation
  scripts/          Vivado TCL scripts and Python runner
  example_proj/     Ready-to-build board examples
    arty_a7_100t/   Digilent Arty A7-100T (HW verified)
  build/            Synthesis/implementation output (generated)
```

<a id="contributing"></a>
## Contributing <sub>[↑ Top](#top)</sub>


Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

The most impactful contributions are **board-level examples** that show the encoder
running on hardware beyond the reference Arty A7-100T. All examples live under
[`example_proj/<board_name>/`](example_proj/). New examples for Nexys Video,
ZedBoard, DE10-Nano, iCEBreaker, and others are welcome.

<a id="license"></a>
## License <sub>[↑ Top](#top)</sub>


Apache License 2.0 + Commons Clause v1.0. See [LICENSE](LICENSE) for full terms.

**Non-commercial use** (research, education, hobby projects, open-source) is
freely permitted under the Apache 2.0 terms.

**Commercial use** (integration into commercial products, services, or
consulting engagements) requires written permission from the author.
Contact: hello@bard0.com
