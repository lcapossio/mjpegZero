# Arty A7-100T Ethernet RTP/JPEG demo

Streams mjpegZero output to a host over Ethernet as RTP/JPEG over UDP
(RFC 2435 payload type 26). The demo uses the emacZero MAC and is egress-only:
the FPGA learns the host destination from a UDP control packet, then sends RTP
packets back to the host's UDP port 5004.

There are two tops:

| Top | Build script | Use case |
|-----|--------------|----------|
| `demo_top_vtpg_eth` | `scripts/create_project_vtpg.tcl` | Live 720p moving test-pattern video generated in fabric. This is the main streaming demo. |
| `demo_top_eth` | `scripts/create_project.tcl` | Still JPEG uploaded/encoded over JTAG, then sent once per Ethernet trigger. |

RTSP is not implemented. RTSP is a TCP control protocol, while emacZero is
UDP-only; RTP/JPEG plus an SDP file is enough for `ffplay`, VLC, or GStreamer to
open the stream.

## Network defaults

| Role | Value |
|------|-------|
| FPGA MAC | `02:00:00:00:00:01` |
| FPGA IP | `192.168.237.50` |
| Host IP | `192.168.237.1/24` |
| Trigger/control UDP port | `9999` |
| VTPG register-write UDP port | `9998` |
| RTP/JPEG UDP port | `5004` |

Set the host NIC to `192.168.237.1/24`. On Windows, for example:

```powershell
netsh interface ip set address name="Ethernet 2" static 192.168.237.1 255.255.255.0
New-NetFirewallRule -DisplayName "RTP-JPEG 5004" -Direction Inbound -Protocol UDP -LocalPort 5004 -Action Allow -Profile Any
```

## Live VTPG demo

The live demo is:

```text
vtpgz_core
  -> mjpegzero_enc_top
  -> jpeg_capture + demo_jpeg_buffer
  -> jpeg_rtp_tx
  -> axis_frame_buffer
  -> arty_tx_arbiter
  -> eth_mac_sys (MII)
```

Control is split out of the top:

```text
UDP trigger/control packets -> vtpg_udp_control
frame sequencing/rate control -> vtpg_stream_control
```

`vtpg_stream_control` runs the loop:

```text
write runtime JPEG quality -> kick one VTPG frame -> wait for JPEG capture
-> drop or stream the frame -> wait for RTP done -> repeat
```

Everything in the moving-pattern datapath runs in one functional clock domain
(about 130.9 MHz from `clk_gen_eth`). The MII clock crossings are handled inside
`eth_mac_sys`.

### Build and program

From the repository root:

```sh
vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/create_project_vtpg.tcl
```

The bitstream is written to:

```text
example_proj/arty_a7_100t_eth/build/arty_a7_vtpg_demo.bit
```

Program it with the helper script:

```sh
vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/program_fpga.tcl
```

The helper defaults to the VTPG live-stream bitstream. You can also spell it out:

```sh
vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/program_fpga.tcl -tclargs vtpg
```

### View and control

The easiest path is the Python viewer:

```sh
cd example_proj/arty_a7_100t_eth
python python/stream_view.py
```

It sends the `start` opcode on launch, receives RTP/JPEG on UDP 5004, displays
the video, and overlays JPEG bitrate, total on-wire bitrate, fps, frame size,
and resolution. For a headless check:

```sh
python python/stream_view.py --console --duration 5
```

Override network settings when needed:

```sh
python python/stream_view.py --fpga-ip 192.168.237.50 --rtp-port 5004 --trigger-port 9999
```

You can also use `ffplay` directly. Start the player first:

```sh
ffplay -protocol_whitelist file,udp,rtp -fflags nobuffer -i python/stream_vtpg.sdp
```

Then control the stream:

```sh
python python/eth_control.py start
python python/eth_control.py stop
python python/eth_control.py single
```

The first byte of each UDP payload to port 9999 is the opcode:

