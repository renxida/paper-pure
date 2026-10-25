// Framebuffer capture: grab the QImage xochitl renders the screen into and
// push dirty rectangles to rmemud, which relays them to the host.
//
// Display socket protocol (little-endian), shim -> rmemud:
//   hello: "RMFB" u16 width u16 height
//   rect:  'F' u16 x u16 y u16 w u16 h u32 zlen, zlib(RGBA rows)
//   activity: 'A'  (the panel is being driven; sent at most every 100ms)
// rmemud -> shim: 'R' = resend the whole screen (a new viewer joined).
#include "common.h"
#include "devices.h"
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <zlib.h>

#define W RMEMU_SCREEN_W
#define H RMEMU_SCREEN_H
#define TILE 52  // divides both 1404 and 1872

// xochitl's screen image. The Pure's Carta 1300 backend renders RGB32 like
// the Paper Pro, but also creates a full-screen Grayscale8 QImage that stays
// empty here. RMEMU_FB_FORMAT=<QImage::Format> picks which one to capture
// (default 4, RGB32; 0 = the last full-screen image of any known format), so
// keep raw bytes and convert per pixel on the way out.
static const unsigned char *screen;
static long screen_bpl;
static int screen_fmt, screen_bpp;
static unsigned char *shadow;   // raw bytes rmemud last got (W * bpp per row)
static volatile int poke;       // set on display activity; makes the scanner look now
// The screen memory is SWTCON's and is freed when xochitl exits. The scanner
// only reads it under this lock (see free() below).
static pthread_mutex_t screen_lock = PTHREAD_MUTEX_INITIALIZER;

// QImage::Format values (Qt 6) we know how to read.
enum { F_RGB32 = 4, F_ARGB32 = 5, F_ARGB32P = 6, F_RGB16 = 7, F_RGBX8888 = 16, F_RGBA8888 = 17,
       F_RGBA8888P = 18, F_GRAY8 = 24, F_GRAY16 = 28 };
static int fmt_bpp(int fmt) {
    switch (fmt) {
    case F_RGB32: case F_ARGB32: case F_ARGB32P: case F_RGBX8888: case F_RGBA8888: case F_RGBA8888P: return 4;
    case F_RGB16: case F_GRAY16: return 2;
    case F_GRAY8: return 1;
    default: return 0;
    }
}
static void to_rgba(const unsigned char *src, unsigned char *dst, int n) {
    for (int c = 0; c < n; c++, dst += 4) {
        unsigned r, g, b;
        switch (screen_fmt) {
        case F_RGB16: { uint16_t v = ((const uint16_t *)src)[c]; r = (v >> 11) * 255 / 31; g = ((v >> 5) & 63) * 255 / 63; b = (v & 31) * 255 / 31; break; }
        case F_GRAY16: r = g = b = ((const uint16_t *)src)[c] >> 8; break;
        case F_GRAY8: r = g = b = src[c]; break;
        case F_RGBX8888: case F_RGBA8888: case F_RGBA8888P: r = src[c * 4]; g = src[c * 4 + 1]; b = src[c * 4 + 2]; break;
        default: { uint32_t px = ((const uint32_t *)src)[c]; r = (px >> 16) & 255; g = (px >> 8) & 255; b = px & 255; }
        }
        dst[0] = r; dst[1] = g; dst[2] = b; dst[3] = 255;
    }
}

static int send_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w <= 0) return -1;
        p += w; n -= (size_t)w;
    }
    return 0;
}

static int send_rect(int fd, int x, int y, int w, int h) {
    size_t raw_len = (size_t)w * h * 4;
    unsigned char *raw = malloc(raw_len);
    for (int r = 0; r < h; r++) {
        const unsigned char *src = screen + (long)(y + r) * screen_bpl + (long)x * screen_bpp;
        to_rgba(src, raw + (size_t)r * w * 4, w);
        memcpy(shadow + ((size_t)(y + r) * W + x) * screen_bpp, src, (size_t)w * screen_bpp);
    }
    uLongf zlen = compressBound(raw_len);
    unsigned char *msg = malloc(13 + zlen);
    int rc = -1;
    if (compress2(msg + 13, &zlen, raw, raw_len, 1) == Z_OK) {
        msg[0] = 'F';
        uint16_t hdr[4] = { (uint16_t)x, (uint16_t)y, (uint16_t)w, (uint16_t)h };
        memcpy(msg + 1, hdr, 8);
        uint32_t zl = (uint32_t)zlen;
        memcpy(msg + 9, &zl, 4);
        rc = send_all(fd, msg, 13 + zlen);
    }
    free(raw); free(msg);
    return rc;
}

static int tile_dirty(int tx, int ty) {
    for (int r = 0; r < TILE; r++) {
        int y = ty * TILE + r;
        const unsigned char *src = screen + (long)y * screen_bpl + (long)tx * TILE * screen_bpp;
        if (memcmp(src, shadow + ((size_t)y * W + tx * TILE) * screen_bpp, (size_t)TILE * screen_bpp)) return 1;
    }
    return 0;
}

// Send each horizontal band of dirty tiles as one rect spanning its dirty columns.
static int scan(int fd) {
    for (int ty = 0; ty < H / TILE; ty++) {
        int x0 = -1, x1 = -1;
        for (int tx = 0; tx < W / TILE; tx++)
            if (tile_dirty(tx, ty)) { if (x0 < 0) x0 = tx; x1 = tx; }
        if (x0 >= 0 && send_rect(fd, x0 * TILE, ty * TILE, (x1 - x0 + 1) * TILE, TILE)) return -1;
    }
    return 0;
}

