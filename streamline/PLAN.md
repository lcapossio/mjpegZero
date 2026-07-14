# streamline/ — Plan for the Optimized MJPEG Encoder RTL

## 1. Purpose

`streamline/` will contain a heavily optimized rewrite of every Verilog module in
`rtl/`, produced module-by-module, starting with the quantizer and the Huffman
encoder. Each module is a **drop-in replacement**: same filename, same module
name, same ports, so any mix of `rtl/` and `streamline/` modules can be
simulated and synthesized together, and every replacement can be verified in
isolation against the module it replaces.

Two qualities define the deliverable, and they are equally important:

1. **Performance** — every stage sustains one sample per clock in the worst
   case, the design closes timing at 150 MHz with margin on the reference
   part (Spartan-7 XC7S50), and resource usage goes down, not up.

2. **Timeless, blameless source** — every file reads as if it were the first
   and only implementation. Comments state what the code does and why each
   step exists, grounded in the JPEG standard, the mathematics, or a hardware
   constraint. No file references another codebase, a prior version, a fixed
   bug, or a tool anecdote. The code has no past — only a present.

## 2. End-state goals (definition of success)

The project is complete when all of the following hold:

| # | Goal | How it is measured |
|---|------|--------------------|
| G1 | Full encoder built entirely from `streamline/` produces **spec-valid JPEGs** at every supported resolution/quality | Decode with libjpeg; structural validation of markers |
| G2 | **Worst-case throughput ≥ 1 sample/clock in every stage** — the back end is never the bottleneck, even on pathological (all-nonzero-coefficient) blocks | Cycle-accurate cocotb measurement per stage; end-to-end frame time |
| G3 | **Fmax ≥ 150 MHz with positive slack at 175 MHz** on XC7S50 via `synth_timing_wrapper` | Vivado post-route WNS (`scripts/check_timing.tcl`) |
| G4 | **Resource reduction** vs `rtl/` at identical parameters — target ≥ 30% fewer DSPs (Loeffler DCT) and reduced LUTRAM (smaller Huffman ring) | Utilization reports, compared via `scripts/check_core_resources.py` |
| G5 | **Byte-identical output** for the lossless back end: with identical coefficients and tables, streamline quantizer + Huffman + packer + JFIF emit byte-identical JPEG streams to `rtl/` | Golden byte-compare harness |
| G6 | **Quality parity or better** once the DCT changes: decoded PSNR of streamline output ≥ `rtl/` baseline − 0.05 dB on the reference image set (expected: better) | Decode + PSNR script against `scripts/hw_test_mandrill.py` vectors |
| G7 | **Lint-clean without blanket waivers** — Verilator lints pass with at most narrow, individually justified pragmas; no file-wide waivers | `verilator --lint-only` in CI |
| G8 | Every file passes the **timelessness review** (Section 4 checklist) | Manual review gate per merge |

Non-goals (explicitly out of scope):

- The VHDL twin in `rtl/vhdl/` — it stays as-is.
- New features (new pixel formats, new markers, multi-pixel-per-clock input).
- Changing the top-level port list. The known fragility that the JPEG output
  stream has no `tready` is **retained** in v1 so that `streamline/` remains a
  drop-in swap; hardening it is recorded here as future work, not in the code.

## 3. Scope and module inventory

Everything under `rtl/` that is Verilog. The core encoder (13 files) is the
main body of work; the Ethernet egress modules in `rtl/eth/` are a final phase.

| Module | Lines | Verdict | Headline change |
|--------|------:|---------|-----------------|
| `quantizer.v` | 673 | **Optimize + clean** | Saturating output, faster table update, one source of truth for tables |
| `huffman_encoder.v` | 809 | **Rewrite** | Serial 11-state FSM → pipelined encoder, ~1 symbol/cycle, zero-run skip |
| `bitstream_packer.v` | 270 | **Rewrite** | Accept up to 32 pending bits (64-bit buffer allows it); multi-byte drain |
| `dct_1d.v` | 228 | **Rewrite** | True Loeffler/LLM factorization: 64 → 11 multiplies per 8-point transform |
| `dct_2d.v` | 301 | **Optimize** | Fold output transpose into downstream addressing; buffer consolidation |
| `zigzag_reorder.v` | 144 | **Absorb or optimize** | Fold zigzag into the DCT output transpose read order if timing allows |
| `input_buffer.v` | 444 | **Optimize** | Replace per-cycle address multiplies with incrementing accumulators |
| `rgb_to_ycbcr.v` | 156 | **Clean port** | Already 1 px/clock; share/pack DSPs, keep exact arithmetic |
| `jfif_writer.v` | 1200 | **Optimize + shrink** | DQT prefetch to 1 byte/clock; tables via functions instead of unrolled literals |
| `mjpegzero_enc_top.v` | 576 | **Rewrite integration** | In-band component tags instead of parallel latency-matched shift FIFOs |
| `axi4_lite_regs.v` | 168 | **Clean port** | Honor `wstrb`; otherwise minimal |
| `bram_sdp.v` | 102 | **Clean port** | Drop dead pipeline stages in the single-tile case |
| `synth_timing_wrapper.v` | 193 | **Regenerate** | Mirror the streamline top exactly |
| `eth/axis_frame_buffer.v`, `eth/jpeg_rtp_trigger.v`, `eth/jpeg_rtp_tx.v`, `eth/mac_csr_init.v` | ~1000 | **Phase 6** | Same standards applied; analyzed in detail when the phase begins |

