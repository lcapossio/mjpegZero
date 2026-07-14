#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# ============================================================================
# parity.py — byte-exact parity harness for streamline/ module verification
# ============================================================================
# Compiles and runs the full-encoder testbench (sim/tb_iverilog.sv) twice:
#
#   baseline : every module taken from rtl/
#   swapped  : the modules named with --swap taken from streamline/,
#              all others from rtl/
#
# and byte-compares the two encoded JPEG outputs. Because streamline modules
# are drop-in replacements (same module name, same ports), each run is a
# separate compile; parity is judged on the emitted bitstream, which for the
# lossless back end (quantizer, huffman_encoder, bitstream_packer, and the
# jfif_writer at matching tables) must be byte-identical.
#
# Usage:
#   python3 streamline/verify/parity.py --self-check
#   python3 streamline/verify/parity.py --swap quantizer
#   python3 streamline/verify/parity.py --swap quantizer,huffman_encoder \
#       --lite --quality 75 --width 64 --height 8
#
# Exit code 0 = byte-identical; 1 = mismatch or simulation failure.
# ============================================================================

import argparse
import filecmp
import os
import shutil
import subprocess
import sys

PROJ = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
RTL = os.path.join(PROJ, 'rtl')
STREAMLINE = os.path.join(PROJ, 'streamline', 'rtl', 'encoder')
SIM = os.path.join(PROJ, 'sim')
BUILD = os.path.join(PROJ, 'build', 'parity')

# Compile order matches the FuseSoC rtl fileset (mjpegzero.core).
MODULES = [
    'bram_sdp', 'input_buffer', 'dct_1d', 'dct_2d', 'quantizer',
    'zigzag_reorder', 'huffman_encoder', 'bitstream_packer', 'jfif_writer',
    'axi4_lite_regs', 'rgb_to_ycbcr', 'mjpegzero_enc_top',
]


def source_list(swaps):
    """Return the .v file list with swapped modules taken from streamline/."""
    files = []
    for mod in MODULES:
        tree = STREAMLINE if mod in swaps else RTL
        path = os.path.join(tree, mod + '.v')
        if not os.path.isfile(path):
            sys.exit(f'ERROR: {path} does not exist')
        files.append(path)
    return files


def run_encoder(tag, swaps, opts):
    """Compile and simulate one encoder build; return path to its JPEG."""
    workdir = os.path.join(BUILD, tag)
    shutil.rmtree(workdir, ignore_errors=True)
    os.makedirs(workdir)
    # tb_iverilog.sv reads test_vectors/*.hex relative to the run directory.
    shutil.copytree(os.path.join(SIM, 'test_vectors'),
                    os.path.join(workdir, 'test_vectors'))

    defines = [
        '-DTB_IMG_WIDTH=%d' % opts.width,
        '-DTB_IMG_HEIGHT=%d' % opts.height,
    ]
    if opts.lite:
        defines += ['-DLITE_MODE', '-DLITE_QUALITY=%d' % opts.quality]
    else:
        defines += ['-DTEST_QUALITY=%d' % opts.quality]
    if opts.tv:
        defines += ['-DTV_HEX_FILE=\\"%s\\"' % opts.tv]

    vvp_file = os.path.join(workdir, 'sim.vvp')
    compile_cmd = (['iverilog', '-g2012', '-o', vvp_file] + defines
                   + source_list(swaps)
                   + [os.path.join(SIM, 'tb_iverilog.sv')])
    print(f'[{tag}] compiling ({len(swaps) or "no"} swapped: '
          f'{", ".join(sorted(swaps)) or "-"})')
    r = subprocess.run(compile_cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr, sep='\n')
        sys.exit(f'ERROR: iverilog compile failed for {tag}')

    print(f'[{tag}] simulating...')
    r = subprocess.run(['vvp', 'sim.vvp'], cwd=workdir,
                       capture_output=True, text=True)
    log = os.path.join(workdir, 'sim.log')
    with open(log, 'w') as f:
        f.write(r.stdout + r.stderr)
    if 'ALL TESTS PASSED' not in r.stdout:
        tail = '\n'.join(r.stdout.splitlines()[-25:])
        print(tail)
        sys.exit(f'ERROR: simulation did not pass for {tag} (log: {log})')

    jpg = os.path.join(workdir, 'sim_output.jpg')
    if not os.path.isfile(jpg):
        sys.exit(f'ERROR: {tag} produced no sim_output.jpg')
    return jpg


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--swap', default='',
                   help='comma-separated module names to take from streamline/')
    p.add_argument('--self-check', action='store_true',
                   help='run rtl-vs-rtl and require identical output')
    p.add_argument('--lite', action='store_true', help='LITE_MODE=1')
    p.add_argument('--quality', type=int, default=95)
    p.add_argument('--width', type=int, default=64)
    p.add_argument('--height', type=int, default=8)
    p.add_argument('--tv', default='',
                   help='test-vector hex file (relative to the run dir), '
                        'for sizes other than the default 64x8')
    p.add_argument('--psnr', action='store_true',
                   help='judge by decoded PSNR vs the source crop instead '
                        'of byte identity (for swaps that legitimately '
                        'change rounding, e.g. the DCT); needs numpy+Pillow')
    opts = p.parse_args()

    swaps = set(filter(None, opts.swap.split(',')))
    unknown = swaps - set(MODULES)
    if unknown:
        sys.exit(f'ERROR: unknown module(s): {", ".join(sorted(unknown))}')
    if not swaps and not opts.self_check:
        sys.exit('ERROR: give --swap <modules> or --self-check')

    base_jpg = run_encoder('baseline', set(), opts)
    test_jpg = run_encoder('swapped' if swaps else 'baseline2', swaps, opts)

    if opts.psnr:
        import io
        import numpy as np
        from PIL import Image
        src = np.asarray(Image.open(os.path.join(
            PROJ, 'python', 'test_images', 'mandrill_720p.png'))
            .convert('RGB'))[0:opts.height, 0:opts.width].astype(np.float64)

        def psnr(path):
            img = np.asarray(Image.open(io.BytesIO(open(path, 'rb').read()))
                             .convert('RGB')).astype(np.float64)
            mse = np.mean((src - img) ** 2)
            return 10 * np.log10(255**2 / mse)

        pb, pt = psnr(base_jpg), psnr(test_jpg)
        ok = pt >= pb - 0.05
        print(f'PSNR baseline {pb:.3f} dB, swapped {pt:.3f} dB, '
              f'delta {pt-pb:+.4f} dB -> {"PASS" if ok else "FAIL"}')
        return 0 if ok else 1

    if filecmp.cmp(base_jpg, test_jpg, shallow=False):
        size = os.path.getsize(base_jpg)
        print(f'PARITY OK: outputs byte-identical ({size} bytes)')
        return 0
    a, b = open(base_jpg, 'rb').read(), open(test_jpg, 'rb').read()
    diff_at = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y),
                   min(len(a), len(b)))
    print(f'PARITY FAIL: sizes {len(a)} vs {len(b)}, '
          f'first difference at byte {diff_at}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
