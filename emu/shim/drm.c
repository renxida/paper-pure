// Fake KMS device standing in for the i.MX93 LCDIF that drives the e-ink
// panel. SWTCON (xochitl's software timing controller) talks atomic KMS to it
// and scans out waveform phase frames; we accept those, pace page-flip events
// at the panel refresh rate, and otherwise ignore the phase data — the real
// pixels are captured upstream in fb.c.
#include "common.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <pthread.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <libdrm/drm.h>
#include <libdrm/drm_mode.h>
#include <libdrm/drm_fourcc.h>

void (*drm_on_flip)(void);

enum { CRTC = 31, ENC = 32, CONN = 33, PLANE = 34 };
enum {
    P_ACTIVE = 1, P_MODE_ID, P_OUT_FENCE,
    P_FB_ID = 10, P_CRTC_ID, P_SRC_X, P_SRC_Y, P_SRC_W, P_SRC_H, P_CRTC_X, P_CRTC_Y, P_CRTC_W, P_CRTC_H, P_TYPE,
    P_CONN_CRTC_ID = 30, P_DPMS,
};

static const struct { uint32_t id; const char *name; uint32_t flags; } props[] = {
    { P_ACTIVE, "ACTIVE", DRM_MODE_PROP_RANGE }, { P_MODE_ID, "MODE_ID", DRM_MODE_PROP_BLOB },
    { P_OUT_FENCE, "OUT_FENCE_PTR", DRM_MODE_PROP_RANGE },
    { P_FB_ID, "FB_ID", DRM_MODE_PROP_OBJECT }, { P_CRTC_ID, "CRTC_ID", DRM_MODE_PROP_OBJECT },
    { P_SRC_X, "SRC_X", DRM_MODE_PROP_RANGE }, { P_SRC_Y, "SRC_Y", DRM_MODE_PROP_RANGE },
    { P_SRC_W, "SRC_W", DRM_MODE_PROP_RANGE }, { P_SRC_H, "SRC_H", DRM_MODE_PROP_RANGE },
    { P_CRTC_X, "CRTC_X", DRM_MODE_PROP_SIGNED_RANGE }, { P_CRTC_Y, "CRTC_Y", DRM_MODE_PROP_SIGNED_RANGE },
    { P_CRTC_W, "CRTC_W", DRM_MODE_PROP_RANGE }, { P_CRTC_H, "CRTC_H", DRM_MODE_PROP_RANGE },
    { P_TYPE, "type", DRM_MODE_PROP_ENUM | DRM_MODE_PROP_IMMUTABLE },
    { P_CONN_CRTC_ID, "CRTC_ID", DRM_MODE_PROP_OBJECT }, { P_DPMS, "DPMS", DRM_MODE_PROP_ENUM },
};
static const uint32_t crtc_props[] = { P_ACTIVE, P_MODE_ID, P_OUT_FENCE };
static const uint32_t plane_props[] = { P_FB_ID, P_CRTC_ID, P_SRC_X, P_SRC_Y, P_SRC_W, P_SRC_H,
                                        P_CRTC_X, P_CRTC_Y, P_CRTC_W, P_CRTC_H, P_TYPE };
static const uint32_t conn_props[] = { P_CONN_CRTC_ID, P_DPMS };

static int rd = -1, wr = -1, mem = -1;  // event pipe (rd is the fd xochitl sees) + buffer memory
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static off_t heap;

struct dumb { uint32_t w, h, bpp, pitch; uint64_t size, off; };
static struct dumb dumbs[128];
static int ndumbs;
struct fb { uint32_t handle, w, h, pitch, fmt; };
static struct fb fbs[256];  // index = fb id - 100
static uint32_t nfbs;
struct blob { void *data; uint32_t len; };
static struct blob blobs[64];  // index = blob id - 200
static uint32_t cur_fb, cur_mode_blob, plane_crtc, conn_crtc, crtc_active;
uint64_t drm_commits;
#define commits drm_commits
static struct timespec next_vsync;

static const double refresh_hz = 85.0;

