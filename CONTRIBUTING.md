# Contributing to mjpegZero

Contributions are welcome. The most impactful contributions are
**board-level examples** that show the encoder running on hardware beyond the
reference Arty S7-50 — but bug fixes, verification improvements, and
documentation are equally appreciated.

---

## Ways to Contribute

| Type | Examples |
|------|---------|
| Board examples | Nexys Video, Genesys 2, ZedBoard, Basys 3, DE10-Nano, iCEBreaker |
| RTL improvements | 4:2:0 subsampling, restart markers, additional resolutions |
| Verification | New test images, corner-case simulation vectors, formal proofs |
| Documentation | Tutorials, waveform captures, board bring-up notes |
| Bug fixes | Timing violations, simulation mismatches, protocol errors |

---

## Adding a New Board Example

All board examples live under [`example_proj/`](example_proj/), one
subdirectory per board. The Arty S7-50 reference is at
[`example_proj/arty_s7_50/`](example_proj/arty_s7_50/).
To add support for another board, create a new subdirectory following the same
layout:

```
example_proj/<board_name>/
  rtl/
    clk_gen.v           Clock generation (PLL/MMCM/PLL_ADV for your device)
    <board>_top.v       Top-level (instantiates mjpegzero_enc_top)
  constraints/
    <board>.xdc         Pin assignments and timing constraints
  scripts/
    create_project.tcl  Vivado/Quartus/nextpnr build script
  python/
    demo.py             Host program (UART / JTAG-AXI / PCIe / etc.)
  README.md             Board-specific build + run instructions
```

### Checklist for a new board example

- [ ] `clk_gen.v` generates a clock suitable for the encoder (100–150 MHz recommended;
      150 MHz required for 1080p30 / 720p60)
- [ ] Top-level instantiates `mjpegzero_enc_top` with correct `IMG_WIDTH`,
      `IMG_HEIGHT`, `LITE_MODE`, and `LITE_QUALITY` generics
- [ ] Encoder is enabled via AXI4-Lite CTRL register (see `axi_init.v` for
      a reference one-shot master, or write directly from your host interface)
- [ ] `README.md` documents prerequisites, build command, program steps, and
      expected resource utilisation
- [ ] Synthesis runs cleanly (no unresolved references, no critical warnings)
- [ ] Timing is met post place-and-route (positive WNS at target frequency)

### Core RTL rules

The encoder core (`rtl/`) is **Verilog 2001** and must stay portable across
tools. When writing board RTL:

- Use Verilog 2001 syntax (`reg`, `wire`, `always @(posedge clk)`, no
  `logic`, no `always_ff`, no `3'(n)` casts)
- Prefer explicit primitive instantiation for PLLs (MMCME2_ADV, PLL_ADV) so
  Vivado does not infer one with unexpected settings
- Infer BRAMs with `(* ram_style = "block" *)` or `(* ram_style = "distributed" *)`
  as appropriate; do not rely on tool defaults for timing-critical memories
- Do not add `tready` to the encoder JPEG output — the encoder has no output
  backpressure by design (see the architecture note in the main README)

---

## Reporting Bugs

Open an issue with:
- Vivado version and device part string (e.g. `xc7s50csga324-1`)
- Synthesis / simulation command used
- Relevant log excerpt or waveform showing the problem
- Expected vs. actual behaviour

---

## Pull Request Process

1. Fork the repository and create a feature branch
2. Keep commits focused — one logical change per commit
3. Include a brief description of what was tested (simulation, synthesis,
   or hardware) and on which tool version
4. Open a PR against `main`; the PR description should note:
   - Board / device targeted
   - Resource utilisation (LUT / FF / BRAM / DSP) if synthesised
   - Whether timing was met and at what frequency

Pull requests are automatically checked by CI (Python verification, Verilator RTL lint,
and iverilog simulation). Hardware testing on Arty S7-50 is done manually before merge.

---

## Code Style

- Indent with **4 spaces** (no tabs)
- Keep line length under **100 characters** where practical
- Module and signal names: `snake_case`
- Local parameters: `ALL_CAPS`
- One module per file; filename matches module name

---

## License

By contributing you agree that your contribution will be licensed under the
same [MIT + Commons Clause license](LICENSE) as the rest of the project.
This means non-commercial use remains free; commercial use requires written
permission from the project author (hello@bard0.com).