| Opcode | Meaning |
|--------|---------|
| `G` or any other non-stop/non-single byte | Start continuous streaming |
| `S`, `s`, or `0x00` | Stop after the current frame finishes |
| `1` or `0x02` | Encode and stream exactly one frame |

The same trigger packet latches the host MAC/IP as the RTP destination, so the
host does not need to keep sending triggers once continuous streaming starts.
The legacy `eth_trigger.py` sends `GO`, which still means start.

### Keyboard pattern control

With `stream_view.py` focused, keys write VTPG configuration registers over UDP
port 9998. The packet format is:

```text
byte 0: register offset
bytes 1..4: 32-bit big-endian value
```

The host owns this state, mirroring the KV260 `dp_vtpgzero_box.c` app.

| Key | Effect |
|-----|--------|
| `0`-`9`, except `5` | Pattern: 0 bars, 1/2 gradients, 3 checker, 4 solid, 6 grid, 7 ramp, 8 noise, 9 image |
| `+` / `-` | Grow / shrink the moving box |
| `f` / `s` | Box faster / slower |
| `b` / `c` | Cycle box / solid color |
| `g` / `G` | Grid spacing down / up |
| `k` / `K` | Checker size down / up |
| `i` | Toggle banana image-in-box vs solid box fill |

Pattern 9 renders the 128x128 mandrill image scaled to full screen. The image
memory in `data/mandrill_128x128_ycbcr.mem` and the banana box texture in
`data/banana_32x32_ycbcr.mem` are studio-range BT.601 YCbCr because
`vtpgz_core` runs in YUV output mode for this demo.

## Fabric rate control

Rate control is implemented in fabric in
[`rtl/vtpg_stream_control.v`](rtl/vtpg_stream_control.v). The host does not know
future frames and does not choose quality per frame.

The hardware observes the just-captured JPEG size and decides the next frame's
runtime quality:

| Condition after capture | Action |
|-------------------------|--------|
| JPEG buffer overflowed | Drop that frame, decrement quality by 20, count one dropped frame |
| JPEG size above 87.5% of buffer capacity | Stream the frame, decrement quality by 5 |
| JPEG size below 50% of buffer capacity for 4 good frames | Increment quality by 1 |
| Otherwise | Keep current quality |

Defaults:

| Parameter | Value |
|-----------|-------|
| Initial quality | Q75 |
| Minimum quality | Q5 |
| Maximum quality | Q95 |
| JPEG buffer capacity | `JPEG_WORDS * 4`, normally 256 KiB |
| Quality-write settle time | 600 fabric-clock cycles before kicking the next frame |

On overflow, the bad frame is not transmitted because the captured JPEG is
partial. The next frame is captured at the lower quality. Read live status over
JTAG with:

```sh
python python/hw_status_vtpg.py
```

Status word 0 includes current `rc_quality` and the low byte of
`rc_dropped_frames`.

## Diagnostics

| Tool | What it does |
|------|--------------|
| `python python/stream_view.py` | GUI viewer with bitrate/fps/frame-size HUD and keyboard VTPG control |
| `python python/stream_view.py --console --duration 5` | Headless live bitrate/fps readout |
| `python python/measure_bitrate.py [seconds] [fpga_ip] [rtp_port] [trigger_port]` | One-shot bitrate summary |
| `python python/profile_frames.py [seconds]` | Splits each frame period into encode time and RTP burst time |
| `python python/hw_status_vtpg.py` | JTAG status: loop state, quality, dropped frames, Ethernet flags |
| `python python/test_opcodes.py` | Hardware smoke test for start/stop/single behavior |
| `python python/rtp_jpeg_recv.py 5004 out.jpg` | Receive one RTP/JPEG frame and reconstruct a JFIF file |

Measured on hardware with the live VTPG demo at 720p: colorbar-style content is
around 60 fps and roughly tens of KiB per frame. High-entropy patterns such as
noise or image mode produce larger frames; the fabric rate controller backs
quality down if the 256 KiB JPEG buffer would overflow.

## Still-image Ethernet demo

