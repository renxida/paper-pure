// Fake evdev devices for the pen digitizer, touchscreen, power key and hall
// sensor. Opening one hands out a Unix socket subscribed to rmemud, which
// streams input_event records to every reader in every process; the EVIOC*
// ioctls are answered here from the device descriptions and rmemud's shared
// key/switch state.
#include "common.h"
#include "devices.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define BIT(arr, n) ((arr)[(n) / 8] |= 1 << ((n) % 8))

struct dev {
    const char *name;
    struct input_id id;
    unsigned char ev[4], key[KEY_MAX / 8 + 1], abs[ABS_MAX / 8 + 1], sw[SW_MAX / 8 + 1], prop[INPUT_PROP_MAX / 8 + 1];
    struct input_absinfo absinfo[ABS_CNT];
};
static struct dev devs[NDEV];

static struct { int fd, dev; } open_fds[64];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void abs_axis(struct dev *d, int code, int min, int max, int res) {
    BIT(d->abs, code);
    d->absinfo[code] = (struct input_absinfo){ .minimum = min, .maximum = max, .resolution = res };
}

static void setup(void) {
    struct dev *d = &devs[DEV_PEN];
    d->name = "Elan marker input";
    d->id = (struct input_id){ BUS_I2C, 0x04f3, 0x2a3f, 1 };
    BIT(d->ev, EV_SYN); BIT(d->ev, EV_KEY); BIT(d->ev, EV_ABS); BIT(d->ev, EV_MSC);
    BIT(d->key, BTN_TOOL_PEN); BIT(d->key, BTN_TOOL_RUBBER); BIT(d->key, BTN_TOUCH);
    BIT(d->key, BTN_STYLUS); BIT(d->key, BTN_STYLUS2);
    abs_axis(d, ABS_X, 0, RMEMU_SCREEN_W * PEN_SCALE, 100);
    abs_axis(d, ABS_Y, 0, RMEMU_SCREEN_H * PEN_SCALE, 100);
    abs_axis(d, ABS_PRESSURE, 0, 4095, 0);
    abs_axis(d, ABS_DISTANCE, 0, 255, 0);
    abs_axis(d, ABS_TILT_X, -9000, 9000, 0);
    abs_axis(d, ABS_TILT_Y, -9000, 9000, 0);
    BIT(d->prop, INPUT_PROP_DIRECT);

    d = &devs[DEV_TOUCH];
    d->name = "Elan touchscreen";
    d->id = (struct input_id){ BUS_I2C, 0x04f3, 0x2a40, 1 };
    BIT(d->ev, EV_SYN); BIT(d->ev, EV_KEY); BIT(d->ev, EV_ABS);
    BIT(d->key, BTN_TOUCH);
    abs_axis(d, ABS_X, 0, RMEMU_SCREEN_W - 1, 0);
    abs_axis(d, ABS_Y, 0, RMEMU_SCREEN_H - 1, 0);
    abs_axis(d, ABS_MT_SLOT, 0, 9, 0);
    abs_axis(d, ABS_MT_TRACKING_ID, 0, 65535, 0);
    abs_axis(d, ABS_MT_POSITION_X, 0, RMEMU_SCREEN_W - 1, 0);
    abs_axis(d, ABS_MT_POSITION_Y, 0, RMEMU_SCREEN_H - 1, 0);
    abs_axis(d, ABS_MT_PRESSURE, 0, 255, 0);
    abs_axis(d, ABS_MT_TOUCH_MAJOR, 0, 255, 0);
    BIT(d->prop, INPUT_PROP_DIRECT);

    d = &devs[DEV_BUTTONS];
    d->name = "30370000.snvs:snvs-powerkey";
    d->id = (struct input_id){ BUS_HOST, 0, 0, 0 };
    BIT(d->ev, EV_SYN); BIT(d->ev, EV_KEY);
    BIT(d->key, KEY_POWER);

    d = &devs[DEV_HALL];
    d->name = "gpio-hall-sensors";
    d->id = (struct input_id){ BUS_HOST, 0, 0, 0 };
    BIT(d->ev, EV_SYN); BIT(d->ev, EV_SW);
    BIT(d->sw, SW_LID); BIT(d->sw, SW_TABLET_MODE); BIT(d->sw, SW_PEN_INSERTED);

    for (int i = 0; i < 64; i++) open_fds[i].fd = -1;
}

static void init_once(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, setup);
}

static int dev_for_path(const char *path) {
    if (!strcmp(path, "/dev/input/by-path/platform-gpio-hall-sensors-event")) return DEV_HALL;
    for (int i = 0; i < NDEV; i++) if (!strcmp(path, dev_path(i))) return i;
    return -1;
}

