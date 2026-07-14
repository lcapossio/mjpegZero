// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// uvc_descriptors — the device's descriptor set, as typed structures
//
// Every descriptor is a named, packed struct (usb_desc_types.h /
// uvc_desc_types.h) with designated initializers, one field per line so each
// entry reads against the specification's own descriptor tables; the
// configuration bundles are structs-of-structs so every wTotalLength is a
// sizeof() the compiler maintains. A byte-identity gate (gen/Makefile:
// make check) proves the emitted bytes are identical to the Lattice
// baseline's golden set, so field edits cannot silently change what goes on
// the wire unnoticed.
//
// Values inherited from the verified baseline (not spec-derived) are marked
// "baseline:": VID/PID, GUIDs, frame intervals, MS OS 2.0 parameters.
// -----------------------------------------------------------------------------

#include "usb_desc_types.h"
#include "uvc_desc_types.h"
#include "uvc_descriptors.h"

// ---- Identity and stream parameters ------------------------------------------

#define VID             0x2AC1      // baseline: Lattice
#define PID             0xFD00      // baseline
#define BCD_DEV         0x0010      // baseline
#define DEV_CLK_HZ      100000000u  // VC header dwClockFrequency

#define BPP             16          // YUY2 bits per pixel
#define FRAME_IVAL      0x00017406u // baseline: 9.5238 ms (105.0 Hz), 100 ns units
#define FRAME_IVAL_STEP 0x000186A0u // baseline: 10 ms
#define MAX_FRAME(w, h) ((uint32_t)(w) * (h) * BPP / 8 + 2)

#define YUY2_GUID   {0x59,0x55,0x59,0x32,0x00,0x00,0x10,0x00, \
                     0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71}
#define XU_GUID     {0x0c,0x89,0xb6,0xac,0xb3,0xa3,0x60,0x40, \
                     0x8b,0x9a,0xdf,0x34,0xee,0xf3,0x9a,0x2f}   // baseline
#define MSOS20_UUID {0xDF,0x60,0xDD,0xD8,0x89,0x45,0xC7,0x4C, \
                     0x9C,0xD2,0x65,0x9D,0x9E,0x64,0x8A,0x9F}   // MS OS 2.0

// Per-descriptor wire-size proofs live beside their types (usb_desc_types.h,
// uvc_desc_types.h); the bundle-size proofs below are this configuration's.

// ---- Device descriptors --------------------------------------------------------

#define DEVICE_DESC(bcd_usb, max_pkt0) {        \
    .bLength            = 18,                   \
    .bDescriptorType    = USB_DT_DEVICE,        \
    .bcdUSB             = (bcd_usb),            \
    .bDeviceClass       = 0xEF,                 \
    .bDeviceSubClass    = 0x02,                 \
    .bDeviceProtocol    = 0x01,     /* Misc / Common / IAD */ \
    .bMaxPacketSize0    = (max_pkt0),           \
    .idVendor           = VID,                  \
    .idProduct          = PID,                  \
    .bcdDevice          = BCD_DEV,              \
    .iManufacturer      = 1,                    \
    .iProduct           = 2,                    \
    .iSerialNumber      = 3,                    \
    .bNumConfigurations = 1,                    \
}

static const usb_device_descriptor_t dev_hs = DEVICE_DESC(0x0210, 64);
static const usb_device_descriptor_t dev_ss = DEVICE_DESC(0x0320, 9); // 2^9 = 512

static const usb_device_qualifier_descriptor_t dev_qual = {
    .bLength            = 10,
    .bDescriptorType    = USB_DT_DEVICE_QUALIFIER,
    .bcdUSB             = 0x0210,
    .bDeviceClass       = 0xEF,
    .bDeviceSubClass    = 0x02,
    .bDeviceProtocol    = 0x01,
    .bMaxPacketSize0    = 64,
    .bNumConfigurations = 1,
    .bReserved          = 0,
};

// ---- BOS ------------------------------------------------------------------------

