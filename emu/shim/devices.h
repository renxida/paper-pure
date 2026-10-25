// Shared between the shim (answers EVIOC* ioctls) and rmemud (injects events):
// the fake input devices and the IPC endpoints that connect them.
#pragma once
#include <linux/input.h>
#include <stdint.h>

#define RMEMU_SCREEN_W 1404  // Paper Pure (tatsu), portrait
#define RMEMU_SCREEN_H 1872

#define RMEMU_RUN "/run/rmemu"
#define RMEMU_DISPLAY_SOCK RMEMU_RUN "/display.sock"  // xochitl's shim pushes frames here
#define RMEMU_INPUT_SOCK RMEMU_RUN "/input.sock"      // device readers subscribe here
#define RMEMU_STATE_FILE RMEMU_RUN "/state"           // key/switch state, mmap'd by readers

enum { DEV_BUTTONS, DEV_PEN, DEV_TOUCH, DEV_HALL, NDEV };
// Pseudo-device for subscribing to uevents (sd_device monitors): rmemud sends
// u16 length + "subsystem\0sysname\0KEY=VALUE\0...".
#define DEV_UEVENT 0xfe

// Pen axes are 1/10 screen pixel; touch axes are screen pixels.
#define PEN_SCALE 10

struct shared_state {
    uint32_t magic;
    unsigned char key[NDEV][KEY_MAX / 8 + 1];
    unsigned char sw[NDEV][SW_MAX / 8 + 1];
};
#define RMEMU_STATE_MAGIC 0x524d4555u

static inline const char *dev_path(int i) {
    static const char *const p[NDEV] = { "/dev/input/event0", "/dev/input/event1", "/dev/input/event2", "/dev/input/event3" };
    return p[i];
}

// A reader's first (and only) message to rmemud: 'S' u8 device.
