# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
Generate correct Verilog ROM initialization for ALL Huffman table entries.
Output can be pasted directly into huffman_encoder.v.
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from jpeg_common import (
    AC_LUMA_BITS, AC_LUMA_VALS, AC_CHROMA_BITS, AC_CHROMA_VALS,
    build_huffman_table,
)


def gen_verilog_rom(name, bits, vals):
    """Generate Verilog ROM initialization lines."""
    table = build_huffman_table(bits, vals)
    lines = []

    # Sort by symbol value for organized output
    for sym in sorted(table.keys()):
        code_len, code_val = table[sym]
        # MSB-align the code in 16 bits
        code_msb = code_val << (16 - code_len)
        code_bin = format(code_msb, '016b')
        # Insert underscores for readability
        lines.append(f"        {name}[8'h{sym:02X}] = {{5'd{code_len}, 16'b{code_bin}}};")

    return lines


print("// ============================================================")
print("// AC Luminance ROM (Table K.5) - GENERATED FROM STANDARD")
print("// ============================================================")
for line in gen_verilog_rom("ac_luma_rom", AC_LUMA_BITS, AC_LUMA_VALS):
    print(line)

print()
print("// ============================================================")
print("// AC Chrominance ROM (Table K.6) - GENERATED FROM STANDARD")
print("// ============================================================")
for line in gen_verilog_rom("ac_chroma_rom", AC_CHROMA_BITS, AC_CHROMA_VALS):
    print(line)