## 4. The timeless / blameless code standard

This is the contract every `streamline/` file must satisfy. It is enforced as
a review checklist at every merge (goal G8).

### 4.1 Principles

1. **Present tense, no provenance.** A comment describes what the code does
   and why, as a standing fact. The code never says where it came from, what
   it replaced, or what was wrong before it existed.
2. **Reasons come from three sources only:** the standard (ITU-T T.81, JFIF
   1.02, BT.601, AXI4), the mathematics (bit-width proofs, rounding
   identities), or a hardware constraint (BRAM read latency, DSP width,
   synthesis elaboration rules). Never from history.
3. **Tool constraints are stated as standing facts**, not anecdotes.
   *Write:* "Tables are built by constant-index assignments so synthesis can
   evaluate them at elaboration." *Never:* "Vivado used to choke on this."
4. **Every non-obvious step carries its why.** Magic constants get a one-line
   derivation. Every FSM state says what it accomplishes. Every inter-module
   contract (latency, no-backpressure, credit cap) is stated in the header of
   **both** modules that share it.
5. **No archaeology artifacts:** no TODO/FIXME/HACK, no commented-out code,
   no dead ports or signals, no "v2"/"new"/"improved" in names or comments,
   no references to files outside `streamline/`.
6. **Succinct.** One clear sentence beats a paragraph. Block comments explain
   design; line comments are reserved for genuinely surprising lines.

### 4.2 Litmus test — before/after

The existing code fails the standard like this; the rewrite states the same
knowledge as a timeless fact:

| Blame/history style (never) | Timeless style (always) |
|---|---|
| "Fixes and improvements over initial version: three DC predictors instead of two" | "Three DC predictors, one per component (Y, Cb, Cr), as required by T.81 §F.1.1.5.1." |
| "Old condition (bit_cnt <= 32) allowed the encoder to see acceptance while draining — caused overflow" | "A new code is accepted only while ≤ 32 bits are pending: the 64-bit buffer then always holds the worst-case 32-bit code." |
| "CRITICAL: Must check huff_bp_ready too! ... caused frame_done to fire early" | "A block is counted only on an accepted transfer (`valid && ready`); counting on `valid` alone would count stalled beats twice." |
| "Without the latch the pulse is missed and the read side stalls forever" | "`lines_done` is latched because it is a single-cycle pulse and the reader may be mid-block when it fires." |

### 4.3 Standard file header

Every file opens with this shape (content varies, structure does not):

```verilog
// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// <module> — <one-line role in the encoder>
//
// Function
//   <2-6 lines: what it computes, which part of T.81/JFIF it implements>
//
// Interface
//   <handshake discipline, framing signals, sideband meaning>
//
// Contract
//   <latency, throughput, and any invariant shared with neighbors,
//    e.g. "fixed 4-cycle latency, one sample per clock, never stalls">
// -----------------------------------------------------------------------------
```

## 5. Architecture decisions (apply to all modules)

- **D1 — Two handshake disciplines, stated explicitly.** The math pipeline
  (level-shift → DCT → quantizer → zigzag) is a **fixed-latency, valid-only
  stream**: it never stalls and never needs `ready`. The elastic boundary
  (block buffer → Huffman → packer → JFIF) uses **valid/ready**. Each header
  names which discipline it obeys. This matches the current design's physics
  but makes the contract explicit instead of implicit.
- **D2 — Component identity travels in-band.** A 2-bit `comp` tag rides
  alongside the data through the fixed-latency pipeline. This deletes the two
  hand-tuned latency-matching shift FIFOs in the top level, which silently
  break whenever any stage's latency changes.
- **D3 — One source of truth per table.** The T.81 base quantization tables,
  Huffman code tables, and zigzag map each exist exactly once, as constant
  functions usable at elaboration by every consumer (quantizer datapath,
  JFIF DQT/DHT emitters, LITE-mode precompute). No duplicated literals.
