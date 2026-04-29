# Arty S7-50 mjpegZero Demo - fcapz, 720p

> Status: unverified board port. This project has not yet been built, timed, or
> hardware-tested by the maintainers. The verified reference demo is
> [`../arty_a7_100t/`](../arty_a7_100t/).

Board-level example for the mjpegZero core. A Python host program prepares
1280x720 YUYV frames and transfers them to the FPGA via the
[fpgacapZero](../../fcapz/README.md) debug bridge on the same USB cable used
for programming. No vendor debug IP, separate UART cable, or extra
hardware is required.

Pixel data streams directly from the host to the encoder without an on-chip
frame buffer; compressed JPEGs are stored in on-chip BRAM and read back after
encoding.

## Hardware

| Item | Detail |
|------|--------|
| Board | Digilent Arty S7-50 |
| Device | XC7S50CSGA324-1 |
| FPGA clock | 100 MHz oscillator to 150 MHz via MMCME2_ADV |
| Host interface | fcapz bridge on USER4 + ELA on USER1/USER2 |
| Image size | 1280 x 720 pixels, YUYV 4:2:2 |
| JPEG buffer | 64 KB on-chip by default |

## Prerequisites

- Vivado 2025.x with Spartan-7 device support installed (project flow tested with 2025.2)
- `vivado` executable in PATH for bitstream builds
- `hw_server` and `xsdb` on PATH for the fcapz host
- `fcapz/` submodule initialized with `git submodule update --init`
- Python 3.9+ with `pip install Pillow numpy tqdm`

## Building The Bitstream

From the repository root:

```bash
vivado -mode batch -source example_proj/arty_s7_50/scripts/create_project.tcl
```

The script adds the fcapz RTL (`fcapz_ejtagaxi_xilinx7` on USER4 and
`fcapz_ela_xilinx7` on USER1/USER2), runs synthesis/place/route, and writes:

```text
example_proj/arty_s7_50/build/arty_s7_demo.bit
```

If this build succeeds, record the Vivado version, utilization, WNS, fcapz
configuration, and hardware-test result here before treating the port as
validated.

## Running The Demo

Encode a single image:

```bash
python example_proj/common/python/demo.py \
    --bit example_proj/arty_s7_50/build/arty_s7_demo.bit \
    --program \
    --image photo.jpg --out out.jpg
```

Encode a batch:

```bash
python example_proj/common/python/demo.py \
    --bit example_proj/arty_s7_50/build/arty_s7_demo.bit \
    --program \
    --image img1.jpg img2.jpg img3.jpg img4.jpg \
    --out-dir results/
```

Omit `--program` and `--bit` when the board is already programmed:

```bash
python example_proj/common/python/demo.py --image new.jpg --out new_out.jpg
```

## AXI4 Address Map

All addresses are 32-bit byte-addressed. The fcapz bridge issues
standard AXI4 burst transactions on USER4.

| Address | Access | Description |
|---------|--------|-------------|
| `0x0000_0000` - `0x01BF_FFFF` | Write burst | Pixel stream, two pixels per 32-bit word |
| `0x0200_0000` | Write | DEMO_CTRL: bit 0 = start, bit 1 = reset |
| `0x0200_0000` | Read | DEMO_STATUS: bit 0 = done, bit 1 = overflow, bit 2 = axi_error, bit 3 = running, bit 4 = armed |
| `0x0200_0004` | Read | JPEG_SIZE: `[18:0]` = byte count |
| `0x0200_0008` | Read | JPEG_CAPACITY: output buffer capacity in bytes |
| `0x0300_0000` - `0x0300_FFFF` | Read burst | JPEG data, 32-bit little-endian words (64 KB envelope at JPEG_WORDS=16384) |

## File Structure

```text
example_proj/
  common/rtl/
    clk_gen.v
    axi_init.v
    demo_top.v
  common/python/
    demo.py
  arty_s7_50/
    constraints/arty_s7_50.xdc
    scripts/create_project.tcl
fcapz/
  Git submodule: bridge RTL, ELA, and Python host
```
