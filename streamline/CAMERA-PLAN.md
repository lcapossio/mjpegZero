# CAMERA-PLAN.md — IMX900C → ISP → MJPEG → UVC on CrossLinkU-NX

Companion to [ENCODER-PLAN.md](ENCODER-PLAN.md), which governs the streamline rewrite of the
JPEG encoder. This plan covers everything **around** that encoder needed to
ship a complete camera: sensor control, MIPI/CSI-2 reception, the RAW and RGB
ISP stages, a RISC-V control processor with C firmware, and UVC delivery over
the CrossLinkU-NX hardened USB 3.2 Gen 1 interface. The pipeline inventory
and stage rationale come from [SUMMARY.md](SUMMARY.md).

The two standards from ENCODER-PLAN.md apply unchanged and extend to firmware:

1. **Timeless, blameless source** (ENCODER-PLAN.md §4) — for Verilog *and* C. C files
   state what they do and why, grounded in the datasheet, the USB/UVC specs,
   or the mathematics; no history, no tool anecdotes, no references to code
   they replaced.
2. **Swap-and-verify** (ENCODER-PLAN.md §7) — proven on mjpegZero: begin from a
   known-good baseline, replace one stage at a time behind a stable
   interface, and verify each swap against a golden model before the next.
   Here the baseline is the Lattice CrossLinkU-NX UVC reference design
   instead of `rtl/`.

## 1. Objectives and end state

| # | Goal | How it is measured |
|---|------|--------------------|
| C-G1 | IMX900C streams into the FPGA: CSI-2 frames received, unpacked, frame/line sync locked | Frame counter + CRC-checked capture of sensor test pattern |
| C-G2 | Full ISP in our own Verilog: BLC → WB → debayer → CCM → gamma → CSC → 4:2:2 | Per-stage bit-exact match against the Python golden model |
| C-G3 | UVC camera enumerates and streams MJPEG to stock hosts (Linux/macOS/Windows, no custom driver) | `v4l2-ctl`/QuickTime/Camera app playback at target mode |
| C-G4 | **Sustained 1920×1080 at 60 fps end to end — the stated objective** | Host-side frame-rate and drop-count measurement |
| C-G5 | Control plane = our RV32I core + C firmware: sensor config, exposure/WB loops, UVC requests, JPEG rate control | Firmware unit tests + on-target behavior |
| C-G6 | Every module we author passes the timelessness review and `verilator -Wall`; C compiles warning-free with `-Wall -Wextra` | Review gate per merge |
| C-G7 | Fits LIFCL-33U with ≥ 15% LUT headroom | Radiant post-route utilization |
| C-G8 | Image quality: gray-world neutral gray scenes, no visible fixed-pattern artifacts, decoded PSNR within 1 dB of the Python ISP+JPEG model on captured RAW | Golden-RAW replay comparison |

Non-goals for v1: 4:2:0, scaling (crop only), H.264, USB UAC/audio, DPC/LSC
(insertion points reserved), auto-focus. **4K is out of scope permanently on
this sensor**: the IMX900C's active array is ~2048×1536 (3.2 MP) and 4K
needs 8.3 MP — no architecture choice changes that. The ceiling here is
1080p60 (the objective) and, with the same throughput architecture,
full-sensor 2048×1536 at roughly 45 fps.

## 2. The hardware/software split

One rule decides where every function lives:

- **Per-pixel or per-line rate → Verilog.** D-PHY byte handling, CSI-2
  unpacking, all ISP arithmetic, JPEG, UVC payload framing, FIFOs/CDC.
- **Per-frame rate or slower → C on the RV32 core.** Sensor register
  programming, exposure/white-balance loops (consuming hardware-computed
  statistics), UVC control requests (probe/commit, controls), CCM/gamma
  table updates, JPEG quality/rate control, fault handling, telemetry.
- **Needed before the CPU exists → ROM sequencer.** Sensor bring-up uses a
  ROM-driven I2C register sequencer so first pixels never wait on firmware;
  the CPU later drives the same I2C master through the same CSR bus, and
  the sequencer remains as the fallback bring-up path.

