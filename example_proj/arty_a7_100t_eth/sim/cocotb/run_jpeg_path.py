#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio
#
# cocotb runner for the demo JPEG output path:
#   jpeg_capture -> demo_jpeg_buffer -> jpeg_rtp_tx   (Icarus / Verilog)
#
#   python run_jpeg_path.py        (exit 0 = PASS, non-zero = FAIL)

import shutil
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner, get_results

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]

SOURCES = [
    REPO / "example_proj" / "common" / "rtl" / "jpeg_capture.v",
    REPO / "example_proj" / "common" / "rtl" / "demo_jpeg_buffer.v",
    REPO / "rtl" / "eth" / "jpeg_rtp_tx.v",
    HERE / "tb_jpeg_path.v",
]


def main():
    build = HERE / "build_jpeg_path"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy2(HERE / "test_jpeg_path.py", build / "test_jpeg_path.py")

    params = {"JPEG_WORDS": 512}
    print("=== cocotb: jpeg_path (icarus)  JPEG_WORDS=512 ===")
    runner = get_runner("icarus")
    runner.build(
        verilog_sources=[str(s) for s in SOURCES],
        hdl_toplevel="tb_jpeg_path",
        parameters=params,
        timescale=("1ns", "1ps"),
        build_dir=str(build),
        always=True,
    )
    results_xml = runner.test(
        hdl_toplevel="tb_jpeg_path",
        test_module="test_jpeg_path",
        test_dir=str(build),
        build_dir=str(build),
        parameters=params,
    )
    num_tests, num_failed = get_results(results_xml)
    print(f"=== RESULT jpeg_path: {num_tests - num_failed}/{num_tests} passed ===")
    return 1 if num_failed else 0


if __name__ == "__main__":
    sys.exit(main())
