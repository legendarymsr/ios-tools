/* Amalgamated vhci-bridge for Android asset extract (flat file).
 * Generated from vhci-bridge/{tcp-usb.h,usbip_wire.h,bridge.c}.
 */

/* ==== begin tcp-usb.h ==== */
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

/* ==== end tcp-usb.h ==== */

/* ==== begin usbip_wire.h ==== */
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

/* ==== end usbip_wire.h ==== */

/* ==== begin bridge.c ==== */
/*
 * Inferno hcd-tcp <-> Linux USB/IP VHCI bridge.
 *
 * Speaks the same wire protocol as Inferno's usb-tcp-remote (cc4302a +
 * ios-tools patches-7): we are the DEVICE side of that link. VHCI is the
 * Linux USB host that replaces the companion VM's EHCI.
 *
 * AGPL-3.0-or-later (same as Inferno's tcp-usb). ios-tools / legendarymsr.
 */
#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#ifndef DEFAULT_SOCK
#define DEFAULT_SOCK "/root/InfernoData/restore/usb.sock"
#endif
#ifndef DEFAULT_VHCI
#define DEFAULT_VHCI "/sys/devices/platform/vhci_hcd.0"
#endif
#ifndef DEFAULT_DEVID
#define DEFAULT_DEVID ((1u << 16) | 1u)
#endif
#define NAK_RETRY_MS 2
#define MAX_XFER 65536

static const char *g_listen_path = DEFAULT_SOCK;
static const char *g_vhci_path = DEFAULT_VHCI;
static uint32_t g_devid = DEFAULT_DEVID;
static int g_speed = USB_SPEED_HIGH;
static int g_verbose = 1; /* default on: step 5 needs the log */

#define LOG(fmt, ...) do { \
    fprintf(stderr, "[vhci-bridge] " fmt "\n", ##__VA_ARGS__); fflush(stderr); \
} while (0)
#define DBG(fmt, ...) do { \
    if (g_verbose) LOG(fmt, ##__VA_ARGS__); \
} while (0)

static ssize_t read_full(int fd, void *buf, size_t n)
{
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (char *)buf + got, n - got);
        if (r == 0) return 0;
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        got += (size_t)r;
    }
    return (ssize_t)got;
}

static bool write_full(int fd, const void *buf, size_t n)
{
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = write(fd, (const char *)buf + sent, n - sent);
        if (w < 0) { if (errno == EINTR) continue; return false; }
        sent += (size_t)w;
    }
    return true;
}

static uint32_t be32x(uint32_t v, int to_be) { return to_be ? htonl(v) : ntohl(v); }

static void usbip_hdr_endian(struct usbip_header *h, int send)
{
    uint32_t cmd = send ? h->base.command : 0;
    h->base.command   = be32x(h->base.command, send);
    h->base.seqnum    = be32x(h->base.seqnum, send);
    h->base.devid     = be32x(h->base.devid, send);
    h->base.direction = be32x(h->base.direction, send);
    h->base.ep        = be32x(h->base.ep, send);
    if (!send) cmd = h->base.command;
    switch (cmd) {
    case USBIP_CMD_SUBMIT:
        h->u.cmd_submit.transfer_flags = be32x(h->u.cmd_submit.transfer_flags, send);
        h->u.cmd_submit.transfer_buffer_length =
            (int32_t)be32x((uint32_t)h->u.cmd_submit.transfer_buffer_length, send);
        h->u.cmd_submit.start_frame =
            (int32_t)be32x((uint32_t)h->u.cmd_submit.start_frame, send);
        h->u.cmd_submit.number_of_packets =
            (int32_t)be32x((uint32_t)h->u.cmd_submit.number_of_packets, send);
        h->u.cmd_submit.interval =
            (int32_t)be32x((uint32_t)h->u.cmd_submit.interval, send);
        break;
    case USBIP_RET_SUBMIT:
        h->u.ret_submit.status =
            (int32_t)be32x((uint32_t)h->u.ret_submit.status, send);
        h->u.ret_submit.actual_length =
            (int32_t)be32x((uint32_t)h->u.ret_submit.actual_length, send);
        h->u.ret_submit.start_frame =
            (int32_t)be32x((uint32_t)h->u.ret_submit.start_frame, send);
        h->u.ret_submit.number_of_packets =
            (int32_t)be32x((uint32_t)h->u.ret_submit.number_of_packets, send);
        h->u.ret_submit.error_count =
            (int32_t)be32x((uint32_t)h->u.ret_submit.error_count, send);
        break;
    case USBIP_CMD_UNLINK:
        h->u.cmd_unlink.seqnum = be32x(h->u.cmd_unlink.seqnum, send);
        break;
    case USBIP_RET_UNLINK:
        h->u.ret_unlink.status =
            (int32_t)be32x((uint32_t)h->u.ret_unlink.status, send);
        break;
    }
}

