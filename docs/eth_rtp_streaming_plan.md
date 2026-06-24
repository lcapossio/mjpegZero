# Arty A7-100T Ethernet RTP/JPEG Streaming — Design & Plan

**Branch:** `arty-eth-emaczero`
**Goal:** Expand the Arty A7-100T hardware test so the encoded JPEG is streamed to a
host over Ethernet as **RTP/JPEG (RFC 2435) over UDP**, playable live in
`ffplay`/VLC/GStreamer via an SDP file.

## Scope decisions (locked)

- **Egress only.** Keep the existing fpgacapZero (fcapz) EJTAG-AXI JTAG path for
  pixel upload + control/status. Ethernet **adds** JPEG egress; it does not replace
  JTAG ingest. No Ethernet RX command/pixel parsing.
- **Transport: RTP/JPEG over UDP (RFC 2435), implemented in fabric.** True RTSP is
  *not* attempted — RTSP is a TCP control protocol and emacZero is UDP-only (no TCP
  stack). RTP/JPEG over UDP + an SDP file gives the same "open it in a player"
  experience without RTSP/TCP.
- **A7-100T only.** Ethernet cannot go on the shared `demo_top.v` because the
  **Arty S7-50 has no Ethernet PHY**. A new A7-only top (`demo_top_eth.v` or
  `arty_a7_eth_top.v`) is used; the shared `demo_top.v` is left untouched.
- **Destination discovery: host-trigger.** The host sends one UDP "trigger" packet
  to the FPGA; fabric latches the sender's MAC/IP/port (via `net_rx`) and streams the
  RTP/JPEG frame back to it. No ARP-initiated send; static-IP config left as a knob.

## Why this is a good fit

- emacZero is Verilog-2001, **already hardware-validated on the same Arty A7-100T**
  with the onboard TI DP83848 **MII** PHY at 100 Mbps full duplex.
- Encoder output is **YUV 4:2:2** → RFC 2435 **type 0** exactly.
- `restart_interval=0` (default) → no restart markers → RTP/JPEG type 0 (not 64/65).
- 1280×720 → Width/8 = 160, Height/8 = 90, both ≤ 255 (RFC 2435 limit is /8 ≤ 255).

---

## JPEG buffer layout (the key enabler)

The encoder writes a full JFIF stream into `demo_jpeg_buffer` (32-bit words, LE).
With `LITE_MODE=1`, no DRI, no EXIF, the header is a **fixed 623 bytes**:

| Segment        | Bytes | Byte offset (within frame) |
|----------------|------:|----------------------------|
| SOI + APP0     |    20 | 0 – 19                     |
| DQT luma hdr   |     5 | 20 – 24                    |
| **DQT luma data (zigzag)** | 64 | **25 – 88**     |
| DQT chroma hdr |     5 | 89 – 93                    |
| **DQT chroma data (zigzag)** | 64 | **94 – 157**  |
| SOF0           |    19 | 158 – 176                  |
| DHT (4 tables) |   432 | 177 – 608                  |
| SOS            |    14 | 609 – 622                  |
| **Scan data**  |   var | **623 – (size-3)**         |
| EOI (FF D9)    |     2 | (size-2) – (size-1)        |

Source: [jfif_writer.v:349-628](../rtl/jfif_writer.v#L349) (full-mode FSM; LITE ROM
mirrors the same layout — *verify offsets against the LITE ROM during impl*).

Therefore, for RTP/JPEG:
- **Scan payload** = buffer bytes `[623 .. size-3]` sent **verbatim, including JPEG
  byte-stuffing (0xFF→0xFF 00)**, excluding EOI. (This matches ffmpeg's
  `rtpenc_jpeg` behaviour.)
- **Quant tables** for the RTP quant-table header = 64 luma bytes at offset 25 +
  64 chroma bytes at offset 94, both already in zigzag order. `size` =
  `jpeg_byte_cnt` from the existing JPEG capture logic.

---

## RTP/JPEG packet format (our concrete values)

Per UDP datagram (MTU 1500, payload chunk ≈ 1400 B; first packet of a frame is
132 B smaller to carry the quant-table header):

```
Ethernet (14) | IPv4 (20) | UDP (8) | RTP (12) | RTP-JPEG main (8)
   [first packet only: + quant-table hdr (4) + 128 table bytes]
   | scan-data fragment
```

