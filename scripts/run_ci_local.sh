#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
# run_ci_local.sh — simulate GitHub Actions CI jobs locally via WSL
#
# Usage:
#   bash scripts/run_ci_local.sh [job ...]
#
# Jobs: verify  rtl-lint  rtl-sim  rtl-coverage  fusesoc  all (default)
#
# Prerequisites (install once):
#   sudo apt-get install -y verilator iverilog ffmpeg g++ make lcov
#   pip install numpy scipy Pillow fusesoc   (in a venv or user install)
#
# Example:
#   bash scripts/run_ci_local.sh rtl-lint rtl-coverage

set -euo pipefail

PROJ=/mnt/c/Projects/MJPEGenc
cd "$PROJ"

PASS=0; FAIL=0
FAILED_JOBS=()

# ── helpers ─────────────────────────────────────────────────────────────────

run_job() {
    local name=$1
    echo ""
    echo "================================================================="
    echo "  JOB: $name"
    echo "================================================================="
}

ok()   { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*" >&2; }

finish_job() {
    local name=$1 rc=$2
    if [ "$rc" -eq 0 ]; then
        echo "--> $name PASSED"
        PASS=$((PASS+1))
    else
        echo "--> $name FAILED (exit $rc)" >&2
        FAIL=$((FAIL+1))
        FAILED_JOBS+=("$name")
    fi
}

check_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found in PATH"; exit 1; }
}

check_python_pkg() {
    python3 -c "import $1" 2>/dev/null || { echo "ERROR: Python package '$1' not installed"; exit 1; }
}

# ── prerequisite check ──────────────────────────────────────────────────────

check_prereqs() {
    local tools=("$@")
    for t in "${tools[@]}"; do
        check_tool "$t"
    done
}

# ── job: verify ─────────────────────────────────────────────────────────────

job_verify() {
    run_job "verify (Python)"
    (
        set -e
        check_prereqs python3 ffmpeg
        check_python_pkg numpy
        check_python_pkg scipy
        check_python_pkg PIL
        echo "--- verify_huffman_rom"
        python3 python/verify_huffman_rom.py
        echo "--- verify_lite_quality"
        python3 python/verify_lite_quality.py
        echo "--- test_encoder (PSNR check)"
        python3 python/test_encoder.py
        echo "--- mandrill_compare Q=50/75/95"
        python3 python/mandrill_compare.py --quality 50 --out /tmp/mandrill_Q50.png || true
        python3 python/mandrill_compare.py --quality 75 --out /tmp/mandrill_Q75.png || true
        python3 python/mandrill_compare.py --quality 95 --out /tmp/mandrill_Q95.png || true
    )
    finish_job "verify" $?
}

# ── job: rtl-lint ────────────────────────────────────────────────────────────

job_rtl_lint() {
    run_job "rtl-lint (Verilator)"
    (
        set -e
        check_prereqs verilator
        for f in \
            rtl/dct_1d.v \
            rtl/zigzag_reorder.v \
            rtl/bitstream_packer.v \
            rtl/axi4_lite_regs.v \
            rtl/rgb_to_ycbcr.v; do
            echo "--- lint: $f"
            verilator --lint-only -Wall --bbox-unsup "$f"
        done
        echo "--- lint: rtl/dct_2d.v"
        verilator --lint-only -Wall --bbox-unsup rtl/dct_1d.v rtl/dct_2d.v
        echo "--- lint: rtl/input_buffer.v"
        verilator --lint-only -Wall --bbox-unsup rtl/vendor/sim/bram_sdp.v rtl/input_buffer.v
        echo "--- lint: quantizer LITE_MODE=0"
        verilator --lint-only -Wall --bbox-unsup -DLITE_MODE=0 rtl/quantizer.v
        echo "--- lint: quantizer LITE_MODE=1"
        verilator --lint-only -Wall --bbox-unsup -DLITE_MODE=1 rtl/quantizer.v
        echo "--- lint: huffman_encoder"
        verilator --lint-only -Wall --bbox-unsup rtl/huffman_encoder.v
        echo "--- lint: jfif_writer"
        verilator --lint-only -Wall --bbox-unsup rtl/jfif_writer.v
        echo "--- lint: top LITE_MODE=0"
        verilator --lint-only -Wall --bbox-unsup -DLITE_MODE=0 \
            rtl/vendor/sim/bram_sdp.v rtl/dct_1d.v rtl/dct_2d.v \
            rtl/input_buffer.v rtl/quantizer.v rtl/zigzag_reorder.v \
            rtl/huffman_encoder.v rtl/bitstream_packer.v rtl/jfif_writer.v \
            rtl/axi4_lite_regs.v rtl/mjpegzero_enc_top.v
        echo "--- lint: top LITE_MODE=1"
        verilator --lint-only -Wall --bbox-unsup -DLITE_MODE=1 \
            rtl/vendor/sim/bram_sdp.v rtl/dct_1d.v rtl/dct_2d.v \
            rtl/input_buffer.v rtl/quantizer.v rtl/zigzag_reorder.v \
            rtl/huffman_encoder.v rtl/bitstream_packer.v rtl/jfif_writer.v \
            rtl/axi4_lite_regs.v rtl/mjpegzero_enc_top.v
    )
    finish_job "rtl-lint" $?
}