The CPU is **our own RV32I core** (machine mode, ~2 stage, AXI4-Lite
master), written to the same standard as every other module — it is
deliberately the *last* major block built (Phase C6), once a working
camera exists to host it. Until then, control paths are ROM tables and
small FSMs that the CPU later subsumes.

Everything in the pixel path is our Verilog by the end state, with one
pragmatic exception: the D-PHY **electrical** layer uses Lattice IO/SerDes
primitives (that layer is silicon, not RTL, on any vendor); our ownership
begins at byte alignment. The Lattice soft D-PHY RX, CSI-2 decoder, and
debayer IP serve as known-good baseline stages during bring-up and are
replaced by ours in Phases C3–C4 via swap-and-verify.

## 3. Repository layout

```
streamline/camera/
  rtl/
    ctrl/    i2c_master.v  seq_rom.v  csr_fabric.v
    csi/     dphy_byte_align.v  csi2_rx.v  raw_unpack.v  frame_sync.v
    isp/     blc.v  wb_gains.v  debayer.v  ccm.v  gamma_lut.v
             csc_422.v  crop.v  stats_ae_awb.v
    cpu/     rv32_core.v  rv32_soc.v  (bus bridges, timer, mailbox)
    uvc/     uvc_packetizer.v  usb_ep_fifo.v  descriptors (generated)
    top/     camera_top.v  clocks/resets/CDC
  fw/        C sources: init, uvc_ctrl, ae_awb, rate_ctrl, main loop
  model/     Python golden ISP (stage-per-file, bit-exact fixed point)
  sim/       cocotb/iverilog benches; csi2_frame_gen; RAW replay vectors
  boards/    LIFCL-33U-EVN constraints, Radiant project, pinout
```

The JPEG encoder is consumed from `streamline/` as-is (it is
drop-in-parameterized and already verified); its remaining phases (ENCODER-PLAN.md
Phases 2–4) proceed independently and this plan only assumes the Phase 1
back end.

## 4. Bandwidth and resource budget (verified at C0, tracked every phase)

- **Pixel rates.** The objective, 1920×1080@60, is 124.4 Mpx/s; the ISP
  runs one pixel per clock and closes at ≥ 135 MHz. The JPEG coefficient
  path carries 2 coefficients per pixel at 4:2:2 → **248.9 Mcoeff/s, beyond
  any single 1-coefficient/clock path at a realistic Nexus-fabric clock**
  (150 MHz sustains ~1080p36). See "Reaching 1080p60" below.
- **Reaching 1080p60 — restart-interval parallelism.** Two JPEG encoder
  cores encode alternating restart intervals of the same scan. T.81 makes
  intervals fully independent: DC predictors reset at every restart marker
  and each segment is byte-aligned, so a merger interleaves finished
  segments byte-for-byte losslessly. Each core sees ~124 Mcoeff/s — inside
  the envelope the streamline back end already sustains — and the same
  structure yields full-sensor 2048×1536 at ~45 fps. Two consequences:
  restart markers (DRI) are **mandatory in every frame**, so the packer's
  restart-path correctness (ENCODER-RESULTS.md defect 2, fixed in streamline) is
  load-bearing; and the interval length is chosen per mode so both cores'
  workloads balance (one MCU row per interval is the starting point).
- **USB.** 1080p30 MJPEG at typical quality ≈ 3–8 MB/s — far inside USB 3.2
  Gen 1; even worst-case Q95 frames fit with 10× margin. The frame-drop
  policy (§8, C5) exists for pathological frames, not steady state.
