// sd_device monitor stand-in. marker-manager (Marker docking) and libcslpower
// (charger plug/unplug) watch power_supply/i2c uevents through libsystemd's
// sd_device_monitor; there's no udev netlink traffic in a container, so the
// monitors subscribe to rmemud instead, which sends uevents when the host
// docks the Marker or plugs in USB.
#include "common.h"
#include "devices.h"
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

typedef struct sd_event sd_event;
typedef struct sd_event_source sd_event_source;
typedef int (*monitor_handler)(void *m, void *dev, void *userdata);

struct monitor {
    int fd;
    sd_event *event;
    sd_event_source *src;
    monitor_handler handler;
    void *userdata;
    char subsystems[4][32];
    int nsub;
};

struct fake_device {
    const char *subsystem, *sysname;
    const char *props[32];
    int nprops;
};

// Fake devices only exist on the stack for the duration of a handler call.
static __thread const void *current;
static int is_fake(const void *d) { return d && d == current; }

int sd_device_monitor_new(void **ret) {
    struct monitor *m = calloc(1, sizeof *m);
    m->fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX, .sun_path = RMEMU_INPUT_SOCK };
    unsigned char sub[2] = { 'S', DEV_UEVENT };
    if (connect(m->fd, (struct sockaddr *)&a, sizeof a) || write(m->fd, sub, 2) != 2)
        TRACE("sd_device_monitor: rmemud unavailable, monitor will stay silent");
    *ret = m;
    return 0;
}

int sd_device_monitor_filter_add_match_subsystem_devtype(void *mp, const char *subsystem, const char *devtype) {
    (void)devtype;
    struct monitor *m = mp;
    if (subsystem && m->nsub < 4) snprintf(m->subsystems[m->nsub++], 32, "%s", subsystem);
    return 0;
}

int sd_device_monitor_attach_event(void *mp, sd_event *event) {
    struct monitor *m = mp;
    if (!event) {
        int (*def)(sd_event **) = dlsym(RTLD_DEFAULT, "sd_event_default");
        if (def) def(&event);
    }
    m->event = event;
    return 0;
}

int sd_device_monitor_detach_event(void *mp) {
    struct monitor *m = mp;
    sd_event_source *(*unref)(sd_event_source *) = dlsym(RTLD_DEFAULT, "sd_event_source_unref");
    if (m->src && unref) unref(m->src);
    m->src = NULL; m->event = NULL;
    return 0;
}

static int read_full(int fd, void *buf, size_t n) {
    char *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= (size_t)r;
    }
    return 0;
}

static int on_io(sd_event_source *s, int fd, uint32_t revents, void *userdata) {
    (void)s; (void)revents;
    struct monitor *m = userdata;
    uint16_t len;
    char buf[2048];
    if (read_full(fd, &len, 2) || len > sizeof buf - 1 || read_full(fd, buf, len)) {
        sd_device_monitor_detach_event(m);
        return 0;
    }
    buf[len] = 0;
    struct fake_device d = { 0 };
    char *p = buf, *end = buf + len;
    d.subsystem = p; p += strlen(p) + 1;
    d.sysname = p < end ? p : ""; p += strlen(p) + 1;
    while (p < end && d.nprops < 32) { d.props[d.nprops++] = p; p += strlen(p) + 1; }
    int match = !m->nsub;
    for (int i = 0; i < m->nsub; i++) match |= !strcmp(m->subsystems[i], d.subsystem);
    TRACE("uevent %s/%s -> %s", d.subsystem, d.sysname, match ? "delivered" : "filtered");
    if (match && m->handler) { current = &d; m->handler(m, &d, m->userdata); current = NULL; }
    return 0;
}

int sd_device_monitor_start(void *mp, monitor_handler handler, void *userdata) {
    struct monitor *m = mp;
    m->handler = handler; m->userdata = userdata;
    if (!m->event) sd_device_monitor_attach_event(m, NULL);
    int (*add_io)(sd_event *, sd_event_source **, int, uint32_t, void *, void *) = dlsym(RTLD_DEFAULT, "sd_event_add_io");
    if (!add_io || !m->event) return -ENOSYS;
    return add_io(m->event, &m->src, m->fd, 1 /* EPOLLIN */, (void *)on_io, m) < 0 ? -EIO : 0;
}

int sd_device_monitor_stop(void *mp) { return sd_device_monitor_detach_event(mp); }

void *sd_device_monitor_unref(void *mp) {
    struct monitor *m = mp;
    if (!m) return NULL;
    sd_device_monitor_detach_event(m);
    close(m->fd);
    free(m);
    return NULL;
}

// Accessors: answer for our fake devices, defer to libsystemd for real ones.
#define FORWARD(name, ...) do { static int (*real)(); if (!real) real = dlsym(RTLD_NEXT, name); return real ? real(__VA_ARGS__) : -ENOSYS; } while (0)

int sd_device_get_sysname(void *dev, const char **ret) {
    if (is_fake(dev)) { *ret = ((struct fake_device *)dev)->sysname; return 0; }
    FORWARD("sd_device_get_sysname", dev, ret);
}
int sd_device_get_subsystem(void *dev, const char **ret) {
    if (is_fake(dev)) { *ret = ((struct fake_device *)dev)->subsystem; return 0; }
    FORWARD("sd_device_get_subsystem", dev, ret);
}
int sd_device_get_property_value(void *dev, const char *key, const char **ret) {
    if (is_fake(dev)) {
        struct fake_device *d = dev;
        size_t kl = strlen(key);
        for (int i = 0; i < d->nprops; i++)
            if (!strncmp(d->props[i], key, kl) && d->props[i][kl] == '=') { *ret = d->props[i] + kl + 1; return 0; }
        return -ENOENT;
    }
    FORWARD("sd_device_get_property_value", dev, key, ret);
}
