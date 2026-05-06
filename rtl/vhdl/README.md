# MJPEG Encoder VHDL Sources

Native VHDL sources for the MJPEG encoder live here.

The port was done top-down:

1. Add the VHDL top-level entity.
2. Replace child Verilog modules with VHDL modules one at a time.
3. Keep the Verilog modules in `../` as the golden reference for equivalence
   tests.

The current top-level is `mjpegzero_enc_top.vhd`, a VHDL structural top. The
top-level regression uses VHDL for the encoder hierarchy and reuses the
existing SystemVerilog testbench as the driver/checker.

`bram_sdp.vhd` is a portable inferred simple dual-port RAM with the same
two-cycle read latency as the Verilog vendor shims. Vendor-specific Verilog RAM
shims remain available where an explicit primitive is still needed.

Use VHDL-2008 for new files.