- **RTP header (12 B):** `0x80`; byte1 = `0x1A` (PT=26 JPEG) or `0x9A` (M=1 on the
  last packet of the frame); seq(16, ++ per packet); timestamp(32, 90 kHz, constant
  per frame, ++ per frame); SSRC(32, fixed e.g. 0x0A0B0C0D).
- **RTP-JPEG main header (8 B):** type-specific=0; **fragment offset (3 B)** = byte
  offset of this fragment within the scan data (NOT counting the quant-table bytes);
  type=0; **Q=255** (tables in-band); Width=160; Height=90.
- **Quant-table header (first packet only, 4 B):** MBZ=0; Precision=0; Length=128;
  then 128 table bytes (luma then chroma).
- **UDP/IPv4/Ethernet headers**: built exactly as `udp_blast.v` already does
  (IP checksum precomputed, UDP checksum=0). Reuse that header-emit structure.

Host plays it with an SDP like:
```
v=0
m=video 5004 RTP/AVP 26
c=IN IP4 <host-ip>
a=rtpmap:26 JPEG/90000
```
`ffplay -protocol_whitelist file,udp,rtp -i stream.sdp`

---

## Architecture

```
            150 MHz domain (unchanged, proven)        100 MHz MAC domain         async MII
 fcapz EJTAG-AXI ─┐                                                              25 MHz
 (pixels+ctrl)    ├─ demo write/ctrl FSM ─ encoder ─ JPEG buffer(write port A) │
 JTAG/USB         │                                        │ (dual-clock BRAM)  │
                  └─ ctrl/status regs                       │ read port B @100   │
                                                            ▼                    │
   net_rx ◄─ eth_mac_sys.m_axis (RX) ◄──────────┐    jpeg_rtp_tx ──► tx arbiter ─► eth_mac_sys.s_axis (TX)
   (capture src mac/ip/port, trigger port)       │         ▲              ▲            │ MII ─► DP83848 PHY
   arp_responder ───────────────────────────────┴─────────┘──────────────┘            │
   mac_csr_init (AXI4-Lite: MAC addr, 100M FDX, tx_en/rx_en)
```

### Clocking / CDC plan

- **Keep encoder + fcapz + JPEG-buffer write at 150 MHz** (preserves proven timing).
- **New 100 MHz island**: `eth_mac_sys`, `net_rx`, `arp_responder`, `arty_tx_arbiter`,
  `jpeg_rtp_tx`, `mac_csr_init`. Derive 100 MHz + 25 MHz (PHY ref) from the MMCM
  (`clk_gen`), alongside the existing 150 MHz.
- **JPEG buffer becomes dual-clock**: write port @150 (encoder), read port @100
  (`jpeg_rtp_tx`). Safe because reads only happen *after* `enc_done` (no concurrent
  write to the bytes being read). Cross `enc_done` + `jpeg_byte_cnt` 150→100 with
  2-FF synchronizers + a small "frame_ready" handshake.
- MII clock domains (`mii_tx_clk`/`mii_rx_clk`, 25 MHz) are async to 100 MHz and are
  handled internally by emacZero's `mii_if.v` (store-and-forward FIFOs).