static struct drm_mode_modeinfo panel_mode(void) {
    // SWTCON insists on this scanout geometry: each 32-bit "pixel" carries
    // packed waveform phases for several panel pixels. On the Pure (Carta
    // 1300, 1404x1872) it wants 260x1408; xochitl logs "DRM error: size
    // mismatch ... (expected 1408x260)" otherwise. Blanking is a guess.
    struct drm_mode_modeinfo m = {0};
    m.hdisplay = 260; m.vdisplay = 1408;
    m.hsync_start = 265; m.hsync_end = 270; m.htotal = 275;
    m.vsync_start = 1410; m.vsync_end = 1412; m.vtotal = 1414;
    m.vrefresh = 85;
    m.clock = (uint32_t)((uint64_t)m.htotal * m.vtotal * m.vrefresh / 1000);
    m.type = DRM_MODE_TYPE_PREFERRED | DRM_MODE_TYPE_DRIVER;
    snprintf(m.name, sizeof m.name, "%dx%d", m.hdisplay, m.vdisplay);
    return m;
}

int drm_open(void) {
    if (rd >= 0) return dup(rd);
    int p[2];
    if (pipe2(p, O_CLOEXEC)) return -1;
    rd = p[0]; wr = p[1];
    mem = memfd_create("rmemu-drm", MFD_CLOEXEC);
    clock_gettime(CLOCK_MONOTONIC, &next_vsync);
    TRACE("fake /dev/dri/card0 -> fd %d", rd);
    return rd;
}

int drm_is_fd(int fd) { return fd >= 0 && fd == rd; }

void *drm_mmap(void *addr, size_t len, int prot, int flags, off_t off) {
    return mmap(addr, len, prot, flags, mem, off);
}

static void put32(uint64_t ptr, uint32_t avail, uint32_t i, uint32_t v) {
    if (ptr && i < avail) ((uint32_t *)(uintptr_t)ptr)[i] = v;
}
static void put64(uint64_t ptr, uint32_t avail, uint32_t i, uint64_t v) {
    if (ptr && i < avail) ((uint64_t *)(uintptr_t)ptr)[i] = v;
}

static uint64_t prop_value(uint32_t obj, uint32_t prop) {
    switch (prop) {
    case P_ACTIVE: return crtc_active;
    case P_MODE_ID: return cur_mode_blob;
    case P_FB_ID: return cur_fb;
    case P_CRTC_ID: return obj == CONN ? conn_crtc : plane_crtc;
    case P_TYPE: return 1; /* DRM_PLANE_TYPE_PRIMARY */
    default: return 0;
    }
}

static void list_props(struct drm_mode_obj_get_properties *o, const uint32_t *ids, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        put32(o->props_ptr, o->count_props, i, ids[i]);
        put64(o->prop_values_ptr, o->count_props, i, prop_value(o->obj_id, ids[i]));
    }
    o->count_props = n;
}

static void ts_add(struct timespec *t, long ns) {
    t->tv_nsec += ns;
    while (t->tv_nsec >= 1000000000L) { t->tv_nsec -= 1000000000L; t->tv_sec++; }
}

// Block until the next simulated vblank, then queue a flip-complete event.
static void vblank(uint64_t user_data, int want_event) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long period = (long)(1e9 / refresh_hz);
    if (now.tv_sec > next_vsync.tv_sec + 1) next_vsync = now;
    ts_add(&next_vsync, period);
    clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next_vsync, NULL);
    if (drm_on_flip) drm_on_flip();
    if (!want_event) return;
    struct drm_event_vblank ev = {0};
    ev.base.type = DRM_EVENT_FLIP_COMPLETE;
    ev.base.length = sizeof ev;
    ev.user_data = user_data;
    ev.tv_sec = next_vsync.tv_sec;
    ev.tv_usec = next_vsync.tv_nsec / 1000;
    ev.sequence = (uint32_t)commits;
    ev.crtc_id = CRTC;
    if (write(wr, &ev, sizeof ev) != sizeof ev) LOG("drm event write failed");
}


