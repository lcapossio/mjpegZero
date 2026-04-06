#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Commons Clause v1.0 applies — commercial use requires written permission. Contact: hello@bard0.com
# Copyright (c) 2026 Leonardo Capossio — bard0 design
#
"""
run_ci_local.py — Run GitHub Actions CI jobs locally.

Mirrors the jobs in .github/workflows/ci.yml so you can validate changes
before pushing. Each job is a sequence of steps; failure in any step fails
the job. The summary at the end reports per-job and overall PASS/FAIL.

Usage:
    python scripts/run_ci_local.py                 # run all jobs
    python scripts/run_ci_local.py verify rtl-sim  # run selected jobs
    python scripts/run_ci_local.py --list          # list available jobs

Available jobs:
    verify             Python-only verification (Tier 1)
    rtl-lint           Verilator lint (all parameter combinations)
    rtl-sim            iverilog RTL simulation (full + lite + corner cases)
    rtl-verilator-sim  Verilator functional simulation
    rtl-coverage       Verilator code coverage
    fusesoc            FuseSoC core validation + lint
    all                All of the above (default)

Tool prerequisites are checked at job start. Missing tools fail the job
with a clear message rather than a cryptic subprocess error.
"""

import argparse
import os
import shutil
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Paths (resolved relative to this script — no hardcoded absolute paths)
# ---------------------------------------------------------------------------
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_DIR   = os.path.dirname(SCRIPT_DIR)
PYTHON     = sys.executable

# Per-job state populated during run
PASS_COUNT = 0
FAIL_COUNT = 0
FAILED_JOBS = []
JOB_RESULTS = []   # list of (name, ok, duration_s, failed_step)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def banner(text):
    line = '=' * 70
    print()
    print(line)
    print(f'  {text}')
    print(line)


def step_banner(text):
    print()
    print(f'--- {text}')


def find_tool(name):
    return shutil.which(name)


def check_tools(*tools):
    """Verify all tools exist in PATH. Returns list of missing tools."""
    missing = [t for t in tools if not find_tool(t)]
    return missing


def check_python_modules(*modules):
    """Verify Python modules importable. Returns list of missing modules."""
    missing = []
    for mod in modules:
        try:
            __import__(mod)
        except ImportError:
            missing.append(mod)
    return missing


def run_step(cmd, cwd=None):
    """Run a command. Stream output. Return True on success."""
    if cwd is None:
        cwd = PROJ_DIR
    print(f'  $ {" ".join(cmd)}')
    try:
        result = subprocess.run(cmd, cwd=cwd)
    except FileNotFoundError as e:
        print(f'  ERROR: command not found: {e}')
        return False
    return result.returncode == 0


def py(*args):
    """Build a python invocation as a list."""
    return [PYTHON] + list(args)


def run_job(name, prereqs_tools, prereqs_modules, steps):
    """
    Run a job: check prerequisites, then execute each step in order.
    Stops on first failure within the job.

    steps: list of (step_name, cmd_list) tuples
    """
    global PASS_COUNT, FAIL_COUNT, FAILED_JOBS, JOB_RESULTS

    banner(f'JOB: {name}')
    t0 = time.time()

    missing_tools = check_tools(*prereqs_tools)
    if missing_tools:
        print(f'  SKIP: missing tools in PATH: {", ".join(missing_tools)}')
        FAIL_COUNT += 1
        FAILED_JOBS.append(name)
        JOB_RESULTS.append((name, False, 0.0, f'missing tools: {missing_tools}'))
        return False

    missing_modules = check_python_modules(*prereqs_modules)
    if missing_modules:
        print(f'  SKIP: missing Python modules: {", ".join(missing_modules)}')
        print(f'  Hint: pip install -r python/requirements.txt')
        FAIL_COUNT += 1
        FAILED_JOBS.append(name)
        JOB_RESULTS.append((name, False, 0.0, f'missing modules: {missing_modules}'))
        return False

    failed_step = None
    for step_name, cmd in steps:
        step_banner(step_name)
        if not run_step(cmd):
            failed_step = step_name
            break

    duration = time.time() - t0
    ok = failed_step is None
    if ok:
        print(f'\n  --> {name} PASSED ({duration:.1f}s)')
        PASS_COUNT += 1
    else:
        print(f'\n  --> {name} FAILED at step "{failed_step}" ({duration:.1f}s)')
        FAIL_COUNT += 1
        FAILED_JOBS.append(name)
    JOB_RESULTS.append((name, ok, duration, failed_step))
    return ok


