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
   ffplay -use_wallclock_as_timestamps 1 -protocol_whitelist file,udp,rtp -fflags nobuffer -i python/stream.sdp
   ```
4. Send **one** trigger to capture the destination and start the loop:
   `python python/eth_trigger.py 192.168.237.50 9999`

   The FPGA then streams continuous moving frames (~30-40 fps). `python/hw_status_vtpg.py`
   reads the loop state over JTAG.

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

- One still JPEG per trigger (re-trigger to resend; continuous MJPEG is a future
  extension). `restart_interval` must stay 0 (type 0, no restart markers).
- Host address is learned from the trigger packet (no static-IP mode yet).
- 100 Mbps MII; the MAC pads short frames and adds preamble/FCS/IFG.
