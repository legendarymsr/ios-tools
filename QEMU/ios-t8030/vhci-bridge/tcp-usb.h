// SPDX-License-Identifier: GPL-3.0-or-later
/* Inferno cc4302a tcp-usb.h (AGPL-3.0) - wire format only */
#ifndef IOS_TOOLS_TCP_USB_H
#define IOS_TOOLS_TCP_USB_H
#include <stdint.h>
#ifdef __GNUC__
#define PACKED __attribute__((packed))
#else
#define PACKED
#endif

enum {
    TCP_USB_REQUEST = 1,
    TCP_USB_RESPONSE,
    TCP_USB_RESET,
    TCP_USB_CANCEL
};

typedef struct PACKED {
    uint8_t type;
} tcp_usb_header_t;

typedef struct PACKED {
    uint8_t addr;
    int32_t pid;
    uint8_t ep;
    uint64_t id;
    uint32_t stream;
    uint8_t short_not_ok;
    uint8_t int_req;
    uint16_t length;
} tcp_usb_request_header;

typedef struct PACKED {
    uint8_t addr;
    int32_t pid;
    uint8_t ep;
    uint64_t id;
    uint32_t status;
    uint16_t length;
} tcp_usb_response_header;

typedef struct PACKED {
    uint8_t addr;
    int32_t pid;
    uint8_t ep;
    uint64_t id;
} tcp_usb_cancel_header;

/* QEMU USB packet ids / return codes (hw/usb.h) */
#define USB_TOKEN_SETUP 0x2d
#define USB_TOKEN_IN    0x69
#define USB_TOKEN_OUT   0xe1

#define USB_RET_SUCCESS            0
#define USB_RET_NODEV             (-1)
#define USB_RET_NAK               (-2)
#define USB_RET_STALL             (-3)
#define USB_RET_BABBLE            (-4)
#define USB_RET_IOERROR           (-5)
#define USB_RET_ASYNC             (-6)
#define USB_RET_ADD_TO_QUEUE      (-7)
#define USB_RET_REMOVE_FROM_QUEUE (-8)

#define USB_REQ_SET_ADDRESS 0x05
#endif
