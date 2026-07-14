// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// usb23_hal — device-mode driver contract for the CrossLinkU-NX USB23 core
//
// Function
//   Owns the Synopsys DWC3-compatible USB23 device controller: core reset
//   and PHY configuration, event-buffer service, endpoint lifecycle
//   (configure / stall / transfer), and TRB queue management. Exposes USB
//   as speed-agnostic endpoints and events; contains no class knowledge.
//
// Interface
//   One context struct per controller instance, initialized against the
//   controller's base address; no global state. Transfers are asynchronous:
//   the caller submits a buffer, the HAL queues TRBs and later delivers a
//   completion through the endpoint's registered callback from
//   usb23_irq_service(). Control (EP0) traffic is surfaced as setup-packet
//   callbacks; the class layer above answers with usb23_ep0_send/recv/stall.
//
// Contract
//   The DWC3 command ceremonies are preserved exactly from the verified
//   baseline (Lattice usb23hal / Synopsys programming guide v3.30b §4.x),
//   including: GUSB2PHYCFG suspend-bit save/clear/restore around DEPCMD at
//   HS/FS speeds, ENDTRANSFER sequencing, and the undocumented register
//   writes carried verbatim (never derived, never "improved"). No function
//   allocates; all buffers are caller-owned and 4-byte aligned. Callbacks
//   run in interrupt context and must not block.
// -----------------------------------------------------------------------------

#ifndef USB23_HAL_H
#define USB23_HAL_H

#include <stdint.h>
#include <stdbool.h>
#include "usb_desc_types.h"     // usb_setup_packet_t (ch9 wire formats)

// ---- Types ------------------------------------------------------------------

typedef enum {
    USB23_SPEED_UNKNOWN = 0,
    USB23_SPEED_FULL,       // USB 1.1, 12 Mbps
    USB23_SPEED_HIGH,       // USB 2.0, 480 Mbps
    USB23_SPEED_SUPER,      // USB 3.2 Gen 1, 5 Gbps
} usb23_speed_t;

typedef enum {
    USB23_EP_CONTROL = 0,
    USB23_EP_BULK,
    USB23_EP_INTERRUPT,
    USB23_EP_ISOCHRONOUS,
} usb23_ep_type_t;

typedef enum {
    USB23_DIR_OUT = 0,      // host -> device
    USB23_DIR_IN  = 1,      // device -> host
} usb23_dir_t;

struct usb23;   // opaque; storage provided by the caller, layout private

// Completion of a previously submitted transfer. status is 0 on success.
typedef void (*usb23_xfer_cb_t)(struct usb23 *u, uint8_t ep,
                                usb23_dir_t dir, uint8_t *buf,
                                uint32_t done_bytes, int status);

// Device-level events the class layer must observe. Callbacks recover
// their owning context with usb23_user(u).
typedef struct {
    void (*on_reset)(struct usb23 *u);                       // bus reset
    void (*on_connect_done)(struct usb23 *u, usb23_speed_t); // speed known
    void (*on_setup)(struct usb23 *u, const usb_setup_packet_t *setup);
    void (*on_disconnect)(struct usb23 *u);
} usb23_dev_callbacks_t;

// ---- Lifecycle --------------------------------------------------------------

// Initialize the controller at base_addr (core soft reset, PHY config,
// event buffer allocation from the caller-supplied region, EP0 setup).
// Does not attach to the bus. user is an opaque pointer returned by
// usb23_user() — how callbacks reach the layer that registered them.
// Returns 0 on success.
int  usb23_init(struct usb23 *u, uintptr_t base_addr,
                const usb23_dev_callbacks_t *cbs, void *user,
                void *evt_buf, uint32_t evt_buf_len);

// The user pointer given to usb23_init().
void *usb23_user(const struct usb23 *u);

// Attach to / detach from the bus (DCTL.RUN_STOP).
void usb23_start(struct usb23 *u);
void usb23_stop(struct usb23 *u);

// Set the device address during enumeration (SET_ADDRESS).
void usb23_set_address(struct usb23 *u, uint8_t addr);

usb23_speed_t usb23_speed(const struct usb23 *u);

// ---- Event service ----------------------------------------------------------

// Drain the event buffer and dispatch callbacks. Call from the USB
// interrupt handler (or poll). Bounded work per call: at most one full
// event-buffer sweep.
void usb23_irq_service(struct usb23 *u);

// ---- Endpoints --------------------------------------------------------------

// Configure a (ep, dir) pair: DEPCFG/DEPXFERCFG ceremony, max packet size
// per current speed, and completion callback registration.
int  usb23_ep_configure(struct usb23 *u, uint8_t ep, usb23_dir_t dir,
                        usb23_ep_type_t type, uint16_t max_pkt,
                        usb23_xfer_cb_t on_complete);

// Submit one transfer. The HAL owns TRB slicing for len > TRB capacity.
// Buffer must remain valid until the completion callback fires.
int  usb23_ep_submit(struct usb23 *u, uint8_t ep, usb23_dir_t dir,
                     uint8_t *buf, uint32_t len);

// Abort any in-flight transfer on (ep, dir): ENDTRANSFER + TRB reclaim.
void usb23_ep_abort(struct usb23 *u, uint8_t ep, usb23_dir_t dir);

int  usb23_ep_stall(struct usb23 *u, uint8_t ep, usb23_dir_t dir);
int  usb23_ep_clear_stall(struct usb23 *u, uint8_t ep, usb23_dir_t dir);
bool usb23_ep_is_stalled(struct usb23 *u, uint8_t ep, usb23_dir_t dir);

// ---- EP0 (control) ----------------------------------------------------------

// Respond to the current setup transaction. Zero-length send completes a
// status stage. usb23_ep0_stall() answers unsupported requests.
int  usb23_ep0_send(struct usb23 *u, const uint8_t *buf, uint32_t len);
int  usb23_ep0_recv(struct usb23 *u, uint8_t *buf, uint32_t len);
void usb23_ep0_stall(struct usb23 *u);

#endif // USB23_HAL_H
