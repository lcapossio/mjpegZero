# streamline/ — Measured Results

Phase-by-phase measurements against `rtl/` at identical parameters.
Provenance and rationale live here and in commit messages — never in the
`.v` files (PLAN.md §4).

## Phase 0 — Verification harness (complete)

- `verify/parity.py`: two-run byte-exact compare of full-encoder JPEG output
  (iverilog + `sim/tb_iverilog.sv`), any subset of modules swapped to
  `streamline/`. Self-check (rtl vs rtl) byte-identical in runtime-quality
  and LITE modes.
- Module torture benches: `tb_packer.sv` (+ Python T.81 golden model),
  `tb_huffman.sv` (two-run transaction diff), `tb_huffman_perf.sv`
  (cycle-accurate throughput).

## Phase 1 — Quantizer, Huffman encoder, bitstream packer (complete)

Zigzag reorder was pulled forward from Phase 2: the faster back end runs
blocks gaplessly, which exposes a data-corrupting race in
`rtl/zigzag_reorder.v` (see defect 3). All four modules are drop-in
replacements, `verilator --lint-only -Wall` clean.

### Correctness

| Configuration | Result |
|---|---|
| Full-encoder parity, runtime mode, Q = 1, 9, 25, 50, 75, 95 | byte-identical |
| Full-encoder parity, LITE mode, Q = 2, 50, 75, 95 | byte-identical |
| Full-encoder, Q = 100 (both modes) | rtl baseline is corrupted by defect 3 (proven below); streamline output is the correct stream; decoded PSNR 38.09 dB vs baseline 38.10 dB (within the G6 margin) |
| Packer vs T.81 golden: 3000 codes, 0xFF chains, 81 restarts (unaligned tails), 25% output stalls | exact (5069/5069 bytes) |
| Huffman vs rtl, transaction diff: 60 blocks — run boundaries 15/16/17/32/47, DC-only, lone-tail, ±2047 extremes, dense large (cat ≤ 11), restart pulses, bursty stalls | identical (1097/1097 words) |
| Quantizer parity swept alone across 10 mode/quality configs | byte-identical |

### Throughput (worst case: dense all-nonzero blocks, output unstalled)

| Implementation | Cycles/block, steady state |
|---|---|
| rtl Huffman encoder | 321 |
| streamline Huffman encoder | **67** (4.8x; front-end feed rate is 64) |

The packer accepts with up to 32 bits pending (rtl: 7), so codes averaging
≤ 8 bits stream at one per clock. `HUFF_BANKS` can drop from 8 to 2 once the
top level is streamlined (Phase 4), reclaiming the LUTRAM ring.

### Source size

| Module | rtl lines | streamline lines |
|---|---|---|
| quantizer | 673 | 439 |
| bitstream_packer | 270 | 249 |
| huffman_encoder | 809 | 748 |
| zigzag_reorder | 144 | 138 |

### rtl/ defects found (all verified by directed test)

1. **Packer ready is not truthful.** `bp_ready` omits the output-slot term
   its accept path requires, so under output backpressure a compliant
   sender sees ready, advances, and the code is silently lost (~14% of
   torture-stream bytes). Not reachable in the shipped encoder only because
   the rtl Huffman encoder's emit protocol never offers during the window.
2. **Packer restart padding drops bits.** A restart arriving with ≥ 8 bits
   pending drains whole bytes, then discards the 1-7 bit tail instead of
   padding it (S_RST_PAD pads only when bit_cnt < 8).
3. **Zigzag reorder corrupts back-to-back blocks.** The read mux uses the
   live write-side buffer selector; when block N+1 completes during block
   N's final read cycle, coefficient 63 of block N is read from block N+1's
   buffer. Standalone proof: two gapless blocks with distinct final
   coefficients — rtl emits block 1's value inside block 0. Latent in rtl
   because the slow back end inserts credit gaps, and invisible below
   Q ≈ 100 because trailing coefficients quantize to zero.
4. *(Known, scheduled Phase 2)* `dct_1d` claims Loeffler but implements a
   64-multiply matrix product per row.

## Phase 2 — Loeffler DCT (complete)

- **Models first:** bit-exact Python contracts (`verify/dct_model.py`,
  `verify/dct2d_psnr.py`). The Loeffler/LLM factorization with orthonormal
  constants folded to Q12 needs 14 constant multiplies per 8-point
  transform (measured, not asserted) vs 64 in the direct form, with the
  same per-pass normalization — either dct_1d drops into either dct_2d.
- **Model accuracy:** peak 1.53 LSB vs float reference (matrix: 1.31) over
  20k random rows; end-to-end block-level PSNR delta vs the matrix
  pipeline at Q50/75/95/100: worst 0.0016 dB (gate 0.05).
- **`dct_1d.v`:** the 14 products time-share **2 physical multipliers**
  (vs 8 always busy) on a static 7-cycle schedule — 16 → 4 multipliers for
  the 2-D pair. Bit-exact vs model: 16,176/16,176 coefficients across
  directed extremes + 2000 random rows, back-to-back and gapped.
- **`dct_2d.v`:** same row-column architecture (rtl's buffer latching was
  already correct), unified buffer arrays, streamline standard. Bit-exact
  vs model: 26,304/26,304 coefficients across 411 blocks.
- **Full-encoder PSNR gate** (`parity.py --psnr`, all six streamline
  modules swapped): worst delta −0.0081 dB across runtime Q50/75/95/100
  and LITE Q75 (gate 0.05); at Q50/75 the delta is exactly 0.
- **Zigzag fusion decision:** deferred to Phase 4 as a `ZIGZAG_OUT`
  parameter on dct_2d (default raster, preserving drop-in), adopted when
  the streamline top exists to use it; the standalone race-free
  zigzag_reorder covers until then.

### Open items

- Vivado elaboration of the constant-function table initializers
  (quantizer LITE mode) is untested here (iverilog/Verilator only) — check
  at the first synthesis gate (`run_all.py synth`).
- ~~`rtl/dct_2d.v`'s output transpose uses the same live-selector double
  buffer as defect 3~~ — verified false on full read: both dct_2d buffers
  latch their read selectors at block completion (the correct form).
  Defect 3 is unique to `rtl/zigzag_reorder.v`.