The still demo keeps the original JTAG upload/encode flow and only uses Ethernet
for RTP/JPEG egress.

Build it with:

```sh
vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/create_project.tcl
```

The bitstream is written to:

```text
example_proj/arty_a7_100t_eth/build/arty_a7_eth_demo.bit
```

Program it with:

```sh
vivado -mode batch -source example_proj/arty_a7_100t_eth/scripts/program_fpga.tcl -tclargs still
```

Use the base Arty A7 JTAG demo tooling to upload pixels and encode one JPEG.
Then start a receiver:

```sh
ffplay -protocol_whitelist file,udp,rtp -i example_proj/arty_a7_100t_eth/python/stream.sdp
```

Trigger one send:

```sh
python example_proj/arty_a7_100t_eth/python/eth_trigger.py 192.168.237.50 9999
```

`demo_top_eth` sends one JPEG per trigger. Re-trigger to resend the same buffer;
upload/encode a new image over JTAG to change the frame.

## Simulation and CI

The CI-covered Ethernet/JPEG path test is:

```sh
python example_proj/arty_a7_100t_eth/sim/cocotb/run_jpeg_path.py
```

It verifies the `jpeg_capture -> demo_jpeg_buffer -> jpeg_rtp_tx` contract,
including normal frames and overflow/partial-capture behavior.

Older standalone RTP simulations are also useful when working on the packetizer:

```sh
python scripts/run_rtp_sim.py
python scripts/run_rtp_eth_sim.py
```

## Troubleshooting

| Symptom | Checks |
|---------|--------|
| No packets in the viewer | Confirm the host NIC is `192.168.237.1/24`, firewall allows UDP 5004, the board is programmed with `arty_a7_vtpg_demo.bit`, and `python/hw_status_vtpg.py` shows `dbg_udp=1` after a start packet. |
| `dbg_udp=0` | The FPGA is not seeing UDP packets. Check cable/switch, host route, FPGA IP, and that the packet is sent to port 9999. |
| `dbg_udp=1` but no RTP | Check `dbg_trg`, `loop_en`, `cap_done`, and `rtp_busy` in `hw_status_vtpg.py`. A missing trigger destination usually means the start packet was not sent from the host that is listening. |
| Viewer starts then freezes | Try `python/stream_view.py --console --duration 5` to separate GUI decode issues from network issues. Also check whether quality dropped and frames are being discarded. |
| Noise pattern is choppy or quality falls | Expected if the JPEG size approaches the 256 KiB buffer. The rate controller will drop overflow frames and lower quality until frames fit. |
| `ffplay` opens but shows nothing | Start `ffplay` before sending `eth_control.py start`, and use `python/stream_vtpg.sdp` for the VTPG demo. |
| Program script loads the wrong image | Use `-tclargs vtpg` or `-tclargs still` explicitly. No argument defaults to `vtpg`. |

## Resources and timing

For `demo_top_vtpg_eth` on XC7A100T, a representative Vivado 2025.2 post-route
build at 130.9 MHz used approximately:

| LUT | FF | BRAM tiles | DSP | WNS |
|----:|---:|-----------:|----:|----:|
| 7,347 | 6,863 | 96 / 135 | 21 | +0.003 ns |

The exact WNS varies by placement. The encoder runs in full/runtime-quality mode
with `HUFF_BANKS=8`; the fabric clock is below the still demo's 150 MHz target to
close the combined VTPG + encoder + Ethernet design on the Arty A7-100T.

## Limitations

- RTP/JPEG type 0 only; `restart_interval` remains 0.
- Host address is learned from the trigger packet; there is no static destination
  register yet.
- The live demo is store-and-forward per frame: encode/capture the whole JPEG,
  then burst it over Ethernet.
- 100 Mbps MII is the link limit. emacZero pads short frames and adds
  preamble/FCS/IFG below the AXI-stream packet layer.
- `stream_view.py` reconstructs the JFIF header on the host because the RTP/JPEG
  payload carries quant tables and scan payload rather than the full JFIF file.