typedef struct {
    usb_bos_descriptor_t             bos;
    usb_usb20_extension_descriptor_t usb2ext;
    usb_superspeed_cap_descriptor_t  sscap;
    usb_platform_cap_descriptor_t    msos20;
} USB_PACKED bos_bundle_t;

static const bos_bundle_t bos = {
    .bos = {
        .bLength             = 5,
        .bDescriptorType     = USB_DT_BOS,
        .wTotalLength        = sizeof(bos_bundle_t),
        .bNumDeviceCaps      = 3,
    },
    .usb2ext = {
        .bLength             = 7,
        .bDescriptorType     = USB_DT_DEVICE_CAPABILITY,
        .bDevCapabilityType  = USB_CAP_USB20_EXTENSION,
        .bmAttributes        = 0,           // baseline: LPM disabled
    },
    .sscap = {
        .bLength             = 10,
        .bDescriptorType     = USB_DT_DEVICE_CAPABILITY,
        .bDevCapabilityType  = USB_CAP_SUPERSPEED_USB,
        .bmAttributes        = 0,
        .wSpeedsSupported    = 0x000E,      // FS / HS / SS
        .bFunctionalitySupport = 2,
        .bU1DevExitLat       = 0,           // baseline: LPM off
        .wU2DevExitLat       = 0,
    },
    .msos20 = {
        .bLength             = 28,
        .bDescriptorType     = USB_DT_DEVICE_CAPABILITY,
        .bDevCapabilityType  = USB_CAP_PLATFORM,
        .bReserved           = 0,
        .PlatformCapabilityUUID = MSOS20_UUID,
        .dwWindowsVersion    = 0x06030000,  // baseline: Windows 8.1+
        .wMSOSDescriptorSetTotalLength = 0x014A,  // baseline
        .bMS_VendorCode      = 0x20,        // baseline: WINUSB_REQ
        .bAltEnumCode        = 0,
    },
};

// ---- Configuration bundles -------------------------------------------------------
// One struct per link speed; identical class content, speed-specific bulk
// endpoint (512 vs 1024) and the SS endpoint companion.

#define CFG_CLASS_MEMBERS                                       \
    usb_interface_assoc_descriptor_t     iad;                   \
    usb_interface_descriptor_t           if_vc;                 \
    uvc_vc_header_descriptor_t           vc_header;             \
    uvc_camera_terminal_descriptor_t     camera;                \
    uvc_output_terminal_descriptor_t     output;                \
    uvc_extension_unit_descriptor_t      xu;                    \
    usb_interface_descriptor_t           if_vs;                 \
    uvc_vs_input_header_descriptor_t     vs_header;             \
    uvc_format_uncompressed_descriptor_t fmt_yuy2;              \
    uvc_frame_uncompressed_descriptor_t  frame_1080p;           \
    uvc_frame_uncompressed_descriptor_t  frame_720p;            \
    uvc_color_matching_descriptor_t      color

typedef struct {
    usb_configuration_descriptor_t cfg;
    CFG_CLASS_MEMBERS;
    usb_endpoint_descriptor_t      ep_video;
} USB_PACKED cfg_hs_bundle_t;

typedef struct {
    usb_configuration_descriptor_t   cfg;
    CFG_CLASS_MEMBERS;
    usb_endpoint_descriptor_t        ep_video;
    usb_ss_ep_companion_descriptor_t ep_video_comp;
} USB_PACKED cfg_ss_bundle_t;

#define VC_TOTAL (sizeof(uvc_vc_header_descriptor_t) +          \
                  sizeof(uvc_camera_terminal_descriptor_t) +    \
                  sizeof(uvc_output_terminal_descriptor_t) +    \
                  sizeof(uvc_extension_unit_descriptor_t))

#define VS_TOTAL (sizeof(uvc_vs_input_header_descriptor_t) +     \
                  sizeof(uvc_format_uncompressed_descriptor_t) + \
                  2 * sizeof(uvc_frame_uncompressed_descriptor_t) + \
                  sizeof(uvc_color_matching_descriptor_t))