- XDC: `create_clock` on ETH_RX_CLK/ETH_TX_CLK (40 ns) + `set_clock_groups
  -asynchronous` between sys/eth_rx/eth_tx (borrow from emacZero's `arty_a7.xdc`).

---

## New RTL modules to write

1. **`jpeg_rtp_tx.v`** (100 MHz) — the core. On `frame_ready` + captured 4-tuple +
   `enable`: read the JPEG buffer (scan region + quant tables), emit RTP/JPEG/UDP/IP/
   Ethernetframed packets to an AXIS master. FSM modeled on `udp_blast.v`'s
   header-emit + 1-deep skid, with: quant-table header on packet 0, fragment-offset
   tracking, marker bit on last packet, finite length = scan_len.
2. **`jpeg_rtp_trigger.v`** (or reuse `udp_blast_trigger.v`) — latch sender 4-tuple
   when a UDP packet hits the chosen trigger port (e.g. 5004); pulse `start`.
3. **`mac_csr_init.v`** — tiny AXI4-Lite master FSM: write MAC_LO/MAC_HI, then CTRL
   for 100M full-duplex + tx_en + rx_en. (CSR map below; exact CTRL value TBD vs
   `axilite_regs.v`.)
4. **`demo_top_eth.v`** (A7-only top) — instantiate the existing demo datapath
   (encoder, fcapz, JPEG buffer, ctrl/status) + the 100 MHz Ethernet island; make the
   JPEG buffer dual-clock; wire trigger→rtp_tx→arbiter→MAC and MAC→net_rx→trigger/arp.

JPEG buffer change: add a second (100 MHz) read port to `demo_jpeg_buffer.v`
(true-dual-port BRAM: port A write@150, port B read@100). The existing JTAG read of
the JPEG port can remain (debug) or be dropped since egress moves to Ethernet.

---

## emacZero integration reference (from RTL, not docs)

### CSR map (`emaczero/rtl/axilite_regs.v`) — bring-up writes
- `0x0C MAC_LO` = our_mac[31:0]
- `0x10 MAC_HI` = our_mac[47:32]
- `0x04 CTRL` : [0]tx_en [1]rx_en [2]promisc [4:3]speed(00=1G,01=100M,10=10M)
  [5]full_duplex [6]jumbo [7]tx_csum_off [8]passthrough.
  **Verify exact 100M-FDX value against the RTL** (tx_en|rx_en|speed=01|fdx).
- No separate GO bit; MAC is live once tx_en/rx_en set.

### Arty MII pins (`emaczero/fpga/arty_a7/constraints/arty_a7.xdc`, Bank 15 LVCMOS33)
TXD H14/J14/J13/H17, TX_EN H15, TX_CLK H16, RXD D18/E17/E18/G17, RX_DV G16,
RXERR C17, RX_CLK F15, CRS G14, COL D17, MDC F16, MDIO K13, REF_CLK G18, RSTN C16.
PHY reset held low ~200 ms after MMCM lock. MDIO not required (PHY autonegs).

### Filelist to add to the Vivado build
Core MAC (MII): `crc32, async_fifo, sync_fifo, mii_if, eth_mac_rx, eth_mac_tx,
eth_mac, mdio_master, eth_stats, eth_pause, axilite_regs, ddr_output, ddr_input,
rgmii_if, gmii_cdc, net/tx_csum_off, eth_mac_sys` (all under `emaczero/rtl/`).
L3: `net/net_rx`. Arty helpers: `arp_responder`, `arty_tx_arbiter` (from
`emaczero/fpga/arty_a7/rtl/`). Optionally `udp_blast_trigger`.

---

## Host side (`example_proj/arty_a7_100t/python/` or `scripts/`)

- `stream.sdp` (template above) + a one-liner `ffplay`/VLC command in the README.
- `eth_trigger.py` — send the UDP trigger packet to the FPGA's IP:port.
- `rtp_jpeg_recv.py` — optional pure-Python RFC 2435 depacketizer: reassemble the
  RTP/JPEG stream, rebuild a full JFIF, save `out.jpg`, and PSNR-compare vs the sim
  reference (byte-exact vs the JTAG read-back path is the strongest check).

---

## Staged implementation plan

1. **M1 — `jpeg_rtp_tx` + standalone sim. ✅ DONE.** Packetizer
   [rtl/eth/jpeg_rtp_tx.v](../rtl/eth/jpeg_rtp_tx.v), TB
   [sim/tb_jpeg_rtp_tx.sv](../sim/tb_jpeg_rtp_tx.sv), depacketizer/verifier
   [python/rtp_jpeg_verify.py](../python/rtp_jpeg_verify.py), runner
   [scripts/run_rtp_sim.py](../scripts/run_rtp_sim.py). `python scripts/run_rtp_sim.py`
   passes all gates on both a 3-packet (320x176) and single-packet (64x8) JPEG under
   AXIS backpressure: G1 scan byte-exact, G2 in-band quant tables byte-exact, G3
   RTP/JPEG structural sanity, G4 reconstructed decodes pixel-identical. The `prep`
   validator also rejects non-type-0 JPEGs (DRI/EXIF). *No board needed.*
2. **M2 — trigger + arbiter integration sim. ✅ DONE.** New trigger
   [rtl/eth/jpeg_rtp_trigger.v](../rtl/eth/jpeg_rtp_trigger.v); integration TB
   [sim/tb_jpeg_rtp_eth.sv](../sim/tb_jpeg_rtp_eth.sv); runner
   [scripts/run_rtp_eth_sim.py](../scripts/run_rtp_eth_sim.py). Chain
   `net_rx -> jpeg_rtp_trigger -> jpeg_rtp_tx -> arty_tx_arbiter` (jpeg on the
   arbiter's `udp` input). A crafted UDP trigger frame is streamed into net_rx; the
   captured sender address drives the emitted stream. `python scripts/run_rtp_eth_sim.py`
   passes G1-G4 plus **G5** (emitted dst MAC/IP/port == trigger sender) under
   backpressure. The full MAC (`eth_mac_sys`) + MII loopback BFM is deferred — the
   MAC is already emacZero-HW-validated; it gets elaborated/closed in M4.
3. **M3 — `demo_top_eth.v` + dual-clock buffer + `mac_csr_init`. ✅ DONE.**
   [example_proj/arty_a7_100t_eth/rtl/demo_top_eth.v](../example_proj/arty_a7_100t_eth/rtl/demo_top_eth.v)
   integrates the 150 MHz datapath + 100 MHz Ethernet island.
   [mac_csr_init.v](../rtl/eth/mac_csr_init.v) and
   [jpeg_buffer_dc.v](../example_proj/arty_a7_100t_eth/rtl/jpeg_buffer_dc.v) unit-tested
   ([tb_mac_csr_init.sv](../sim/tb_mac_csr_init.sv), [tb_jpeg_buffer_dc.sv](../sim/tb_jpeg_buffer_dc.sv)).
   [clk_gen_eth.v](../example_proj/arty_a7_100t_eth/rtl/clk_gen_eth.v) makes 150/100/25.
4. **M4 — XDC + Vivado build. ✅ DONE — timing closed, bitstream written.**
   [constraints/arty_a7_100t_eth.xdc](../example_proj/arty_a7_100t_eth/constraints/arty_a7_100t_eth.xdc),
   [scripts/create_project.tcl](../example_proj/arty_a7_100t_eth/scripts/create_project.tcl)
   (`-verilog_define XILINX_7SERIES`). On XC7A100T: **WNS = +0.255 ns** (0 failing
   setup/hold endpoints), `build/arty_a7_eth_demo.bit`. Impl: 5,696 LUT / 5,742 FF /
   80 RAMB36 + 4 RAMB18 / 21 DSP / 21 IOB. Three synth/timing bugs found+fixed:
   multi-driver on `jpeg_rtp_tx` IP length/checksum, `ddr_output` black box
   (XILINX_7SERIES), and the IP checksum on the critical path — pipelined into 2
   register stages (−1.27 → −0.46 → +0.255 ns). Verifier G3 now validates the IP
   header checksum so the field is covered in sim.
5. **M5 — Hardware bring-up. ✅ DONE — works on the Arty A7-100T.** Program; PHY
   links 100M full-duplex; ARP resolves `192.168.237.50`→`02:00:00:00:00:01`;
   JTAG-encode a frame (`hw_encode.py`); trigger (`eth_trigger.py`); the host
   receives the RTP/JPEG stream (`rtp_jpeg_recv.py`) and decodes it **pixel-identical
   (max abs diff = 0) to the JTAG read-back**. NIC RX +248 KB per trigger.
   **Root-cause fix found on HW:** emacZero's `eth_mac_tx` is cut-through and corrupts
   a frame on any mid-frame `tvalid` bubble; `jpeg_rtp_tx` bubbles at every 32-bit
   BRAM word boundary, so every RTP frame was corrupted (NIC dropped them, CRC). Fixed
   with a per-frame store-and-forward buffer
   [rtl/eth/axis_frame_buffer.v](../rtl/eth/axis_frame_buffer.v) that streams each
   frame gap-free. JTAG-readable debug status (dbg flags, captured dst, MAC frame
   count) added to `demo_top_eth` + `hw_status.py` made the diagnosis possible.
   Host IP subnet is `192.168.237.0/24` (PC `.1`, FPGA `.50`).
6. **M6 — Docs + README. ✅ example README done** at
   [example_proj/arty_a7_100t_eth/README.md](../example_proj/arty_a7_100t_eth/README.md).

### Extensions (not in first pass)
- Continuous/looping resend (re-stream current buffer at an interval) for "video".
- Static-IP destination via CSR instead of host-trigger.
- Per-frame re-encode loop for true MJPEG motion.

## Open risks / to-verify
- LITE-mode header offsets (623 / 25 / 94) vs the LITE ROM — confirm in impl.
- Exact CTRL value for 100M FDX MII vs `axilite_regs.v`.
- Whether to keep the JTAG JPEG read port (BRAM port pressure) or drop it.
- ETH_REF_CLK feedback requirement on this specific Arty revision.
- Timing closure of the 150/100 dual-clock design with the added Ethernet logic.
