# DRC waivers for standalone IP core synthesis (no board pin constraints).
# Downgrade NSTD-1 / UCIO-1 from ERROR to WARNING so write_bitstream
# can complete without I/O LOC / IOSTANDARD assignments.
# This file is an XDC (Vivado Tcl source) so set_property is executed
# during constraint loading and persists for the full Vivado session.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