// Uncompressed frame descriptor, continuous interval (UVC 1.5 payload spec).
#define YUY2_FRAME(idx, w, h) {                     \
    .bLength                 = 38,                  \
    .bDescriptorType         = UVC_CS_INTERFACE,    \
    .bDescriptorSubtype      = UVC_VS_FRAME_UNCOMPRESSED, \
    .bFrameIndex             = (idx),               \
    .bmCapabilities          = 0,                   \
    .wWidth                  = (w),                 \
    .wHeight                 = (h),                 \
    .dwMinBitRate            = 0xFFFFFFFF,          /* baseline */ \
    .dwMaxBitRate            = 0xFFFFFFFF,          /* baseline */ \
    .dwMaxVideoFrameBufferSize = MAX_FRAME(w, h),   \
    .dwDefaultFrameInterval  = FRAME_IVAL,          \
    .bFrameIntervalType      = 0,                   /* continuous */ \
    .dwMinFrameInterval      = FRAME_IVAL,          \
    .dwMaxFrameInterval      = FRAME_IVAL + FRAME_IVAL_STEP, \
    .dwFrameIntervalStep     = FRAME_IVAL_STEP,     \
}

// Shared class-content initializer (identical at HS and SS).
#define CFG_CLASS_INIT                                          \
    .iad = {                                                    \
        .bLength             = 8,                               \
        .bDescriptorType     = USB_DT_INTERFACE_ASSOC,          \
        .bFirstInterface     = 0,                               \
        .bInterfaceCount     = 2,                               \
        .bFunctionClass      = 0x0E,    /* CC_VIDEO */          \
        .bFunctionSubClass   = 0x03,    /* interface collection */ \
        .bFunctionProtocol   = 0,                               \
        .iFunction           = 2,                               \
    },                                                          \
    .if_vc = {                                                  \
        .bLength             = 9,                               \
        .bDescriptorType     = USB_DT_INTERFACE,                \
        .bInterfaceNumber    = 0,                               \
        .bAlternateSetting   = 0,                               \
        .bNumEndpoints       = 0,                               \
        .bInterfaceClass     = 0x0E,    /* CC_VIDEO */          \
        .bInterfaceSubClass  = 0x01,    /* VideoControl */      \
        .bInterfaceProtocol  = 0x01,    /* UVC 1.5 */           \
        .iInterface          = 2,                               \
    },                                                          \
    .vc_header = {                                              \
        .bLength             = 13,                              \
        .bDescriptorType     = UVC_CS_INTERFACE,                \
        .bDescriptorSubtype  = UVC_VC_HEADER,                   \
        .bcdUVC              = 0x0150,                          \
        .wTotalLength        = VC_TOTAL,                        \
        .dwClockFrequency    = DEV_CLK_HZ,                      \
        .bInCollection       = 1,                               \
        .baInterfaceNr       = {1},                             \
    },                                                          \
    .camera = {                                                 \
        .bLength             = 18,                              \
        .bDescriptorType     = UVC_CS_INTERFACE,                \
        .bDescriptorSubtype  = UVC_VC_INPUT_TERMINAL,           \
        .bTerminalID         = 1,                               \
        .wTerminalType       = 0x0201,  /* ITT_CAMERA */        \
        .bAssocTerminal      = 2,                               \
        .iTerminal           = 0,                               \
        .wObjectiveFocalLengthMin = 0,                          \
        .wObjectiveFocalLengthMax = 0,                          \
        .wOcularFocalLength  = 0,                               \
        .bControlSize        = 3,                               \
        .bmControls          = {0, 0, 0},                       \
    },                                                          \
    .output = {                                                 \
        .bLength             = 9,                               \
        .bDescriptorType     = UVC_CS_INTERFACE,                \
        .bDescriptorSubtype  = UVC_VC_OUTPUT_TERMINAL,          \
        .bTerminalID         = 2,                               \
        .wTerminalType       = 0x0101,  /* TT_STREAMING */      \
        .bAssocTerminal      = 1,                               \
        .bSourceID           = 1,       /* <- camera terminal */ \
        .iTerminal           = 0,                               \
    },                                                          \
    .xu = {                                                     \
        .bLength             = 26,                              \
        .bDescriptorType     = UVC_CS_INTERFACE,                \
        .bDescriptorSubtype  = UVC_VC_EXTENSION_UNIT,           \
        .bUnitID             = 4,                               \
        .guidExtensionCode   = XU_GUID,                         \
        .bNumControls        = 1,                               \
        .bNrInPins           = 1,                               \
        .baSourceID          = {2},     /* <- output terminal */ \
        .bControlSize        = 1,                               \
        .bmControls          = {0x01},                          \
        .iExtension          = 0,                               \
    },                                                          \
    .if_vs = {                                                  \
        .bLength             = 9,                               \
        .bDescriptorType     = USB_DT_INTERFACE,                \
        .bInterfaceNumber    = 1,                               \
        .bAlternateSetting   = 0,                               \
        .bNumEndpoints       = 1,                               \
        .bInterfaceClass     = 0x0E,    /* CC_VIDEO */          \
        .bInterfaceSubClass  = 0x02,    /* VideoStreaming */    \
        .bInterfaceProtocol  = 0x01,    /* UVC 1.5 */           \
        .iInterface          = 0,                               \
    },                                                          \
    .vs_header = {                                              \
        .bLength             = 14,                              \
        .bDescriptorType     = UVC_CS_INTERFACE,                \
        .bDescriptorSubtype  = UVC_VS_INPUT_HEADER,             \
        .bNumFormats         = 1,                               \
        .wTotalLength        = VS_TOTAL,                        \
        .bEndpointAddress    = 0x81,    /* bulk IN */           \
        .bmInfo              = 0,                               \
        .bTerminalLink       = 2,       /* <- output terminal */ \
        .bStillCaptureMethod = 0,                               \
        .bTriggerSupport     = 0,                               \
        .bTriggerUsage       = 0,                               \
        .bControlSize        = 1,                               \
        .bmaControls         = {0},                             \
    },                                                          \
    .fmt_yuy2 = {                                               \
        .bLength             = 27,                              \
        .bDescriptorType     = UVC_CS_INTERFACE,                \
        .bDescriptorSubtype  = UVC_VS_FORMAT_UNCOMPRESSED,      \
        .bFormatIndex        = 1,                               \
        .bNumFrameDescriptors = 2,                              \
        .guidFormat          = YUY2_GUID,                       \
        .bBitsPerPixel       = BPP,                             \
        .bDefaultFrameIndex  = 2,       /* baseline: 720p */    \
        .bAspectRatioX       = 0,                               \
        .bAspectRatioY       = 0,                               \
        .bmInterlaceFlags    = 0,                               \
        .bCopyProtect        = 0,                               \
    },                                                          \
    .frame_1080p = YUY2_FRAME(1, 1920, 1080),                   \
    .frame_720p  = YUY2_FRAME(2, 1280,  720),                   \
    .color = {                                                  \
        .bLength             = 6,                               \
        .bDescriptorType     = UVC_CS_INTERFACE,                \
        .bDescriptorSubtype  = UVC_VS_COLORFORMAT,              \
        .bColorPrimaries     = 0,                               \
        .bTransferCharacteristics = 0,                          \
        .bMatrixCoefficients = 0,                               \
    }