# ── job: rtl-sim ─────────────────────────────────────────────────────────────

job_rtl_sim() {
    run_job "rtl-sim (iverilog)"
    (
        set -e
        check_prereqs iverilog vvp python3 ffmpeg
        check_python_pkg numpy
        check_python_pkg PIL
        echo "--- generate test vectors"
        python3 python/test_encoder.py
        echo "--- verify_rtl_sim (full mode)"
        python3 python/verify_rtl_sim.py
        echo "--- verify_rtl_sim (lite mode)"
        python3 python/verify_rtl_sim.py --lite
    )
    finish_job "rtl-sim" $?
}

# ── job: rtl-coverage ────────────────────────────────────────────────────────

job_rtl_coverage() {
    run_job "rtl-coverage (Verilator)"
    (
        set -e
        check_prereqs verilator g++ make lcov python3 ffmpeg
        check_python_pkg numpy
        check_python_pkg PIL
        echo "--- generate test vectors"
        python3 python/test_encoder.py
        echo "--- coverage full mode"
        python3 python/run_coverage.py --html
        echo "--- coverage lite mode"
        python3 python/run_coverage.py --lite --html
    )
    finish_job "rtl-coverage" $?
}

# ── job: fusesoc ─────────────────────────────────────────────────────────────

job_fusesoc() {
    run_job "fusesoc (core validation + lint)"
    (
        set -e
        check_prereqs fusesoc verilator make
        echo "--- register library"
        fusesoc library add mjpegzero .
        echo "--- core-info"
        fusesoc core-info bard0-design:mjpegzero:mjpegzero_enc
        echo "--- lint LITE_MODE=1 (default)"
        fusesoc run --target lint bard0-design:mjpegzero:mjpegzero_enc
        echo "--- lint LITE_MODE=0"
        fusesoc run --target lint bard0-design:mjpegzero:mjpegzero_enc --LITE_MODE 0
    )
    finish_job "fusesoc" $?
}

# ── dispatch ─────────────────────────────────────────────────────────────────

JOBS=("${@:-all}")
if [[ "${JOBS[*]}" == "all" ]]; then
    JOBS=(verify rtl-lint rtl-sim rtl-coverage fusesoc)
fi

for job in "${JOBS[@]}"; do
    case "$job" in
        verify)       job_verify ;;
        rtl-lint)     job_rtl_lint ;;
        rtl-sim)      job_rtl_sim ;;
        rtl-coverage) job_rtl_coverage ;;
        fusesoc)      job_fusesoc ;;
        all)          job_verify; job_rtl_lint; job_rtl_sim; job_rtl_coverage; job_fusesoc ;;
        *) echo "Unknown job: $job  (verify|rtl-lint|rtl-sim|rtl-coverage|fusesoc|all)" >&2; exit 1 ;;
    esac
done

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "================================================================="
echo "  CI LOCAL SUMMARY"
echo "================================================================="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "${#FAILED_JOBS[@]}" -gt 0 ]; then
    echo "  Failed jobs: ${FAILED_JOBS[*]}"
    exit 1
else
    echo "  ALL JOBS PASSED"
fi
