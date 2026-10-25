// libc interposition: routes hardware paths to fakes (DRM, sysfs tree) and
// logs device access so missing hardware shows up in the container log.
#include "common.h"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <pthread.h>
#include <sched.h>
#include <sys/timerfd.h>
#include <time.h>
#include <signal.h>

int rmemu_debug;
static const char *fakeroot = "/opt/rmemu/root";
// systemd itself (PID 1, and its systemd-* daemons) needs none of this: the
// fake tree is also bind-mounted at the real /sys paths. Nor do rmemud,
// which feeds the real /dev/input FIFOs, and rmemu-wifi. Faking for them
// breaks them: PID 1 aborts when realpath() answers outside /sys, logind
// crashes on a fake device monitor. Leave them alone.
int rmemu_off;

static int hw_path(const char *p) {
    return !rmemu_off && p && (!strncmp(p, "/dev/", 5) || !strncmp(p, "/sys/", 5) || !strncmp(p, "/proc/device-tree", 17));
}

// Redirect hardware paths into the fake tree when a fake file exists there.
static const char *redirect(const char *path, char *buf, size_t n) {
    if (!hw_path(path)) return path;
    snprintf(buf, n, "%s%s", fakeroot, path);
    static int (*real_faccessat)(int, const char *, int, int);
    if (!real_faccessat) real_faccessat = dlsym(RTLD_NEXT, "faccessat");
    return real_faccessat(AT_FDCWD, buf, F_OK, 0) == 0 ? buf : path;
}

static int do_open(int dirfd, const char *path, int flags, mode_t mode) {
    if (hw_path(path) && !strcmp(path, "/dev/dri/card0")) return drm_open();
    if (hw_path(path) && !strncmp(path, "/dev/input/", 11)) {
        int fd = input_open(path, flags);
        if (fd != -2) return fd;
    }
    char buf[512];
    const char *p = redirect(path, buf, sizeof buf);
    REAL(openat);
    int fd = real_openat(dirfd, p, flags, mode);
    if (hw_path(path)) TRACE("open %s%s -> %d%s", path, p != path ? " (fake)" : "", fd, fd < 0 ? " FAIL" : "");
    return fd;
}

#define MODE_ARG mode_t mode = 0; if (flags & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
int open(const char *path, int flags, ...) { MODE_ARG; return do_open(AT_FDCWD, path, flags, mode); }
int open64(const char *path, int flags, ...) { MODE_ARG; return do_open(AT_FDCWD, path, flags, mode); }
int __open_2(const char *path, int flags) { return do_open(AT_FDCWD, path, flags, 0); }
int __open64_2(const char *path, int flags) { return do_open(AT_FDCWD, path, flags, 0); }
int openat(int dirfd, const char *path, int flags, ...) { MODE_ARG; return do_open(dirfd, path, flags, mode); }
int openat64(int dirfd, const char *path, int flags, ...) { MODE_ARG; return do_open(dirfd, path, flags, mode); }

FILE *fopen(const char *path, const char *m) {
    REAL(fopen);
    char buf[512];
    const char *p = redirect(path, buf, sizeof buf);
    FILE *f = real_fopen(p, m);
    if (hw_path(path)) TRACE("fopen %s%s -> %s", path, p != path ? " (fake)" : "", f ? "ok" : "FAIL");
    return f;
}
FILE *fopen64(const char *path, const char *m) { return fopen(path, m); }

// busybox hexdump (and anything else using freopen) must see the fakes too.
FILE *freopen(const char *path, const char *m, FILE *s) {
    REAL(freopen);
    char buf[512];
    const char *p = redirect(path, buf, sizeof buf);
    FILE *f = real_freopen(p, m, s);
    if (hw_path(path)) TRACE("freopen %s%s -> %s", path, p != path ? " (fake)" : "", f ? "ok" : "FAIL");
    return f;
}
FILE *freopen64(const char *path, const char *m, FILE *s) { return freopen(path, m, s); }