/* ---------- Inferno link (usb-tcp-remote role) ---------- */
typedef struct {
    int fd;
    pthread_mutex_t wlock;
    uint8_t addr;
} InfernoLink;

static InfernoLink g_link = { .fd = -1 };
static int g_vhci_fd = -1;
static int g_vhci_port = -1;
static volatile int g_stop;
static uint64_t g_next_id = 1;

static bool inf_send_req(InfernoLink *L, int pid, uint8_t ep, uint64_t id,
                         const void *data, uint16_t len, uint8_t short_not_ok)
{
    tcp_usb_header_t hdr = { .type = TCP_USB_REQUEST };
    tcp_usb_request_header req;
    memset(&req, 0, sizeof(req));
    req.addr = L->addr;
    req.pid = pid;
    req.ep = ep;
    req.id = id;
    req.short_not_ok = short_not_ok;
    req.length = len;

    DBG("TX REQUEST addr=%u pid=0x%x ep=%u id=%" PRIu64 " len=%u",
        req.addr, pid, ep, id, len);

    pthread_mutex_lock(&L->wlock);
    bool ok = write_full(L->fd, &hdr, sizeof(hdr))
           && write_full(L->fd, &req, sizeof(req));
    if (ok && len > 0 && pid != USB_TOKEN_IN)
        ok = write_full(L->fd, data, len);
    pthread_mutex_unlock(&L->wlock);
    if (!ok) LOG("write to Inferno failed: %s", strerror(errno));
    return ok;
}

static bool inf_send_cancel(InfernoLink *L, int pid, uint8_t ep, uint64_t id)
{
    tcp_usb_header_t hdr = { .type = TCP_USB_CANCEL };
    tcp_usb_cancel_header c = { .addr = L->addr, .pid = pid, .ep = ep, .id = id };
    DBG("TX CANCEL pid=0x%x ep=%u id=%" PRIu64, pid, ep, id);
    pthread_mutex_lock(&L->wlock);
    bool ok = write_full(L->fd, &hdr, sizeof(hdr)) && write_full(L->fd, &c, sizeof(c));
    pthread_mutex_unlock(&L->wlock);
    return ok;
}

static bool inf_send_reset(InfernoLink *L)
{
    tcp_usb_header_t hdr = { .type = TCP_USB_RESET };
    L->addr = 0;
    LOG("TX RESET (bus reset toward iOS)");
    pthread_mutex_lock(&L->wlock);
    bool ok = write_full(L->fd, &hdr, sizeof(hdr));
    pthread_mutex_unlock(&L->wlock);
    return ok;
}

/* ---------- pending URBs ---------- */
typedef enum { ST_SETUP = 1, ST_DATA, ST_STATUS, ST_BULK } Stage;

typedef struct Pending {
    uint32_t seqnum;
    uint32_t direction;
    uint32_t ep;
    int32_t  buflen;
    uint32_t transfer_flags;
    unsigned char setup[8];
    bool is_ctrl;
    bool cancelled;
    bool sent_reset; /* unused per-urb */
    int pid;
    uint64_t inf_id;
    Stage stage;
    void *out_data;
    void *in_data;
    int32_t actual;
    uint64_t gen; /* bumped on cancel so NAK retry won't use freed state */
    struct timespec nak_due; /* zero = not waiting for NAK retry */
    struct Pending *next;
} Pending;

static pthread_mutex_t g_plock = PTHREAD_MUTEX_INITIALIZER;
static Pending *g_pending;
static uint64_t g_gen = 1;
static bool g_did_port_reset; /* one bus reset before first enumerate */

static Pending *pend_find_seq(uint32_t seq)
{
    for (Pending *p = g_pending; p; p = p->next)
        if (p->seqnum == seq) return p;
    return NULL;
}

static Pending *pend_find_inf(uint64_t id, int pid, uint8_t ep)
{
    for (Pending *p = g_pending; p; p = p->next)
        if (!p->cancelled && p->inf_id == id && p->pid == pid && (uint8_t)p->ep == ep)
            return p;
    return NULL;
}