// PROBE (temporary): analyze each scanned-out phase frame.
static void probe_frame(uint32_t fb_id) {
    static int on = -1;
    if (on < 0) on = getenv("RMEMU_PROBE") != NULL;
    if (!on || fb_id < 100 || fb_id - 100 >= nfbs) return;
    struct fb *f = &fbs[fb_id - 100];
    if (f->handle < 1 || f->handle > (uint32_t)ndumbs) return;
    struct dumb *d = &dumbs[f->handle - 1];
    const uint32_t *px = mmap(NULL, d->size, PROT_READ, MAP_SHARED, mem, d->off);
    if (px == MAP_FAILED) return;
    uint32_t x0 = 9999, y0 = 9999, x1 = 0, y1 = 0, hi = 0;
    uint32_t hist[8] = {0};
    for (uint32_t y = 0; y < f->h; y++) {
        const uint32_t *row = (const uint32_t *)((const char *)px + (size_t)y * f->pitch);
        for (uint32_t x = 0; x < f->w; x++) {
            uint32_t v = row[x];
            if (v >> 24) hi++;
            for (int b = 0; b < 8; b++) {
                uint32_t ph = (v >> (b * 3)) & 7;
                hist[ph]++;
                if (ph) { uint32_t X = x * 8 + b; if (X < x0) x0 = X; if (X > x1) x1 = X; if (y < y0) y0 = y; if (y > y1) y1 = y; }
            }
        }
    }
    munmap((void *)px, d->size);
    static char last[256]; static int reps; static uint64_t first;
    char cur[256];
    snprintf(cur, sizeof cur, "bbox=%u,%u-%u,%u hi=%u h=%u %u %u %u %u %u %u %u", x0, y0, x1, y1, hi, hist[0], hist[1], hist[2], hist[3], hist[4], hist[5], hist[6], hist[7]);
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    if (strcmp(cur, last)) {
        if (reps) LOG("probe   x%d", reps);
        LOG("probe #%llu t=%ld.%03ld %s", (unsigned long long)commits, (long)ts.tv_sec, ts.tv_nsec / 1000000, cur);
        strcpy(last, cur); reps = 0; first = commits;
    } else reps++;
    (void)first;
}

static int atomic(struct drm_mode_atomic *a) {
    uint32_t *objs = (uint32_t *)(uintptr_t)a->objs_ptr;
    uint32_t *counts = (uint32_t *)(uintptr_t)a->count_props_ptr;
    uint32_t *pids = (uint32_t *)(uintptr_t)a->props_ptr;
    uint64_t *vals = (uint64_t *)(uintptr_t)a->prop_values_ptr;
    if (a->flags & DRM_MODE_ATOMIC_TEST_ONLY) return 0;
    uint32_t k = 0;
    for (uint32_t i = 0; i < a->count_objs; i++) {
        for (uint32_t j = 0; j < counts[i]; j++, k++) {
            uint64_t v = vals[k];
            switch (pids[k]) {
            case P_ACTIVE: crtc_active = v; break;
            case P_MODE_ID:
                if (v != cur_mode_blob && v >= 200 && v < 264 && blobs[v - 200].len >= sizeof(struct drm_mode_modeinfo)) {
                    struct drm_mode_modeinfo *m = blobs[v - 200].data;
                    TRACE("drm mode %ux%u htotal=%u vtotal=%u clock=%u", m->hdisplay, m->vdisplay, m->htotal, m->vtotal, m->clock);
                }
                cur_mode_blob = v; break;
            case P_FB_ID:
                if (v && v != cur_fb && commits < 4 && v >= 100 && v - 100 < nfbs) {
                    struct fb *f = &fbs[v - 100];
                    TRACE("drm scanout fb %llu: %ux%u pitch=%u fmt=%.4s", (unsigned long long)v, f->w, f->h, f->pitch, (char *)&f->fmt);
                }
                cur_fb = v; break;
            case P_CRTC_ID: if (objs[i] == CONN) conn_crtc = v; else plane_crtc = v; break;
            }
        }
    }
    commits++;
    probe_frame(cur_fb);
    if (commits == 1 || !(commits % 5000)) TRACE("drm atomic commit #%llu flags=0x%x", (unsigned long long)commits, a->flags);
    vblank(a->user_data, a->flags & DRM_MODE_PAGE_FLIP_EVENT);
    return 0;
}