# ---------------------------------------------------------------------------
# Job definitions (mirror .github/workflows/ci.yml)
# ---------------------------------------------------------------------------
def job_verify():
    return run_job(
        'verify',
        prereqs_tools=['ffmpeg'],
        prereqs_modules=['numpy', 'scipy', 'PIL'],
        steps=[
            ('verify_huffman_rom', py('python/verify_huffman_rom.py')),
            ('verify_lite_quality', py('python/verify_lite_quality.py')),
            ('test_encoder (PSNR check)', py('python/test_encoder.py')),
            ('mandrill_compare Q=50',  py('python/mandrill_compare.py', '--quality', '50',
                                         '--out', 'build/mandrill_Q50.png')),
            ('mandrill_compare Q=75',  py('python/mandrill_compare.py', '--quality', '75',
                                         '--out', 'build/mandrill_Q75.png')),
            ('mandrill_compare Q=95',  py('python/mandrill_compare.py', '--quality', '95',
                                         '--out', 'build/mandrill_Q95.png')),
        ],
    )


def _lint_top(lite_mode, rgb_input):
    rtl = [
        'rtl/vendor/sim/bram_sdp.v', 'rtl/dct_1d.v', 'rtl/dct_2d.v',
        'rtl/input_buffer.v', 'rtl/quantizer.v', 'rtl/zigzag_reorder.v',
        'rtl/huffman_encoder.v', 'rtl/bitstream_packer.v', 'rtl/jfif_writer.v',
        'rtl/axi4_lite_regs.v', 'rtl/rgb_to_ycbcr.v', 'rtl/mjpegzero_enc_top.v',
    ]
    defs = [f'-DLITE_MODE={lite_mode}']
    if rgb_input:
        defs.append('-DRGB_INPUT=1')
    return ['verilator', '--lint-only', '-Wall', '--bbox-unsup'] + defs + rtl


def job_rtl_lint():
    individual = [
        'rtl/dct_1d.v', 'rtl/zigzag_reorder.v', 'rtl/bitstream_packer.v',
        'rtl/axi4_lite_regs.v', 'rtl/rgb_to_ycbcr.v', 'rtl/jfif_writer.v',
    ]
    steps = []
    for f in individual:
        steps.append((f'lint {f}',
                      ['verilator', '--lint-only', '-Wall', '--bbox-unsup', f]))
    steps += [
        ('lint dct_2d (with dct_1d)',
         ['verilator', '--lint-only', '-Wall', '--bbox-unsup',
          'rtl/dct_1d.v', 'rtl/dct_2d.v']),
        ('lint input_buffer (with bram_sdp)',
         ['verilator', '--lint-only', '-Wall', '--bbox-unsup',
          'rtl/vendor/sim/bram_sdp.v', 'rtl/input_buffer.v']),
        ('lint quantizer LITE_MODE=0',
         ['verilator', '--lint-only', '-Wall', '--bbox-unsup',
          '-DLITE_MODE=0', 'rtl/quantizer.v']),
        ('lint quantizer LITE_MODE=1',
         ['verilator', '--lint-only', '-Wall', '--bbox-unsup',
          '-DLITE_MODE=1', 'rtl/quantizer.v']),
        ('lint huffman_encoder',
         ['verilator', '--lint-only', '-Wall', '--bbox-unsup',
          'rtl/huffman_encoder.v']),
        ('lint top LITE_MODE=0 RGB_INPUT=0', _lint_top(0, False)),
        ('lint top LITE_MODE=1 RGB_INPUT=0', _lint_top(1, False)),
        ('lint top LITE_MODE=1 RGB_INPUT=1', _lint_top(1, True)),
        ('lint top LITE_MODE=0 RGB_INPUT=1', _lint_top(0, True)),
    ]
    # Vendor BRAM stubs
    for vendor in ('altera', 'lattice', 'microchip', 'efinix', 'gowin', 'sim'):
        steps.append((f'lint vendor/{vendor}/bram_sdp.v',
                      ['verilator', '--lint-only', '-Wall', '--bbox-unsup',
                       f'rtl/vendor/{vendor}/bram_sdp.v']))

    return run_job('rtl-lint',
                   prereqs_tools=['verilator'],
                   prereqs_modules=[],
                   steps=steps)


def job_rtl_sim():
    return run_job(
        'rtl-sim',
        prereqs_tools=['iverilog', 'vvp', 'ffmpeg'],
        prereqs_modules=['numpy', 'PIL'],
        steps=[
            ('generate test image',         py('python/test_encoder.py')),
            ('verify_rtl_sim full mode',    py('python/verify_rtl_sim.py')),
            ('verify_rtl_sim lite mode',    py('python/verify_rtl_sim.py', '--lite')),
            ('verify_rtl_sim --rgb full',   py('python/verify_rtl_sim.py', '--rgb')),
            ('verify_rtl_sim --rgb lite',   py('python/verify_rtl_sim.py', '--lite', '--rgb')),
            ('verify_rtl_sim --gaps full',  py('python/verify_rtl_sim.py', '--gaps')),
            ('verify_rtl_sim --gaps lite',  py('python/verify_rtl_sim.py', '--lite', '--gaps')),
            ('verify_rtl_sim --min-width full',
             py('python/verify_rtl_sim.py', '--min-width')),
            ('verify_rtl_sim --min-width lite',
             py('python/verify_rtl_sim.py', '--lite', '--min-width')),
            ('verify_exif full 72 DPI',     py('python/verify_exif.py')),
            ('verify_exif full 96 DPI',     py('python/verify_exif.py',
                                              '--x-res', '96', '--y-res', '96', '--res-unit', '2')),
            ('verify_exif lite 96 DPI',     py('python/verify_exif.py', '--lite',
                                              '--x-res', '96', '--y-res', '96', '--res-unit', '2')),
            ('verify_axi_regs full',        py('python/verify_axi_regs.py')),
            ('verify_axi_regs lite',        py('python/verify_axi_regs.py', '--lite')),
        ],
    )


