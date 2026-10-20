/*
 * Inferno hcd-tcp <-> Linux USB/IP VHCI bridge.
 *
 * Listens on a unix socket (usb-tcp-remote role). When the iOS VM's hcd-tcp
 * connects, attaches that device to vhci_hcd so usbmuxd in this chroot sees
 * a real /dev/bus/usb device - no companion USB-host VM needed.
 *
 * AGPL-3.0-or-later (same as Inferno's tcp-usb). ios-tools / legendarymsr.
 */
#define _GNU_SOURCE
#include "tcp-usb.h"
#include "usbip_wire.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
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
#define MAX_PKT 65536

static const char *g_listen_path = DEFAULT_SOCK;
static const char *g_vhci_path = DEFAULT_VHCI;
static uint32_t g_devid = DEFAULT_DEVID;
static int g_speed = USB_SPEED_HIGH;
static int g_verbose = 0;

#define LOG(fmt, ...) do { \
    fprintf(stderr, "[vhci-bridge] " fmt "\n", ##__VA_ARGS__); fflush(stderr); \
} while (0)
#define DBG(fmt, ...) do { \
    if (g_verbose) LOG(fmt, ##__VA_ARGS__); \
} while (0)

/* ---------- reliable I/O ---------- */
static ssize_t read_full(int fd, void *buf, size_t n)
{
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (char *)buf + got, n - got);
        if (r == 0) return 0;
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        got += (size_t)r;
    }
    return (ssize_t)got;
}

static bool write_full(int fd, const void *buf, size_t n)
{
    size_t sent = 0;
    while (sent < n) {
        ssize_t w = write(fd, (const char *)buf + sent, n - sent);
        if (w < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        sent += (size_t)w;
    }
    return true;
}

/* ---------- endian helpers for USBIP ---------- */
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
        h->u.cmd_submit.transfer_buffer_length = (int32_t)be32x((uint32_t)h->u.cmd_submit.transfer_buffer_length, send);
        h->u.cmd_submit.start_frame = (int32_t)be32x((uint32_t)h->u.cmd_submit.start_frame, send);
        h->u.cmd_submit.number_of_packets = (int32_t)be32x((uint32_t)h->u.cmd_submit.number_of_packets, send);
        h->u.cmd_submit.interval = (int32_t)be32x((uint32_t)h->u.cmd_submit.interval, send);
        break;
    case USBIP_RET_SUBMIT:
        h->u.ret_submit.status = (int32_t)be32x((uint32_t)h->u.ret_submit.status, send);
        h->u.ret_submit.actual_length = (int32_t)be32x((uint32_t)h->u.ret_submit.actual_length, send);
        h->u.ret_submit.start_frame = (int32_t)be32x((uint32_t)h->u.ret_submit.start_frame, send);
        h->u.ret_submit.number_of_packets = (int32_t)be32x((uint32_t)h->u.ret_submit.number_of_packets, send);
        h->u.ret_submit.error_count = (int32_t)be32x((uint32_t)h->u.ret_submit.error_count, send);
        break;
    case USBIP_CMD_UNLINK:
        h->u.cmd_unlink.seqnum = be32x(h->u.cmd_unlink.seqnum, send);
        break;
    case USBIP_RET_UNLINK:
        h->u.ret_unlink.status = (int32_t)be32x((uint32_t)h->u.ret_unlink.status, send);
        break;
    }
}

/* ---------- Inferno link ---------- */
typedef struct {
    int fd;
    pthread_mutex_t wlock;
    uint8_t addr; /* SET_ADDRESS tracking, like usb-tcp-remote */
} InfernoLink;