static const cfg_hs_bundle_t cfg_hs = {
    .cfg = {
        .bLength             = 9,
        .bDescriptorType     = USB_DT_CONFIGURATION,
        .wTotalLength        = sizeof(cfg_hs_bundle_t),
        .bNumInterfaces      = 2,
        .bConfigurationValue = 1,
        .iConfiguration      = 0,
        .bmAttributes        = 0xC0,    // self-powered
        .bMaxPower           = 0x32,    // 100 mA
    },
    CFG_CLASS_INIT,
    .ep_video = {
        .bLength             = 7,
        .bDescriptorType     = USB_DT_ENDPOINT,
        .bEndpointAddress    = 0x81,    // bulk IN
        .bmAttributes        = 0x02,    // bulk
        .wMaxPacketSize      = 512,     // USB 2.0 HS
        .bInterval           = 0,
    },
};

static const cfg_ss_bundle_t cfg_ss = {
    .cfg = {
        .bLength             = 9,
        .bDescriptorType     = USB_DT_CONFIGURATION,
        .wTotalLength        = sizeof(cfg_ss_bundle_t),
        .bNumInterfaces      = 2,
        .bConfigurationValue = 1,
        .iConfiguration      = 0,
        .bmAttributes        = 0xC0,    // self-powered
        .bMaxPower           = 0x32,    // 100 mA
    },
    CFG_CLASS_INIT,
    .ep_video = {
        .bLength             = 7,
        .bDescriptorType     = USB_DT_ENDPOINT,
        .bEndpointAddress    = 0x81,    // bulk IN
        .bmAttributes        = 0x02,    // bulk
        .wMaxPacketSize      = 1024,    // USB 3.2 Gen 1
        .bInterval           = 0,
    },
    .ep_video_comp = {
        .bLength             = 6,
        .bDescriptorType     = USB_DT_SS_EP_COMPANION,
        .bMaxBurst           = 0x0F,    // 16-packet bursts
        .bmAttributes        = 0,
        .wBytesPerInterval   = 0,
    },
};

