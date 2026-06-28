#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Leonardo Capossio - bard0 design
#
# Dual-language cocotb runner: drives the SAME test (test_encoder.py) against the
# Verilog port (Icarus) and the VHDL port (GHDL), reusing the golden coefficient
# compare. OS-agnostic: all paths are pathlib-relative to the repo, PATH uses
# os.pathsep, and GHDL's runtime lib dir is derived from `which ghdl` (no
# hardcoded install paths), so it runs unchanged on Linux CI.
#
#   python test_runner.py [verilog|vhdl] [lite|full] [quality] [frames]
# defaults: verilog lite 75 1   (exit code 0 = PASS, non-zero = FAIL)

import os
import shutil
import subprocess
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner, get_results

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
RTL = REPO / "rtl"
VHDL = RTL / "vhdl"
TV_DIR = REPO / "sim" / "test_vectors"
PY_DIR = REPO / "python"

V_SOURCES = [RTL / f for f in (
    "bram_sdp.v", "dct_1d.v", "dct_2d.v", "input_buffer.v", "quantizer.v",
    "zigzag_reorder.v", "huffman_encoder.v", "bitstream_packer.v",
    "jfif_writer.v", "axi4_lite_regs.v", "rgb_to_ycbcr.v", "mjpegzero_enc_top.v",
)]
VHDL_SOURCES = [VHDL / f for f in (
    "mjpegzero_pkg.vhd", "axi4_lite_regs.vhd", "bram_sdp.vhd", "input_buffer.vhd",
    "dct_1d.vhd", "dct_2d.vhd", "quantizer.vhd", "huffman_encoder.vhd",
    "bitstream_packer.vhd", "rgb_to_ycbcr.vhd", "zigzag_reorder.vhd",
    "jfif_writer.vhd", "mjpegzero_enc_top.vhd",
)]


def reference_for(q):
    return TV_DIR / ("reference_4mcu.jpg" if q == 95 else f"reference_4mcu_q{q}.jpg")


def ensure_vectors(ref):
    if TV_DIR.joinpath("yuyv_input.hex").is_file() and ref.is_file():
        return
    print("Generating test vectors ...")
    subprocess.run([sys.executable, str(PY_DIR / "generate_test_vectors.py")], check=True)


def augment_path_for_ghdl():
    """Make GHDL's VPI dependencies resolvable without hardcoding install paths.

    cocotb's cocotbvpi_ghdl.dll needs GHDL's libghdlvpi (in <ghdl>/lib), the
    Python runtime, and cocotb's own libs on the loader search path. Derive all
    three; harmless on Linux where the loader finds them via rpath/ldconfig.
    """
    extra = []
    ghdl = shutil.which("ghdl")
    if ghdl:
        libdir = Path(ghdl).resolve().parent.parent / "lib"
        if libdir.is_dir():
            extra.append(str(libdir))
    extra.append(str(Path(sys.executable).resolve().parent))
    try:
        import cocotb
        libs = Path(cocotb.__file__).resolve().parent / "libs"
        if libs.is_dir():
            extra.append(str(libs))
    except Exception:
        pass
    os.environ["PATH"] = os.pathsep.join(extra + [os.environ.get("PATH", "")])


def main():
    lang = sys.argv[1] if len(sys.argv) > 1 else "verilog"
    mode = sys.argv[2] if len(sys.argv) > 2 else "lite"
    quality = int(sys.argv[3]) if len(sys.argv) > 3 else 75
    frames = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    lite = (mode == "lite")
    sim = "icarus" if lang == "verilog" else "ghdl"

    ref = reference_for(quality)
    ensure_vectors(ref)

    # GHDL's work library is cwd-relative and cocotb runs the test in test_dir,
    # so build and test must share one dir; copy the test module in.
    build = HERE / f"build_{lang}_{mode}_q{quality}_f{frames}"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy2(HERE / "test_encoder.py", build / "test_encoder.py")

    os.environ["ENC_TV_DIR"] = str(TV_DIR)
    os.environ["ENC_PY_DIR"] = str(PY_DIR)
    os.environ["ENC_REF"] = str(ref)
    os.environ["ENC_QUALITY"] = str(quality)
    os.environ["ENC_FRAMES"] = str(frames)
    os.environ.setdefault("ENC_EXPECT_MIN_PIPE_DEPTH", "3")

    parameters = {
        "IMG_WIDTH": 64, "IMG_HEIGHT": 8,
        "LITE_MODE": 1 if lite else 0, "LITE_QUALITY": quality,
    }

    print(f"=== cocotb: {lang}/{sim}  {mode}  Q={quality}  frames={frames} ===")
    runner = get_runner(sim)

    if sim == "ghdl":
        augment_path_for_ghdl()
        # --syn-binding: bind component instances to same-name entities in work
        # (GHDL's default binding is stricter than Vivado's; without it every
        # submodule is "not bound" and the encoder elaborates hollow).
        ghdl_args = ["--std=93", "--syn-binding"]
        runner.build(
            vhdl_sources=[str(s) for s in VHDL_SOURCES],
            hdl_toplevel="mjpegzero_enc_top",
            parameters=parameters,
            build_args=ghdl_args,
            build_dir=str(build),
            always=True,
        )
        test_args = ghdl_args
    else:
        runner.build(
            verilog_sources=[str(s) for s in V_SOURCES],
            hdl_toplevel="mjpegzero_enc_top",
            parameters=parameters,
            timescale=("1ns", "1ps"),
            build_dir=str(build),
            always=True,
        )
        test_args = []

    results_xml = runner.test(
        hdl_toplevel="mjpegzero_enc_top",
        test_module="test_encoder",
        test_dir=str(build),
        build_dir=str(build),
        parameters=parameters,
        test_args=test_args,
    )

    num_tests, num_failed = get_results(results_xml)
    print(f"=== RESULT {lang}/{sim} {mode} Q{quality} f{frames}: "
          f"{num_tests - num_failed}/{num_tests} passed ===")
    return 1 if num_failed else 0


if __name__ == "__main__":
    sys.exit(main())