static const struct shared_state *shared(void) {
    static const struct shared_state *st;
    if (st) return st;
    REAL(open);
    int fd = real_open(RMEMU_STATE_FILE, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NULL;
    void *p = mmap(NULL, sizeof *st, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p != MAP_FAILED) st = p;
    return st;
}

int input_open(const char *path, int flags) {
    init_once();
    int dev = dev_for_path(path);
    if (dev < 0) return -2;  // not ours
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = { .sun_family = AF_UNIX, .sun_path = RMEMU_INPUT_SOCK };
    unsigned char sub[2] = { 'S', (unsigned char)dev };
    if (fd < 0 || connect(fd, (struct sockaddr *)&a, sizeof a) || write(fd, sub, 2) != 2) {
        if (fd >= 0) close(fd);
        TRACE("input: %s unavailable (is rmemud running?)", path);
        errno = ENODEV;
        return -1;
    }
    if (flags & O_NONBLOCK) fcntl(fd, F_SETFL, O_NONBLOCK);
    pthread_mutex_lock(&lock);
    for (int i = 0; i < 64; i++) if (open_fds[i].fd < 0) { open_fds[i].fd = fd; open_fds[i].dev = dev; break; }
    pthread_mutex_unlock(&lock);
    TRACE("input: opened %s (%s) -> fd %d", path, devs[dev].name, fd);
    return fd;
}

static int dev_of(int fd) {
    if (fd < 0) return -1;
    for (int i = 0; i < 64; i++) if (open_fds[i].fd == fd) return open_fds[i].dev;
    return -1;
}

int input_is_fd(int fd) { return dev_of(fd) >= 0; }

void input_close(int fd) {
    pthread_mutex_lock(&lock);
    for (int i = 0; i < 64; i++) if (open_fds[i].fd == fd) open_fds[i].fd = -1;
    pthread_mutex_unlock(&lock);
}

static int copy_bits(void *arg, unsigned len, const void *bits, size_t n) {
    size_t c = len < n ? len : n;
    memset(arg, 0, len);
    memcpy(arg, bits, c);
    return (int)c;
}

int input_ioctl(int fd, unsigned long req, void *arg) {
    int dev = dev_of(fd);
    if (dev < 0) { errno = EBADF; return -1; }
    struct dev *d = &devs[dev];
    unsigned len = _IOC_SIZE(req), nr = _IOC_NR(req);
    if (_IOC_TYPE(req) != 'E') { errno = ENOTTY; return -1; }
    if (req == EVIOCGVERSION) { *(int *)arg = EV_VERSION; return 0; }
    if (req == EVIOCGID) { *(struct input_id *)arg = d->id; return 0; }
    // Timestamps are always CLOCK_REALTIME (the kernel default).
    if (req == EVIOCGRAB || req == EVIOCSCLOCKID || req == EVIOCGREP || req == EVIOCSREP) return 0;
    if (_IOC_DIR(req) == _IOC_READ) {
        const struct shared_state *st = shared();
        static const unsigned char zero[KEY_MAX / 8 + 1];
        if (nr == _IOC_NR(EVIOCGNAME(0))) return copy_bits(arg, len, d->name, strlen(d->name) + 1);
        if (nr == _IOC_NR(EVIOCGPHYS(0))) return copy_bits(arg, len, "rmemu", 6);
        if (nr == _IOC_NR(EVIOCGUNIQ(0))) return copy_bits(arg, len, "", 1);
        if (nr == _IOC_NR(EVIOCGPROP(0))) return copy_bits(arg, len, d->prop, sizeof d->prop);
        if (nr == _IOC_NR(EVIOCGKEY(0))) return copy_bits(arg, len, st ? st->key[dev] : zero, KEY_MAX / 8 + 1);
        if (nr == _IOC_NR(EVIOCGSW(0))) return copy_bits(arg, len, st ? st->sw[dev] : zero, SW_MAX / 8 + 1);
        if (nr == _IOC_NR(EVIOCGLED(0)) || nr == _IOC_NR(EVIOCGSND(0))) { memset(arg, 0, len); return 0; }
        if (nr >= _IOC_NR(EVIOCGBIT(0, 0)) && nr <= _IOC_NR(EVIOCGBIT(EV_MAX, 0))) {
            switch (nr - _IOC_NR(EVIOCGBIT(0, 0))) {
            case 0: return copy_bits(arg, len, d->ev, sizeof d->ev);
            case EV_KEY: return copy_bits(arg, len, d->key, sizeof d->key);
            case EV_ABS: return copy_bits(arg, len, d->abs, sizeof d->abs);
            case EV_SW: return copy_bits(arg, len, d->sw, sizeof d->sw);
            default: memset(arg, 0, len); return 0;
            }
        }
        if (nr >= _IOC_NR(EVIOCGABS(0)) && nr <= _IOC_NR(EVIOCGABS(ABS_MAX))) {
            *(struct input_absinfo *)arg = d->absinfo[nr - _IOC_NR(EVIOCGABS(0))];
            return 0;
        }
        if (nr == _IOC_NR(EVIOCGMTSLOTS(0))) { memset(arg, 0, len); return 0; }
    }
    TRACE("input: unhandled ioctl 0x%lx on %s", req, d->name);
    return 0;
}

// For the fake udev: describe device i. Returns 0 when out of range.
int input_dev_info(int i, const char **devnode, const char **name, const char **kind) {
    init_once();
    if (i < 0 || i >= NDEV) return 0;
    static const char *const kinds[NDEV] = { "key", "tablet", "touchscreen", "switch" };
    *devnode = dev_path(i); *name = devs[i].name; *kind = kinds[i];
    return 1;
}
