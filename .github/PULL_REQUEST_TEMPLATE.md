## Summary
<!-- One or two sentences describing the change -->

## Type
- [ ] Bug fix
- [ ] New board example
- [ ] RTL improvement
- [ ] Verification / test
- [ ] Documentation

## Tested on
<!-- Board, device part, tool version -->

## Resource utilisation (if synthesised)
| Resource | Used | Available |
|----------|------|-----------|
| LUT      |      |           |
| FF       |      |           |
| BRAM36   |      |           |
| DSP      |      |           |

## Timing
<!-- WNS at target frequency, or N/A -->

## Checklist
- [ ] Verilog 2001 only (no `logic`, no `always_ff`, no cast syntax)
- [ ] `python/verify_rtl_sim.py` passes (full and lite mode)
- [ ] Verilator lint clean (`verilator --lint-only -Wall --bbox-unsup`)
- [ ] SPDX + Commons Clause header on all new source files