DIR *opendir(const char *path) {
    REAL(opendir);
    char buf[512];
    const char *p = redirect(path, buf, sizeof buf);
    DIR *d = real_opendir(p);
    if (hw_path(path)) TRACE("opendir %s%s -> %s", path, p != path ? " (fake)" : "", d ? "ok" : "FAIL");
    return d;
}

// Path-taking calls that must see the same fake tree as open().
#define PATH_HOOK(ret, name, fail, params, args)                                        \
    ret name params {                                                                   \
        REAL(name);                                                                     \
        char buf[512];                                                                  \
        const char *orig = path;                                                        \
        path = redirect(path, buf, sizeof buf);                                         \
        ret r = real_##name args;                                                       \
        if (hw_path(orig)) TRACE(#name " %s%s -> %s", orig, path != orig ? " (fake)" : "", \
                               r == fail ? "FAIL" : "ok");                              \
        return r;                                                                       \
    }
PATH_HOOK(int, stat, -1, (const char *path, struct stat *st), (path, st))
PATH_HOOK(int, lstat, -1, (const char *path, struct stat *st), (path, st))
PATH_HOOK(int, stat64, -1, (const char *path, struct stat64 *st), (path, st))
PATH_HOOK(int, lstat64, -1, (const char *path, struct stat64 *st), (path, st))
PATH_HOOK(int, access, -1, (const char *path, int mode), (path, mode))
PATH_HOOK(ssize_t, readlink, -1, (const char *path, char *b, size_t n), (path, b, n))
PATH_HOOK(char *, realpath, NULL, (const char *path, char *resolved), (path, resolved))
PATH_HOOK(int, fstatat, -1, (int dirfd, const char *path, struct stat *st, int fl), (dirfd, path, st, fl))
PATH_HOOK(int, fstatat64, -1, (int dirfd, const char *path, struct stat64 *st, int fl), (dirfd, path, st, fl))
PATH_HOOK(int, faccessat, -1, (int dirfd, const char *path, int mode, int fl), (dirfd, path, mode, fl))
PATH_HOOK(int, statx, -1, (int dirfd, const char *path, int fl, unsigned mask, struct statx *st), (dirfd, path, fl, mask, st))

int ioctl(int fd, unsigned long req, ...) {
    va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
    if (drm_is_fd(fd)) return drm_ioctl(req, arg);
    if (input_is_fd(fd)) return input_ioctl(fd, req, arg);
    REAL(ioctl);
    return real_ioctl(fd, req, arg);
}

int close(int fd) {
    REAL(close);
    if (input_is_fd(fd)) input_close(fd);
    return real_close(fd);
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    if (drm_is_fd(fd)) return drm_mmap(addr, len, prot, flags, off);
    REAL(mmap);
    return real_mmap(addr, len, prot, flags, fd, off);
}
void *mmap64(void *addr, size_t len, int prot, int flags, int fd, off_t off) { return mmap(addr, len, prot, flags, fd, off); }

// SWTCON wants realtime priority for its vsync/framegen threads and reads it
// back to verify. A container can't grant that and timing here doesn't need
// it, so remember what was asked for and report it.
static struct { pthread_t t; int policy, prio; } fake_sched[32];
static pthread_mutex_t sched_lock = PTHREAD_MUTEX_INITIALIZER;

int pthread_setschedparam(pthread_t t, int policy, const struct sched_param *p) {
    REAL(pthread_setschedparam);
    int r = real_pthread_setschedparam(t, policy, p);
    if (r != EPERM) return r;
    pthread_mutex_lock(&sched_lock);
    int i;
    for (i = 0; i < 32 && fake_sched[i].t && !pthread_equal(fake_sched[i].t, t); i++) ;
    if (i < 32) fake_sched[i].t = t, fake_sched[i].policy = policy, fake_sched[i].prio = p ? p->sched_priority : 0;
    pthread_mutex_unlock(&sched_lock);
    return 0;
}
int pthread_getschedparam(pthread_t t, int *policy, struct sched_param *p) {
    REAL(pthread_getschedparam);
    int r = real_pthread_getschedparam(t, policy, p);
    pthread_mutex_lock(&sched_lock);
    for (int i = 0; i < 32 && fake_sched[i].t; i++)
        if (pthread_equal(fake_sched[i].t, t)) { *policy = fake_sched[i].policy; p->sched_priority = fake_sched[i].prio; }
    pthread_mutex_unlock(&sched_lock);
    return r;
}
int sched_setscheduler(pid_t pid, int policy, const struct sched_param *p) {
    REAL(sched_setscheduler);
    int r = real_sched_setscheduler(pid, policy, p);
    if (r < 0 && errno == EPERM) { TRACE("sched_setscheduler faked"); errno = 0; r = 0; }
    return r;
}

