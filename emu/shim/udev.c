// Minimal libudev replacement. There is no udevd in the container, so the
// real library can't report ID_INPUT_* properties; Qt's input plugins and
// xochitl's device monitor would find nothing. This one lists the shim's fake
// input devices and supports the enumerate/monitor calls they make.
#include "common.h"
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct udev { int refs; };
struct udev_list_entry { char *name, *value; struct udev_list_entry *next; };
struct udev_device {
    int idx;  // index into input_dev_info, or -1 for the parent "inputN" node
    char syspath[96], devpath[96], sysname[32];
    const char *devnode, *name, *kind;
    struct udev_list_entry *props;
    struct udev_device *parent;
};
struct udev_enumerate { char *subsys[8]; int nsub; char *pk[8], *pv[8]; int nprop; struct udev_list_entry *list; };
struct udev_monitor { int fds[2]; };

static struct udev_list_entry *list_add(struct udev_list_entry **head, const char *name, const char *value) {
    struct udev_list_entry *e = calloc(1, sizeof *e), **p = head;
    e->name = strdup(name); e->value = value ? strdup(value) : NULL;
    while (*p) p = &(*p)->next;
    *p = e;
    return e;
}
static void list_free(struct udev_list_entry *e) {
    while (e) { struct udev_list_entry *n = e->next; free(e->name); free(e->value); free(e); e = n; }
}

struct udev *udev_new(void) { struct udev *u = calloc(1, sizeof *u); u->refs = 1; return u; }
struct udev *udev_ref(struct udev *u) { if (u) u->refs++; return u; }
struct udev *udev_unref(struct udev *u) { if (u && !--u->refs) free(u); return NULL; }

static struct udev_device *make_device(int i) {
    const char *node, *name, *kind;
    if (!input_dev_info(i, &node, &name, &kind)) return NULL;
    struct udev_device *d = calloc(1, sizeof *d);
    d->idx = i; d->devnode = node; d->name = name; d->kind = kind;
    const char *ev = strrchr(node, '/') + 1;
    snprintf(d->sysname, sizeof d->sysname, "%s", ev);
    snprintf(d->devpath, sizeof d->devpath, "/devices/virtual/input/input%d/%s", i, ev);
    snprintf(d->syspath, sizeof d->syspath, "/sys%s", d->devpath);
    list_add(&d->props, "DEVNAME", node);
    list_add(&d->props, "DEVPATH", d->devpath);
    list_add(&d->props, "SUBSYSTEM", "input");
    list_add(&d->props, "ID_INPUT", "1");
    if (!strcmp(kind, "tablet")) list_add(&d->props, "ID_INPUT_TABLET", "1");
    if (!strcmp(kind, "touchscreen")) list_add(&d->props, "ID_INPUT_TOUCHSCREEN", "1");
    if (!strcmp(kind, "key")) { list_add(&d->props, "ID_INPUT_KEY", "1"); list_add(&d->props, "ID_INPUT_KEYBOARD", "1"); }
    if (!strcmp(kind, "switch")) list_add(&d->props, "ID_INPUT_SWITCH", "1");
    return d;
}

const char *udev_list_entry_get_name(struct udev_list_entry *e) { return e ? e->name : NULL; }
const char *udev_list_entry_get_value(struct udev_list_entry *e) { return e ? e->value : NULL; }
struct udev_list_entry *udev_list_entry_get_next(struct udev_list_entry *e) { return e ? e->next : NULL; }

struct udev_enumerate *udev_enumerate_new(struct udev *u) { (void)u; return calloc(1, sizeof(struct udev_enumerate)); }
struct udev_enumerate *udev_enumerate_unref(struct udev_enumerate *e) {
    if (!e) return NULL;
    for (int i = 0; i < e->nsub; i++) free(e->subsys[i]);
    for (int i = 0; i < e->nprop; i++) { free(e->pk[i]); free(e->pv[i]); }
    list_free(e->list); free(e);
    return NULL;
}
int udev_enumerate_add_match_subsystem(struct udev_enumerate *e, const char *s) {
    if (e->nsub < 8) e->subsys[e->nsub++] = strdup(s);
    return 0;
}
int udev_enumerate_add_match_property(struct udev_enumerate *e, const char *k, const char *v) {
    if (e->nprop < 8) { e->pk[e->nprop] = strdup(k); e->pv[e->nprop++] = strdup(v ? v : ""); }
    return 0;
}
int udev_enumerate_scan_devices(struct udev_enumerate *e) {
    list_free(e->list); e->list = NULL;
    int want_input = !e->nsub;
    for (int i = 0; i < e->nsub; i++) want_input |= !strcmp(e->subsys[i], "input");
    if (!want_input) return 0;
    for (int i = 0;; i++) {
        struct udev_device *d = make_device(i);
        if (!d) break;
        // udev ORs property matches.
        int ok = !e->nprop;
        for (int p = 0; p < e->nprop; p++)
            for (struct udev_list_entry *pe = d->props; pe; pe = pe->next)
                if (!strcmp(pe->name, e->pk[p]) && !strcmp(pe->value, e->pv[p])) ok = 1;
        if (ok) list_add(&e->list, d->syspath, NULL);
        list_free(d->props); free(d);
    }
    return 0;
}
struct udev_list_entry *udev_enumerate_get_list_entry(struct udev_enumerate *e) { return e->list; }