// Wire-size proofs against the verified baseline set.
_Static_assert(sizeof(cfg_hs_bundle_t) == 231, "cfg_hs wire size");
_Static_assert(sizeof(cfg_ss_bundle_t) == 237, "cfg_ss wire size");
_Static_assert(sizeof(bos_bundle_t)    ==  50, "bos wire size");

// ---- Capability table for the probe/commit machine --------------------------------

static const char *strings[] = {
    "Lattice Semiconductor",    // 1: iManufacturer  (baseline)
    "Lattice USB23",            // 2: iProduct       (baseline)
    "00000001",                 // 3: iSerialNumber  (baseline)
};

static const uvc_frame_desc_t yuy2_frames[2] = {
    {
        .width           = 1920,
        .height          = 1080,
        .interval_100ns  = FRAME_IVAL,
        .max_frame_bytes = MAX_FRAME(1920, 1080),
    },
    {
        .width           = 1280,
        .height          = 720,
        .interval_100ns  = FRAME_IVAL,
        .max_frame_bytes = MAX_FRAME(1280, 720),
    },
};

static const uvc_format_desc_t formats[1] = {
    {
        .kind     = UVC_FMT_YUY2,
        .n_frames = 2,
        .frames   = yuy2_frames,
    },
};

const uvc_descriptors_t uvc_descriptors_yuy2 = {
    .dev_desc_hs       = (const uint8_t *)&dev_hs,
    .dev_desc_hs_len   = sizeof dev_hs,
    .dev_desc_ss       = (const uint8_t *)&dev_ss,
    .dev_desc_ss_len   = sizeof dev_ss,
    .dev_qual_desc     = (const uint8_t *)&dev_qual,
    .dev_qual_desc_len = sizeof dev_qual,
    .cfg_desc_hs       = (const uint8_t *)&cfg_hs,
    .cfg_desc_hs_len   = sizeof cfg_hs,
    .cfg_desc_ss       = (const uint8_t *)&cfg_ss,
    .cfg_desc_ss_len   = sizeof cfg_ss,
    .bos_desc          = (const uint8_t *)&bos,
    .bos_desc_len      = sizeof bos,
    .strings           = strings,
    .n_strings         = 3,
    .formats           = formats,
    .n_formats         = 1,
};