static void pend_remove(Pending *t)
{
    Pending **pp = &g_pending;
    while (*pp) {
        if (*pp == t) { *pp = t->next; break; }
        pp = &(*pp)->next;
    }
}

static void pend_free(Pending *p)
{
    free(p->out_data);
    free(p->in_data);
    free(p);
}

static int32_t qemu_to_urb(int st)
{
    switch (st) {
    case USB_RET_SUCCESS: return 0;
    case USB_RET_STALL:   return -32;   /* EPIPE */
    case USB_RET_BABBLE:  return -75;   /* EOVERFLOW */
    case USB_RET_NODEV:   return -19;   /* ENODEV */
    case USB_RET_IOERROR: return -71;   /* EPROTO */
    default:              return -71;
    }
}

static bool usbip_send_ret_submit(uint32_t seq, uint32_t dir, uint32_t ep,
                                  int32_t status, int32_t actual, const void *data)
{
    struct usbip_header h;
    memset(&h, 0, sizeof(h));
    h.base.command = USBIP_RET_SUBMIT;
    h.base.seqnum = seq;
    h.base.devid = g_devid;
    h.base.direction = dir;
    h.base.ep = ep;
    h.u.ret_submit.status = status;
    h.u.ret_submit.actual_length = actual;
    /* non-iso: 0 packets (not -1) so vhci does not wait for iso descriptors */
    h.u.ret_submit.number_of_packets = 0;
    usbip_hdr_endian(&h, 1);
    if (g_vhci_fd < 0) return false;
    if (!write_full(g_vhci_fd, &h, sizeof(h))) {
        LOG("write RET_SUBMIT header failed: %s", strerror(errno));
        return false;
    }
    if (dir == USBIP_DIR_IN && actual > 0 && data) {
        if (!write_full(g_vhci_fd, data, (size_t)actual)) {
            LOG("write RET_SUBMIT data failed: %s", strerror(errno));
            return false;
        }
    }
    DBG("TX RET_SUBMIT seq=%u status=%d actual=%d", seq, status, actual);
    return true;
}

static bool usbip_send_ret_unlink(uint32_t seq, int32_t status)
{
    struct usbip_header h;
    memset(&h, 0, sizeof(h));
    h.base.command = USBIP_RET_UNLINK;
    h.base.seqnum = seq;
    h.base.devid = g_devid;
    h.u.ret_unlink.status = status;
    usbip_hdr_endian(&h, 1);
    return g_vhci_fd >= 0 && write_full(g_vhci_fd, &h, sizeof(h));
}

static void complete_pending(Pending *p, int qemu_status)
{
    if (p->cancelled) {
        pend_remove(p);
        pend_free(p);
        return;
    }
    int32_t urb = qemu_to_urb(qemu_status);
    int32_t actual = (qemu_status == USB_RET_SUCCESS) ? p->actual : 0;
    usbip_send_ret_submit(p->seqnum, p->direction, p->ep, urb, actual, p->in_data);
    pend_remove(p);
    pend_free(p);
}

static uint16_t ctrl_wlen(const Pending *p)
{
    return (uint16_t)(p->setup[6] | (p->setup[7] << 8));
}

static bool ctrl_is_in(const Pending *p) { return (p->setup[0] & 0x80) != 0; }

