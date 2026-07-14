# SUMMARY.md — IMX900C + CrossLinkU-NX → UVC over USB 3.2 Pipeline Inventory

The five color-path blocks (debayer, CCM, CSC, chroma resampler, JPEG) are
the **core color-processing path**, not the entire IMX900C-to-UVC pipeline:
several stages are required before debayering, one important stage after the
CCM (gamma), and the JPEG/UVC transport machinery at the end. This document
inventories every stage and the rationale for each; [CAMERA-PLAN.md](CAMERA-PLAN.md)
sequences the work and [ENCODER-PLAN.md](ENCODER-PLAN.md) governs the encoder rewrite.

## Pipeline manifest — execution order → module file

Two-digit stage numbers give the pixel's path through the design in `ls`-free,
rename-free form (numbers live here and in each file's `Position` header
section, never in filenames — see ENCODER-PLAN.md §1's drop-in contract).
File names for stages not yet written follow [CAMERA-PLAN.md](CAMERA-PLAN.md) §3.

| Stage | Function | File | Status |
|---|---|---|---|
| 01 | D-PHY byte alignment | `camera/rtl/csi/dphy_byte_align.v` | planned (Lattice IP baseline until C3) |
| 02 | CSI-2 packet decode | `camera/rtl/csi/csi2_rx.v` | planned (Lattice IP baseline until C3) |
| 03 | RAW10/12 unpack | `camera/rtl/csi/raw_unpack.v` | planned C2 (ours) |
| 04 | Frame/line sync, active region | `camera/rtl/csi/frame_sync.v` | planned C2 (ours) |
| 05 | Black-level correction | `camera/rtl/isp/blc.v` | planned C3 |
| 06 | White-balance gains | `camera/rtl/isp/wb_gains.v` | planned C3 |
| 07 | Defective-pixel correction | `camera/rtl/isp/dpc.v` | **reserved** insertion point (C7) |
| 08 | Lens-shading correction | `camera/rtl/isp/lsc.v` | **reserved** insertion point (C7) |
| 09 | Debayer — MHC 5×5 ([DEBAYER-PLAN.md](DEBAYER-PLAN.md)) | `camera/rtl/isp/debayer.v` | planned C4 |
| 10 | Color-correction matrix | `camera/rtl/isp/ccm.v` | planned C4 |
| 11 | Gamma / tone LUT | `camera/rtl/isp/gamma_lut.v` | planned C4 |
| 12 | RGB→YCbCr + filtered 4:2:2 | `camera/rtl/isp/csc_422.v` | planned C4 |
| 13 | Center crop | `camera/rtl/isp/crop.v` | planned C4 |
| 14 | MCU/block formatter | `input_buffer.v` | `rtl/` until encoder Phase 3 |
| 15 | 8×8 2-D DCT (dct_1d ×2 inside) | `dct_2d.v`, `dct_1d.v` | **streamline ✓** |
| 16 | Quantizer | `quantizer.v` | **streamline ✓** |
| 17 | Zigzag reorder | `zigzag_reorder.v` | **streamline ✓** (fuses into 15 at Phase 4) |
| 18 | Huffman encoder | `huffman_encoder.v` | **streamline ✓** |
| 19 | Bitstream packer | `bitstream_packer.v` | **streamline ✓** |
| 20 | JFIF/JPEG headers | `jfif_writer.v` | `rtl/` until encoder Phase 4 |
| 21 | UVC payload packetizer | `camera/rtl/uvc/uvc_packetizer.v` | planned C5 |
| 22 | USB endpoint FIFO / CDC | `camera/rtl/uvc/usb_ep_fifo.v` | planned C5 |
| 23 | USB 3.2 Gen 1 hard interface | (CrossLinkU-NX silicon) | configure only |

Not in the numbered pixel path (no linear position by design):

| Function | File(s) | Notes |
|---|---|---|
| Sensor bring-up sequencer + I2C | `camera/rtl/ctrl/{seq_rom,i2c_master,csr_fabric}.v` | control plane, C2 |
| AE/AWB statistics | `camera/rtl/isp/stats_ae_awb.v` | taps the RAW stream, feeds firmware |
| Quantizer table read | `quantizer.v` `qt_rd` port | side tap serving stage 20's DQT |
| RV32 SoC + firmware | `camera/rtl/cpu/`, `camera/fw/` | control plane, C6 |
| Infrastructure | `bram_sdp.v`, `axi4_lite_regs.v`, `mjpegzero_enc_top.v`, `synth_timing_wrapper.v` | instantiated throughout |

Parallelism note: at CAMERA-PLAN.md C5b, stages 14–19 are instantiated
**twice** (restart-interval dual core) with a byte-aligned segment merger
ahead of stage 20 — a fork the linear numbering intentionally does not
encode.

## Complete pipeline

```text
IMX900C
   │
   ├─ Sensor clock, reset, power sequencing
   ├─ Sensor register configuration
   │
   ▼
MIPI D-PHY receiver
   ▼
CSI-2 packet receiver
   ▼
RAW10/RAW12 byte-to-pixel unpacker
   ▼
Active-image extraction / synchronization / buffering
   ▼
RAW-domain corrections
   │
   ├─ Black-level correction
   ├─ Defective-pixel correction
   ├─ White-balance gains
   ├─ Lens-shading correction       [recommended]
   └─ Raw noise reduction           [optional]
   │
   ▼
Debayer
   ▼
Color-correction matrix
   ▼
Gamma / tone curve / bit-depth conversion
   ▼
RGB → YCbCr color-space conversion
   ▼
Chroma resampling: 4:4:4 → 4:2:2 or 4:2:0
   ▼
Crop / scale / format conversion, if needed
   ▼
JPEG encoder
   ▼
UVC payload packetizer
   ▼
USB endpoint/FIFO/control logic
   ▼
CrossLinkU-NX USB 3.2 Gen 1 hard interface
   ▼
USB host
```

## 1. Sensor initialization and control

Before receiving pixels, something must configure the IMX900C:

- power rails and power-up timing;
- reset sequencing;
- 24 MHz input clock for CSI-2 operation;
- MIPI lane count and lane speed;
- RAW output format and bit depth;
- image dimensions and cropping;
- frame rate;
- exposure time;
- analog and digital gain;
- test-pattern mode;
- horizontal or vertical inversion, where needed.

The IMX900-AQR is the color version, with approximately 3.2 megapixels and a recommended recording region of approximately 2048 × 1536. Sony specifies multiple power rails and a 24 MHz input-clock mode for CSI-2.

This control could be implemented with:

- a small FPGA state machine;
- a soft RISC-V processor;
- an external microcontroller;
- or host-driven control through the FPGA.

For initial bring-up, use a **simple ROM-driven register sequencer**, not a CPU.

## 2. MIPI D-PHY and CSI-2 reception

“Reading MIPI” actually consists of several separate layers:

```text
Electrical MIPI D-PHY receiver
        ↓
Lane alignment and byte reconstruction
        ↓
CSI-2 packet decoding
        ↓
Virtual-channel and data-type selection
        ↓
RAW10/RAW12 pixel unpacking
        ↓
Line-valid, frame-valid and pixel stream
```

Do **not write the electrical D-PHY or CSI-2 receiver from scratch** unless absolutely necessary.

Lattice’s current CrossLinkU-NX UVC reference design already includes:

- a soft MIPI D-PHY receiver;
- CSI-2 reception;
- conversion to an 8-bit byte stream;
- a byte-to-pixel converter;
- and Lattice’s debayer IP.

It targets the same LIFCL-33U-EVN evaluation board, although its supplied sensor configuration primarily targets Raspberry Pi Camera Module 2 rather than the IMX900C.

The actual task is therefore:

> Adapt the existing Lattice MIPI receiver and byte-to-pixel path for the IMX900’s lane rate, lane count, CSI-2 data type, Bayer pattern, resolution and timing.

That is much less work than implementing MIPI reception from zero.

### Important distinction

The **USB side is hardened**, but the Lattice UVC reference design uses a **soft MIPI D-PHY** on this evaluation-board configuration. CrossLinkU-NX provides integrated hardened USB 2.0 and USB 3.2 Gen 1 functionality, with up to a 5 Gbps signaling rate.

## 3. RAW unpacking and stream normalization

The MIPI output is not automatically a convenient “one pixel per clock” stream.

Logic is needed for:

- unpacking packed RAW10 or RAW12 groups;
- converting the pixels to a convenient internal width;
- identifying line and frame boundaries;
- removing packet headers and blanking;
- handling CSI-2 short packets;
- cropping optical-black or non-image pixels;
- crossing from the MIPI byte clock into the ISP pixel clock;
- buffering temporary rate differences.

The Lattice reference design’s byte-to-pixel converter supplies part of this functionality.

Use a **16-bit internal pixel representation**, with fixed-point integer arithmetic—not floating point:

```text
RAW10 → 16-bit unsigned internal samples
RAW12 → 16-bit unsigned internal samples
```

The extra bits provide room for gains, matrix operations and rounding.

## 4. Black-level correction

This stage is **mandatory**.

A supposedly black pixel from the sensor normally does not produce a numeric value of exactly zero. Each Bayer channel may have a slightly different offset:

```text
R'  = max(R  - black_R,  0)
Gr' = max(Gr - black_Gr, 0)
Gb' = max(Gb - black_Gb, 0)
B'  = max(B  - black_B,  0)
```

Without proper black-level subtraction:

- blacks can appear gray;
- color casts appear in dark regions;
- the CCM produces incorrect colors;
- shadows compress poorly;
- gain and gamma processing amplify the error.

This operation should happen **before debayering**.

## 5. Defective-pixel correction

This is not required to make the pipeline function, but it is strongly recommended for a production camera.

Hot or dead pixels are best corrected while the data is still Bayer RAW, generally using neighboring pixels of the same color. A simple implementation can replace an outlier with the median or bounded estimate of nearby same-color pixels.

Omit this during initial bring-up, but leave a clean insertion point for it.

## 6. White balance

White balance is also missing as an explicit block.

Separate gains are applied to the Bayer color channels before debayering:

```text
R  × gain_R
Gr × gain_Gr
Gb × gain_Gb
B  × gain_B
```

This is computationally inexpensive and generally preferable to trying to correct a large sensor-color imbalance entirely in the CCM.

Initially, use **fixed calibrated gains**. Later, add automatic white balance using frame statistics generated in the FPGA and a slow control loop running on a host or soft processor.

Thus the color path is more accurately:

```text
Black-level correction
    ↓
White-balance gains
    ↓
Debayer
    ↓
CCM
```

## 7. Lens-shading correction

Because illumination and lens response vary across the sensor, the image may become darker or color-shifted near the edges.

Lens-shading correction applies a position-dependent gain:

```text
corrected_pixel = raw_pixel × gain(x, y, Bayer_channel)
```

The first image can omit this. A polished camera, especially with a small M12 lens and a 2.25 µm-pixel sensor, should expect to need it.

A practical FPGA implementation does not need a full-resolution correction map. Use a coarse two-dimensional grid and bilinear interpolation between gain values.

## 8. Debayer

Required: the IMX900C/AQR is the color version.

The debayer must know:

- exact Bayer order: RGGB, GRBG, GBRG or BGGR;
- first active-pixel position;
- whether the sensor image has been horizontally or vertically flipped;
- valid image boundaries.

A Bayer-order error produces dramatically incorrect colors and is common during sensor bring-up.

Lattice’s UVC reference design already includes a debayer IP block; use it initially as the known-good path, then replace it with ours (MHC 5×5 per DEBAYER-PLAN.md).

## 9. Color-correction matrix

Yes. The CCM converts the camera sensor’s RGB response into the desired output color space, normally something approximately aligned with sRGB/Rec.709 primaries.

Conceptually:

```text
Rout = M00·R + M01·G + M02·B
Gout = M10·R + M11·G + M12·B
Bout = M20·R + M21·G + M22·B
```

Include:

- signed coefficients;
- sufficient accumulator width;
- rounding;
- saturation/clamping;
- programmable coefficients.

Do not hard-code the final CCM permanently. The correct values depend on:

- the sensor;
- lens;
- IR-cut filter;
- illuminant;
- white-balance convention;
- desired color standard.

## 10. Gamma or tone mapping

This is the biggest processing block easily forgotten in a naive pipeline sketch.

After debayering and CCM, pixel values are generally still approximately **linear-light RGB**. Ordinary UVC video and JPEG images normally expect nonlinear, display-oriented values.

The path needs something resembling:

```text
Linear RGB
    ↓
Gamma / tone curve
    ↓
8-bit nonlinear R'G'B'
```

Without this:

- midtones will be much too dark;
- shadow detail will look poor;
- the 10/12-bit to 8-bit conversion will be crude;
- JPEG compression behavior will be less favorable.

For FPGA implementation, use either:

- a small lookup table;
- piecewise-linear segments;
- or a programmable one-dimensional LUT.

A 1D LUT per channel is inexpensive. Initially all three channels can use the same curve.

The recommended sequence is:

```text
Debayer
    ↓
White-balanced linear RGB
    ↓
CCM
    ↓
Clamp
    ↓
Gamma/tone LUT
    ↓
8-bit RGB
```

There are alternate professional ISP orderings, but this one is appropriate here.

## 11. Color-space conversion

Yes. Convert nonlinear RGB into JPEG-compatible YCbCr:

```text
R'G'B' → Y'CbCr
```

Use programmable fixed-point coefficients and explicitly choose the convention:

- full range or limited range;
- BT.601-like or BT.709-like coefficients;
- exact chroma center;
- output bit depth.

For UVC MJPEG, use an internally consistent **full-range JPEG YCbCr** path rather than accidentally mixing limited-range video conventions into the JPEG encoder.

## 12. Chroma resampling

Yes. After RGB-to-YCbCr conversion, resample:

```text
4:4:4 → 4:2:2
```

or:

```text
4:4:4 → 4:2:0
```

For the first FPGA implementation, use **4:2:2**:

- less vertical buffering;
- simpler streaming architecture;
- better preservation of vertical chroma detail;
- natural fit for line-oriented processing;
- still a substantial reduction in chroma data.

Once everything works, evaluate 4:2:0 if bandwidth savings justify the additional vertical filtering and buffering.

Do not simply discard every other chroma sample. Apply at least a basic low-pass filter before decimation.

## 13. Cropping or scaling

This depends on what resolution is exposed over UVC.

The IMX900’s active image is approximately 2048 × 1536, while the primary output mode is 1920 × 1080.

One of these is therefore needed:

### Center crop

```text
2048 × 1536 → 1920 × 1080
```

This is simple and requires almost no additional processing, but loses the top and bottom of the 4:3 image.

### Scaling

```text
2048 × 1536 → 1440 × 1080
```

with pillarboxing to 1920 × 1080, or another chosen mapping.

This preserves the whole 4:3 field of view but requires a scaler and line buffers.

### Sensor ROI

Configure the sensor to output a smaller region directly, where its supported operating modes permit it.

For first bring-up, use either the sensor’s native output or a simple center crop. Do not make scaling part of the critical path until the camera and JPEG encoder work.

## 14. JPEG input formatting

Between chroma resampling and the DCT sits the **MCU/block formatter**.

For 4:2:2 JPEG, it must assemble the stream into groups such as:

```text
Y block 0: 8 × 8
Y block 1: 8 × 8
Cb block:  8 × 8
Cr block:  8 × 8
```

This means line buffers and address/control logic are needed even though the mathematical JPEG chain starts at the DCT.

The JPEG pipeline then becomes:

```text
MCU/block formatter
    ↓
Level handling
    ↓
8×8 DCT
    ↓
Quantization
    ↓
Zigzag ordering
    ↓
DC differential coding
    ↓
AC run-length/category generation
    ↓
Huffman lookup
    ↓
Magnitude-bit append
    ↓
Bit packing
    ↓
0xFF byte stuffing
    ↓
JPEG headers and markers
```

## 15. UVC and USB packetization

The USB hard interface does not, by itself, turn a JPEG byte stream into a UVC camera.

Still required:

- USB device descriptors;
- UVC VideoControl descriptors;
- UVC VideoStreaming descriptors;
- format and frame descriptors;
- probe and commit request handling;
- UVC payload headers;
- frame-start/end indication;
- endpoint buffering;
- transfer scheduling;
- handling of USB backpressure;
- frame dropping or recovery after overflow;
- clock-domain crossing into the USB subsystem.

Lattice’s UVC reference design is explicitly intended to provide this camera-sensor-to-USB template over the CrossLinkU-NX hard USB interface.

## The minimum viable implementation

For the first working IMX900C MJPEG/UVC camera:

1. IMX900 register sequencer.
2. Lattice soft D-PHY and CSI-2 receiver.
3. Lattice byte-to-pixel converter.
4. RAW unpacking and active-region extraction.
5. Black-level correction.
6. Fixed white-balance gains.
7. Lattice debayer initially.
8. Programmable CCM.
9. Programmable gamma/tone LUT.
10. RGB-to-YCbCr converter.
11. 4:2:2 chroma resampler.
12. Simple crop—no scaler initially.
13. JPEG MCU formatter and encoder.
14. UVC payload and USB reference-design integration.
15. Adequate FIFOs and a defined frame-drop policy.

Then add, in this order:

1. defective-pixel correction;
2. lens-shading correction;
3. better chroma filters;
4. exposure statistics and auto-exposure;
5. automatic white balance;
6. raw denoising;
7. scaling;
8. custom camera-trained JPEG tables.

## Bottom line

The naive pipeline sketch:

```text
MIPI → debayer → CCM → CSC → chroma resampler
```

should really be:

```text
Sensor control                              ctrl/seq_rom.v, ctrl/i2c_master.v
    ↓
MIPI D-PHY + CSI-2 + RAW unpacking          csi/dphy_byte_align.v → csi/csi2_rx.v → csi/raw_unpack.v
    ↓
Frame/line synchronization and buffering    csi/frame_sync.v
    ↓
Black-level correction                      isp/blc.v
    ↓
White-balance gains                         isp/wb_gains.v
    ↓
Defective-pixel / lens-shading, when ready  isp/dpc.v, isp/lsc.v          [reserved]
    ↓
Debayer (MHC 5×5, DEBAYER-PLAN.md)          isp/debayer.v
    ↓
CCM                                         isp/ccm.v
    ↓
Gamma/tone mapping, 10/12-to-8-bit          isp/gamma_lut.v
    ↓
RGB-to-YCbCr                                isp/csc_422.v  ┐
    ↓                                                      ├ one module
Chroma resampling 4:4:4 → 4:2:2             isp/csc_422.v  ┘
    ↓
Crop (no scaler in v1)                      isp/crop.v
    ↓
JPEG block formatting and encoding          input_buffer.v → dct_2d.v (dct_1d.v ×2) →
                                            quantizer.v → zigzag_reorder.v →
                                            huffman_encoder.v → bitstream_packer.v →
                                            jfif_writer.v
    ↓
UVC framing                                 uvc/uvc_packetizer.v
    ↓
USB 3.2                                     uvc/usb_ep_fifo.v → CrossLinkU-NX hard USB
```

Directory-prefixed files live under `camera/rtl/` (CAMERA-PLAN.md §3); bare
filenames are the JPEG encoder in `streamline/` (or `rtl/` until their
rewrite phase lands). `[reserved]` marks insertion points that stay empty in
v1 (CAMERA-PLAN.md C7).

The most easily overlooked pieces are **sensor initialization, RAW unpacking, black-level correction, white balance, gamma/tone conversion, block formatting, and UVC packetization**.