static bool inf_send_req(InfernoLink *L, int pid, uint8_t ep, uint64_t id,
                         const void *data, uint16_t len, uint8_t short_not_ok)
{
    tcp_usb_header_t hdr = { .type = TCP_USB_REQUEST };
    tcp_usb_request_header req = { 0 };
    req.addr = L->addr;
    req.pid = pid;
    req.ep = ep;
    req.id = id;
    req.short_not_ok = short_not_ok;
    req.length = len;

    pthread_mutex_lock(&L->wlock);
    bool ok = write_full(L->fd, &hdr, sizeof(hdr))
           && write_full(L->fd, &req, sizeof(req))
           && (len == 0 || pid == USB_TOKEN_IN || write_full(L->fd, data, len));
    pthread_mutex_unlock(&L->wlock);
    return ok;
}

static bool inf_send_cancel(InfernoLink *L, int pid, uint8_t ep, uint64_t id)
{
    tcp_usb_header_t hdr = { .type = TCP_USB_CANCEL };
    tcp_usb_cancel_header c = { .addr = L->addr, .pid = pid, .ep = ep, .id = id };
    pthread_mutex_lock(&L->wlock);
    bool ok = write_full(L->fd, &hdr, sizeof(hdr)) && write_full(L->fd, &c, sizeof(c));
    pthread_mutex_unlock(&L->wlock);
    return ok;
}

static bool inf_send_reset(InfernoLink *L)
{
    tcp_usb_header_t hdr = { .type = TCP_USB_RESET };
    L->addr = 0;
    pthread_mutex_lock(&L->wlock);
    bool ok = write_full(L->fd, &hdr, sizeof(hdr));
    pthread_mutex_unlock(&L->wlock);
    return ok;
}

/* ---------- pending USBIP submits ---------- */
typedef struct Pending {
    uint32_t seqnum;
    uint32_t direction;
    uint32_t ep;
    int32_t  buflen;
    uint32_t transfer_flags;
    unsigned char setup[8];
    bool is_ctrl;
    bool cancelled;
    /* Inferno side */
    int pid;           /* current/outstanding Inferno pid */
    uint64_t inf_id;   /* Inferno packet id (== seqnum) */
    enum { ST_SETUP, ST_DATA, ST_STATUS, ST_DONE } stage;
    void *out_data;    /* OUT payload (malloc'd) */
    void *in_data;     /* IN payload collected */
    int32_t actual;
    int qemu_status;   /* last non-NAK status */
    struct Pending *next;
} Pending;

static pthread_mutex_t g_plock = PTHREAD_MUTEX_INITIALIZER;
static Pending *g_pending;
static InfernoLink g_link = { .fd = -1 };
static int g_vhci_fd = -1; /* socketpair end we keep */
static int g_vhci_port = -1;
static volatile int g_stop;

