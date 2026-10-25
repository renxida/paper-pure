// rmemud: the emulated device's hardware hub, running inside the container.
//
//  - TCP :8888 for host clients (the rmemu server): sends the screen, takes input.
//  - display.sock: xochitl's shim pushes screen rects here; relayed to every client.
//  - input.sock: every process that opens a fake /dev/input/event* subscribes here
//    and receives input_event streams; key/switch state is published in a shared
//    file for EVIOCGKEY/EVIOCGSW.
//  - Marker docking also updates the fake NFC/battery sysfs nodes.
//
// Host input record (16 bytes, little-endian):
//   u8 type, u8 flags, u16 pressure, i32 x, i32 y, i16 tilt_x, i16 tilt_y
//   x/y are in 1/8 units: screen coordinates (portrait 1404x1872, origin
//   top-left) for pen/touch, the code or value below for the others.
//   'P' pen:    flags bit0 in range, bit1 touching, bit2 eraser, bit3 side button
//   'T' touch:  flags low nibble = slot, bit4 down, bit5 more contacts follow (defer SYN)
//   'K' key:    x = key code, flags bit0 = pressed
//   'S' switch: x = switch code, flags bit0 = value
//   'M' marker: flags bit0 = docked (magnetically attached and charging)
//   'C' charger: flags bit0 = USB power connected
//   'B' battery: x = charge percent
#define _GNU_SOURCE  // accept4
#include "../shim/devices.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define LOG(...) do { fprintf(stderr, "[rmemud] " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define MAXC 64
#define FAKE_SYS "/opt/rmemu/root/sys"

enum { C_FREE, C_HOST, C_DISPLAY, C_READER, C_PENDING };
struct conn {
    int fd, kind, dev;
    unsigned char *buf; size_t len, cap;  // inbound bytes not yet parsed
};
static struct conn conns[MAXC];
static struct shared_state *state;

// ---------------------------------------------------------------- plumbing

static int listen_unix(const char *path) {
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX };
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 16)) { LOG("cannot listen on %s: %s", path, strerror(errno)); exit(1); }
    chmod(path, 0666);
    return fd;
}

static int listen_tcp(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = INADDR_ANY };
    if (bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 8)) { LOG("cannot listen on :%d: %s", port, strerror(errno)); exit(1); }
    return fd;
}

static struct conn *add_conn(int fd, int kind) {
    for (int i = 0; i < MAXC; i++)
        if (conns[i].kind == C_FREE) { conns[i] = (struct conn){ .fd = fd, .kind = kind, .dev = -1 }; return &conns[i]; }
    close(fd);
    return NULL;
}

static void drop(struct conn *c) {
    if (c->kind == C_DISPLAY) LOG("display disconnected");
    close(c->fd); free(c->buf);
    *c = (struct conn){ .kind = C_FREE };
}

static int send_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}

static struct conn *display(void) {
    for (int i = 0; i < MAXC; i++) if (conns[i].kind == C_DISPLAY) return &conns[i];
    return NULL;
}

static void host_hello(struct conn *c) {
    unsigned char hello[8] = { 'R', 'M', 'F', 'B' };
    uint16_t dims[2] = { RMEMU_SCREEN_W, RMEMU_SCREEN_H };
    memcpy(hello + 4, dims, 4);
    if (send_all(c->fd, hello, sizeof hello)) { drop(c); return; }
    struct conn *d = display();
    if (d && send_all(d->fd, "R", 1)) drop(d);  // ask the shim for a full frame
}

// ---------------------------------------------------------------- input

static struct input_event batch[NDEV][64];
static int nbatch[NDEV];

static void emit(int dev, int type, int code, int value) {
    if (nbatch[dev] < 64) batch[dev][nbatch[dev]++] = (struct input_event){ .type = type, .code = code, .value = value };
}

// Readers that don't load the shim (static binaries, e.g. pp-agent's
// triple-press watcher) can't see the fake devices through it. For them each
// device is also a FIFO at its /dev/input path, fed the same events while
// someone has it open.
static int fifo_fd[NDEV] = { -1, -1, -1, -1 };
static void fifo_send(int dev, const void *buf, size_t n) {
    if (fifo_fd[dev] < 0) fifo_fd[dev] = open(dev_path(dev), O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fifo_fd[dev] < 0) return;  // nobody reading
    if (write(fifo_fd[dev], buf, n) < 0 && errno != EAGAIN) { close(fifo_fd[dev]); fifo_fd[dev] = -1; }
}

