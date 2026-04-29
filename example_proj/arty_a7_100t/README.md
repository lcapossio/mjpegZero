# Arty A7-100T — mjpegZero Demo

**Device:** XC7A100TCSG324-1 (Artix-7)
**Resolution:** 1280 × 720 (720p)  **Mode:** LITE_MODE=1, LITE_QUALITY=75
**Clock:** 150 MHz (100 MHz oscillator → MMCME2_ADV ×9 ÷ 6)
**Host interface:** [fpgacapZero](../../fcapz/README.md) bridge on USER4 + ELA on USER1/USER2 (same USB cable as programming)

---

## Prerequisites

- Vivado 2025.x (free WebPACK edition is sufficient)
- `hw_server` + `xsdb` on PATH (bundled with Vivado; needed for fcapz host)
- `fcapz/` submodule initialised: `git submodule update --init`
- Python ≥ 3.8 with `pip install Pillow numpy tqdm`
- Digilent Arty A7-100T board connected via USB

---

## Build

```bash
vivado -mode batch -source example_proj/arty_a7_100t/scripts/create_project.tcl
```

Bitstream written to `example_proj/arty_a7_100t/build/arty_a7_demo.bit`.

---

## Program

Open Vivado Hardware Manager, connect to the board, and program:

```tcl
open_hw_manager
connect_hw_server
open_hw_target
set_property PROGRAM.FILE {example_proj/arty_a7_100t/build/arty_a7_demo.bit} [lindex [get_hw_devices] 0]
program_hw_devices [lindex [get_hw_devices] 0]
```

Or from demo.py (programs the board then encodes):

```bash
python example_proj/common/python/demo.py \
    --bit example_proj/arty_a7_100t/build/arty_a7_demo.bit \
    --program --image photo.jpg --out out.jpg
```

---

## LED Indicators

| LED | Pin | Meaning |
|-----|-----|---------|
| LD0 | H5 | Heartbeat (~0.9 Hz) |
| LD1 | J5 | Encoding active |
| LD2 | T9 | Encode done (latched) |
| LD3 | T10 | AXI write activity |

---

## AXI Address Map

| Address | Name | Access | Description |
|---------|------|--------|-------------|
| `0x0000_0000–0x01BF_FFFF` | PIXEL_PORT | W | YUYV pixel data (burst) |
| `0x0200_0000` | DEMO_CTRL | W | `[0]`=start, `[1]`=reset |
| `0x0200_0000` | DEMO_STATUS | R | `[0]`=enc_done, `[1]`=overflow, `[2]`=axi_error, `[3]`=running, `[4]`=armed |
| `0x0200_0004` | JPEG_SIZE | R | `[18:0]`=byte count |
| `0x0200_0008` | JPEG_CAPACITY | R | JPEG buffer capacity in bytes |
| `0x0300_0000–0x0301_FFFF` | JPEG_PORT | R | Compressed JPEG (burst) |

---

## Resource Utilisation

Latest post-route fcapz demo build at 150 MHz:

| Resource | Used  | Available | Utilization |
|----------|-------|-----------|-------------|
| LUT      | 5,587 | 63,400    | 8.81%       |
| FF       | 6,275 | 126,800   | 4.95%       |
| BRAM     | 78.5 tiles | 135 | 58.15%      |
| DSP48E1  | 21    | 240       | 8.75%       |

WNS = +0.108 ns at 150 MHz. This build uses vanilla fcapz `da892ca` with a
minimized 16-bit, 512-sample ELA (`INPUT_PIPE=1`, no timestamps, no decimation)
plus the EJTAG-AXI bridge used by the hardware test.

---

## Hardware Verification (Mandrill 1280x720, Q75)

```bash
python scripts/hw_test_mandrill.py \
    --bit example_proj/arty_a7_100t/build/arty_a7_demo.bit --program
```

| Comparison       | Y-PSNR   | JPEG size  | Compression |
|------------------|----------|------------|-------------|
| HW vs Original   | 38.45 dB | 230 KB     | 11.8:1      |
| Sim vs Original  | 38.45 dB | 230 KB     | 11.8:1      |
| HW vs Sim        | inf dB   | byte-exact | -           |

HW and RTL simulation receive the same YUYV input via `python/yuyv_convert.py`.

---

## Shared RTL

The top-level logic is in [`example_proj/common/rtl/demo_top.v`](../common/rtl/demo_top.v).
Other board ports reuse this RTL where possible, with board-specific pinout and device
details handled in their local constraints and scripts.

See the main [README](../../README.md) for full encoder documentation.