static int connect_display(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX, .sun_path = RMEMU_DISPLAY_SOCK };
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a)) { if (fd >= 0) close(fd); return -1; }
    unsigned char hello[8] = { 'R', 'M', 'F', 'B' };
    uint16_t dims[2] = { W, H };
    memcpy(hello + 4, dims, 4);
    if (send_all(fd, hello, sizeof hello) || send_rect(fd, 0, 0, W, H)) { close(fd); return -1; }
    LOG("fb: connected to rmemud");
    return fd;
}

extern uint64_t drm_commits;

// One scan step: keep the host's copy of the screen current. Returns -1 to
// drop the connection. Called with screen_lock held.
static int scan_step(int fd, int *idle, int *quiet_ticks, int *busy_ticks, uint64_t *seen) {
    // Poll ~60Hz right after display activity, ~4Hz otherwise; wake early on 'R'.
    struct pollfd p = { fd, POLLIN, 0 };
    if (poll(&p, 1, 16) > 0) {
        char c;
        if (recv(fd, &c, 1, 0) <= 0) return -1;
        if (c == 'R' && send_rect(fd, 0, 0, W, H)) return -1;
    }
    if (poke) { poke = 0; *idle = 0; }
    // Waveforms keep running after the image changes; tell the host so
    // "wait until idle" covers the whole refresh.
    if (drm_commits != *seen && ++*quiet_ticks >= 6) {
        *seen = drm_commits; *quiet_ticks = 0;
        if (send_all(fd, "A", 1)) return -1;
    }
    // xochitl's main thread computing (building a page) counts as activity too.
    if (main_thread_busy(200) && ++*busy_ticks >= 6) {
        *busy_ticks = 0;
        if (send_all(fd, "A", 1)) return -1;
    }
    if ((*idle)++ > 30 && *idle % 15) return 0;
    return scan(fd);
}

static void *scanner(void *arg) {
    (void)arg;
    int fd = -1, idle = 0, quiet_ticks = 0, busy_ticks = 0;
    uint64_t seen = 0;
    for (;;) {
        pthread_mutex_lock(&screen_lock);
        // xochitl destroyed its screen image (it is exiting): hands off.
        if (!screen) { pthread_mutex_unlock(&screen_lock); sleep(1); continue; }
        if (fd < 0) fd = connect_display();
        if (fd >= 0 && scan_step(fd, &idle, &quiet_ticks, &busy_ticks, &seen)) { close(fd); fd = -1; }
        pthread_mutex_unlock(&screen_lock);
        if (fd < 0) sleep(1);
    }
    return NULL;
}

static void on_flip(void) { poke = 1; }

static void found_screen(const void *data, long bpl, int fmt) {
    if (!shadow) shadow = calloc((size_t)W * H, 4);
    pthread_mutex_lock(&screen_lock);
    screen_fmt = fmt; screen_bpp = fmt_bpp(fmt); screen_bpl = bpl; screen = data;
    pthread_mutex_unlock(&screen_lock);
    LOG("fb: captured screen buffer %p (%dx%d bpl %ld format %d)", data, W, H, bpl, fmt);
    static int started;
    if (started++) return;
    drm_on_flip = on_flip;
    pthread_t th;
    pthread_create(&th, NULL, scanner, NULL);
}

// xochitl's epaper renderer paints the whole UI into a full-screen QImage
// wrapped around SWTCON-owned memory; SWTCON diffs it into waveform phases.
// Grab it as it's constructed. (Other full-screen QImages, e.g. the boot
// splash pixmap, are transient.)
void _ZN6QImageC1EPhiixNS_6FormatEPFvPvES2_(void *self, unsigned char *data, int w, int h, long long bpl, int fmt,
                                             void (*cleanup)(void *), void *info) {
    static void (*real)(void *, unsigned char *, int, int, long long, int, void (*)(void *), void *);
    if (!real) real = dlsym(RTLD_NEXT, "_ZN6QImageC1EPhiixNS_6FormatEPFvPvES2_");
    real(self, data, w, h, bpl, fmt, cleanup, info);
    if (w >= 1000 && h >= 1000) TRACE("fb: QImage(data) %dx%d bpl=%lld fmt=%d", w, h, bpl, fmt);
    static int pick = -1;
    if (pick < 0) pick = getenv("RMEMU_FB_FORMAT") ? atoi(getenv("RMEMU_FB_FORMAT")) : 4;
    if (w == W && h == H && fmt_bpp(fmt) && (!pick || fmt == pick)) found_screen(data, (long)bpl, fmt);
}

// SWTCON mallocs the screen buffer and frees it when xochitl exits. Let the
// scanner go first, or it reads freed memory and xochitl segfaults on stop
// (about one stop in three under qemu; then OnFailure= reboots the "tablet").
extern void __libc_free(void *);
void free(void *p) {
    if (p && p == screen) {
        pthread_mutex_lock(&screen_lock);
        if (p == screen) screen = NULL;
        pthread_mutex_unlock(&screen_lock);
        TRACE("fb: screen buffer freed, scanner lets go");
    }
    __libc_free(p);
}

void fb_init(void) {}