static Pending *pend_find(uint32_t seq)
{
    for (Pending *p = g_pending; p; p = p->next)
        if (p->seqnum == seq) return p;
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

/* map QEMU USB_RET_* -> Linux URB status (negative errno) */
static int32_t qemu_to_urb(int st)
{
    switch (st) {
    case USB_RET_SUCCESS: return 0;
    case USB_RET_STALL:   return -32;  /* EPIPE */
    case USB_RET_BABBLE:  return -75;  /* EOVERFLOW */
    case USB_RET_NODEV:   return -19;  /* ENODEV */
    case USB_RET_IOERROR: return -71;  /* EPROTO */
    case USB_RET_NAK:     return -11;  /* EAGAIN - should not reach here */
    default:              return -71;
    }
}

static bool usbip_send_ret_submit(int fd, uint32_t seq, uint32_t devid,
                                  uint32_t dir, uint32_t ep,
                                  int32_t status, int32_t actual,
                                  const void *data)
{
    struct usbip_header h;
    memset(&h, 0, sizeof(h));
    h.base.command = USBIP_RET_SUBMIT;
    h.base.seqnum = seq;
    h.base.devid = devid;
    h.base.direction = dir;
    h.base.ep = ep;
    h.u.ret_submit.status = status;
    h.u.ret_submit.actual_length = actual;
    h.u.ret_submit.start_frame = 0;
    h.u.ret_submit.number_of_packets = 0;
    h.u.ret_submit.error_count = 0;
    usbip_hdr_endian(&h, 1);
    if (!write_full(fd, &h, sizeof(h))) return false;
    /* IN data follows the header when actual > 0 */
    if (dir == USBIP_DIR_IN && actual > 0 && data)
        return write_full(fd, data, (size_t)actual);
    return true;
}

static bool usbip_send_ret_unlink(int fd, uint32_t seq, uint32_t devid, int32_t status)
{
    struct usbip_header h;
    memset(&h, 0, sizeof(h));
    h.base.command = USBIP_RET_UNLINK;
    h.base.seqnum = seq;
    h.base.devid = devid;
    h.u.ret_unlink.status = status;
    usbip_hdr_endian(&h, 1);
    return write_full(fd, &h, sizeof(h));
}

/* complete a pending submit toward VHCI */
static void complete_pending(Pending *p, int qemu_status)
{
    if (p->cancelled) {
        pend_remove(p);
        pend_free(p);
        return;
    }
    int32_t urb = qemu_to_urb(qemu_status);
    int32_t actual = (qemu_status == USB_RET_SUCCESS) ? p->actual : 0;
    DBG("RET_SUBMIT seq=%u status=%d actual=%d", p->seqnum, urb, actual);
    usbip_send_ret_submit(g_vhci_fd, p->seqnum, g_devid, p->direction, p->ep,
                          urb, actual, p->in_data);
    pend_remove(p);
    pend_free(p);
}

/* advance / start Inferno transaction for a pending URB */
static bool kick_pending(Pending *p)
{
    if (p->cancelled) return true;

    if (!p->is_ctrl) {
        int pid = (p->direction == USBIP_DIR_IN) ? USB_TOKEN_IN : USB_TOKEN_OUT;
        p->pid = pid;
        p->inf_id = p->seqnum;
        p->stage = ST_DATA;
        uint16_t len = (uint16_t)(p->buflen > 0 ? p->buflen : 0);
        uint8_t sno = (p->transfer_flags & URB_SHORT_NOT_OK) ? 1 : 0;
        return inf_send_req(&g_link, pid, (uint8_t)p->ep, p->inf_id,
                            p->out_data, (pid == USB_TOKEN_OUT) ? len : len, sno);
    }

    /* control: SETUP -> DATA? -> STATUS */
    if (p->stage == ST_SETUP || p->stage == 0) {
        p->stage = ST_SETUP;
        p->pid = USB_TOKEN_SETUP;
        p->inf_id = ((uint64_t)p->seqnum << 2) | 0;
        /* SET_ADDRESS: mirror usb-tcp-remote */
        if (p->setup[0] == 0 && p->setup[1] == USB_REQ_SET_ADDRESS) {
            g_link.addr = (uint8_t)(p->setup[2] | (p->setup[3] << 8));
            DBG("SET_ADDRESS -> %u", g_link.addr);
        }
        return inf_send_req(&g_link, USB_TOKEN_SETUP, 0, p->inf_id, p->setup, 8, 0);
    }
    return true;
}

static bool ctrl_next_after_setup(Pending *p)
{
    uint16_t wlen = (uint16_t)(p->setup[6] | (p->setup[7] << 8));
    uint8_t bm = p->setup[0];
    bool in = (bm & 0x80) != 0;

    if (wlen > 0) {
        p->stage = ST_DATA;
        if (in) {
            p->pid = USB_TOKEN_IN;
            p->inf_id = ((uint64_t)p->seqnum << 2) | 1;
            if (!p->in_data) p->in_data = calloc(1, wlen);
            return inf_send_req(&g_link, USB_TOKEN_IN, 0, p->inf_id, NULL, wlen, 0);
        } else {
            p->pid = USB_TOKEN_OUT;
            p->inf_id = ((uint64_t)p->seqnum << 2) | 1;
            uint16_t n = (uint16_t)((p->buflen < wlen) ? p->buflen : wlen);
            return inf_send_req(&g_link, USB_TOKEN_OUT, 0, p->inf_id, p->out_data, n, 0);
        }
    }
    /* no data: status is IN (for host-to-device) or OUT (device-to-host) - with no data, status is IN */
    p->stage = ST_STATUS;
    p->pid = USB_TOKEN_IN;
    p->inf_id = ((uint64_t)p->seqnum << 2) | 2;
    return inf_send_req(&g_link, USB_TOKEN_IN, 0, p->inf_id, NULL, 0, 0);
}

static bool ctrl_next_after_data(Pending *p)
{
    uint8_t bm = p->setup[0];
    bool in = (bm & 0x80) != 0;
    /* status stage opposite direction of data, length 0 */
    p->stage = ST_STATUS;
    p->pid = in ? USB_TOKEN_OUT : USB_TOKEN_IN;
    p->inf_id = ((uint64_t)p->seqnum << 2) | 2;
    return inf_send_req(&g_link, p->pid, 0, p->inf_id, NULL, 0, 0);
}

static void msleep(int ms)
{
    struct timespec ts = { .tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}

/* handle one Inferno RESPONSE */
static void on_inferno_response(const tcp_usb_response_header *r, void *payload)
{
    pthread_mutex_lock(&g_plock);
    Pending *p = NULL;
    for (Pending *x = g_pending; x; x = x->next) {
        if (x->inf_id == r->id && x->pid == r->pid && x->ep == r->ep) { p = x; break; }
        /* also match by seq for non-ctrl */
        if (!x->is_ctrl && x->seqnum == (uint32_t)r->id) { p = x; break; }
        if (x->is_ctrl && (x->seqnum == (uint32_t)(r->id >> 2))) { p = x; break; }
    }
    if (!p) {
        DBG("orphan RESPONSE id=%" PRIu64 " pid=0x%x status=%u", r->id, r->pid, r->status);
        pthread_mutex_unlock(&g_plock);
        free(payload);
        return;
    }
    if (p->cancelled) {
        if ((int)r->status == USB_RET_REMOVE_FROM_QUEUE) {
            /* cancel ack */
        }
        pthread_mutex_unlock(&g_plock);
        free(payload);
        return;
    }

    int st = (int)r->status;
    if (st == USB_RET_NAK || st == USB_RET_ASYNC) {
        /* re-poll shortly; keep URB pending */
        pthread_mutex_unlock(&g_plock);
        free(payload);
        msleep(NAK_RETRY_MS);
        pthread_mutex_lock(&g_plock);
        if (!p->cancelled)
            inf_send_req(&g_link, p->pid, (uint8_t)p->ep, p->inf_id,
                         (p->pid == USB_TOKEN_OUT) ? p->out_data : NULL,
                         (p->pid == USB_TOKEN_IN) ? (uint16_t)(p->buflen > 0 ? p->buflen :
                             (p->is_ctrl ? (p->setup[6] | (p->setup[7] << 8)) : 0)) : 0,
                         0);
        pthread_mutex_unlock(&g_plock);
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

    /* SUCCESS */
    if (p->is_ctrl) {
        if (p->stage == ST_SETUP) {
            if (!ctrl_next_after_setup(p)) LOG("ctrl after SETUP send failed");
            pthread_mutex_unlock(&g_plock);
            free(payload);
            return;
        }
        if (p->stage == ST_DATA) {
            if (p->pid == USB_TOKEN_IN && payload && r->length) {
                memcpy(p->in_data, payload, r->length);
                p->actual = r->length;
            } else if (p->pid == USB_TOKEN_OUT) {
                p->actual = r->length;
            }
            if (!ctrl_next_after_data(p)) LOG("ctrl after DATA send failed");
            pthread_mutex_unlock(&g_plock);
            free(payload);
            return;
        }
        if (p->stage == ST_STATUS) {
            complete_pending(p, USB_RET_SUCCESS);
            pthread_mutex_unlock(&g_plock);
            free(payload);
            return;
        }
    } else {
        if (p->direction == USBIP_DIR_IN && payload && r->length) {
            p->in_data = realloc(p->in_data, r->length);
            memcpy(p->in_data, payload, r->length);
            p->actual = r->length;
        } else {
            p->actual = r->length;
        }
        complete_pending(p, USB_RET_SUCCESS);
    }
    pthread_mutex_unlock(&g_plock);
    free(payload);
}

static void *inferno_reader(void *arg)
{
    (void)arg;
    for (;;) {
        if (g_stop || g_link.fd < 0) break;
        tcp_usb_header_t hdr;
        ssize_t n = read_full(g_link.fd, &hdr, sizeof(hdr));
        if (n <= 0) { LOG("Inferno link closed"); g_stop = 1; break; }
        if (hdr.type == TCP_USB_RESPONSE) {
            tcp_usb_response_header r;
            if (read_full(g_link.fd, &r, sizeof(r)) != (ssize_t)sizeof(r)) {
                LOG("short RESPONSE header"); g_stop = 1; break;
            }
            void *payload = NULL;
            if (r.length > 0 && r.pid == USB_TOKEN_IN && (int)r.status != USB_RET_ASYNC) {
                payload = malloc(r.length);
                if (!payload || read_full(g_link.fd, payload, r.length) != (ssize_t)r.length) {
                    free(payload); LOG("short RESPONSE payload"); g_stop = 1; break;
                }
            } else if (r.length > 0 && r.pid != USB_TOKEN_IN && (int)r.status != USB_RET_ASYNC) {
                /* OUT response has no payload on the wire from host side; length is actual */
            }
            on_inferno_response(&r, payload);
        } else if (hdr.type == TCP_USB_REQUEST || hdr.type == TCP_USB_CANCEL || hdr.type == TCP_USB_RESET) {
            LOG("unexpected Inferno type %u from iOS host - dropping link", hdr.type);
            g_stop = 1; break;
        } else {
            LOG("unknown Inferno type %u", hdr.type);
            g_stop = 1; break;
        }
    }
    return NULL;
}

/* ---------- VHCI attach ---------- */
static int find_free_vhci_port(void)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/status", g_vhci_path);
    FILE *f = fopen(path, "r");
    if (!f) {
        /* try status.0 */
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
            if (strcmp(hub, "hs") == 0 && sta == 4 /* VDEV_ST_NULL */) {
                port = (int)p;
                break;
            }
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
    if (w < 0) { LOG("attach write failed: %s (buf=%s)", strerror(err), buf); return -1; }
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

/* ---------- VHCI reader (USBIP commands) ---------- */
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
    p->out_data = out_buf; /* may be NULL for IN */
    p->stage = p->is_ctrl ? ST_SETUP : ST_DATA;

    pthread_mutex_lock(&g_plock);
    p->next = g_pending;
    g_pending = p;
    if (!kick_pending(p)) {
        LOG("kick_pending failed seq=%u", p->seqnum);
        complete_pending(p, USB_RET_IOERROR);
    }
    pthread_mutex_unlock(&g_plock);
}

static void handle_cmd_unlink(struct usbip_header *h)
{
    uint32_t victim = h->u.cmd_unlink.seqnum;
    pthread_mutex_lock(&g_plock);
    Pending *p = pend_find(victim);
    if (p) {
        p->cancelled = true;
        inf_send_cancel(&g_link, p->pid, (uint8_t)p->ep, p->inf_id);
    }
    pthread_mutex_unlock(&g_plock);
    /* unlink status: -ECONNRESET (104) if was pending */
    usbip_send_ret_unlink(g_vhci_fd, h->base.seqnum, g_devid, p ? -104 : 0);
    DBG("RET_UNLINK for seq %u (victim %u) %s", h->base.seqnum, victim, p ? "pending" : "miss");
}

static void *vhci_reader(void *arg)
{
    (void)arg;
    for (;;) {
        if (g_stop || g_vhci_fd < 0) break;
        struct usbip_header h;
        ssize_t n = read_full(g_vhci_fd, &h, sizeof(h));
        if (n <= 0) { LOG("VHCI socket closed"); g_stop = 1; break; }
        usbip_hdr_endian(&h, 0);
        if (h.base.command == USBIP_CMD_SUBMIT) {
            void *buf = NULL;
            int32_t len = h.u.cmd_submit.transfer_buffer_length;
            if (h.base.direction == USBIP_DIR_OUT && len > 0) {
                buf = malloc((size_t)len);
                if (!buf || read_full(g_vhci_fd, buf, (size_t)len) != len) {
                    free(buf); LOG("short OUT buffer"); g_stop = 1; break;
                }
            }
            DBG("CMD_SUBMIT seq=%u ep=%u dir=%u len=%d ctrl=%d",
                h.base.seqnum, h.base.ep, h.base.direction, len, h.base.ep == 0);
            handle_cmd_submit(&h, buf);
        } else if (h.base.command == USBIP_CMD_UNLINK) {
            DBG("CMD_UNLINK seq=%u unlink=%u", h.base.seqnum, h.u.cmd_unlink.seqnum);
            handle_cmd_unlink(&h);
        } else {
            LOG("unknown USBIP cmd %u", h.base.command);
            g_stop = 1; break;
        }
    }
    return NULL;
}

/* ---------- listen / accept ---------- */
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
}

static int run_session(int inf_fd)
{
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return -1; }

    g_stop = 0;
    g_link.fd = inf_fd;
    pthread_mutex_init(&g_link.wlock, NULL);
    g_link.addr = 0;
    g_vhci_fd = sv[0];

    if (vhci_attach(sv[1]) < 0) {
        close(sv[0]); close(sv[1]);
        g_vhci_fd = -1;
        return -1;
    }
    close(sv[1]); /* kernel holds a ref via sockfd_lookup */

    /* bus reset so iOS re-enumerates cleanly */
    inf_send_reset(&g_link);

    pthread_t t_inf, t_vhci;
    pthread_create(&t_inf, NULL, inferno_reader, NULL);
    pthread_create(&t_vhci, NULL, vhci_reader, NULL);

    while (!g_stop) sleep(1);

    pthread_join(t_inf, NULL);
    pthread_join(t_vhci, NULL);
    cleanup_session();
    return 0;
}

static void usage(const char *a)
{
    fprintf(stderr,
        "Usage: %s [-s unix.sock] [-V vhci_sysfs_dir] [-d devid] [-S speed] [-v]\n"
        "  listens for Inferno hcd-tcp, attaches the device to vhci_hcd.\n", a);
}

int main(int argc, char **argv)
{
    int opt;
    while ((opt = getopt(argc, argv, "s:V:d:S:vh")) != -1) {
        switch (opt) {
        case 's': g_listen_path = optarg; break;
        case 'V': g_vhci_path = optarg; break;
        case 'd': g_devid = strtoul(optarg, NULL, 0); break;
        case 'S': g_speed = atoi(optarg); break;
        case 'v': g_verbose = 1; break;
        default: usage(argv[0]); return 2;
        }
    }
    signal(SIGPIPE, SIG_IGN);

    char attach[512];
    snprintf(attach, sizeof(attach), "%s/attach", g_vhci_path);
    if (access(attach, W_OK) != 0) {
        LOG("VHCI not available (%s): %s", attach, strerror(errno));
        LOG("flash the Larry kernel with USBIP/VHCI built-in, or use the companion VM fallback");
        return 3;
    }

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
        LOG("session ended - listening again");
    }
    close(lfd);
    unlink(g_listen_path);
    return 0;
}
