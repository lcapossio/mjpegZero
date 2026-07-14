# FIRMWARE-PLAN.md — UVC control-plane C for the RV32 core

Companion to [CAMERA-PLAN.md](CAMERA-PLAN.md) (§2 hardware/software split,
§5.4 firmware verification, phases C5–C6). The two streamline standards
apply to C unchanged: **timeless, blameless source** and **swap-and-verify**
(ENCODER-PLAN.md §4, §7). `fw/` holds *our* firmware; the Lattice reference
firmware stays untouched in its own tree
(`RD02306.../propelsdk/riscv_mc/src/`) as the known-good baseline every
layer is verified against.

## 1. Architecture — three layers, one rule each

```text
fw/uvc_class.h      UVC 1.5 control plane: ch9 + VC/VS requests,
                    Probe/Commit FSM, payload headers.
                    Rule: pure functions over a context; host-testable;
                    no hardware knowledge beyond the usb23 handle.
        │
fw/usb23_hal.h      DWC3/USB23 device driver: core init, event buffer,
                    endpoints, TRB queues, EP0.
                    Rule: preserves the verified DWC3 ceremonies exactly;
                    no class knowledge.
        │
      (silicon)     USB23 hard controller.

fw/video_source.h   Producer contract (buffer credits, frame delimiters)
                    between the pixel pipeline / UVC packetizer and USB.
                    Rule: firmware moves pointers and credits, never bytes.

Supporting: fw/usb_desc_types.h + fw/uvc_desc_types.h (wire-format structs
with per-type size proofs), fw/uvc_descriptors.{h,c} (this device's
descriptor set, byte-gated by fw/gen/ against the baseline golden bytes).

Wiring order (who initializes whom):
    usb23_init(&u, BASE, uvc_class_callbacks(), &uvc_ctx, evt, len);
    uvc_class_init(&uvc_ctx, &u, &uvc_descriptors_yuy2, &events, &vsrc);
```

The headers are the deliverable of record — contracts first, in the house
Function/Interface/Contract style, before any `.c` exists (the same
spec-before-code shape as the RTL work).

## 2. Provenance rules

- **From the Lattice baseline** (Propel-licensed for use with Lattice
  devices): register sequences, DEPCMD ceremonies, quirk workarounds
  (GUSB2PHYCFG suspend handling), the undocumented register writes —
  carried semantically verbatim into `usb23_hal.c`, cited to the Synopsys
  programming guide sections the baseline names.
- **From Apache-2.0 sources** (Zephyr `usbd_uvc.c`; TinyUSB/CherryUSB video
  classes as MIT/Apache references): probe/commit control-flow patterns,
  descriptor-generation approach. Port freely with attribution.
- **From GPL sources (U-Boot/Linux dwc3): concepts only, never code.**
- Undocumented writes are never "improved," only carried and marked.

## 3. What we improve over the baseline (the point of the rewrite)

1. **Layering** — the baseline tangles class logic and controller logic in
   single handlers; the three-layer split above is the structural fix.
2. **Descriptors as typed structures, byte-gated** — every descriptor is a
   named packed struct with designated initializers and spec field names
   (`usb_desc_types.h`, `uvc_desc_types.h`); configuration bundles are
   structs-of-structs so every `wTotalLength` is a compiler-maintained
   `sizeof()`, with `_Static_assert` wire-size proofs. Byte-exactness
   against the baseline is machine-checked (`gen/ make check`), which is
   what makes readable structs safe. HS/SS share one class-content
   initializer (no duplication). The MJPEG/YUY2 choice becomes a
   formats-table change.
3. **Probe/Commit as a pure state machine** — spec-cited, host-unit-tested,
   including deferred mode changes at frame boundaries (via
   `video_source`'s quiesce contract) rather than flag-polling in a main
   loop.
4. **Timeless source** — headers with contracts, no dead code, no debug
   scaffolding, `-Wall -Wextra` clean (CAMERA-PLAN C-G6).

## 4. Verification (CAMERA-PLAN §5.4, made specific)

- Every `fw/*.c` compiles **twice**: RV32 target and native host. The class
  layer and probe/commit FSM run host-side against a scripted CSR/transport
  mock with spec-derived cases (valid negotiations, out-of-range rejects,
  stall paths, mid-stream commits).
- **Swap-and-verify on hardware**: the Lattice firmware runs as baseline on
  the eval board; our layers replace it one at a time (HAL first under the
  baseline's class code, then our class code over our HAL), with
  enumeration + streaming evidence (`lsusb`/`dmesg`, Cynthion traces)
  compared at each step.
- Payload-header correctness (FID toggle, EOF placement) is asserted
  against the `video_source` frame flags in host tests — correct by
  construction before hardware sees it.

## 5. Order of work

| Step | Content | Gate |
|---|---|---|
| F0 | Contracts (`usb23_hal.h`, `uvc_class.h`, `video_source.h`) — **done** | headers reviewed against baseline + specs |
| F1 | Descriptor set as typed structs — **done for YUY2** (`fw/usb_desc_types.h` + `fw/uvc_desc_types.h` wire layouts; `fw/uvc_descriptors.c` designated-initializer bundles with `sizeof()`-maintained totals and `_Static_assert` size proofs; golden bytes extracted from the unmodified baseline by `gen/dump_baseline.c`; `gen/ make check` green: all six artifacts byte-identical, `-Wall -Wextra` clean). MJPEG bundle: pending (formats-table change once the packetizer path exists) | struct bytes byte-identical to baseline descriptors for the YUY2 config ✓ |
| F2 | `usb23_hal.c` (port of baseline sequences behind the new API) | enumerates on hardware under baseline class logic |
| F3 | `uvc_class.c` + host test suite | host tests green; hardware enumeration + YUY2 streaming vs baseline behavior |
| F4 | `video_source.c` against the UVC packetizer CSRs (C5) | live MJPEG streaming; commit-during-streaming safe |
| F5 | AE/AWB + rate control loops (C6, on hardware statistics) | CAMERA-PLAN C-G5 |