static void flush(int dev) {
    emit(dev, EV_SYN, SYN_REPORT, 0);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    for (int i = 0; i < nbatch[dev]; i++) batch[dev][i].time = tv;
    size_t n = sizeof batch[dev][0] * nbatch[dev];
    fifo_send(dev, batch[dev], n);
    for (int i = 0; i < MAXC; i++) {
        struct conn *c = &conns[i];
        if (c->kind != C_READER || c->dev != dev) continue;
        // Readers that stop reading lose events, like a full evdev buffer.
        ssize_t w = send(c->fd, batch[dev], n, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (w < 0 && errno != EAGAIN) drop(c);
    }
    nbatch[dev] = 0;
}

static int bit(const unsigned char *a, int n) { return (a[n / 8] >> (n % 8)) & 1; }
static void set_bit(unsigned char *a, int n, int v) { if (v) a[n / 8] |= 1 << (n % 8); else a[n / 8] &= ~(1 << (n % 8)); }

static void key(int dev, int code, int down) {
    if (bit(state->key[dev], code) == !!down) return;
    set_bit(state->key[dev], code, down);
    emit(dev, EV_KEY, code, !!down);
}

static void sw(int dev, int code, int v) {
    set_bit(state->sw[dev], code, v);
    emit(dev, EV_SW, code, !!v);
}

static void write_fake(const char *rel, const char *val) {
    char path[256];
    snprintf(path, sizeof path, FAKE_SYS "%s", rel);
    FILE *f = fopen(path, "w");
    if (f) { fputs(val, f); fputc('\n', f); fclose(f); }
}

// Broadcast a uevent to sd_device monitors: subsystem, sysname, NULL-terminated KEY=VALUE list.
static void uevent(const char *subsystem, const char *sysname, const char *const *props) {
    char msg[2048];
    size_t n = 2;
    n += (size_t)snprintf(msg + n, sizeof msg - n, "%s", subsystem) + 1;
    n += (size_t)snprintf(msg + n, sizeof msg - n, "%s", sysname) + 1;
    for (; *props && n < sizeof msg - 64; props++) n += (size_t)snprintf(msg + n, sizeof msg - n, "%s", *props) + 1;
    uint16_t len = (uint16_t)(n - 2);
    memcpy(msg, &len, 2);
    for (int i = 0; i < MAXC; i++)
        if (conns[i].kind == C_READER && conns[i].dev == DEV_UEVENT && send_all(conns[i].fd, msg, n)) drop(&conns[i]);
}

static int marker_capacity = 82;

static void marker_dock(int docked) {
    char cap[48];
    snprintf(cap, sizeof cap, "POWER_SUPPLY_CAPACITY=%d", marker_capacity);
    write_fake("/nfc/status/device_state", docked ? "DEVICE_DOCKED" : "DEVICE_UNDOCKED");
    write_fake("/class/power_supply/nfc-marker-battery/online", docked ? "1" : "0");
    write_fake("/class/power_supply/nfc-marker-battery/present", docked ? "1" : "0");
    write_fake("/class/power_supply/nfc-marker-battery/status", docked ? "Charging" : "Discharging");
    sw(DEV_HALL, SW_PEN_INSERTED, docked);
    flush(DEV_HALL);
    const char *const ps[] = { "ACTION=change", "POWER_SUPPLY_NAME=nfc-marker-battery", "POWER_SUPPLY_TYPE=Battery",
                               docked ? "POWER_SUPPLY_ONLINE=1" : "POWER_SUPPLY_ONLINE=0",
                               docked ? "POWER_SUPPLY_PRESENT=1" : "POWER_SUPPLY_PRESENT=0",
                               docked ? "POWER_SUPPLY_STATUS=Charging" : "POWER_SUPPLY_STATUS=Discharging", cap,
                               "POWER_SUPPLY_CAPACITY_LEVEL=Normal", "POWER_SUPPLY_SERIAL_NUMBER=RM0000EMU0001", NULL };
    uevent("power_supply", "nfc-marker-battery", ps);
    const char *const i2c[] = { "ACTION=change", docked ? "DEVICE_STATE=DEVICE_DOCKED" : "DEVICE_STATE=DEVICE_UNDOCKED", NULL };
    uevent("i2c", "nfc", i2c);
    LOG("marker %s", docked ? "docked" : "undocked");
}

static int battery = 85, plugged;

static void power_update(void) {
    // The Pure's libcslpower reads the MAX77818 fuel gauge and charger (the
    // Paper Pro's max1726x/max77963 names don't exist here). marker-manager
    // is shared with the Paper Pro and still looks at max77963-charger/online,
    // so mirror the plug state there too.
    char cap[16];
    snprintf(cap, sizeof cap, "%d", battery);
    write_fake("/class/power_supply/max77818_battery/capacity", cap);
    write_fake("/class/power_supply/max77818_battery/status", plugged ? (battery >= 100 ? "Full" : "Charging") : "Discharging");
    write_fake("/class/power_supply/max77818_battery/current_now", plugged ? "900000" : "-150000");
    write_fake("/class/power_supply/max77818-charger/online", plugged ? "1" : "0");
    write_fake("/class/power_supply/max77818-charger/status", plugged ? "Charging" : "Not charging");
    write_fake("/class/power_supply/max77963-charger/online", plugged ? "1" : "0");
    const char *const ch[] = { "ACTION=change", "POWER_SUPPLY_NAME=max77818-charger", plugged ? "POWER_SUPPLY_ONLINE=1" : "POWER_SUPPLY_ONLINE=0", NULL };
    uevent("power_supply", "max77818-charger", ch);
    char capp[48];
    snprintf(capp, sizeof capp, "POWER_SUPPLY_CAPACITY=%d", battery);
    const char *const bat[] = { "ACTION=change", "POWER_SUPPLY_NAME=max77818_battery", capp, NULL };
    uevent("power_supply", "max77818_battery", bat);
    LOG("power: battery %d%%, usb %s", battery, plugged ? "connected" : "disconnected");
}

static int slot_ids[16], next_tracking = 1;

static void handle_record(const unsigned char rec[16]) {
    struct { uint8_t type, flags; uint16_t pressure; int32_t x, y; int16_t tx, ty; } __attribute__((packed)) r;
    memcpy(&r, rec, 16);
    switch (r.type) {
    case 'P': {
        int in_range = r.flags & 1, touching = r.flags & 2, eraser = r.flags & 4;
        if (in_range) {
            emit(DEV_PEN, EV_ABS, ABS_X, r.x * PEN_SCALE / 8);
            emit(DEV_PEN, EV_ABS, ABS_Y, r.y * PEN_SCALE / 8);
            emit(DEV_PEN, EV_ABS, ABS_PRESSURE, touching ? (r.pressure ? r.pressure : 2048) : 0);
            emit(DEV_PEN, EV_ABS, ABS_DISTANCE, touching ? 0 : 20);
            emit(DEV_PEN, EV_ABS, ABS_TILT_X, r.tx);
            emit(DEV_PEN, EV_ABS, ABS_TILT_Y, r.ty);
        }
        key(DEV_PEN, eraser ? BTN_TOOL_RUBBER : BTN_TOOL_PEN, in_range);
        if (!in_range) { key(DEV_PEN, BTN_TOOL_PEN, 0); key(DEV_PEN, BTN_TOOL_RUBBER, 0); }
        key(DEV_PEN, BTN_TOUCH, touching);
        key(DEV_PEN, BTN_STYLUS, r.flags & 8);
        flush(DEV_PEN);
        break;
    }
    case 'T': {
        int slot = r.flags & 15, down = r.flags & 16, more = r.flags & 32;
        emit(DEV_TOUCH, EV_ABS, ABS_MT_SLOT, slot);
        if (down) {
            if (!slot_ids[slot]) { slot_ids[slot] = next_tracking++ & 0xffff; emit(DEV_TOUCH, EV_ABS, ABS_MT_TRACKING_ID, slot_ids[slot]); }
            emit(DEV_TOUCH, EV_ABS, ABS_MT_POSITION_X, r.x / 8);
            emit(DEV_TOUCH, EV_ABS, ABS_MT_POSITION_Y, r.y / 8);
            emit(DEV_TOUCH, EV_ABS, ABS_MT_PRESSURE, 64);
            emit(DEV_TOUCH, EV_ABS, ABS_MT_TOUCH_MAJOR, 16);
        } else if (slot_ids[slot]) {
            slot_ids[slot] = 0;
            emit(DEV_TOUCH, EV_ABS, ABS_MT_TRACKING_ID, -1);
        }
        if (!more) {
            int any = 0;
            for (int i = 0; i < 16; i++) any |= slot_ids[i];
            key(DEV_TOUCH, BTN_TOUCH, any);
            flush(DEV_TOUCH);
        }
        break;
    }
    case 'K':
        if (r.x / 8 > 0 && r.x / 8 <= KEY_MAX) key(DEV_BUTTONS, r.x / 8, r.flags & 1);
        flush(DEV_BUTTONS);
        break;
    case 'S':
        if (r.x / 8 >= 0 && r.x / 8 <= SW_MAX) { sw(DEV_HALL, r.x / 8, r.flags & 1); flush(DEV_HALL); }
        break;
    case 'M':
        marker_dock(r.flags & 1);
        break;
    case 'C':
        plugged = r.flags & 1;
        power_update();
        break;
    case 'B':
        battery = r.x / 8 < 0 ? 0 : r.x / 8 > 100 ? 100 : r.x / 8;
        power_update();
        break;
    default:
        LOG("unknown record type %d", r.type);
    }
}

// ---------------------------------------------------------------- main loop

static void on_readable(struct conn *c) {
    if (c->cap - c->len < 65536) { c->cap = c->cap * 2 + 65536; c->buf = realloc(c->buf, c->cap); }
    ssize_t n = recv(c->fd, c->buf + c->len, c->cap - c->len, 0);
    if (n <= 0) { drop(c); return; }
    c->len += (size_t)n;
    size_t off = 0;
    switch (c->kind) {
    case C_HOST:
        for (; c->len - off >= 16; off += 16) handle_record(c->buf + off);
        break;
    case C_PENDING:  // first bytes decide: 'S' dev = input reader, "RMFB" = display
        if (c->len >= 2 && c->buf[0] == 'S') {
            c->kind = C_READER; c->dev = c->buf[1] < NDEV || c->buf[1] == DEV_UEVENT ? c->buf[1] : 0;
            off = c->len;
        } else if (c->len >= 8 && !memcmp(c->buf, "RMFB", 4)) {
            struct conn *old = display();
            if (old && old != c) drop(old);
            c->kind = C_DISPLAY; off = 8;
            LOG("display connected");
            goto display_data;
        }
        break;
    case C_READER:
        off = c->len;  // readers have nothing more to say
        break;
    case C_DISPLAY:
    display_data:
        // Relay complete 'F' rects and 'A' activity pings to every host client.
        while (c->len - off >= 1 && c->buf[off] == 'A') {
            for (int i = 0; i < MAXC; i++)
                if (conns[i].kind == C_HOST && send_all(conns[i].fd, "A", 1)) drop(&conns[i]);
            off++;
        }
        while (c->len - off >= 13) {
            if (c->buf[off] == 'A') { off++; continue; }
            uint32_t zlen;
            memcpy(&zlen, c->buf + off + 9, 4);
            if (c->len - off < 13 + (size_t)zlen) break;
            for (int i = 0; i < MAXC; i++)
                if (conns[i].kind == C_HOST && send_all(conns[i].fd, c->buf + off, 13 + zlen)) drop(&conns[i]);
            off += 13 + zlen;
        }
        break;
    }
    memmove(c->buf, c->buf + off, c->len - off);
    c->len -= off;
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    mkdir(RMEMU_RUN, 0755);
    mkdir("/dev/input", 0755);
    for (int i = 0; i < NDEV; i++) { unlink(dev_path(i)); mkfifo(dev_path(i), 0660); }

    int sfd = open(RMEMU_STATE_FILE, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (sfd < 0 || ftruncate(sfd, sizeof *state)) { LOG("cannot create %s", RMEMU_STATE_FILE); return 1; }
    state = mmap(NULL, sizeof *state, PROT_READ | PROT_WRITE, MAP_SHARED, sfd, 0);
    state->magic = RMEMU_STATE_MAGIC;
    marker_dock(0);

    int tcp = listen_tcp(8888);
    int ui = listen_unix(RMEMU_INPUT_SOCK), ud = listen_unix(RMEMU_DISPLAY_SOCK);
    LOG("ready (tcp :8888, %s, %s)", RMEMU_INPUT_SOCK, RMEMU_DISPLAY_SOCK);

    for (;;) {
        struct pollfd p[MAXC + 3];
        struct conn *who[MAXC + 3];
        int n = 0;
        p[n] = (struct pollfd){ tcp, POLLIN, 0 }; who[n++] = NULL;
        p[n] = (struct pollfd){ ui, POLLIN, 0 }; who[n++] = NULL;
        p[n] = (struct pollfd){ ud, POLLIN, 0 }; who[n++] = NULL;
        for (int i = 0; i < MAXC; i++)
            if (conns[i].kind != C_FREE) { p[n] = (struct pollfd){ conns[i].fd, POLLIN, 0 }; who[n++] = &conns[i]; }
        if (poll(p, n, -1) < 0) continue;
        for (int i = 0; i < 3; i++) {
            if (!(p[i].revents & POLLIN)) continue;
            int fd = accept4(p[i].fd, NULL, NULL, SOCK_CLOEXEC);
            if (fd < 0) continue;
            if (i == 0) {
                int one = 1;
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                struct conn *c = add_conn(fd, C_HOST);
                if (c) host_hello(c);
            } else {
                add_conn(fd, C_PENDING);
            }
        }
        for (int i = 3; i < n; i++)
            if (p[i].revents & (POLLIN | POLLHUP | POLLERR) && who[i]->kind != C_FREE && who[i]->fd == p[i].fd) on_readable(who[i]);
    }
}