static bool send_stage(Pending *p)
{
    if (p->cancelled) return true;

    if (!p->is_ctrl) {
        p->pid = (p->direction == USBIP_DIR_IN) ? USB_TOKEN_IN : USB_TOKEN_OUT;
        p->inf_id = g_next_id++;
        p->stage = ST_BULK;
        uint16_t len = (uint16_t)(p->buflen > 0 ? (p->buflen > MAX_XFER ? MAX_XFER : p->buflen) : 0);
        uint8_t sno = (p->transfer_flags & URB_SHORT_NOT_OK) ? 1 : 0;
        return inf_send_req(&g_link, p->pid, (uint8_t)p->ep, p->inf_id,
                            p->out_data, len, sno);
    }

    switch (p->stage) {
    case ST_SETUP:
        p->pid = USB_TOKEN_SETUP;
        p->inf_id = g_next_id++;
        /* Mirror usb-tcp-remote: remember SET_ADDRESS from the SETUP bytes. */
        if (p->setup[0] == 0 && p->setup[1] == USB_REQ_SET_ADDRESS)
            g_link.addr = (uint8_t)(p->setup[2] | (p->setup[3] << 8));
        return inf_send_req(&g_link, USB_TOKEN_SETUP, 0, p->inf_id, p->setup, 8, 0);

    case ST_DATA: {
        uint16_t wlen = ctrl_wlen(p);
        if (ctrl_is_in(p)) {
            p->pid = USB_TOKEN_IN;
            p->inf_id = g_next_id++;
            if (!p->in_data) p->in_data = calloc(1, wlen ? wlen : 1);
            return inf_send_req(&g_link, USB_TOKEN_IN, 0, p->inf_id, NULL, wlen, 0);
        }
        p->pid = USB_TOKEN_OUT;
        p->inf_id = g_next_id++;
        uint16_t n = (uint16_t)((p->buflen < wlen) ? p->buflen : wlen);
        return inf_send_req(&g_link, USB_TOKEN_OUT, 0, p->inf_id, p->out_data, n, 0);
    }

    case ST_STATUS:
        /*
         * Status stage is the opposite direction of the data stage; with no
         * data stage, status is IN (same as EHCI / usb-tcp-remote).
         */
        if (ctrl_wlen(p) == 0)
            p->pid = USB_TOKEN_IN;
        else
            p->pid = ctrl_is_in(p) ? USB_TOKEN_OUT : USB_TOKEN_IN;
        p->inf_id = g_next_id++;
        return inf_send_req(&g_link, p->pid, 0, p->inf_id, NULL, 0, 0);

    default:
        return false;
    }
}

static void kick_pending(Pending *p)
{
    /* One bus reset before the first URB, like EHCI port reset on plug-in.
     * Do NOT reset at accept-time — that raced the restore ramdisk and
     * could reboot the guest (-no-reboot → QEMU exit). */
    if (!g_did_port_reset) {
        g_did_port_reset = true;
        inf_send_reset(&g_link);
    }
    if (!send_stage(p)) {
        LOG("send_stage failed seq=%u", p->seqnum);
        complete_pending(p, USB_RET_IOERROR);
    }
}

static void schedule_nak_retry(Pending *p)
{
    clock_gettime(CLOCK_MONOTONIC, &p->nak_due);
    p->nak_due.tv_nsec += NAK_RETRY_MS * 1000000L;
    if (p->nak_due.tv_nsec >= 1000000000L) {
        p->nak_due.tv_sec++;
        p->nak_due.tv_nsec -= 1000000000L;
    }
}

static void on_inferno_response(const tcp_usb_response_header *r, void *payload)
{
    int st = (int32_t)r->status;
    DBG("RX RESPONSE addr=%u pid=0x%x ep=%u id=%" PRIu64 " status=%d len=%u",
        r->addr, r->pid, r->ep, r->id, st, r->length);

    pthread_mutex_lock(&g_plock);
    Pending *p = pend_find_inf(r->id, r->pid, r->ep);
    if (!p) {
        DBG("orphan RESPONSE (cancelled or late)");
        pthread_mutex_unlock(&g_plock);
        free(payload);
        return;
    }
    if (p->cancelled) {
        pthread_mutex_unlock(&g_plock);
        free(payload);
        return;
    }

    if (st == USB_RET_ASYNC) {
        /* Final status will follow; do not re-send (usb-tcp-remote behaviour). */
        memset(&p->nak_due, 0, sizeof(p->nak_due));
        pthread_mutex_unlock(&g_plock);
        free(payload);
        return;
    }
    if (st == USB_RET_NAK) {
        schedule_nak_retry(p);
        pthread_mutex_unlock(&g_plock);
        free(payload);
        return;
    }
    if (st == USB_RET_REMOVE_FROM_QUEUE) {
        pthread_mutex_unlock(&g_plock);
        free(payload);
        return;
    }
    if (st != USB_RET_SUCCESS) {
        complete_pending(p, st);
        pthread_mutex_unlock(&g_plock);
        free(payload);
        return;
    }

    /* SUCCESS — advance control stages or finish */
    memset(&p->nak_due, 0, sizeof(p->nak_due));
    if (p->is_ctrl) {
        if (p->stage == ST_SETUP) {
            p->stage = (ctrl_wlen(p) > 0) ? ST_DATA : ST_STATUS;
            if (!send_stage(p)) complete_pending(p, USB_RET_IOERROR);
        } else if (p->stage == ST_DATA) {
            if (p->pid == USB_TOKEN_IN && payload && r->length) {
                size_t n = r->length;
                if (n > (size_t)ctrl_wlen(p)) n = ctrl_wlen(p);
                memcpy(p->in_data, payload, n);
                p->actual = (int32_t)n;
            } else if (p->pid == USB_TOKEN_OUT) {
                p->actual = r->length;
            }
            p->stage = ST_STATUS;
            if (!send_stage(p)) complete_pending(p, USB_RET_IOERROR);
        } else if (p->stage == ST_STATUS) {
            /* After SET_ADDRESS status IN, usb-tcp-remote applies addr to the
             * USB device object; we already set g_link.addr from SETUP. */
            complete_pending(p, USB_RET_SUCCESS);
        }
    } else {
        if (p->direction == USBIP_DIR_IN && payload && r->length) {
            p->in_data = realloc(p->in_data, r->length);
            if (p->in_data) memcpy(p->in_data, payload, r->length);
            p->actual = r->length;
        } else {
            p->actual = r->length;
        }
        complete_pending(p, USB_RET_SUCCESS);
    }
    pthread_mutex_unlock(&g_plock);
    free(payload);
}

