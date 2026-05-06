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
   - Initially allow mixed-language simulation by instantiating existing
     Verilog children where the simulator supports it.
2. Control and format-facing blocks
   - `axi4_lite_regs` - translated
   - `jfif_writer` - remaining
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
   - Keep the Verilog `bram_sdp` shims for mixed-language tests.
   - Add VHDL RAM wrappers once the native VHDL pipeline needs pure-VHDL
     synthesis.

## Verification Strategy

- Keep the existing SystemVerilog testbenches as golden regressions.
- Add mixed-language runs that replace one Verilog module at a time with its
  VHDL counterpart.
- Use `python scripts/run_vhdl_top_sim.py` for the current mixed-language
  top-level regression.
- The current mixed run replaces the top, AXI registers, input buffer, DCT,
  quantizer, zigzag, Huffman encoder, RGB conversion, and bitstream packer with
  VHDL. It still uses Verilog `jfif_writer` and vendor `bram_sdp`.
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
