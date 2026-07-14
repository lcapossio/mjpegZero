// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// uvc_class — USB Video Class 1.5 device logic (control plane)
//
// Function
//   Implements the UVC device control plane over the usb23_hal transport:
//   standard Chapter 9 requests (descriptor delivery, configuration,
//   interface alt-settings), VideoControl and VideoStreaming class requests,
//   and the Probe/Commit negotiation state machine (UVC 1.5 §4.3.1.1).
//   Descriptor tables are consumed from the generated descriptor source
//   (one Python truth -> C structs; nothing hand-packed here).
//
// Interface
//   Pure with respect to hardware: all state lives in the caller's
//   uvc_class context; the only side effects are through the usb23 handle
//   it is given and the uvc_stream_events callbacks it raises. Every
//   request handler is a plain function of (context, setup packet) and is
//   compiled and unit-tested on the host against spec-derived cases before
//   it ever runs on the RV32 (CAMERA-PLAN.md §5.4).
//
// Contract
//   Probe/Commit follows UVC 1.5: GET/SET_CUR(PROBE) negotiate against the
//   device's format/frame capability table; SET_CUR(COMMIT) latches the
//   negotiated mode and raises on_commit with the resolved format, frame,
//   and interval. Requests for unsupported controls answer with a protocol
//   STALL and set bRequestErrorCode per §2.4.4 (VC_REQUEST_ERROR_CODE).
//   Payload headers are 12 bytes with FID toggling per frame and EOF set
//   on each frame's final payload (UVC 1.5 §2.4.3.3); this module supplies
//   the header bytes, the video path supplies the timing. Mode changes
//   during active streaming are deferred to the frame boundary the
//   video_source reports — never applied mid-frame.
// -----------------------------------------------------------------------------

#ifndef UVC_CLASS_H
#define UVC_CLASS_H

#include <stdint.h>
#include <stdbool.h>
#include "usb23_hal.h"

// ---- Capability description (from the descriptor generator) ------------------

typedef enum {
    UVC_FMT_YUY2 = 0,   // uncompressed 4:2:2 (debug / bring-up mode)
    UVC_FMT_MJPEG,      // variable-length JPEG frames (product mode)
} uvc_format_kind_t;

typedef struct {
    uint16_t width;
    uint16_t height;
    uint32_t interval_100ns;    // default frame interval (UVC units)
    uint32_t max_frame_bytes;   // dwMaxVideoFrameSize advertised
} uvc_frame_desc_t;

typedef struct {
    uvc_format_kind_t kind;
    uint8_t           n_frames;
    const uvc_frame_desc_t *frames;
} uvc_format_desc_t;

// Generated descriptor bundle: full config descriptors per speed plus the
// capability table the probe/commit machine negotiates against.
typedef struct {
    const uint8_t *dev_desc_hs;   const uint16_t dev_desc_hs_len;
    const uint8_t *dev_desc_ss;   const uint16_t dev_desc_ss_len;
    const uint8_t *dev_qual_desc; const uint16_t dev_qual_desc_len;
    const uint8_t *cfg_desc_hs;   const uint16_t cfg_desc_hs_len;
    const uint8_t *cfg_desc_ss;   const uint16_t cfg_desc_ss_len;
    const uint8_t *bos_desc;      const uint16_t bos_desc_len;
    const char   **strings;       const uint8_t  n_strings;
    const uvc_format_desc_t *formats;
    uint8_t        n_formats;
} uvc_descriptors_t;

// ---- Negotiated stream state --------------------------------------------------

typedef struct {
    uint8_t  format_index;      // 1-based, as on the wire
    uint8_t  frame_index;       // 1-based, as on the wire
    uint32_t interval_100ns;
    uint32_t max_payload_bytes; // dwMaxPayloadTransferSize in force
    uint32_t max_frame_bytes;   // dwMaxVideoFrameSize in force
} uvc_mode_t;

typedef struct {
    // Host committed a mode: (re)configure the video path. Deferred by the
    // caller to a frame boundary if streaming is active.
    void (*on_commit)(void *ctx, const uvc_mode_t *mode);
    // Streaming interface alt-setting / bulk stream state changed.
    void (*on_stream_enable)(void *ctx, bool enabled);
} uvc_stream_events_t;

struct uvc_class;   // opaque; storage owned by the caller

// ---- Lifecycle ----------------------------------------------------------------

// Bind the class to a transport and descriptor bundle. Registers itself
// for the transport's on_setup/on_reset/on_connect_done events.
int uvc_class_init(struct uvc_class *c, struct usb23 *u,
                   const uvc_descriptors_t *desc,
                   const uvc_stream_events_t *events, void *events_ctx);

// Current negotiated (probed but not committed) and committed modes.
const uvc_mode_t *uvc_probed_mode(const struct uvc_class *c);
const uvc_mode_t *uvc_committed_mode(const struct uvc_class *c);
bool              uvc_stream_enabled(const struct uvc_class *c);

// ---- Payload headers -----------------------------------------------------------

// Fill a 12-byte UVC payload header. fid toggles per frame; eof marks the
// frame's final payload. Returns header length (12).
uint32_t uvc_payload_header(uint8_t out[12], bool fid, bool eof);

// ---- Host-testable request core -------------------------------------------------
// The full dispatcher, exposed so host-side unit tests can drive the exact
// code the target runs: returns true if the request was consumed (reply or
// stall already issued through the transport).
bool uvc_handle_setup(struct uvc_class *c, const usb_setup_packet_t *setup);

#endif // UVC_CLASS_H