/* NAK retry worker — must not block the Inferno reader */
static void *nak_thread(void *arg)
{
    (void)arg;
    while (!g_stop) {
        struct timespec now, sleep_ts = { .tv_sec = 0, .tv_nsec = 1000000L }; /* 1ms */
        clock_gettime(CLOCK_MONOTONIC, &now);
        pthread_mutex_lock(&g_plock);
        for (Pending *p = g_pending; p; p = p->next) {
            if (p->cancelled || p->nak_due.tv_sec == 0) continue;
            if (now.tv_sec > p->nak_due.tv_sec ||
                (now.tv_sec == p->nak_due.tv_sec && now.tv_nsec >= p->nak_due.tv_nsec)) {
                memset(&p->nak_due, 0, sizeof(p->nak_due));
                /* Re-issue the same stage with a fresh id (old one was answered). */
                uint64_t old = p->inf_id;
                (void)old;
                if (!send_stage(p))
                    complete_pending(p, USB_RET_IOERROR);
            }
        }
        pthread_mutex_unlock(&g_plock);
        nanosleep(&sleep_ts, NULL);
    }
    return NULL;
}

static void *inferno_reader(void *arg)
{
    (void)arg;
    while (!g_stop && g_link.fd >= 0) {
        tcp_usb_header_t hdr;
        ssize_t n = read_full(g_link.fd, &hdr, sizeof(hdr));
        if (n <= 0) {
            LOG("Inferno link closed (%s)", n == 0 ? "EOF" : strerror(errno));
            g_stop = 1;
            break;
        }
        if (hdr.type != TCP_USB_RESPONSE) {
            LOG("unexpected Inferno type %u from iOS (want RESPONSE) — dropping link",
                hdr.type);
            g_stop = 1;
            break;
        }
        tcp_usb_response_header r;
        if (read_full(g_link.fd, &r, sizeof(r)) != (ssize_t)sizeof(r)) {
            LOG("short RESPONSE header"); g_stop = 1; break;
        }
        void *payload = NULL;
        int st = (int32_t)r.status;
        if (r.length > 0 && r.pid == USB_TOKEN_IN && st != USB_RET_ASYNC) {
            if (r.length == 0 && 0) { LOG("RESPONSE len %u too big", r.length); g_stop = 1; break; }
            payload = malloc(r.length);
            if (!payload || read_full(g_link.fd, payload, r.length) != (ssize_t)r.length) {
                free(payload); LOG("short RESPONSE payload"); g_stop = 1; break;
            }
        }
        on_inferno_response(&r, payload);
    }
    return NULL;
}

/* ---------- VHCI ---------- */
static int find_free_vhci_port(void)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/status", g_vhci_path);
    FILE *f = fopen(path, "r");
    if (!f) {
        snprintf(path, sizeof(path), "%s/status.0", g_vhci_path);
        f = fopen(path, "r");
    }
    if (!f) { LOG("cannot open %s/status: %s", g_vhci_path, strerror(errno)); return -1; }
    char line[256];
    int port = -1;
    while (fgets(line, sizeof(line), f)) {
        char hub[8];
        unsigned p, sta, spd;
        if (sscanf(line, "%7s %u %u %u", hub, &p, &sta, &spd) == 4) {
            /* VDEV_ST_NULL = 4 */
            if (strcmp(hub, "hs") == 0 && sta == 4) { port = (int)p; break; }
        }
    }
    fclose(f);
    return port;
}

