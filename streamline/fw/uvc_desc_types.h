// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// uvc_desc_types — UVC 1.5 class-specific descriptor wire layouts
//
// Exact wire formats (packed, little-endian) for the class descriptors this
// device uses, with the specification's field names. Array-valued fields
// (bmControls, baSourceID, bmaControls) are sized for THIS device's
// configuration — one streaming interface, one XU input pin, UVC 1.5
// 3-byte camera controls — matching UVC 1.5 §3.7 (VideoControl) and
// §3.9 (VideoStreaming).
// -----------------------------------------------------------------------------

#ifndef UVC_DESC_TYPES_H
#define UVC_DESC_TYPES_H

#include <stdint.h>
#include "usb_desc_types.h"

// Class-specific descriptor types and subtypes (UVC 1.5 §A.4–A.6)
enum {
    UVC_CS_INTERFACE            = 0x24,

    UVC_VC_HEADER               = 0x01,
    UVC_VC_INPUT_TERMINAL       = 0x02,
    UVC_VC_OUTPUT_TERMINAL      = 0x03,
    UVC_VC_EXTENSION_UNIT       = 0x06,

    UVC_VS_INPUT_HEADER         = 0x01,
    UVC_VS_FORMAT_UNCOMPRESSED  = 0x04,
    UVC_VS_FRAME_UNCOMPRESSED   = 0x05,
    UVC_VS_FORMAT_MJPEG         = 0x06,
    UVC_VS_FRAME_MJPEG          = 0x07,
    UVC_VS_COLORFORMAT          = 0x0D,
};

// VideoControl interface header (UVC 1.5 §3.7.2), one streaming interface.
typedef struct uvc_vc_header_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;       // UVC_CS_INTERFACE
    uint8_t  bDescriptorSubtype;    // UVC_VC_HEADER
    uint16_t bcdUVC;
    uint16_t wTotalLength;          // header + units/terminals that follow
    uint32_t dwClockFrequency;
    uint8_t  bInCollection;
    uint8_t  baInterfaceNr[1];
} USB_PACKED uvc_vc_header_descriptor_t;

// Camera input terminal (UVC 1.5 §3.7.2.3); bControlSize = 3 per UVC 1.5.
typedef struct uvc_camera_terminal_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bDescriptorSubtype;    // UVC_VC_INPUT_TERMINAL
    uint8_t  bTerminalID;
    uint16_t wTerminalType;         // ITT_CAMERA = 0x0201
    uint8_t  bAssocTerminal;
    uint8_t  iTerminal;
    uint16_t wObjectiveFocalLengthMin;
    uint16_t wObjectiveFocalLengthMax;
    uint16_t wOcularFocalLength;
    uint8_t  bControlSize;
    uint8_t  bmControls[3];
} USB_PACKED uvc_camera_terminal_descriptor_t;

typedef struct uvc_output_terminal_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bDescriptorSubtype;    // UVC_VC_OUTPUT_TERMINAL
    uint8_t  bTerminalID;
    uint16_t wTerminalType;         // TT_STREAMING = 0x0101
    uint8_t  bAssocTerminal;
    uint8_t  bSourceID;
    uint8_t  iTerminal;
} USB_PACKED uvc_output_terminal_descriptor_t;

// Extension unit (UVC 1.5 §3.7.2.7), one input pin, 1-byte bmControls.
typedef struct uvc_extension_unit_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bDescriptorSubtype;    // UVC_VC_EXTENSION_UNIT
    uint8_t  bUnitID;
    uint8_t  guidExtensionCode[16];
    uint8_t  bNumControls;
    uint8_t  bNrInPins;
    uint8_t  baSourceID[1];
    uint8_t  bControlSize;
    uint8_t  bmControls[1];
    uint8_t  iExtension;
} USB_PACKED uvc_extension_unit_descriptor_t;

// VideoStreaming input header (UVC 1.5 §3.9.2.1), one format.
typedef struct uvc_vs_input_header_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bDescriptorSubtype;    // UVC_VS_INPUT_HEADER
    uint8_t  bNumFormats;
    uint16_t wTotalLength;          // header + formats/frames that follow
    uint8_t  bEndpointAddress;
    uint8_t  bmInfo;
    uint8_t  bTerminalLink;
    uint8_t  bStillCaptureMethod;
    uint8_t  bTriggerSupport;
    uint8_t  bTriggerUsage;
    uint8_t  bControlSize;
    uint8_t  bmaControls[1];
} USB_PACKED uvc_vs_input_header_descriptor_t;

// Uncompressed format (UVC 1.5 payload spec §3.1.1) — YUY2 via guidFormat.
typedef struct uvc_format_uncompressed_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bDescriptorSubtype;    // UVC_VS_FORMAT_UNCOMPRESSED
    uint8_t  bFormatIndex;
    uint8_t  bNumFrameDescriptors;
    uint8_t  guidFormat[16];
    uint8_t  bBitsPerPixel;
    uint8_t  bDefaultFrameIndex;
    uint8_t  bAspectRatioX;
    uint8_t  bAspectRatioY;
    uint8_t  bmInterlaceFlags;
    uint8_t  bCopyProtect;
} USB_PACKED uvc_format_uncompressed_descriptor_t;

// Uncompressed frame, continuous intervals (bFrameIntervalType = 0).
typedef struct uvc_frame_uncompressed_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bDescriptorSubtype;    // UVC_VS_FRAME_UNCOMPRESSED
    uint8_t  bFrameIndex;
    uint8_t  bmCapabilities;
    uint16_t wWidth;
    uint16_t wHeight;
    uint32_t dwMinBitRate;
    uint32_t dwMaxBitRate;
    uint32_t dwMaxVideoFrameBufferSize;
    uint32_t dwDefaultFrameInterval;
    uint8_t  bFrameIntervalType;    // 0 = continuous
    uint32_t dwMinFrameInterval;
    uint32_t dwMaxFrameInterval;
    uint32_t dwFrameIntervalStep;
} USB_PACKED uvc_frame_uncompressed_descriptor_t;

typedef struct uvc_color_matching_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bDescriptorSubtype;    // UVC_VS_COLORFORMAT
    uint8_t  bColorPrimaries;
    uint8_t  bTransferCharacteristics;
    uint8_t  bMatrixCoefficients;
} USB_PACKED uvc_color_matching_descriptor_t;

// ---- Wire-size proofs (UVC 1.5 §3.7/§3.9 descriptor lengths, this device's
// array sizing: 1 streaming interface, 1 XU pin, 3-byte camera controls) ------

_Static_assert(sizeof(uvc_vc_header_descriptor_t)           == 13, "vc header");
_Static_assert(sizeof(uvc_camera_terminal_descriptor_t)     == 18, "camera terminal");
_Static_assert(sizeof(uvc_output_terminal_descriptor_t)     ==  9, "output terminal");
_Static_assert(sizeof(uvc_extension_unit_descriptor_t)      == 26, "extension unit");
_Static_assert(sizeof(uvc_vs_input_header_descriptor_t)     == 14, "vs input header");
_Static_assert(sizeof(uvc_format_uncompressed_descriptor_t) == 27, "format");
_Static_assert(sizeof(uvc_frame_uncompressed_descriptor_t)  == 38, "frame");
_Static_assert(sizeof(uvc_color_matching_descriptor_t)      ==  6, "color matching");

#endif // UVC_DESC_TYPES_H
