# DEBAYER-PLAN.md — Malvar–He–Cutler 5×5 demosaic, plan of record

Status: **decided, not started** (queued behind `dct_2d` / `input_buffer`).
Scope note: the debayer is an ISP block *upstream* of the encoder — it lives in
this directory because streamline/ is where our spec-grade module work happens,
not because it is part of the mjpegZero encoder proper.

## Decision (2026-07): Malvar–He–Cutler 5×5 from day one

We build the **MHC (gradient-corrected linear) 5×5 demosaic** as the first and
only product kernel. There is **no bilinear product mode** and no planned
"quality upgrade later."

### Rationale

1. **The window engine is ~90% of a debayer; the kernel is ~10%.** Line
   buffers, 5×5 windowing, Bayer phase tracking, and boundary policy dominate
   the work. "Bilinear first" would either (a) build a 3×3 engine that gets
   thrown away when 5×5 arrives, or (b) build the 5×5 engine anyway and run
   bilinear coefficients in it — at which point MHC is a coefficient table
   away. MHC-first avoids doing the hardest work twice.
2. **MHC arithmetic is nearly free in hardware.** All MHC filter coefficients
   are small integers over 8 (values like −1, 2, 4, 5 → shifts and adds).
   **Zero DSPs.** Quality gain over bilinear ≈ 5.5 dB PSNR (Kodak set) — one
   of the best quality-per-LUT bargains available.
3. **Compression synergy.** Bilinear's zipper artifacts are false
   high-frequency energy — the most expensive thing to push through a DCT.
   MHC feeds the encoder cleaner spectra: better images *and* smaller JPEG
   frames at the same Q.
4. **Resources/latency are non-issues.** 4 line buffers × 1920 px × ~12 bit
   ≈ 92 kb (a handful of EBRs on a 3.7 Mb device). Inherent latency
   2 lines + a few pixels ≈ 30 µs at 1080p60 — invisible against a 16.7 ms
   frame period.

Reference: Malvar, He, Cutler, "High-quality linear interpolation for
demosaicing of Bayer-patterned color images," ICASSP 2004. Reference
implementations for the golden model exist in OpenCV, scikit-image, and
libcamera.

## Architecture: two independently verified layers

```text
raw stream → [ 5×5 window engine ] → windows + phase → [ MHC kernel ] → RGB
              line buffers, phase,                      shift/add filters,
              boundary policy                           per-phase variants
```

- **Layer 1 — window engine.** Emits, per output pixel: the 5×5 neighborhood,
  the 2-bit Bayer phase, and boundary-resolved samples. Verified alone.
- **Layer 2 — MHC kernel.** Pure combinational/pipelined arithmetic on a
  window + phase. Verified alone against the golden model.

This split is what makes "MHC from day one, never look back" carry no extra
debug risk: when an image is wrong, the failing layer is already isolated.

## Design requirements (bake in from the start)

- **Runtime-configurable Bayer phase** (2 bits, x/y). The IMX900's crop mode
  determines which RGGB phase arrives first, and crop offsets can change.
  Hardcoded phase is the classic debayer landmine.
- **Boundary policy: mirror-2** (reflect two pixels), the standard companion
  to 5×5 kernels. Fixed, documented in the header Contract, and encoded
  identically in the golden model.
- **Streaming interface** in the house style: valid-only / fixed-latency
  AXI4-Stream-like, SOF/EOL framing, no backpressure, no external DRAM.
- Input width sized for **RAW10/RAW12** (parameterized); output = 3 × 8-bit
  RGB (or wider internal, truncated at the CSC handoff — decide at interface
  spec time).
- Header documented in the streamline **Function / Interface / Contract**
  format, including the latency figure and line-buffer inventory.

## Verification plan

1. **Window-engine unit test** (before any color math exists): feed counting
   ramp patterns; check every emitted window, phase label, and mirror-2
   boundary sample against a ~20-line Python window model. Include minimum
   width/height frames and odd crop phases as corner cases.
2. **Kernel golden model**: bit-exact Python MHC (`verify/debayer_model.py`),
   cross-checked against an independent implementation (OpenCV or
   scikit-image) on real images before being trusted as golden.
3. **Full-module test**: RTL vs golden model, bit-exact, on synthetic and
   photographic test images across all four phases; PSNR-vs-reference report
   in the doc header, `parity.py`-culture style.
4. **Diagnostic kernel** (testbench-only): bilinear coefficients in the same
   5×5 frame, selectable in sim as an isolation tool. Never a product mode.

## Non-goals

- Edge-directed / adaptive demosaicing (diminishing returns; violates the
  fixed-latency, do-it-once philosophy).
- 3×3 economy mode.
- Any dependence on frame buffering or external memory.
