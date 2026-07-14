// SPDX-License-Identifier: Apache-2.0
// -----------------------------------------------------------------------------
// usb_desc_types — standard USB descriptor wire layouts (USB 2.0 / 3.2 §9.6)
//
// Every struct is the exact wire format: packed, little-endian fields with
// the specification's own field names. USB 3.2 uses the same descriptor
// format as USB 2.0; SuperSpeed adds only the endpoint companion and the
// BOS device-capability descriptors, defined alongside.
// -----------------------------------------------------------------------------

#ifndef USB_DESC_TYPES_H
#define USB_DESC_TYPES_H

#include <stdint.h>

#define USB_PACKED __attribute__((packed))

// USB Chapter 9 setup packet, wire layout (USB 3.2 §9.3).
typedef struct usb_setup_packet {
    uint8_t  bmRequestType;
    uint8_t  bRequest;
    uint16_t wValue;
    uint16_t wIndex;
    uint16_t wLength;
} USB_PACKED usb_setup_packet_t;

_Static_assert(sizeof(usb_setup_packet_t) == 8, "setup packet wire size");

// Descriptor types (USB 3.2 table 9-6)
enum {
    USB_DT_DEVICE               = 0x01,
    USB_DT_CONFIGURATION        = 0x02,
    USB_DT_STRING               = 0x03,
    USB_DT_INTERFACE            = 0x04,
    USB_DT_ENDPOINT             = 0x05,
    USB_DT_DEVICE_QUALIFIER     = 0x06,
    USB_DT_INTERFACE_ASSOC      = 0x0B,
    USB_DT_BOS                  = 0x0F,
    USB_DT_DEVICE_CAPABILITY    = 0x10,
    USB_DT_SS_EP_COMPANION      = 0x30,
};

// Device capability types (USB 3.2 table 9-14)
enum {
    USB_CAP_USB20_EXTENSION     = 0x02,
    USB_CAP_SUPERSPEED_USB      = 0x03,
    USB_CAP_PLATFORM            = 0x05,
};

typedef struct usb_device_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint16_t bcdUSB;
    uint8_t  bDeviceClass;
    uint8_t  bDeviceSubClass;
    uint8_t  bDeviceProtocol;
    uint8_t  bMaxPacketSize0;
    uint16_t idVendor;
    uint16_t idProduct;
    uint16_t bcdDevice;
    uint8_t  iManufacturer;
    uint8_t  iProduct;
    uint8_t  iSerialNumber;
    uint8_t  bNumConfigurations;
} USB_PACKED usb_device_descriptor_t;

typedef struct usb_device_qualifier_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint16_t bcdUSB;
    uint8_t  bDeviceClass;
    uint8_t  bDeviceSubClass;
    uint8_t  bDeviceProtocol;
    uint8_t  bMaxPacketSize0;
    uint8_t  bNumConfigurations;
    uint8_t  bReserved;
} USB_PACKED usb_device_qualifier_descriptor_t;

typedef struct usb_configuration_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint16_t wTotalLength;
    uint8_t  bNumInterfaces;
    uint8_t  bConfigurationValue;
    uint8_t  iConfiguration;
    uint8_t  bmAttributes;
    uint8_t  bMaxPower;
} USB_PACKED usb_configuration_descriptor_t;

typedef struct usb_interface_assoc_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bFirstInterface;
    uint8_t  bInterfaceCount;
    uint8_t  bFunctionClass;
    uint8_t  bFunctionSubClass;
    uint8_t  bFunctionProtocol;
    uint8_t  iFunction;
} USB_PACKED usb_interface_assoc_descriptor_t;

typedef struct usb_interface_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bInterfaceNumber;
    uint8_t  bAlternateSetting;
    uint8_t  bNumEndpoints;
    uint8_t  bInterfaceClass;
    uint8_t  bInterfaceSubClass;
    uint8_t  bInterfaceProtocol;
    uint8_t  iInterface;
} USB_PACKED usb_interface_descriptor_t;

typedef struct usb_endpoint_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bEndpointAddress;
    uint8_t  bmAttributes;
    uint16_t wMaxPacketSize;
    uint8_t  bInterval;
} USB_PACKED usb_endpoint_descriptor_t;

// SuperSpeed endpoint companion (USB 3.2 §9.6.7) — follows each endpoint.
typedef struct usb_ss_ep_companion_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint8_t  bMaxBurst;
    uint8_t  bmAttributes;
    uint16_t wBytesPerInterval;
} USB_PACKED usb_ss_ep_companion_descriptor_t;

// ---- BOS (USB 3.2 §9.6.2) ----------------------------------------------------

typedef struct usb_bos_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;
    uint16_t wTotalLength;
    uint8_t  bNumDeviceCaps;
} USB_PACKED usb_bos_descriptor_t;

typedef struct usb_usb20_extension_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;       // USB_DT_DEVICE_CAPABILITY
    uint8_t  bDevCapabilityType;    // USB_CAP_USB20_EXTENSION
    uint32_t bmAttributes;          // bit 1 = LPM
} USB_PACKED usb_usb20_extension_descriptor_t;

typedef struct usb_superspeed_cap_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;       // USB_DT_DEVICE_CAPABILITY
    uint8_t  bDevCapabilityType;    // USB_CAP_SUPERSPEED_USB
    uint8_t  bmAttributes;
    uint16_t wSpeedsSupported;      // bit map: LS/FS/HS/SS
    uint8_t  bFunctionalitySupport;
    uint8_t  bU1DevExitLat;
    uint16_t wU2DevExitLat;
} USB_PACKED usb_superspeed_cap_descriptor_t;

// Platform capability (USB 3.2 §9.6.2.4); payload sized for MS OS 2.0.
typedef struct usb_platform_cap_descriptor {
    uint8_t  bLength;
    uint8_t  bDescriptorType;       // USB_DT_DEVICE_CAPABILITY
    uint8_t  bDevCapabilityType;    // USB_CAP_PLATFORM
    uint8_t  bReserved;
    uint8_t  PlatformCapabilityUUID[16];
    uint32_t dwWindowsVersion;      // MS OS 2.0 descriptor set info
    uint16_t wMSOSDescriptorSetTotalLength;
    uint8_t  bMS_VendorCode;
    uint8_t  bAltEnumCode;
} USB_PACKED usb_platform_cap_descriptor_t;

// ---- Wire-size proofs (USB 3.2 §9.6 descriptor lengths) -----------------------

_Static_assert(sizeof(usb_device_descriptor_t)           == 18, "device");
_Static_assert(sizeof(usb_device_qualifier_descriptor_t) == 10, "qualifier");
_Static_assert(sizeof(usb_configuration_descriptor_t)    ==  9, "configuration");
_Static_assert(sizeof(usb_interface_assoc_descriptor_t)  ==  8, "iad");
_Static_assert(sizeof(usb_interface_descriptor_t)        ==  9, "interface");
_Static_assert(sizeof(usb_endpoint_descriptor_t)         ==  7, "endpoint");
_Static_assert(sizeof(usb_ss_ep_companion_descriptor_t)  ==  6, "ss companion");
_Static_assert(sizeof(usb_bos_descriptor_t)              ==  5, "bos");
_Static_assert(sizeof(usb_usb20_extension_descriptor_t)  ==  7, "usb2 ext cap");
_Static_assert(sizeof(usb_superspeed_cap_descriptor_t)   == 10, "ss cap");
_Static_assert(sizeof(usb_platform_cap_descriptor_t)     == 28, "platform cap");

#endif // USB_DESC_TYPES_H
