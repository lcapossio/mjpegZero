# VHDL Translation Plan

This branch starts a top-down VHDL port of the MJPEG encoder while keeping the
existing Verilog implementation as the golden reference.

## Source Layout

- `rtl/`
  - Existing synthesizable Verilog sources. These remain the reference design.
- `rtl/vhdl/`
  - Native VHDL sources for the MJPEG encoder.
  - Files should mirror the Verilog module names where practical, for example
    `mjpegzero_enc_top.vhd`, `input_buffer.vhd`, and `dct_1d.vhd`.
  - Shared VHDL declarations live in `mjpegzero_pkg.vhd`.
- `rtl/vendor/`
  - Existing vendor-specific Verilog RAM shims.
  - Vendor primitives should be wrapped or re-authored only when needed for a
    pure-VHDL synthesis target.
- `sim/`
  - Existing Verilog/SystemVerilog testbenches and vectors.
- `sim/vhdl/`
  - Native VHDL testbenches and shared VHDL simulation utilities.

## Translation Order

Translate top down, but verify bottom-up whenever a leaf becomes available.

1. `mjpegzero_enc_top` - translated
   - Create the VHDL entity first.
   - The initial mixed-language shell has been replaced by native VHDL
     children.
2. Control and format-facing blocks
   - `axi4_lite_regs` - translated
   - `jfif_writer` - translated
   - `bitstream_packer` - translated
3. Core pipeline blocks
   - `input_buffer` - translated
   - `dct_2d` - translated
   - `dct_1d` - translated
   - `quantizer` - translated
   - `zigzag_reorder` - translated
   - `huffman_encoder` - translated
   - `rgb_to_ycbcr` - translated
4. RAM abstraction
   - `bram_sdp` - translated for simulation.
   - Keep vendor-specific Verilog RAM shims for vendor synthesis flows.
5. Synthesis wrappers
   - `synth_timing_wrapper` - translated

## Verification Strategy

- Keep the existing SystemVerilog testbenches as golden regressions.
- Add runs that replace one Verilog module at a time with its VHDL counterpart.
- Use `python scripts/run_vhdl_top_sim.py` for the current VHDL top-level
  regression.
- The current VHDL top-level regression uses VHDL for the encoder hierarchy and
  keeps the existing SystemVerilog testbench as the golden driver/checker.
- Add VHDL testbenches under `sim/vhdl/` for modules where a small focused test
  is faster than the full image pipeline.
- Compare against the current image/JPEG byte outputs before declaring a module
  translated.

## Coding Conventions

- Use VHDL-2008.
- Use `ieee.std_logic_1164` and `ieee.numeric_std`.
- Prefer `std_logic_vector` at module/entity boundaries to match the existing
  Verilog interfaces.
- Use `signed` and `unsigned` internally where arithmetic intent matters.
- Keep reset polarity and cycle timing identical to the Verilog source unless a
  test explicitly proves the change is harmless.