- **D4 — Drop-in compatibility.** Filenames, module names, parameters, and
  ports match `rtl/` exactly. A new FuseSoC target (`streamline`) selects the
  fileset; `sim/` benches run unmodified against either tree.
- **D5 — Saturate, never wrap.** Every truncation in the datapath is either
  proven safe by bit-width analysis (proof in a comment) or explicitly
  saturating. The quantizer output gets the saturation the current code lacks.
- **D6 — Credit discipline is owned by the top.** The blocks-in-flight cap
  (`pipeline_depth < HUFF_BANKS`) remains the mechanism that prevents Huffman
  ring overflow, and is documented as a named invariant in both the top and
  the Huffman header. With the pipelined Huffman, `HUFF_BANKS` defaults down
  from 8 to 2, reclaiming LUTRAM (goal G4).

## 6. Per-module plans

### 6.1 `quantizer.v` — Phase 1

Already a clean 4-stage, 1-coefficient/clock reciprocal-multiply pipeline.
The work is correctness hardening, table-machinery consolidation, and source
shrink (673 → ~350 lines expected):

1. **Saturating output (D5).** The multiply result is currently truncated to
   16 bits with no clamp; add symmetric saturation with a bit-width argument
   in the comment.
2. **One table pipeline (D3).** Base tables, the quality→scale mapping, and
   reciprocal generation become shared constant functions. This eliminates
   all three current duplications: the 49-entry `5000/Q` case (a ROM written
   as a case statement), the second copy of the base tables in LITE mode, and
   the 128 unrolled `initial` lines (replaced by an elaboration-time function
   with constant indices, which synthesizes cleanly).
3. **Table update without hazards.** The quality-change FSM currently rewrites
   reciprocals while the datapath may be reading them; the design is safe only
   because the input buffer happens to take longer than the ~384-cycle rebuild
   to deliver the first coefficient of a frame. Runtime quality changes are a
   first-class operation (the Ethernet demo's adaptive rate controller rewrites
   quality between frames), so the streamline version makes the guarantee
   structural: double-buffered reciprocal tables, rebuilt in the shadow copy
   and swapped at a frame boundary — glitch-free by construction regardless of
   upstream timing, with a shrunken FSM (fold SCALE/ADD/DIV states; ~3
   cycles/entry instead of 5).
4. **Delete dead signals** (`quality` in LITE mode routed but unused, partial
   product slices) so no lint waivers are needed.

*Exit test:* bit-exact against `rtl/quantizer.v` across all 100 qualities ×
both components × directed and random coefficient vectors (the saturation
cases, unreachable through the real DCT range, are additionally checked
against the Python golden model).

### 6.2 `huffman_encoder.v` — Phase 1

The single largest performance defect in the design: a serial FSM spending
3–4 cycles per symbol and one full cycle per zero coefficient, which is why
an 8-deep block ring exists to hide it. Full rewrite:

1. **Pipelined symbol encoder.** Stages: (a) coefficient fetch + zero-run
   accumulation, (b) category via leading-zero count (replaces the 11-deep
   priority chain, twice removed from the critical path), (c) code lookup +
   amplitude bits, (d) emit. Target: one **symbol** per clock sustained,
   including ZRL and EOB, with zero-run coefficients consumed combinationally
   (a run of zeros costs 0 extra cycles — the fetch stage skips to the next
   nonzero using the known last-nonzero index).
2. **Worst case = 64 cycles per block** (all-nonzero block, one symbol/coeff),
   matching the upstream rate exactly. The back end stops being the
   bottleneck (goal G2), so `HUFF_BANKS` default drops to 2 (D6, G4).
3. **Tables once (D3).** DC/AC code tables as constant functions shared with
   the JFIF DHT emitter — today the same 432 bytes exist in two encodings in
   two files.
4. **Clean handshake.** Registered-output skid on the emit stage so
   `out_valid/out_ready` composes without the current deliberate dead cycle
   per emitted code.

*Exit test:* byte-exact bitstream (via the packer) against `rtl/` for full
frames — Huffman coding is lossless, so equality is exact, not approximate.
Plus a cycle-count assertion: a dense random block must encode in ≤ 68 cycles.

### 6.3 `bitstream_packer.v` — Phase 1 (coupled to 6.2)

A fast Huffman encoder is wasted if the packer still refuses input while more
than 7 bits are pending. Rewrite the accept/drain logic:

1. **Accept while ≤ 32 bits pending** — the 64-bit accumulator always has room
   for a worst-case 32-bit code, so acceptance and draining proceed
   concurrently instead of alternating.
