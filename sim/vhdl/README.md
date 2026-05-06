# VHDL Testbenches

Native VHDL testbenches and VHDL-only simulation helpers live here.

The existing SystemVerilog testbenches in `../` remain the primary golden
regressions. During the port, mixed-language simulations should swap in VHDL
modules one at a time while reusing the existing stimulus and output checks.
