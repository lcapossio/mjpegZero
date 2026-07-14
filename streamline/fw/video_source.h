// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// video_source — producer contract between the pixel pipeline and USB
//
// Function
//   Abstracts the hardware video producer (today: the UVC packetizer block
//   and its buffer ring; during bring-up: the Lattice IEBM-style bridge)
//   behind a buffer-credit interface. Firmware acquires filled,
//   frame-delimited buffers, hands them to the USB transport, and releases
//   them back to hardware; it never touches pixel or JPEG bytes.
//
// Interface
//   Interrupt-driven producer: hardware raises the source IRQ when at
//   least one buffer is ready; vs_acquire() then yields buffers in fill
//   order until it reports none. Each buffer carries its byte length and
//   frame flags (first/last payload of the frame) so the caller can wrap
//   it with a UVC payload header without inspecting the data. vs_release()
//   returns the buffer credit to hardware. Formats, dimensions, and frame
//   pacing are configured through vs_start() from the committed UVC mode.
//
// Contract
//   Buffers are yielded in frame order; a frame's last buffer is flagged
//   before any buffer of the next frame is yielded, which is what makes
//   FID/EOF generation above this interface correct by construction.
//   vs_stop() quiesces at a frame boundary: after it returns, no further
//   buffers arrive and all credits are back with hardware — this is the
//   hook that makes commit-during-streaming safe (UVC mode changes apply
//   between frames, never within one). Overflow policy is whole-frame
//   drop: hardware discards complete frames when the ring is full, and
//   frames_dropped counts them; partial frames never reach the host.
//   All counters are observable for the product's debug philosophy.
// -----------------------------------------------------------------------------

#ifndef VIDEO_SOURCE_H
#define VIDEO_SOURCE_H

#include <stdint.h>
#include <stdbool.h>
#include "uvc_class.h"

// ---- Types --------------------------------------------------------------------

typedef struct {
    uint8_t *data;          // buffer payload (device memory, DMA-reachable)
    uint32_t len;           // filled bytes
    bool     frame_start;   // first buffer of a frame
    bool     frame_end;     // last buffer of a frame (drives EOF)
    uint32_t frame_seq;     // frame counter at capture (drives FID parity)
} vs_buffer_t;

typedef struct {
    uint32_t frames_produced;
    uint32_t frames_dropped;    // whole-frame overflow drops
    uint32_t bytes_produced;
    uint32_t ring_high_water;   // max buffers simultaneously in flight
} vs_stats_t;

struct video_source;    // opaque; storage owned by the caller

// ---- Lifecycle ------------------------------------------------------------------

// Bind to the producer hardware's CSR base and buffer ring geometry.
int  vs_init(struct video_source *v, uintptr_t csr_base,
             uint32_t ring_buffers, uint32_t buffer_bytes);

// Configure the pipeline for the committed mode and begin producing at the
// next frame boundary. Returns 0 on success.
int  vs_start(struct video_source *v, const uvc_mode_t *mode);

// Quiesce at a frame boundary; blocks (bounded by one frame period) until
// all credits are returned. No buffers arrive after this returns.
void vs_stop(struct video_source *v);

// ---- Buffer flow ------------------------------------------------------------------

// Service routine for the producer interrupt: acknowledges hardware and
// returns true while buffers may be pending.
bool vs_irq_service(struct video_source *v);

// Yield the next filled buffer, or false if none pending. Ownership passes
// to the caller until vs_release().
bool vs_acquire(struct video_source *v, vs_buffer_t *out);

// Return a buffer's credit to hardware (in any order; hardware tracks by
// buffer index derived from data pointer).
void vs_release(struct video_source *v, const vs_buffer_t *buf);

// ---- Observability -----------------------------------------------------------------

void vs_stats(const struct video_source *v, vs_stats_t *out);

#endif // VIDEO_SOURCE_H