2. **Drain matches line rate.** One byte/clock output with stuffing handled
   in-line; the accept condition above makes single-byte drain sufficient to
   sustain one symbol/clock from the encoder (average code ≤ 8 bits).
3. Restart-marker and flush states keep their behavior, restated per the
   standard's byte-alignment rules rather than as workaround narrative.

*Exit test:* byte-exact against `rtl/` (stuffing, restart markers, flush
padding) on directed torture streams (all-0xFF output, max-length codes) and
full frames; combined 6.2+6.3 throughput assertion under random backpressure.

### 6.4 `dct_1d.v` / `dct_2d.v` — Phase 2

1. **Implement the algorithm the header already claims.** Replace the 8×8
   matrix multiply (8 DSPs busy 8 cycles = 64 multiplies per row) with the
   Loeffler/LLM factorization: 11 multiplies per 8-point transform. Even
   fully parallel (one transform per 8-cycle window) this cuts DSO count per
   1-D instance roughly in half and the multiply count ~6×; the freed DSPs
   are the bulk of goal G4.
2. **Bit-exact growth analysis** at every butterfly stage, written as proofs
   in comments (the standard's precision requirements — IEEE 1180-style error
   bounds — are the acceptance criterion, since Loeffler rounding differs
   legitimately from the matrix version).
3. **One transpose, not two.** The second (output) transpose buffer exists
   only to restore raster order that the zigzag stage immediately scrambles
   again. Fuse them: the column-DCT output is written straight into a
   double-buffered BRAM in zigzag order (D3's single zigzag map used as the
   write-address ROM). This deletes 128×16 bits of registers **and** the
   entire `zigzag_reorder` stage.
4. Move the remaining transpose buffer from distributed registers to
   `bram_sdp` where the port pattern allows.

*Exit test:* IEEE-1180-style accuracy harness against a double-precision
reference DCT; end-to-end decoded-PSNR comparison (goal G6). Byte-exactness
vs `rtl/` is **not** required from this phase on — the PLAN records that the
bitstreams legitimately diverge here and quality is the criterion.

### 6.5 `zigzag_reorder.v` — Phase 2

