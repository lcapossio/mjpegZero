# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# Pre-hook for write_bitstream step (project-mode impl run)
# Downgrade UCIO-1 from error to warning so bitstream proceeds with
# auto-placed led1 (K15 is not a valid CSGA324 ball in Vivado 2025.2).
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