- **LUT budget (rough, to be measured at C0 and re-baselined per phase):**
  CSI-2 RX + unpack ~3k, ISP ~7k, **two** JPEG coefficient paths at ~6.5k
  each (assumes the Loeffler DCT and HUFF_BANKS=2 land first — they are
  prerequisites, not options), shared JFIF writer + segment merger ~1.5k,
  UVC/FIFO ~3k, RV32 SoC ~4k, glue/CDC ~1k → ~31k of 33k. This is the
  plan's tightest constraint and the reason C-G7's headroom target is 15%:
  if the dual-core budget misses at the C5 gate, the fallbacks are, in
  order, 4:2:0 (drops the coefficient rate to 186.7 Mcoeff/s — still
  dual-core, but smaller line buffers elsewhere), reduced-height crop at
  60 fps, or 1080p45 single-core while the budget is recovered.
- **Multipliers.** LIFCL-33U DSP capacity is the scarcest resource: ISP
  (WB, CCM, debayer) and DCT compete. The budget table in CAMERA-RESULTS.md
  gets a DSP column from C0 onward.

## 5. Verification strategy

The mjpegZero experience generalizes:

1. **Python golden ISP** (`model/`) written first, stage per file, exact
   fixed-point semantics (widths, rounding, saturation stated in both the
   model and the RTL header). Every Verilog stage has a two-run bench:
   random + directed images through RTL and model, bit-exact compare.
2. **CSI-2 frame generator** in simulation: synthetic Bayer frames wrapped
   in D-PHY byte streams with real packet headers, ECC, CRC, blanking, and
   deliberate error injection (ECC-correctable, CRC-fail, short frame).
3. **RAW replay.** From C2 onward, captured sensor frames (test pattern,
   then live scenes) become regression vectors: replayed through both the
   RTL pipeline (simulation) and the Python model; decoded-image PSNR is
   the C-G8 gate.
4. **Firmware.** C compiled twice: for RV32 (target) and natively for the
   host, where unit tests run against a Python-scripted CSR mock. UVC
   descriptor tables are generated from one Python source of truth into
   both C structs and the hardware descriptor ROM — one definition, no
   drift.
5. **Hardware-in-loop.** The hardened USB path cannot be fully simulated;
   from C1 every phase ends with an on-board checkpoint (enumeration, then
   test-pattern streaming, then live video), with `dmesg`/`v4l2-ctl`
   evidence recorded in CAMERA-RESULTS.md.

## 6. Sensor control detail (C on RV32; ROM sequencer at bring-up)

Firmware owns, in order of introduction: power/reset/clock sequencing
(datasheet §power-up), base register configuration (lane count/speed, RAW
format, ROI, frame rate), exposure and gain, then closed loops — AE from
hardware luma histograms, AWB from gray-world statistics, both computed in
`stats_ae_awb.v` per frame and read over the CSR bus. Loop cadence is
per-frame; no firmware ever touches pixel data.

## 7. UVC detail (split per the §2 rule)

- **Verilog:** payload header insertion (FID toggle, EOF, PTS/SCR when
  enabled), frame boundary tracking from the JPEG core's `tlast`, endpoint
  FIFOs and CDC into the USB clock domain, descriptor ROM service.
- **C:** enumeration-time descriptor delivery, VideoControl and
  VideoStreaming request handling, probe/commit negotiation state, format
  and frame-interval decisions handed to hardware as CSR writes, and error
  recovery (halt/clear, overflow restart).

## 8. Phases and gates

