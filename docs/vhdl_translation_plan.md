# VHDL Translation Plan

This branch contains a top-down VHDL port of the MJPEG encoder while keeping
the existing Verilog implementation as the golden reference.

## Source Layout

- `rtl/`
  - Existing synthesizable Verilog sources. These remain the reference design.
- `rtl/vhdl/`
  - Native VHDL sources for the MJPEG encoder.
  - Files should mirror the Verilog module names where practical, for example
    `mjpegzero_enc_top.vhd`, `input_buffer.vhd`, and `dct_1d.vhd`.
  - Shared VHDL declarations live in `mjpegzero_pkg.vhd`.
  - The VHDL encoder hierarchy is complete through `mjpegzero_enc_top.vhd`.
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
   - `bram_sdp` - translated as a vendor-neutral inferred two-cycle simple
     dual-port RAM.
   - Keep the core RAM behavioral and vendor-neutral.
5. Synthesis wrappers
   - `synth_timing_wrapper` - translated

## Verification Strategy

- Keep the existing SystemVerilog testbenches as golden regressions.
- Add runs that replace one Verilog module at a time with its VHDL counterpart.
- Use `python scripts/run_vhdl_top_sim.py` for the current VHDL top-level
  regression.
- The current VHDL top-level regression uses VHDL for the encoder hierarchy and
  keeps the existing SystemVerilog testbench as the golden driver/checker.
- Use `scripts/synth/amd/run_synth_vhdl.tcl` for the AMD/Xilinx VHDL synthesis
  smoke path.
- Use `python scripts/check_core_resources.py --run-synth` or
  `python scripts/run_ci_local.py core-resource-equiv` to check that the
  Verilog and VHDL core builds keep the same hard resources and roughly the
  same LUT/FF usage in full and lite modes.
- Use `python scripts/run_postsim.py vhdl` for the VHDL post-synthesis
  functional simulation path.
- Add VHDL testbenches under `sim/vhdl/` for modules where a small focused test
  is faster than the full image pipeline.
- Compare against the current image/JPEG byte outputs before declaring a module
  translated.
- Build the Arty A7-100T board demo with both
  `example_proj/arty_a7_100t/scripts/create_project.tcl` and
  `example_proj/arty_a7_100t/scripts/create_project_vhdl.tcl`.
- Run `python scripts/hw_test_mandrill.py --bit <bitstream> --program` for both
  bitstreams. The current Verilog and VHDL Arty A7-100T bitstreams both produce
  the same 235,118-byte Mandrill 720p Q75 JPEG as simulation.

## Coding Conventions

- Use VHDL-1993.
- Use `ieee.std_logic_1164` and `ieee.numeric_std`.
- Prefer `std_logic_vector` at module/entity boundaries to match the existing
  Verilog interfaces.
- Use `signed` and `unsigned` internally where arithmetic intent matters.
- Keep reset polarity and cycle timing identical to the Verilog source unless a
  test explicitly proves the change is harmless.