static int handle(unsigned long req, void *arg) {
    switch (req) {
    case DRM_IOCTL_VERSION: {
        struct drm_version *v = arg;
        v->version_major = 1; v->version_minor = 0; v->version_patchlevel = 0;
#define CP(f, s) do { size_t l = strlen(s); if (v->f && v->f##_len) memcpy(v->f, s, l < v->f##_len ? l : v->f##_len); v->f##_len = l; } while (0)
        CP(name, "mxsfb-drm"); CP(date, "20160401"); CP(desc, "i.MX LCDIF Controller DRM");
        return 0;
    }
    case DRM_IOCTL_GET_CAP: {
        struct drm_get_cap *c = arg;
        switch (c->capability) {
        case DRM_CAP_DUMB_BUFFER: case DRM_CAP_TIMESTAMP_MONOTONIC: case DRM_CAP_CRTC_IN_VBLANK_EVENT:
        case DRM_CAP_ADDFB2_MODIFIERS: c->value = 1; break;
        case DRM_CAP_DUMB_PREFERRED_DEPTH: c->value = 24; break;
        default: c->value = 0;
        }
        return 0;
    }
    case DRM_IOCTL_SET_CLIENT_CAP: case DRM_IOCTL_SET_MASTER: case DRM_IOCTL_DROP_MASTER:
    case DRM_IOCTL_MODE_RMFB: case DRM_IOCTL_MODE_DESTROY_DUMB: case DRM_IOCTL_MODE_DIRTYFB:
    case DRM_IOCTL_MODE_DESTROYPROPBLOB:
        return 0;
    case DRM_IOCTL_MODE_GETRESOURCES: {
        struct drm_mode_card_res *r = arg;
        put32(r->crtc_id_ptr, r->count_crtcs, 0, CRTC);
        put32(r->connector_id_ptr, r->count_connectors, 0, CONN);
        put32(r->encoder_id_ptr, r->count_encoders, 0, ENC);
        r->count_fbs = 0; r->count_crtcs = r->count_connectors = r->count_encoders = 1;
        r->min_width = r->min_height = 1; r->max_width = r->max_height = 8192;
        return 0;
    }
    case DRM_IOCTL_MODE_GETCONNECTOR: {
        struct drm_mode_get_connector *c = arg;
        struct drm_mode_modeinfo m = panel_mode();
        if (c->modes_ptr && c->count_modes >= 1) memcpy((void *)(uintptr_t)c->modes_ptr, &m, sizeof m);
        put32(c->encoders_ptr, c->count_encoders, 0, ENC);
        for (uint32_t i = 0; i < 2; i++) {
            put32(c->props_ptr, c->count_props, i, conn_props[i]);
            put64(c->prop_values_ptr, c->count_props, i, prop_value(CONN, conn_props[i]));
        }
        c->count_modes = 1; c->count_encoders = 1; c->count_props = 2;
        c->encoder_id = ENC; c->connector_type = DRM_MODE_CONNECTOR_DPI; c->connector_type_id = 1;
        c->connection = 1; c->mm_width = 156; c->mm_height = 209;  // 10.3" at 228 dpi
        return 0;
    }
    case DRM_IOCTL_MODE_GETENCODER: {
        struct drm_mode_get_encoder *e = arg;
        e->encoder_type = DRM_MODE_ENCODER_NONE; e->crtc_id = CRTC; e->possible_crtcs = 1; e->possible_clones = 0;
        return 0;
    }
    case DRM_IOCTL_MODE_GETCRTC: {
        struct drm_mode_crtc *c = arg;
        c->fb_id = cur_fb; c->x = c->y = 0; c->gamma_size = 0; c->mode_valid = 1; c->mode = panel_mode();
        return 0;
    }
    case DRM_IOCTL_MODE_SETCRTC: {
        struct drm_mode_crtc *c = arg;
        TRACE("drm SETCRTC fb=%u mode=%ux%u", c->fb_id, c->mode.hdisplay, c->mode.vdisplay);
        cur_fb = c->fb_id;
        return 0;
    }
    case DRM_IOCTL_MODE_GETPLANERESOURCES: {
        struct drm_mode_get_plane_res *p = arg;
        put32(p->plane_id_ptr, p->count_planes, 0, PLANE);
        p->count_planes = 1;
        return 0;
    }
    case DRM_IOCTL_MODE_GETPLANE: {
        struct drm_mode_get_plane *p = arg;
        static const uint32_t fmts[] = { DRM_FORMAT_XRGB8888, DRM_FORMAT_RGB565, DRM_FORMAT_C8, DRM_FORMAT_R8 };
        uint32_t n = sizeof fmts / sizeof *fmts;
        for (uint32_t i = 0; i < n; i++) put32(p->format_type_ptr, p->count_format_types, i, fmts[i]);
        p->count_format_types = n; p->crtc_id = plane_crtc; p->fb_id = cur_fb; p->possible_crtcs = 1;
        return 0;
    }
    case DRM_IOCTL_MODE_OBJ_GETPROPERTIES: {
        struct drm_mode_obj_get_properties *o = arg;
        switch (o->obj_id) {
        case CRTC: list_props(o, crtc_props, 3); return 0;
        case PLANE: list_props(o, plane_props, 11); return 0;
        case CONN: list_props(o, conn_props, 2); return 0;
        }
        o->count_props = 0;
        return 0;
    }
    case DRM_IOCTL_MODE_GETPROPERTY: {
        struct drm_mode_get_property *p = arg;
        for (size_t i = 0; i < sizeof props / sizeof *props; i++) {
            if (props[i].id != p->prop_id) continue;
            snprintf(p->name, sizeof p->name, "%s", props[i].name);
            p->flags = props[i].flags;
            if (p->prop_id == P_TYPE) {
                static const char *names[] = { "Overlay", "Primary", "Cursor" };
                struct drm_mode_property_enum *e = (void *)(uintptr_t)p->enum_blob_ptr;
                for (uint32_t j = 0; j < 3; j++) {
                    put64(p->values_ptr, p->count_values, j, j);
                    if (e && j < p->count_enum_blobs) { e[j].value = j; snprintf(e[j].name, sizeof e[j].name, "%s", names[j]); }
                }
                p->count_values = p->count_enum_blobs = 3;
            } else if (p->prop_id == P_DPMS) {
                static const char *names[] = { "On", "Standby", "Suspend", "Off" };
                struct drm_mode_property_enum *e = (void *)(uintptr_t)p->enum_blob_ptr;
                for (uint32_t j = 0; j < 4; j++) {
                    put64(p->values_ptr, p->count_values, j, j);
                    if (e && j < p->count_enum_blobs) { e[j].value = j; snprintf(e[j].name, sizeof e[j].name, "%s", names[j]); }
                }
                p->count_values = p->count_enum_blobs = 4;
            } else if (props[i].flags & (DRM_MODE_PROP_RANGE | DRM_MODE_PROP_SIGNED_RANGE)) {
                put64(p->values_ptr, p->count_values, 0, 0);
                put64(p->values_ptr, p->count_values, 1, UINT32_MAX);
                p->count_values = 2; p->count_enum_blobs = 0;
            } else if (props[i].flags & DRM_MODE_PROP_OBJECT) {
                put64(p->values_ptr, p->count_values, 0, p->prop_id == P_FB_ID ? DRM_MODE_OBJECT_FB : DRM_MODE_OBJECT_CRTC);
                p->count_values = 1; p->count_enum_blobs = 0;
            } else {
                p->count_values = p->count_enum_blobs = 0;
            }
            return 0;
        }
        errno = ENOENT;
        return -1;
    }
    case DRM_IOCTL_MODE_CREATEPROPBLOB: {
        struct drm_mode_create_blob *b = arg;
        for (uint32_t i = 0; i < 64; i++) {
            if (blobs[i].data) continue;
            blobs[i].data = malloc(b->length);
            memcpy(blobs[i].data, (void *)(uintptr_t)b->data, b->length);
            blobs[i].len = b->length;
            b->blob_id = 200 + i;
            return 0;
        }
        errno = ENOMEM;
        return -1;
    }
    case DRM_IOCTL_MODE_GETPROPBLOB: {
        struct drm_mode_get_blob *b = arg;
        if (b->blob_id < 200 || b->blob_id >= 264 || !blobs[b->blob_id - 200].data) { errno = ENOENT; return -1; }
        struct blob *bl = &blobs[b->blob_id - 200];
        if (b->data && b->length >= bl->len) memcpy((void *)(uintptr_t)b->data, bl->data, bl->len);
        b->length = bl->len;
        return 0;
    }
    case DRM_IOCTL_MODE_CREATE_DUMB: {
        struct drm_mode_create_dumb *d = arg;
        if (ndumbs >= 128) { errno = ENOMEM; return -1; }
        d->pitch = d->width * ((d->bpp + 7) / 8);
        d->size = (uint64_t)d->pitch * d->height;
        d->handle = ndumbs + 1;
        uint64_t off = (heap + 4095) & ~4095ULL;
        heap = off + ((d->size + 4095) & ~4095ULL);
        if (ftruncate(mem, heap)) LOG("ftruncate failed: %s", strerror(errno));
        dumbs[ndumbs++] = (struct dumb){ d->width, d->height, d->bpp, d->pitch, d->size, off };
        if (ndumbs <= 4) TRACE("drm CREATE_DUMB %ux%u bpp=%u -> handle %u", d->width, d->height, d->bpp, d->handle);
        return 0;
    }
    case DRM_IOCTL_MODE_MAP_DUMB: {
        struct drm_mode_map_dumb *m = arg;
        if (m->handle < 1 || m->handle > (uint32_t)ndumbs) { errno = EINVAL; return -1; }
        m->offset = dumbs[m->handle - 1].off;
        return 0;
    }
    case DRM_IOCTL_MODE_ADDFB: {
        struct drm_mode_fb_cmd *f = arg;
        if (nfbs >= 256) { errno = ENOMEM; return -1; }
        f->fb_id = 100 + nfbs;
        fbs[nfbs++] = (struct fb){ f->handle, f->width, f->height, f->pitch, f->bpp == 32 ? DRM_FORMAT_XRGB8888 : DRM_FORMAT_RGB565 };
        return 0;
    }
    case DRM_IOCTL_MODE_ADDFB2: {
        struct drm_mode_fb_cmd2 *f = arg;
        if (nfbs >= 256) { errno = ENOMEM; return -1; }
        f->fb_id = 100 + nfbs;
        fbs[nfbs++] = (struct fb){ f->handles[0], f->width, f->height, f->pitches[0], f->pixel_format };
        return 0;
    }
    case DRM_IOCTL_MODE_PAGE_FLIP: {
        struct drm_mode_crtc_page_flip *p = arg;
        cur_fb = p->fb_id;
        commits++;
        vblank(p->user_data, p->flags & DRM_MODE_PAGE_FLIP_EVENT);
        return 0;
    }
    case DRM_IOCTL_MODE_ATOMIC:
        return atomic(arg);
    case DRM_IOCTL_WAIT_VBLANK: {
        union drm_wait_vblank *w = arg;
        vblank(0, 0);
        w->reply.sequence = (uint32_t)commits;
        return 0;
    }
    default:
        LOG("drm UNHANDLED ioctl 0x%lx (nr=0x%lx)", req, req & 0xff);
        errno = EINVAL;
        return -1;
    }
}

int drm_ioctl(unsigned long req, void *arg) {
    // Commits block for vblank; don't hold the lock across that.
    if (req == DRM_IOCTL_MODE_ATOMIC || req == DRM_IOCTL_MODE_PAGE_FLIP || req == DRM_IOCTL_WAIT_VBLANK) return handle(req, arg);
    pthread_mutex_lock(&lock);
    int r = handle(req, arg);
    pthread_mutex_unlock(&lock);
    return r;
}
