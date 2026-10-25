#pragma once
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>

extern int rmemu_debug;
#define LOG(...) do { fprintf(stderr, "[rmemu] " __VA_ARGS__); fputc('\n', stderr); } while (0)
// Per-call tracing (every hardware path, dlopen, ...); RMEMU_DEBUG=1 enables it.
#define TRACE(...) do { if (rmemu_debug) LOG(__VA_ARGS__); } while (0)

// Resolve the next definition of a libc symbol we interpose.
#define REAL(name) static __typeof__(name) *real_##name; if (!real_##name) real_##name = dlsym(RTLD_NEXT, #name)

// drm.c
int drm_open(void);
int drm_is_fd(int fd);
int drm_ioctl(unsigned long req, void *arg);
void *drm_mmap(void *addr, size_t len, int prot, int flags, off_t off);
// Called on every committed scanout; fb.c uses it as a "screen changed" tick.
extern void (*drm_on_flip)(void);

// input.c
int input_open(const char *path, int flags);  // -2 if path isn't a fake input device
int input_is_fd(int fd);
int input_ioctl(int fd, unsigned long req, void *arg);
void input_close(int fd);
int input_dev_info(int i, const char **devnode, const char **name, const char **kind);

// fb.c
void fb_init(void);