Absorbed into the DCT output stage per 6.4. The file still exists in
`streamline/` as a drop-in for mixed-tree simulation (same optimization as
today's, with BRAM-backed buffers), but the streamline top does not
instantiate it. If the fused approach misses timing, this module stays in the
pipeline unchanged in role — that decision gate is Phase 2's first milestone.

### 6.6 `input_buffer.v` — Phase 3

1. **Address accumulators.** All read/write addresses become incrementing
   registers with per-component base offsets; the current per-cycle
   `bank*SIZE + line*WIDTH + x` multiplies disappear from the sample path.
2. State machines restated cleanly; the `lines_done` latch stays (it is
   correct) with its reason stated per §4.2.
3. Component tag emitted in-band (D2).

*Exit test:* bit-exact block stream against `rtl/` for full frames, including
back-to-back frames and stall patterns from downstream.

### 6.7 `rgb_to_ycbcr.v` — Phase 3

Already 1 pixel/clock with exact BT.601 arithmetic and a real `tready`.
Streamline version: identical arithmetic (bit-exact — the recent golden
coefficient tests carry over), multiplier sharing where the DSP packer
benefits, timeless header. The known quality nicety (averaging adjacent
chroma instead of dropping) is future work, not v1 — it would break
bit-exactness for no throughput gain.

### 6.8 `jfif_writer.v` — Phase 4

1. **DQT at line rate.** Prefetch the quantizer table read (issue address
   N+1 while emitting byte N) to close the 2-cycles/byte bubble.
2. **Tables from the shared constant functions (D3).** DHT is generated from
   the same Huffman table source as the encoder; DQT-in-LITE-mode from the
   same quantizer table functions. The 900+ lines of unrolled literals
   collapse; expected file size roughly halves.
3. Marker sequencing FSMs restated against JFIF/T.81 section references.

*Exit test:* byte-exact headers vs `rtl/` at matching parameters (LITE and
runtime modes, EXIF on/off), plus libjpeg structural decode.

### 6.9 `mjpegzero_enc_top.v` + `synth_timing_wrapper.v` — Phase 4

1. In-band comp tags (D2) delete both shift-FIFOs.
2. Frame FSM restated; block counting on accepted transfers with the
   invariant named (§4.2).
3. Credit counter documented as the D6 invariant; `HUFF_BANKS` default 2.
4. Port list identical to `rtl/` (D4). Wrapper regenerated to match.

*Exit test:* full-encoder runs in both trees compared end-to-end; synthesis
G3/G4 measurements happen here.

### 6.10 `axi4_lite_regs.v`, `bram_sdp.v` — Phase 4 (light)

- Regs: honor `wstrb` (currently ignored), keep the register map identical.
- BRAM: single-tile instances lose the dead 2-stage tile-select pipeline;
  multi-tile read mux gains an optional output register (latency is already
  absorbed by callers' fixed-latency alignment).

### 6.11 `rtl/eth/*` — Phase 6

The four egress modules (`axis_frame_buffer`, `jpeg_rtp_trigger`,
`jpeg_rtp_tx`, `mac_csr_init`) get the same treatment: deep-read analysis
first (they have not been profiled at the depth of the core), then
optimize/clean per this standard, with RFC 2435 as the cited authority for
the RTP packetizer. Scoped as its own phase so core encoder completion never
blocks on network code.

## 7. Verification strategy

Verification is built **before** the first module lands (Phase 0), reusing
`sim/` and `scripts/` infrastructure:

1. **Module goldens.** Per-module cocotb benches driving identical stimulus
   into `rtl/X.v` and `streamline/X.v`; comparison is byte/bit-exact for the
   lossless stages (6.1, 6.2, 6.3, 6.6, 6.8) and bounds-based for the DCT.
2. **Mixed-tree encoder runs.** Because modules are drop-ins (D4), each phase
   is validated inside an otherwise-`rtl/` encoder before the next phase
   starts — one variable at a time.
3. **End-to-end.** Full-frame encode of the reference images, libjpeg decode,
   PSNR vs source, tracked per phase. Byte-identical requirement holds
   through Phase 1 (back end is lossless); from Phase 2 the criterion is G6.
4. **Performance assertions in CI.** Cycle-count checks (dense-block Huffman
   ≤ 68 cycles; zero credit-stall cycles at steady state) so throughput
   regressions fail loudly, not silently.
5. **Synthesis gates.** `run_all.py synth` + timing/resource checks after
   Phases 1, 2, and 4; results recorded in `streamline/RESULTS.md` (metrics
   live there and in commit messages — never in the RTL, per §4).

## 8. Execution order and gates

| Phase | Content | Gate to pass |
|-------|---------|--------------|
| 0 | Verification harness, golden vectors, FuseSoC `streamline` target, this standard | Harness proves `rtl/` == `rtl/` (self-check); CI wired |
| 1 | `quantizer`, `huffman_encoder`, `bitstream_packer` | **Byte-identical JPEGs**; dense-block ≤ 68 cyc; lint-clean |
| 2 | `dct_1d`, `dct_2d`, zigzag fusion decision | IEEE-1180-style accuracy; PSNR ≥ baseline − 0.05 dB; DSP count down |
| 3 | `input_buffer`, `rgb_to_ycbcr` | Bit-exact streams; no address multipliers in sample path |
| 4 | `jfif_writer`, top, wrapper, regs, bram | Full streamline encoder passes G1–G5; synth meets G3/G4 |
| 5 | Closure: RESULTS.md, resource/timing comparison table, final timelessness review of every file | All of G1–G8 |
| 6 | `rtl/eth/*` | Same standards; RTP output validated against RFC 2435 |

Order rationale: the back end (Phase 1) is where the measured bottleneck is
and where verification is strongest (lossless ⇒ byte-exact), so it delivers
the largest, safest win first — exactly the quantizer-and-Huffman-first
sequence this plan was asked to lead with. The DCT (Phase 2) is the largest
resource win but changes bitstreams, so it goes second, after the byte-exact
back end is locked in as the measuring stick.

## 9. Deliverables

```
streamline/
  PLAN.md                  — this document
  RESULTS.md               — measured timing/resource/PSNR per phase (Phase 5)
  quantizer.v              — Phase 1
  huffman_encoder.v        — Phase 1
  bitstream_packer.v       — Phase 1
  dct_1d.v  dct_2d.v       — Phase 2
  zigzag_reorder.v         — Phase 2 (drop-in; fused out of the default top)
  input_buffer.v           — Phase 3
  rgb_to_ycbcr.v           — Phase 3
  jfif_writer.v            — Phase 4
  mjpegzero_enc_top.v      — Phase 4
  synth_timing_wrapper.v   — Phase 4
  axi4_lite_regs.v         — Phase 4
  bram_sdp.v               — Phase 4
  eth/                     — Phase 6
```

History, rationale-for-change, and comparisons against `rtl/` live in this
file, in `RESULTS.md`, and in commit messages. The `.v` files contain none of
it — they simply are what they are.