// Wake-from-suspend alarm clocks need CAP_WAKE_ALARM (timerfd) and an RTC
// the host kernel can wake from (clock_gettime). Neither is a given in a
// container, and nothing suspends here, so the plain clock behaves the same.
// sd-event probes clock_gettime before it will add an alarm timer, so both
// calls fall back.
static clockid_t alarm_base(clockid_t c) {
    return c == CLOCK_REALTIME_ALARM ? CLOCK_REALTIME : c == CLOCK_BOOTTIME_ALARM ? CLOCK_BOOTTIME : c;
}
int timerfd_create(int clockid, int flags) {
    REAL(timerfd_create);
    int fd = real_timerfd_create(clockid, flags);
    if (fd < 0 && alarm_base(clockid) != clockid) {
        TRACE("timerfd_create: alarm clock %d -> plain clock", clockid);
        fd = real_timerfd_create(alarm_base(clockid), flags);
    }
    return fd;
}
int clock_gettime(clockid_t c, struct timespec *ts) {
    REAL(clock_gettime);
    int r = real_clock_gettime(c, ts);
    if (r < 0 && alarm_base(c) != c) r = real_clock_gettime(alarm_base(c), ts);
    return r;
}

// Main-thread busy tracking (see common.h). Qt's event loop sleeps in
// poll/ppoll; time spent outside it on the main thread is work.
#include <poll.h>
#include <sys/syscall.h>
static volatile int main_in_poll;  // busy from process start until the first poll
static volatile long long main_left_ns;
static long long now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000000000LL + t.tv_nsec;
}
static int is_main_thread(void) { return syscall(SYS_gettid) == getpid(); }
int main_thread_busy(long ms) { return !main_in_poll && now_ns() - main_left_ns > ms * 1000000LL; }
int poll(struct pollfd *fds, nfds_t n, int timeout) {
    REAL(poll);
    if (timeout == 0 || !is_main_thread()) return real_poll(fds, n, timeout);
    main_in_poll = 1;
    int r = real_poll(fds, n, timeout);
    main_left_ns = now_ns(); main_in_poll = 0;
    return r;
}
int ppoll(struct pollfd *fds, nfds_t n, const struct timespec *ts, const sigset_t *mask) {
    REAL(ppoll);
    if ((ts && !ts->tv_sec && !ts->tv_nsec) || !is_main_thread()) return real_ppoll(fds, n, ts, mask);
    main_in_poll = 1;
    int r = real_ppoll(fds, n, ts, mask);
    main_left_ns = now_ns(); main_in_poll = 0;
    return r;
}

// sd-event signal sources need the signal blocked first, and checks that it
// is. qemu-user (x86 hosts) can't map the top few guest realtime signals onto
// host signals, so blocking them silently does nothing and sd-event answers
// EBUSY; libcslpower's pre-autosleep signal is one of them and xochitl
// aborts. That signal comes from the suspend-event driver, which doesn't
// exist here, so listen on a spare signal qemu can map instead.
typedef struct sd_event sd_event;
typedef struct sd_event_source sd_event_source;
static int signal_blockable(int sig) {
    sigset_t ss, cur;
    sigemptyset(&ss); sigaddset(&ss, sig);
    pthread_sigmask(SIG_BLOCK, &ss, NULL);
    pthread_sigmask(SIG_SETMASK, NULL, &cur);
    return sigismember(&cur, sig) == 1;
}
int sd_event_add_signal(sd_event *e, sd_event_source **s, int sig, void *cb, void *ud) {
    REAL(sd_event_add_signal);
    if (!real_sd_event_add_signal) return -ENOSYS;
    int r = real_sd_event_add_signal(e, s, sig, cb, ud);
    int signo = sig & 0x7fffffff & ~(1 << 30);  // strip SD_EVENT_SIGNAL_PROCMASK
    if (r == -EBUSY && signo >= SIGRTMIN && !signal_blockable(signo)) {
        static int next;
        int alt = SIGRTMIN + 8 + next++ % 8;
        sigset_t ss;
        sigemptyset(&ss); sigaddset(&ss, alt);
        pthread_sigmask(SIG_BLOCK, &ss, NULL);
        r = real_sd_event_add_signal(e, s, alt, cb, ud);
        LOG("sd_event_add_signal: signal %d is not usable here (qemu-user?), using %d instead -> %d", signo, alt, r);
    }
    return r;
}

