# Arty A7-100T — Ethernet RTP/JPEG streaming demo

Streams the encoded JPEG to a host over Ethernet as **RTP/JPEG (RFC 2435) over
UDP**, playable live in `ffplay`/VLC/GStreamer. This is an **egress-only**
extension of [`../arty_a7_100t`](../arty_a7_100t): pixel upload + control +
JTAG JPEG read-back still go over the fpgacapZero EJTAG-AXI (JTAG/USB) path; the
new bit is the Ethernet egress through the [emacZero](../../emaczero) MAC.

> RTSP itself is not implemented — it is a TCP control protocol and emacZero is
> UDP-only. RTP/JPEG over UDP + an SDP file gives the same "open it in a player"
> result without RTSP/TCP.

## Architecture

```
 150 MHz: fcapz EJTAG-AXI ── encoder ── JPEG buffer (port A: write + JTAG read)
                                              │  dual-clock TDP BRAM
 100 MHz: eth_mac_sys(MII) ─ net_rx ─ jpeg_rtp_trigger ─ jpeg_rtp_tx ─ arty_tx_arbiter ─ MAC TX
                                                   └ reads JPEG buffer port B
          + arp_responder, mac_csr_init        enc_done/size cross 150→100
```

- Encoder: `LITE_MODE=1`, `LITE_QUALITY=75`, 1280×720, YUV 4:2:2 → RFC 2435 type 0.
- New RTL: [`rtl/eth/jpeg_rtp_tx.v`](../../rtl/eth/jpeg_rtp_tx.v),
  [`jpeg_rtp_trigger.v`](../../rtl/eth/jpeg_rtp_trigger.v),
  [`mac_csr_init.v`](../../rtl/eth/mac_csr_init.v), plus
  [`rtl/clk_gen_eth.v`](rtl/clk_gen_eth.v), [`rtl/jpeg_buffer_dc.v`](rtl/jpeg_buffer_dc.v),
  [`rtl/demo_top_eth.v`](rtl/demo_top_eth.v).

## Network defaults (edit to taste)

| Role | MAC | IP | Notes |
|------|-----|----|-------|
| FPGA | `02:00:00:00:00:01` | `192.168.237.50` | `OUR_MAC`/`OUR_IP` params in `demo_top_eth.v` |
| Host | — | `192.168.237.1` | edit `stream.sdp` / `eth_trigger.py` |

Trigger UDP port `9999`; RTP stream UDP port `5004` (in the SDP). Direct cable or
a switch both work; set the host NIC to `192.168.237.1/24` (admin):
`netsh interface ip set address name="Ethernet 2" static 192.168.237.1 255.255.255.0`.

## Build

```sh
# from repo root (submodules checked out: git submodule update --init --recursive)
vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/create_project.tcl
# fast elaboration check only:
vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/create_project.tcl -tclargs synth
```
Bitstream → `build/arty_a7_eth_demo.bit`. The build defines `XILINX_7SERIES` so
emacZero's DDR/ODDR/IDDR primitives are instantiated.

### Two demo tops

| Top | Build script | What it streams |
|-----|--------------|-----------------|
| `demo_top_eth` | `create_project.tcl` | a **still** JPEG uploaded over JTAG, re-streamed as RTP/JPEG |
| `demo_top_vtpg_eth` | `create_project_vtpg.tcl` | a **moving** pattern (vtpgZero colorbars + bouncing box), encoded + streamed live, autonomously |

```sh
# moving-pattern (live motion) build:
vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/create_project_vtpg.tcl
```
Bitstream -> `build/arty_a7_vtpg_demo.bit`.

## Moving pattern - live motion (`demo_top_vtpg_eth`)

vtpgZero generates colorbars + a bouncing box (YUV 4:2:2, fed straight into the
encoder); an on-chip control FSM loops *generate -> encode -> stream*
autonomously so the host just watches. The box advances one step per frame ->
real motion. No JTAG pixel upload needed.

1. Program `build/arty_a7_vtpg_demo.bit`.
2. Host NIC at `192.168.237.1/24`; allow inbound UDP 5004 (admin):
   `New-NetFirewallRule -DisplayName "RTP-JPEG 5004" -Direction Inbound -Protocol UDP -LocalPort 5004 -Action Allow -Profile Any`
3. Start a player on UDP 5004:
   ```sh
   ffplay -protocol_whitelist file,udp,rtp -fflags nobuffer -i python/stream_vtpg.sdp
   ```
4. Control the stream from the host. The opcode is the **first payload byte** of a
   UDP packet to the trigger port (9999); the same packet (re)latches this host as
   the RTP destination:
   ```sh
   python python/eth_control.py start    # stream continuously (autonomous loop)
   python python/eth_control.py stop      # stop after the current frame finishes
   python python/eth_control.py single    # encode + stream exactly one frame
   ```
   `start` runs the autonomous generate→encode→stream loop; the box advances one
   step per frame (real motion). `eth_trigger.py`'s "GO" still works (= start).
   `python/hw_status_vtpg.py` reads the loop state over JTAG.

### vtpg keyboard control (KV260-style, UDP port 9998)

With the `stream_view.py` window focused, single keystrokes write vtpgZero
config registers over UDP (port 9998), mirroring the KV260 `dp_vtpgzero_box.c`
app — the host owns all state and emits `[reg_offset, value(4 B BE)]` writes:

| Key | Effect |
|-----|--------|
| `0`–`9` (skip `5`) | pattern: 0 bars, 1/2 gradients, 3 checker, 4 solid, 6 grid, 7 ramp, 8 noise, **9 image** |
| `+` / `-` | grow / shrink the moving box (image-in-box rescales) |
| `f` / `s` | box faster / slower |
| `b` / `c` | cycle box / solid colour (8-entry palette) |
| `g` / `G` | grid spacing −/+ (pattern 6) |
| `k` / `K` | checker size −/+ (pattern 3) |
| `i` | toggle the mandrill image inside the box vs solid fill |

**Image mode (mandrill).** `EN_IMAGE=1` renders a 128×128 mandrill scaled to
full screen as pattern 9; `EN_BOX_IMAGE=1` puts a 32×32 mandrill in the moving
box (`i` toggles it). The vtpgZero `.mem` images are RGB, but the core runs
`OUTPUT_MODE=2` (YUV) and reads the image triple directly as `{Y,Cb,Cr}`, so
`scripts/rgb_mem_to_ycbcr.py` converts them to studio BT.601 into
`data/mandrill_*_ycbcr.mem` (added to the build).

## Stream diagnostics (host)

Measured live on hardware (720p, LITE Q75): **~62 fps**, ~22 KB/frame,
**~11 Mbps** compressed — about 11% of the 100 Mbps link. The frame rate is
encoder-bound, not network-bound (encode is ~89% of each frame's period); the
encoder is DCT-limited at the 130.9 MHz functional clock with `HUFF_BANKS=8`.
High-entropy patterns (grid/noise/image) are larger and stream slower.

| Tool | What it does |
|------|--------------|
| `python python/stream_view.py` | live viewer with an on-video HUD: bitrate (JPEG + on-wire), resolution, fps, KB/frame. `--console` for a headless readout. |
| `python python/measure_bitrate.py [seconds]` | one-shot summary: fps, avg frame size, compressed + on-wire bitrate. |
| `python python/profile_frames.py [seconds]` | splits each frame period into encode vs RTP-stream time. |

All three send the start opcode on launch and stop on exit (trigger port 9999),
so they run standalone against the `demo_top_vtpg_eth` build.

## Resources & timing (`demo_top_vtpg_eth`, XC7A100T)

| LUT | FF | BRAM tiles | DSP | WNS |
|----:|---:|-----------:|----:|----:|
| 7,762 | 6,892 | 95 (of 135) | 21 | +0.063 ns |

Functional clock **130.9 MHz** (vs 150 MHz for the still demo). vtpgZero's image
scaler is a ~74 MHz DisplayPort-rate core, so its read path is pipelined
(synchronous BRAM read, +1 px latency) to close above the DP rate — which also
moved the 128×128 image from LUTRAM into BRAM (≈6.6k fewer LUTs, +12 BRAM tiles).
The encoder runs `HUFF_BANKS=8` for DCT-limited ~62 fps at 720p.

## Hardware test flow

1. **Program** `build/arty_a7_eth_demo.bit` over JTAG (reprogram after any power
   cycle so the SPI-flash image doesn't shadow it).
2. **Upload a frame + encode** over JTAG using the same fcapz host tooling as the
   base demo (see [`../arty_a7_100t`](../arty_a7_100t) — `demo.py`). The AXI map
   (pixel port, `DEMO_CTRL` start, `JPEG_SIZE`) is identical. `led2` lights when
   `enc_done`.
3. **Start the player** on the host (listening on UDP 5004):
   ```sh
   ffplay -protocol_whitelist file,udp,rtp -i example_proj/arty_a7_100t_eth/python/stream.sdp
   # or save to a file instead of playing:
   python example_proj/arty_a7_100t_eth/python/rtp_jpeg_recv.py 5004 out.jpg
   ```
4. **Trigger the send**:
   ```sh
   python example_proj/arty_a7_100t_eth/python/eth_trigger.py 192.168.237.50 9999
   ```
   The FPGA captures the host's address from the trigger and streams the JPEG in
   its buffer to `host:5004`. `led3` blinks on Ethernet TX activity. Re-trigger to
   resend; encode a new frame (step 2) to change the image.

## Simulation (no board)

The egress logic is verified end-to-end without hardware:
```sh
python scripts/run_rtp_sim.py        # M1: jpeg_rtp_tx packetizer
python scripts/run_rtp_eth_sim.py    # M2: net_rx → trigger → tx → arbiter
```
Both depacketize the captured stream and check byte-exact scan + in-band quant
tables + RTP/IP structure + pixel-identical decode (see
[`python/rtp_jpeg_verify.py`](../../python/rtp_jpeg_verify.py)).

## Limitations / notes

- `demo_top_eth` (still demo): one JPEG per trigger — re-trigger to resend.
  `demo_top_vtpg_eth` streams **continuous** moving frames under host opcode
  control (`eth_control.py start|stop|single`).
- `restart_interval` stays 0 (RFC 2435 type 0, no restart markers). The Huffman
  DC predictors are reset at every start-of-scan (i.e. each frame), which is
  required for correct **multi-frame** streaming — without it every frame after
  the first decodes with washed-out luma contrast.
- Host address is learned from the trigger/control packet (no static-IP mode yet).
- 100 Mbps MII; the MAC pads short frames and adds preamble/FCS/IFG.
