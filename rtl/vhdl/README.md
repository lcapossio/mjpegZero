# MJPEG Encoder VHDL Sources

Native VHDL sources for the MJPEG encoder live here.

The port is intentionally top-down:

1. Add the VHDL top-level entity and mixed-language structural shell.
2. Replace child Verilog modules with VHDL modules one at a time.
3. Keep the Verilog modules in `../` as the golden reference until equivalence
   tests pass.

The current top-level is `mjpegzero_enc_top.vhd`, a VHDL structural top. The
top-level regression uses VHDL for the encoder hierarchy and reuses the
existing SystemVerilog testbench as the driver/checker.

Use VHDL-2008 for new files.