struct udev_device *udev_device_new_from_syspath(struct udev *u, const char *syspath) {
    (void)u;
    for (int i = 0;; i++) {
        struct udev_device *d = make_device(i);
        if (!d) return NULL;
        if (!strcmp(d->syspath, syspath)) return d;
        list_free(d->props); free(d);
    }
}
struct udev_device *udev_device_unref(struct udev_device *d) {
    if (!d) return NULL;
    if (d->parent) { list_free(d->parent->props); free(d->parent); }
    list_free(d->props); free(d);
    return NULL;
}
struct udev_device *udev_device_ref(struct udev_device *d) { return d; }
const char *udev_device_get_devnode(struct udev_device *d) { return d && d->idx >= 0 ? d->devnode : NULL; }
const char *udev_device_get_devpath(struct udev_device *d) { return d ? d->devpath : NULL; }
const char *udev_device_get_syspath(struct udev_device *d) { return d ? d->syspath : NULL; }
const char *udev_device_get_sysname(struct udev_device *d) { return d ? d->sysname : NULL; }
const char *udev_device_get_subsystem(struct udev_device *d) { return d ? "input" : NULL; }
const char *udev_device_get_action(struct udev_device *d) { (void)d; return "add"; }
struct udev_list_entry *udev_device_get_properties_list_entry(struct udev_device *d) { return d ? d->props : NULL; }
const char *udev_device_get_property_value(struct udev_device *d, const char *key) {
    for (struct udev_list_entry *e = d ? d->props : NULL; e; e = e->next) if (!strcmp(e->name, key)) return e->value;
    return NULL;
}
const char *udev_device_get_sysattr_value(struct udev_device *d, const char *attr) {
    if (!d || !attr) return NULL;
    if (!strcmp(attr, "name")) return d->name;
    // Only the key-capability word matters to Qt's keyboard detection.
    if (!strcmp(attr, "capabilities/key")) return !strcmp(d->kind, "key") ? "10000000000000 0" : "0";
    return NULL;
}
struct udev_device *udev_device_get_parent_with_subsystem_devtype(struct udev_device *d, const char *subsys, const char *devtype) {
    (void)devtype;
    if (!d || d->idx < 0 || (subsys && strcmp(subsys, "input"))) return NULL;
    if (!d->parent) {
        struct udev_device *p = calloc(1, sizeof *p);
        *p = *d;
        p->idx = -1; p->props = NULL; p->parent = NULL;
        snprintf(p->sysname, sizeof p->sysname, "input%d", d->idx);
        char *slash = strrchr(p->devpath, '/'); if (slash) *slash = 0;
        snprintf(p->syspath, sizeof p->syspath, "/sys%s", p->devpath);
        list_add(&p->props, "NAME", d->name);
        d->parent = p;
    }
    return d->parent;
}

// Monitors never fire for now (no hotplug), but must hand out a pollable fd.
struct udev_monitor *udev_monitor_new_from_netlink(struct udev *u, const char *name) {
    (void)u; (void)name;
    struct udev_monitor *m = calloc(1, sizeof *m);
    if (pipe2(m->fds, O_CLOEXEC | O_NONBLOCK)) { free(m); return NULL; }
    return m;
}
struct udev_monitor *udev_monitor_unref(struct udev_monitor *m) {
    if (m) { close(m->fds[0]); close(m->fds[1]); free(m); }
    return NULL;
}
int udev_monitor_filter_add_match_subsystem_devtype(struct udev_monitor *m, const char *s, const char *t) { (void)m; (void)s; (void)t; return 0; }
int udev_monitor_enable_receiving(struct udev_monitor *m) { (void)m; return 0; }
int udev_monitor_get_fd(struct udev_monitor *m) { return m ? m->fds[0] : -1; }
struct udev_device *udev_monitor_receive_device(struct udev_monitor *m) { (void)m; return NULL; }