static int vhci_attach(int sockfd)
{
    int port = find_free_vhci_port();
    if (port < 0) { LOG("no free VHCI HS port"); return -1; }
    char path[512], buf[64];
    snprintf(path, sizeof(path), "%s/attach", g_vhci_path);
    snprintf(buf, sizeof(buf), "%u %d %u %u", port, sockfd, g_devid, g_speed);
    int fd = open(path, O_WRONLY);
    if (fd < 0) { LOG("open %s: %s", path, strerror(errno)); return -1; }
    ssize_t w = write(fd, buf, strlen(buf));
    int err = errno;
    close(fd);
    if (w < 0) { LOG("attach failed: %s (buf=%s)", strerror(err), buf); return -1; }
    LOG("attached VHCI port %d sockfd %d devid 0x%x speed %d", port, sockfd, g_devid, g_speed);
    g_vhci_port = port;
    return port;
}

static void vhci_detach(void)
{
    if (g_vhci_port < 0) return;
    char path[512], buf[32];
    snprintf(path, sizeof(path), "%s/detach", g_vhci_path);
    snprintf(buf, sizeof(buf), "%u", g_vhci_port);
    int fd = open(path, O_WRONLY);
    if (fd >= 0) { write(fd, buf, strlen(buf)); close(fd); }
    LOG("detached VHCI port %d", g_vhci_port);
    g_vhci_port = -1;
}

static void handle_cmd_submit(struct usbip_header *h, void *out_buf)
{
    Pending *p = calloc(1, sizeof(*p));
    p->seqnum = h->base.seqnum;
    p->direction = h->base.direction;
    p->ep = h->base.ep;
    p->buflen = h->u.cmd_submit.transfer_buffer_length;
    p->transfer_flags = h->u.cmd_submit.transfer_flags;
    memcpy(p->setup, h->u.cmd_submit.setup, 8);
    p->is_ctrl = (h->base.ep == 0);
    p->out_data = out_buf;
    p->stage = p->is_ctrl ? ST_SETUP : ST_BULK;
    p->gen = g_gen;

    DBG("CMD_SUBMIT seq=%u ep=%u dir=%u len=%d setup=%02x %02x %02x %02x",
        p->seqnum, p->ep, p->direction, p->buflen,
        p->setup[0], p->setup[1], p->setup[2], p->setup[3]);

    pthread_mutex_lock(&g_plock);
    p->next = g_pending;
    g_pending = p;
    kick_pending(p);
    pthread_mutex_unlock(&g_plock);
}

static void handle_cmd_unlink(struct usbip_header *h)
{
    uint32_t victim = h->u.cmd_unlink.seqnum;
    int found = 0;
    pthread_mutex_lock(&g_plock);
    Pending *p = pend_find_seq(victim);
    if (p) {
        found = 1;
        p->cancelled = true;
        p->gen = ++g_gen;
        memset(&p->nak_due, 0, sizeof(p->nak_due));
        inf_send_cancel(&g_link, p->pid, (uint8_t)p->ep, p->inf_id);
        pend_remove(p);
        pend_free(p);
    }
    pthread_mutex_unlock(&g_plock);
    usbip_send_ret_unlink(h->base.seqnum, found ? -104 : 0); /* -ECONNRESET if was pending */
    DBG("RET_UNLINK seq=%u victim=%u %s", h->base.seqnum, victim, found ? "ok" : "miss");
}

static void *vhci_reader(void *arg)
{
    (void)arg;
    while (!g_stop && g_vhci_fd >= 0) {
        struct usbip_header h;
        ssize_t n = read_full(g_vhci_fd, &h, sizeof(h));
        if (n <= 0) {
            LOG("VHCI socket closed (%s)", n == 0 ? "EOF" : strerror(errno));
            g_stop = 1;
            break;
        }
        usbip_hdr_endian(&h, 0);
        if (h.base.command == USBIP_CMD_SUBMIT) {
            void *buf = NULL;
            int32_t len = h.u.cmd_submit.transfer_buffer_length;
            if (h.base.direction == USBIP_DIR_OUT && len > 0) {
                if (len > MAX_XFER) { LOG("OUT len %d too big", len); g_stop = 1; break; }
                buf = malloc((size_t)len);
                if (!buf || read_full(g_vhci_fd, buf, (size_t)len) != len) {
                    free(buf); LOG("short OUT buffer"); g_stop = 1; break;
                }
            }
            handle_cmd_submit(&h, buf);
        } else if (h.base.command == USBIP_CMD_UNLINK) {
            handle_cmd_unlink(&h);
        } else {
            LOG("unknown USBIP cmd %u", h.base.command);
            g_stop = 1;
            break;
        }
    }
    return NULL;
}

