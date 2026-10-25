// Stand-in for the lis2dw12 accelerometer's orientation events. Only
// libcslorientation uses libiio, so we interpose the handful of libiio v1
// calls it makes instead of faking an IIO sysfs tree. The event stream
// blocks on a pipe that orientation_inject() writes to.
#include "common.h"
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

struct iio_event { uint64_t id; int64_t timestamp; };
static int fake_ctx, fake_dev, fake_chan, fake_attr, fake_stream;
static int evpipe[2] = { -1, -1 };
static bool enabled;

void *iio_create_context(const void *params, const char *uri) {
    (void)params; (void)uri;
    if (evpipe[0] < 0 && pipe2(evpipe, O_CLOEXEC)) return (void *)(intptr_t)-errno;
    return &fake_ctx;
}
void iio_context_destroy(void *ctx) { (void)ctx; }
void *iio_context_find_device(const void *ctx, const char *name) {
    (void)ctx;
    return name && !strcmp(name, "lis2dw12_orientation") ? &fake_dev : NULL;
}
void *iio_device_find_channel(const void *dev, const char *name, bool output) {
    (void)dev; (void)output;
    return name && !strcmp(name, "rot0") ? &fake_chan : NULL;
}
const void *iio_channel_find_attr(const void *chn, const char *name) { (void)chn; (void)name; return &fake_attr; }
const char *iio_channel_get_id(const void *chn) { (void)chn; return "rot0"; }
int iio_attr_read_bool(const void *attr, bool *val) { (void)attr; *val = enabled; return 0; }
int iio_attr_write_bool(const void *attr, bool val) { (void)attr; enabled = val; LOG("iio: orientation events %s", val ? "on" : "off"); return 0; }
void *iio_device_create_event_stream(const void *dev) { (void)dev; return &fake_stream; }
void iio_event_stream_destroy(void *s) { (void)s; }
const void *iio_event_get_channel(const struct iio_event *ev, const void *dev, bool diff) { (void)ev; (void)dev; (void)diff; return &fake_chan; }

int iio_event_stream_read(void *s, struct iio_event *out, bool nonblock) {
    (void)s;
    if (nonblock) return -EAGAIN;
    ssize_t n = read(evpipe[0], out, sizeof *out);
    return n == sizeof *out ? 0 : -EINTR;
}

// Event id layout is not reverse engineered yet; host-side rotation will use this.
void orientation_inject(uint64_t id) {
    struct iio_event ev = { id, 0 };
    if (evpipe[1] >= 0 && write(evpipe[1], &ev, sizeof ev) < 0) LOG("iio: inject failed");
}
