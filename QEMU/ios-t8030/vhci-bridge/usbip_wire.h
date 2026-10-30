// SPDX-License-Identifier: GPL-3.0-or-later
/* USB/IP wire headers (linux/drivers/usb/usbip) - userspace copy */
#ifndef IOS_TOOLS_USBIP_WIRE_H
#define IOS_TOOLS_USBIP_WIRE_H
#include <stdint.h>

#define USBIP_CMD_SUBMIT 0x0001
#define USBIP_CMD_UNLINK 0x0002
#define USBIP_RET_SUBMIT 0x0003
#define USBIP_RET_UNLINK 0x0004
#define USBIP_DIR_OUT 0x00
#define USBIP_DIR_IN  0x01

struct usbip_header_basic {
    uint32_t command;
    uint32_t seqnum;
    uint32_t devid;
    uint32_t direction;
    uint32_t ep;
} __attribute__((packed));

struct usbip_header_cmd_submit {
    uint32_t transfer_flags;
    int32_t transfer_buffer_length;
    int32_t start_frame;
    int32_t number_of_packets;
    int32_t interval;
    unsigned char setup[8];
} __attribute__((packed));

struct usbip_header_ret_submit {
    int32_t status;
    int32_t actual_length;
    int32_t start_frame;
    int32_t number_of_packets;
    int32_t error_count;
} __attribute__((packed));

struct usbip_header_cmd_unlink {
    uint32_t seqnum;
} __attribute__((packed));

struct usbip_header_ret_unlink {
    int32_t status;
} __attribute__((packed));

struct usbip_header {
    struct usbip_header_basic base;
    union {
        struct usbip_header_cmd_submit cmd_submit;
        struct usbip_header_ret_submit ret_submit;
        struct usbip_header_cmd_unlink cmd_unlink;
        struct usbip_header_ret_unlink ret_unlink;
    } u;
} __attribute__((packed));

/* URB transfer_flags bits used here */
#define URB_SHORT_NOT_OK 0x0001
#define URB_ISO_ASAP     0x0002
#define URB_ZERO_PACKET  0x0040
#define URB_NO_INTERRUPT 0x0080
#define URB_FREE_BUFFER  0x0100
#define URB_DIR_MASK     0x0200
#define URB_DIR_IN       0x0200
#define URB_DIR_OUT      0

enum usb_device_speed {
    USB_SPEED_UNKNOWN = 0,
    USB_SPEED_LOW, USB_SPEED_FULL, USB_SPEED_HIGH,
    USB_SPEED_WIRELESS, USB_SPEED_SUPER, USB_SPEED_SUPER_PLUS
};
#endif