static int listen_unix(const char *path)
{
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(a.sun_path)) { LOG("path too long"); close(fd); return -1; }
    strncpy(a.sun_path, path, sizeof(a.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) { perror("bind"); close(fd); return -1; }
    if (listen(fd, 1) < 0) { perror("listen"); close(fd); return -1; }
    chmod(path, 0666);
    LOG("listening on %s", path);
    return fd;
}

static void cleanup_session(void)
{
    g_stop = 1;
    vhci_detach();
    if (g_vhci_fd >= 0) { close(g_vhci_fd); g_vhci_fd = -1; }
    if (g_link.fd >= 0) { close(g_link.fd); g_link.fd = -1; }
    pthread_mutex_lock(&g_plock);
    while (g_pending) {
        Pending *p = g_pending;
        g_pending = p->next;
        pend_free(p);
    }
    pthread_mutex_unlock(&g_plock);
    g_link.addr = 0;
    g_did_port_reset = false;
}

static int run_session(int inf_fd)
{
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return -1; }

    g_stop = 0;
    g_did_port_reset = false;
    g_next_id = 1;
    g_link.fd = inf_fd;
    pthread_mutex_init(&g_link.wlock, NULL);
    g_link.addr = 0;
    g_vhci_fd = sv[0];

    /* Attach first so the host can enumerate; bus reset is deferred until
     * the first URB (kick_pending), matching EHCI plug-in order more closely
     * than resetting the moment the unix socket accepts. */
    if (vhci_attach(sv[1]) < 0) {
        close(sv[0]); close(sv[1]);
        g_vhci_fd = -1;
        return -1;
    }
    close(sv[1]);

    pthread_t t_inf, t_vhci, t_nak;
    pthread_create(&t_inf, NULL, inferno_reader, NULL);
    pthread_create(&t_vhci, NULL, vhci_reader, NULL);
    pthread_create(&t_nak, NULL, nak_thread, NULL);

    while (!g_stop) sleep(1);

    pthread_join(t_inf, NULL);
    pthread_join(t_vhci, NULL);
    /* nak_thread exits on g_stop */
    pthread_join(t_nak, NULL);
    cleanup_session();
    return 0;
}

static void usage(const char *a)
{
    fprintf(stderr,
        "Usage: %s [-s unix.sock] [-V vhci_sysfs_dir] [-d devid] [-S speed] [-q]\n"
        "  -q  quieter (less debug)\n", a);
}

int main(int argc, char **argv)
{
    int opt;
    while ((opt = getopt(argc, argv, "s:V:d:S:qvh")) != -1) {
        switch (opt) {
        case 's': g_listen_path = optarg; break;
        case 'V': g_vhci_path = optarg; break;
        case 'd': g_devid = strtoul(optarg, NULL, 0); break;
        case 'S': g_speed = atoi(optarg); break;
        case 'q': g_verbose = 0; break;
        case 'v': g_verbose = 1; break;
        default: usage(argv[0]); return 2;
        }
    }
    signal(SIGPIPE, SIG_IGN);

    char attach[512];
    snprintf(attach, sizeof(attach), "%s/attach", g_vhci_path);
    if (access(attach, W_OK) != 0) {
        LOG("VHCI not available (%s): %s", attach, strerror(errno));
        return 3;
    }
    LOG("struct sizes: req=%zu resp=%zu cancel=%zu usbip=%zu",
        sizeof(tcp_usb_request_header), sizeof(tcp_usb_response_header),
        sizeof(tcp_usb_cancel_header), sizeof(struct usbip_header));

    int lfd = listen_unix(g_listen_path);
    if (lfd < 0) return 1;

    LOG("waiting for iOS hcd-tcp to connect...");
    for (;;) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            break;
        }
        LOG("iOS hcd-tcp connected");
        run_session(cfd);
        LOG("session ended — listening again");
    }
    close(lfd);
    unlink(g_listen_path);
    return 0;
}