| Phase | Content | Gate |
|-------|---------|------|
| C0 | Platform: Radiant flow for LIFCL-33U-EVN, Lattice UVC reference builds and enumerates unmodified; UART + LED heartbeat; resource baseline recorded | Host sees the reference UVC device; utilization report archived |
| C1 | Reference streaming checkpoint with its supported source (RPi CM2 sensor or internal test pattern) | Host plays reference video; we can rebuild it deterministically |
| C2 | IMX900C bring-up: power/clock/reset, ROM-driven I2C sequencer, D-PHY/CSI-2 (Lattice baseline) adapted to IMX900 lane rate/count/format; frame_sync + raw_unpack (ours) | C-G1: CRC-checked sensor test-pattern frames captured; sequencer ROM generated from a reviewed register table |
| C3 | RAW ISP (ours): black-level correction, WB gains, active-region extraction; golden model for each; stats block skeleton | Bit-exact vs model on replayed RAW; test-pattern image visually correct via debug path |
| C4 | RGB ISP (ours): debayer (**Malvar–He–Cutler 5×5 from the start** — see the C4 debayer note below), CCM, gamma LUT, full-range CSC with **filtered** 4:2:2 (not chroma drop), center crop | Bit-exact vs model per stage; Lattice debayer retired; first live color image via debug path |
| C5 | JPEG + UVC datapath, single core first: streamline encoder integrated, MCU formatting via its input buffer, UVC packetizer + endpoint FIFOs (ours), descriptors from the generator, probe/commit in a minimal FSM, defined frame-drop policy | C-G3 at fixed quality: stock host plays live 1080p30 MJPEG |
| C5b | Throughput doubling: second coefficient path + restart-interval splitter and byte-aligned segment merger; DRI on in every frame; sensor mode raised to 60 fps | **C-G4: sustained 1080p60 on a stock host**; merged stream byte-identical to a single-core encode of the same frame at the same DRI |
| C6 | RV32I core + SoC + firmware: our CPU replaces the probe/commit FSM and takes over sensor control; AE/AWB loops on hardware statistics; JPEG rate control (per the encoder's frame-boundary quality contract) | C-G5; sequencer/FSM fallbacks still build; firmware unit tests green |
| C7 | Image quality round: defective-pixel correction, lens-shading correction (coarse grid + bilinear), chroma filter improvements, tuned CCM/gamma from captures | C-G8; before/after captures archived |
| C8 | Hardening: error injection (CSI errors, USB stalls, sensor dropout) recovers without power cycle; soak test; final timelessness review; CAMERA-RESULTS.md closure | All C-G goals; 24 h soak, zero lockups |

Order rationale: pixels first (C2) because nothing else is debuggable
without them; ISP before USB because the debug path (capture-to-host over
the existing UART/JTAG or the reference USB pipe) lets each stage be seen;
the CPU deliberately late (§2); image quality after the end-to-end path
because tuning needs real captured frames flowing through the real encoder.

### C4 debayer note — MHC 5×5 from day one (decided 2026-07)

The debayer is built as **Malvar–He–Cutler 5×5 from the start; no bilinear
product mode**. Rationale: the window engine (line buffers, 5×5 windowing,
Bayer phase, boundary policy) is ~90% of a debayer and would have to be
rebuilt when moving 3×3 → 5×5, so "bilinear first" does the hardest work
twice; MHC's coefficients are integers over 8 (shift/add only, zero DSPs —
which also softens §4's multiplier-budget pressure) for ≈5.5 dB PSNR over
bilinear; and cleaner edges mean less false high-frequency energy through
the DCT — better images *and* smaller frames at the same Q. Cost is
4 line buffers (≈92 kb ≈ a few EBRs) and 2 lines of latency (~30 µs at
1080p60).

Debug risk is contained by the two-layer discipline: the **window engine**
(emitting 5×5 neighborhood + 2-bit phase + mirror-2 boundary samples) is
unit-verified against a Python window model *before any color math exists*;
the **MHC kernel** is verified separately against a golden model
cross-checked with OpenCV/scikit-image. A bilinear coefficient set may
exist in the same 5×5 frame as a **testbench-only diagnostic**, never a
product mode. Bayer phase is **runtime-configurable** (2 bits, x/y): the
IMX900C's crop offsets determine which RGGB phase arrives first.

Full decision record, requirements, and verification plan:
[DEBAYER-PLAN.md](DEBAYER-PLAN.md).

## 9. Deliverables

- `camera/` tree per §3, every module ours except the D-PHY electrical
  primitives, all to the ENCODER-PLAN.md §4 standard
- `model/` golden ISP + the descriptor/register-table generators
- `fw/` C firmware with host-runnable unit tests
- `CAMERA-RESULTS.md` — per-phase measurements: utilization, fmax, frame rate,
  PSNR, capture evidence
- Bring-up notes per phase in commit messages and CAMERA-RESULTS.md — never in
  the source
