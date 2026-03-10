# FuseSoC synth_amd pre-bitstream hook
# Waive NSTD-1 and UCIO-1 for standalone IP core synthesis (no board XDC)
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
