// SPDX-License-Identifier: Apache-2.0
// Shim for the golden-byte dump harness only: lsc_uvc.h includes the full
// device header for function prototypes it does not need at type level.
// This stub satisfies the include without dragging in the BSP.
#ifndef LSC_USB_DEV_H_
#define LSC_USB_DEV_H_
#include <stdint.h>
struct lsc_usb_dev;
#endif
