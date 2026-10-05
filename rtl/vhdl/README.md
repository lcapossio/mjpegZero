# MJPEG Encoder VHDL Sources

Native VHDL-1993 sources for the MJPEG encoder live here.

The port was done top-down:

1. Add the VHDL top-level entity.
2. Replace child Verilog modules with VHDL modules one at a time.
3. Keep the Verilog modules in `../` as the golden reference for equivalence
   tests.

The current top-level is `mjpegzero_enc_top.vhd`, a VHDL structural top. The
Arty A7-100T demo also has a VHDL encoder bitstream path in
`example_proj/arty_a7_100t/scripts/create_project_vhdl.tcl`.

Verification:

- **CI (GHDL):** `sim/cocotb/test_runner.py` runs one cocotb testbench against
  both the Verilog (Icarus) and VHDL (GHDL) tops and golden-checks each output
  (`cocotb-dual` job). The `vhdl-lint` job analyzes every source here with
  `-Wall --warn-error`.
- **Streams (GHDL):** `python/verify_stream.py --sim cocotb-vhdl --xcheck`
  feeds back-to-back frames (restart, RGB, EXIF, gaps, QUALITY/ENABLE changes)
  and requires every frame to be byte-identical to the Verilog testbench.
- **Local (Vivado xsim):** `scripts/run_vhdl_top_sim.py` drives the VHDL
  hierarchy from the existing SystemVerilog testbench.

As in the Verilog top, the video input width follows `RGB_INPUT`
(`vid_data_w()` in `mjpegzero_pkg.vhd`): 24 bits for RGB, 16 for YUYV. There is
no separate `VID_DATA_W` generic.

Source list:

| Source | Role |
|--------|------|
| `mjpegzero_pkg.vhd` | Shared constants and helper functions |
| `mjpegzero_enc_top.vhd` | Encoder top-level |
| `axi4_lite_regs.vhd` | Control/status register file |
| `input_buffer.vhd` | YUYV de-interleave and MCU input buffering |
| `dct_1d.vhd`, `dct_2d.vhd` | Forward DCT pipeline |
| `quantizer.vhd` | Quantization and reciprocal table update pipeline |
| `zigzag_reorder.vhd` | Zigzag order buffering |
| `huffman_encoder.vhd` | JPEG Huffman entropy encoder |
| `bitstream_packer.vhd` | Bit packing and byte stuffing |
| `jfif_writer.vhd` | JFIF/JPEG marker and header writer |
| `rgb_to_ycbcr.vhd` | Optional RGB input conversion |
| `bram_sdp.vhd` | Vendor-neutral inferred simple dual-port RAM |
| `synth_timing_wrapper.vhd` | Core synthesis timing wrapper |
| `demo_jpeg_buffer.vhd` | Tiled JPEG output buffer for the board demo shell (not part of the core) |

`bram_sdp.vhd` is the vendor-neutral core RAM. It uses behavioral VHDL and has
the same two-cycle read latency as `../bram_sdp.v`.

Use VHDL-1993 for new files.