int pthread_create(pthread_t *t, const pthread_attr_t *attr, void *(*fn)(void *), void *arg) {
    REAL(pthread_create);
    int r = real_pthread_create(t, attr, fn, arg);
    if (r == EPERM && attr) {
        // Explicit realtime scheduling attrs; fall back to inheriting ours.
        pthread_attr_setinheritsched((pthread_attr_t *)attr, PTHREAD_INHERIT_SCHED);
        r = real_pthread_create(t, attr, fn, arg);
        TRACE("pthread_create with realtime attrs -> retried without: %d", r);
    }
    return r;
}

void *dlopen(const char *file, int mode) {
    REAL(dlopen);
    // OP-TEE's PKCS#11 client needs the secure world; use our software token.
    if (file && strstr(file, "libckteec.so")) file = "/opt/rmemu/rmemu-pkcs11.so";
    void *h = real_dlopen(file, mode);
    if (file && !strstr(file, "/plugins/")) TRACE("dlopen %s -> %s", file, h ? "ok" : dlerror());
    return h;
}

// A crash says where: the faulting code and its caller, as library+symbol.
// Then the default action runs (systemd still sees the signal). Programs that
// install their own handler later replace this one.
#include <ucontext.h>
static void on_crash(int sig, siginfo_t *si, void *ucp) {
    ucontext_t *uc = ucp;
    void *at[2] = { (void *)uc->uc_mcontext.pc, (void *)uc->uc_mcontext.regs[30] };
    char line[2][256];
    for (int i = 0; i < 2; i++) {
        Dl_info d = { 0 };
        dladdr(at[i], &d);
        snprintf(line[i], sizeof line[i], "%p %s(%s+%#lx)", at[i], d.dli_fname ? d.dli_fname : "?", d.dli_sname ? d.dli_sname : "?",
                 (unsigned long)((char *)at[i] - (char *)(d.dli_saddr ? d.dli_saddr : d.dli_fbase)));
    }
    LOG("signal %d (addr %p) in thread %ld at %s, called from %s", sig, si->si_addr,
        (long)syscall(SYS_gettid), line[0], line[1]);
    signal(sig, SIG_DFL);
}

__attribute__((constructor)) static void init(void) {
    const char *me = program_invocation_short_name ? program_invocation_short_name : "";
    if (getpid() == 1 || !strncmp(me, "systemd", 7) || !strncmp(me, "rmemu", 5)) { rmemu_off = 1; return; }
    const char *d = getenv("RMEMU_DEBUG");
    rmemu_debug = (d && strcmp(d, "0")) || access("/run/rmemu-debug", F_OK) == 0;
    if (getenv("RMEMU_FAKEROOT")) fakeroot = getenv("RMEMU_FAKEROOT");
    // xochitl's digitizer discovery would otherwise scan for a real Elan device.
    setenv("XOCHITL_DIGITIZER_PATH", "/dev/input/event1", 0);
    // Only xochitl gets the full treatment; child processes just inherit path fakes.
    TRACE("loaded into pid %d", getpid());
    struct sigaction sa = { .sa_sigaction = on_crash, .sa_flags = SA_SIGINFO | SA_RESETHAND };
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    fb_init();
}
