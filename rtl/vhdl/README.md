# MJPEG Encoder VHDL Sources

Native VHDL sources for the MJPEG encoder live here.

The port is intentionally top-down:

1. Add the VHDL top-level entity and mixed-language structural shell.
2. Replace child Verilog modules with VHDL modules one at a time.
3. Keep the Verilog modules in `../` as the golden reference until equivalence
   tests pass.

The initial bridge is `mjpegzero_enc_top.vhd`. It exposes a VHDL entity
while binding to the current Verilog top for mixed-language tools.

Use VHDL-2008 for new files.