def job_rtl_verilator_sim():
    return run_job(
        'rtl-verilator-sim',
        # ffmpeg is needed by test_encoder.py (generate test vectors step)
        prereqs_tools=['verilator', 'g++', 'make', 'ffmpeg'],
        prereqs_modules=['numpy', 'PIL'],
        steps=[
            ('generate test vectors',  py('python/test_encoder.py')),
            ('verilator sim full',     py('python/run_verilator_sim.py')),
            ('verilator sim lite',     py('python/run_verilator_sim.py', '--lite')),
        ],
    )


def job_rtl_coverage():
    return run_job(
        'rtl-coverage',
        prereqs_tools=['verilator', 'g++', 'make', 'ffmpeg'],
        prereqs_modules=['numpy', 'PIL'],
        steps=[
            ('generate test vectors',  py('python/test_encoder.py')),
            ('coverage full mode',     py('python/run_coverage.py')),
            ('coverage lite mode',     py('python/run_coverage.py', '--lite')),
        ],
    )


def job_fusesoc():
    # Use --cores-root instead of `library add` to avoid mutating the user's
    # global ~/.config/fusesoc/fusesoc.conf (which would store an absolute path
    # that breaks across WSL/Windows/Linux boundaries).
    return run_job(
        'fusesoc',
        prereqs_tools=['fusesoc', 'verilator', 'make'],
        prereqs_modules=[],
        steps=[
            ('core-info',
             ['fusesoc', '--cores-root', '.', 'core-info',
              'bard0-design:mjpegzero:mjpegzero_enc']),
            ('lint LITE_MODE=1 (default)',
             ['fusesoc', '--cores-root', '.', 'run', '--target', 'lint',
              'bard0-design:mjpegzero:mjpegzero_enc']),
            ('lint LITE_MODE=0',
             ['fusesoc', '--cores-root', '.', 'run', '--target', 'lint',
              'bard0-design:mjpegzero:mjpegzero_enc', '--LITE_MODE', '0']),
        ],
    )


JOBS = {
    'verify':            job_verify,
    'rtl-lint':          job_rtl_lint,
    'rtl-sim':           job_rtl_sim,
    'rtl-verilator-sim': job_rtl_verilator_sim,
    'rtl-coverage':      job_rtl_coverage,
    'fusesoc':           job_fusesoc,
}

ALL_JOBS_ORDER = [
    'verify', 'rtl-lint', 'rtl-sim',
    'rtl-verilator-sim', 'rtl-coverage', 'fusesoc',
]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description='Run GitHub Actions CI jobs locally',
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument('jobs', nargs='*',
                        help='Jobs to run (default: all)')
    parser.add_argument('--list', action='store_true',
                        help='List available jobs and exit')
    args = parser.parse_args()

    if args.list:
        print('Available jobs:')
        for j in ALL_JOBS_ORDER:
            print(f'  {j}')
        print('  all  (run everything in order)')
        return 0

    if not args.jobs or args.jobs == ['all']:
        selected = ALL_JOBS_ORDER
    else:
        selected = []
        for j in args.jobs:
            if j == 'all':
                selected = ALL_JOBS_ORDER
                break
            if j not in JOBS:
                print(f'ERROR: unknown job "{j}". Use --list to see available jobs.')
                return 2
            selected.append(j)

    # Make sure build/ exists for artifacts
    os.makedirs(os.path.join(PROJ_DIR, 'build'), exist_ok=True)

    print('=' * 70)
    print(f'  mjpegZero local CI runner')
    print(f'  Jobs: {", ".join(selected)}')
    print(f'  Project: {PROJ_DIR}')
    print(f'  Python: {PYTHON}')
    print('=' * 70)

    t0 = time.time()
    for j in selected:
        JOBS[j]()
    total = time.time() - t0

    # Summary
    banner('SUMMARY')
    for name, ok, dur, failed_step in JOB_RESULTS:
        status = 'PASS' if ok else 'FAIL'
        extra = '' if ok else f'  (failed at: {failed_step})'
        print(f'  [{status}] {name:<20} {dur:6.1f}s{extra}')
    print(f'  {"-" * 60}')
    print(f'  Passed: {PASS_COUNT}')
    print(f'  Failed: {FAIL_COUNT}')
    print(f'  Total:  {total:.1f}s')
    if FAILED_JOBS:
        print(f'  Failed jobs: {", ".join(FAILED_JOBS)}')
    print('=' * 70)

    return 0 if FAIL_COUNT == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
