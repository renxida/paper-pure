// rmemu-wifi: the emulated tablet's Wi-Fi, as xochitl sees it over D-Bus.
//
// On the tablet, xochitl's csl wifi library (libcslwifi) talks to
// wpa_supplicant (fi.w1.wpa_supplicant1) on the iw61x radio and reads
// systemd-networkd's OnlineState (org.freedesktop.network1). Neither can run
// here: there is no radio (the stock supplicant's wired driver gets to
// "completed" on the veth, but its SignalPoll fails, which the library reads
// as "disconnected"), and networkd can't set up under qemu-user or without
// CAP_NET_ADMIN. wlan0 is a docker veth that already has an address and the
// default route. So this daemon answers the calls the library makes, with one
// open network, "pp-emu", connected while wlan0 has the default route
// (`ppemu wifi off` takes it away). Without it xochitl says "Pairing with the
// cloud requires a Wi-Fi connection" and sync never starts.
//
//   rmemu-wifi wpa        as wpa_supplicant.service (root; stock D-Bus policy)
//   rmemu-wifi network1   as rmemu-network1.service (user systemd-network)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <systemd/sd-bus.h>
#include <systemd/sd-event.h>

#define LOG(...) do { fprintf(stderr, "[rmemu-wifi] " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define WPA "fi.w1.wpa_supplicant1"
#define ROOT "/fi/w1/wpa_supplicant1"
#define IF ROOT "/Interfaces/0"
#define BSS IF "/BSSs/0"
#define SSID "pp-emu"

static sd_bus *bus;
static int online;     // wlan0 has the default route
static int user_down;  // Disconnect() until Reconnect()/SelectNetwork()

// ---------------------------------------------------------------- state

static int wlan0_online(void) {
    FILE *f = fopen("/proc/net/route", "r");
    if (!f) return 0;
    char line[256], ifn[32];
    unsigned long dst;
    int ok = 0;
    while (fgets(line, sizeof line, f))
        if (sscanf(line, "%31s %lx", ifn, &dst) == 2 && !strcmp(ifn, "wlan0") && dst == 0) ok = 1;
    fclose(f);
    return ok;
}

#define NKV 24
struct net {
    int used, enabled;
    char path[96];
    char key[NKV][32], val[NKV][96];  // wpa_supplicant shows every value as a string
    sd_bus_slot *slot;
};
static struct net nets[8];
static int current = -1;

static int connected(void) { return online && !user_down && current >= 0; }

static const char *kv_get(struct net *n, const char *k) {
    for (int i = 0; i < NKV; i++) if (n->key[i][0] && !strcmp(n->key[i], k)) return n->val[i];
    return NULL;
}
static void kv_set(struct net *n, const char *k, const char *v) {
    int free_i = -1;
    for (int i = 0; i < NKV; i++) {
        if (n->key[i][0] && !strcmp(n->key[i], k)) { snprintf(n->val[i], sizeof n->val[i], "%s", v); return; }
        if (!n->key[i][0] && free_i < 0) free_i = i;
    }
    if (free_i < 0) return;
    snprintf(n->key[free_i], sizeof n->key[free_i], "%s", k);
    snprintf(n->val[free_i], sizeof n->val[free_i], "%s", v);
}

// ---------------------------------------------------------------- helpers

static int append_paths(sd_bus_message *r, int bss) {
    int k = sd_bus_message_open_container(r, 'a', "o");
    if (k < 0) return k;
    if (bss) { if (online) sd_bus_message_append(r, "o", BSS); }
    else for (int i = 0; i < 8; i++) if (nets[i].used) sd_bus_message_append(r, "o", nets[i].path);
    return sd_bus_message_close_container(r);
}

static int append_props(sd_bus_message *r, struct net *n) {
    sd_bus_message_open_container(r, 'a', "{sv}");
    for (int i = 0; i < NKV; i++)
        if (n->key[i][0]) sd_bus_message_append(r, "{sv}", n->key[i], "s", n->val[i]);
    return sd_bus_message_close_container(r);
}

// Read an a{sv} of network settings (AddNetwork, Set Properties) into n.
// Like wpa_supplicant, string values for ssid/psk/identity/password are quoted.
static int read_props(sd_bus_message *m, struct net *n) {
    int k = sd_bus_message_enter_container(m, 'a', "{sv}");
    if (k < 0) return k;
    while ((k = sd_bus_message_enter_container(m, 'e', "sv")) > 0) {
        const char *key, *contents;
        char v[96] = "";
        char type;
        sd_bus_message_read(m, "s", &key);
        sd_bus_message_peek_type(m, &type, &contents);
        sd_bus_message_enter_container(m, 'v', contents);
        if (!strcmp(contents, "s")) {
            const char *s;
            sd_bus_message_read(m, "s", &s);
            int q = !strcmp(key, "ssid") || !strcmp(key, "psk") || !strcmp(key, "sae_password") ||
                    !strcmp(key, "identity") || !strcmp(key, "anonymous_identity") || !strcmp(key, "password");
            snprintf(v, sizeof v, q && s[0] != '"' ? "\"%s\"" : "%s", s);
        } else if (!strcmp(contents, "ay")) {
            const void *p; size_t len;
            sd_bus_message_read_array(m, 'y', &p, &len);
            snprintf(v, sizeof v, "\"%.*s\"", (int)(len < 90 ? len : 90), (const char *)p);
        } else if (!strcmp(contents, "i")) { int32_t i; sd_bus_message_read(m, "i", &i); snprintf(v, sizeof v, "%d", i); }
        else if (!strcmp(contents, "u")) { uint32_t u; sd_bus_message_read(m, "u", &u); snprintf(v, sizeof v, "%u", u); }
        else if (!strcmp(contents, "b")) { int b; sd_bus_message_read(m, "b", &b); snprintf(v, sizeof v, "%d", b); }
        else sd_bus_message_skip(m, contents);
        sd_bus_message_exit_container(m);
        sd_bus_message_exit_container(m);
        kv_set(n, key, v);
    }
    return sd_bus_message_exit_container(m);
}

// Both kinds of change signal: the standard one, and wpa_supplicant's own
// fi.w1.wpa_supplicant1.Interface.PropertiesChanged(a{sv}) that older
// clients listen to.
static void interface_changed(void) {
    sd_bus_emit_properties_changed(bus, IF, WPA ".Interface", "State", "CurrentBSS", "CurrentNetwork",
                                   "CurrentAuthMode", "BSSs", "Networks", NULL);
    sd_bus_message *s = NULL;
    if (sd_bus_message_new_signal(bus, &s, IF, WPA ".Interface", "PropertiesChanged") < 0) return;
    const char *net = connected() ? nets[current].path : "/";
    sd_bus_message_open_container(s, 'a', "{sv}");
    sd_bus_message_append(s, "{sv}", "State", "s", connected() ? "completed" : "disconnected");
    sd_bus_message_append(s, "{sv}", "CurrentBSS", "o", connected() ? BSS : "/");
    sd_bus_message_append(s, "{sv}", "CurrentNetwork", "o", net);
    sd_bus_message_open_container(s, 'e', "sv");
    sd_bus_message_append(s, "s", "BSSs");
    sd_bus_message_open_container(s, 'v', "ao");
    append_paths(s, 1);
    sd_bus_message_close_container(s);
    sd_bus_message_close_container(s);
    sd_bus_message_close_container(s);
    sd_bus_send(bus, s, NULL);
    sd_bus_message_unref(s);
}

// ---------------------------------------------------------------- Network objects

static struct net *net_of(const char *path) {
    for (int i = 0; i < 8; i++) if (nets[i].used && !strcmp(nets[i].path, path)) return &nets[i];
    return NULL;
}

static int net_get(sd_bus *b, const char *path, const char *iface, const char *prop, sd_bus_message *r, void *u, sd_bus_error *e) {
    struct net *n = net_of(path);
    if (!n) return sd_bus_error_set(e, WPA ".InvalidArgs", "no such network");
    if (!strcmp(prop, "Enabled")) return sd_bus_message_append(r, "b", n->enabled);
    return append_props(r, n);
}

static int net_set(sd_bus *b, const char *path, const char *iface, const char *prop, sd_bus_message *v, void *u, sd_bus_error *e) {
    struct net *n = net_of(path);
    if (!n) return sd_bus_error_set(e, WPA ".InvalidArgs", "no such network");
    if (!strcmp(prop, "Enabled")) { int x; sd_bus_message_read(v, "b", &x); n->enabled = x; return 0; }
    return read_props(v, n);
}

static const sd_bus_vtable net_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_WRITABLE_PROPERTY("Properties", "a{sv}", net_get, net_set, 0, 0),
    SD_BUS_WRITABLE_PROPERTY("Enabled", "b", net_get, net_set, 0, 0),
    SD_BUS_SIGNAL("PropertiesChanged", "a{sv}", 0),
    SD_BUS_VTABLE_END
};

static struct net *net_add(void) {
    for (int i = 0; i < 8; i++) {
        if (nets[i].used) continue;
        struct net *n = &nets[i];
        memset(n, 0, sizeof *n);
        n->used = n->enabled = 1;
        snprintf(n->path, sizeof n->path, IF "/Networks/%d", i);
        sd_bus_add_object_vtable(bus, &n->slot, n->path, WPA ".Network", net_vtable, NULL);
        return n;
    }
    return NULL;
}

static void net_remove(struct net *n) {
    if (current >= 0 && &nets[current] == n) current = -1;
    sd_bus_slot_unref(n->slot);
    n->used = 0;
    sd_bus_emit_signal(bus, IF, WPA ".Interface", "NetworkRemoved", "o", n->path);
}

// ---------------------------------------------------------------- Interface

static int if_get(sd_bus *b, const char *path, const char *iface, const char *prop, sd_bus_message *r, void *u, sd_bus_error *e) {
    int c = connected();
    if (!strcmp(prop, "State")) return sd_bus_message_append(r, "s", c ? "completed" : "disconnected");
    if (!strcmp(prop, "Scanning")) return sd_bus_message_append(r, "b", 0);
    if (!strcmp(prop, "Ifname")) return sd_bus_message_append(r, "s", "wlan0");
    if (!strcmp(prop, "Driver")) return sd_bus_message_append(r, "s", "nl80211");
    if (!strcmp(prop, "CurrentBSS")) return sd_bus_message_append(r, "o", c ? BSS : "/");
    if (!strcmp(prop, "CurrentNetwork")) return sd_bus_message_append(r, "o", c ? nets[current].path : "/");
    if (!strcmp(prop, "CurrentAuthMode")) return sd_bus_message_append(r, "s", c ? "NONE" : "INACTIVE");
    if (!strcmp(prop, "BSSs")) return append_paths(r, 1);
    if (!strcmp(prop, "Networks")) return append_paths(r, 0);
    if (!strcmp(prop, "DisconnectReason")) return sd_bus_message_append(r, "i", 0);
    if (!strcmp(prop, "ApScan")) return sd_bus_message_append(r, "u", 1);
    return sd_bus_error_set(e, WPA ".InvalidArgs", "unknown property");
}

static int m_ok(sd_bus_message *m, void *u, sd_bus_error *e) { return sd_bus_reply_method_return(m, ""); }

static int m_scan(sd_bus_message *m, void *u, sd_bus_error *e) {
    sd_bus_message_skip(m, "a{sv}");
    int k = sd_bus_reply_method_return(m, "");
    sd_bus_emit_signal(bus, IF, WPA ".Interface", "ScanDone", "b", 1);
    return k;
}

static int m_disconnect(sd_bus_message *m, void *u, sd_bus_error *e) {
    user_down = 1;
    interface_changed();
    return sd_bus_reply_method_return(m, "");
}

static int m_reconnect(sd_bus_message *m, void *u, sd_bus_error *e) {
    user_down = 0;
    interface_changed();
    return sd_bus_reply_method_return(m, "");
}

static int m_add_network(sd_bus_message *m, void *u, sd_bus_error *e) {
    struct net *n = net_add();
    if (!n) return sd_bus_error_set(e, WPA ".UnknownError", "too many networks");
    read_props(m, n);
    LOG("AddNetwork %s ssid=%s", n->path, kv_get(n, "ssid") ? kv_get(n, "ssid") : "?");
    int k = sd_bus_reply_method_return(m, "o", n->path);
    sd_bus_message *s = NULL;
    if (sd_bus_message_new_signal(bus, &s, IF, WPA ".Interface", "NetworkAdded") >= 0) {
        sd_bus_message_append(s, "o", n->path);
        append_props(s, n);
        sd_bus_send(bus, s, NULL);
        sd_bus_message_unref(s);
    }
    interface_changed();
    return k;
}

static int m_remove_network(sd_bus_message *m, void *u, sd_bus_error *e) {
    const char *p;
    sd_bus_message_read(m, "o", &p);
    struct net *n = net_of(p);
    if (!n) return sd_bus_error_set(e, WPA ".NetworkUnknown", "no such network");
    net_remove(n);
    interface_changed();
    return sd_bus_reply_method_return(m, "");
}

static int m_remove_all(sd_bus_message *m, void *u, sd_bus_error *e) {
    for (int i = 0; i < 8; i++) if (nets[i].used) net_remove(&nets[i]);
    interface_changed();
    return sd_bus_reply_method_return(m, "");
}

static int m_select_network(sd_bus_message *m, void *u, sd_bus_error *e) {
    const char *p;
    sd_bus_message_read(m, "o", &p);
    struct net *n = net_of(p);
    if (!n) return sd_bus_error_set(e, WPA ".NetworkUnknown", "no such network");
    current = (int)(n - nets);
    user_down = 0;
    LOG("SelectNetwork %s", p);
    int k = sd_bus_reply_method_return(m, "");
    sd_bus_emit_signal(bus, IF, WPA ".Interface", "NetworkSelected", "o", p);
    interface_changed();
    return k;
}

static int m_signal_poll(sd_bus_message *m, void *u, sd_bus_error *e) {
    if (!connected()) return sd_bus_error_set(e, WPA ".UnknownError", "Failed to read signal");
    sd_bus_message *r = NULL;
    int k = sd_bus_message_new_method_return(m, &r);
    if (k < 0) return k;
    sd_bus_message_append(r, "a{sv}", 5, "rssi", "i", -45, "linkspeed", "i", 72, "noise", "i", 9999,
                          "frequency", "u", 2437, "width", "s", "20 MHz");
    k = sd_bus_send(NULL, r, NULL);
    sd_bus_message_unref(r);
    return k;
}

static const sd_bus_vtable if_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("Scan", "a{sv}", "", m_scan, 0),
    SD_BUS_METHOD("AbortScan", "", "", m_ok, 0),
    SD_BUS_METHOD("Disconnect", "", "", m_disconnect, 0),
    SD_BUS_METHOD("Reconnect", "", "", m_reconnect, 0),
    SD_BUS_METHOD("Reassociate", "", "", m_reconnect, 0),
    SD_BUS_METHOD("Reattach", "", "", m_reconnect, 0),
    SD_BUS_METHOD("AddNetwork", "a{sv}", "o", m_add_network, 0),
    SD_BUS_METHOD("RemoveNetwork", "o", "", m_remove_network, 0),
    SD_BUS_METHOD("RemoveAllNetworks", "", "", m_remove_all, 0),
    SD_BUS_METHOD("SelectNetwork", "o", "", m_select_network, 0),
    SD_BUS_METHOD("SaveConfig", "", "", m_ok, 0),
    SD_BUS_METHOD("SignalPoll", "", "a{sv}", m_signal_poll, 0),
    SD_BUS_PROPERTY("State", "s", if_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("Scanning", "b", if_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("Ifname", "s", if_get, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("Driver", "s", if_get, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_PROPERTY("CurrentBSS", "o", if_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CurrentNetwork", "o", if_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CurrentAuthMode", "s", if_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("BSSs", "ao", if_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("Networks", "ao", if_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("DisconnectReason", "i", if_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("ApScan", "u", if_get, 0, 0),
    SD_BUS_SIGNAL("PropertiesChanged", "a{sv}", 0),
    SD_BUS_SIGNAL("ScanDone", "b", 0),
    SD_BUS_SIGNAL("NetworkAdded", "oa{sv}", 0),
    SD_BUS_SIGNAL("NetworkRemoved", "o", 0),
    SD_BUS_SIGNAL("NetworkSelected", "o", 0),
    SD_BUS_VTABLE_END
};

// ---------------------------------------------------------------- BSS: the one access point

static int bss_get(sd_bus *b, const char *path, const char *iface, const char *prop, sd_bus_message *r, void *u, sd_bus_error *e) {
    static const uint8_t bssid[6] = {0x02, 0x00, 0x00, 0xe1, 0x00, 0x01};
    if (!strcmp(prop, "SSID")) return sd_bus_message_append_array(r, 'y', SSID, strlen(SSID));
    if (!strcmp(prop, "BSSID")) return sd_bus_message_append_array(r, 'y', bssid, sizeof bssid);
    if (!strcmp(prop, "IEs")) return sd_bus_message_append_array(r, 'y', "", 0);
    if (!strcmp(prop, "Privacy")) return sd_bus_message_append(r, "b", 0);
    if (!strcmp(prop, "Mode")) return sd_bus_message_append(r, "s", "infrastructure");
    if (!strcmp(prop, "Frequency")) return sd_bus_message_append(r, "q", 2437);
    if (!strcmp(prop, "Signal")) return sd_bus_message_append(r, "n", -45);
    if (!strcmp(prop, "Age")) return sd_bus_message_append(r, "u", 0);
    if (!strcmp(prop, "Rates")) return sd_bus_message_append(r, "au", 3, 54000000, 24000000, 6000000);
    if (!strcmp(prop, "WPS")) return sd_bus_message_append(r, "a{sv}", 1, "Type", "s", "");
    if (!strcmp(prop, "RSN") || !strcmp(prop, "WPA"))   // an open network: no key management
        return sd_bus_message_append(r, "a{sv}", 3, "KeyMgmt", "as", 0, "Pairwise", "as", 0, "Group", "s", "");
    return sd_bus_error_set(e, WPA ".InvalidArgs", "unknown property");
}

static const sd_bus_vtable bss_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_PROPERTY("SSID", "ay", bss_get, 0, 0),
    SD_BUS_PROPERTY("BSSID", "ay", bss_get, 0, 0),
    SD_BUS_PROPERTY("IEs", "ay", bss_get, 0, 0),
    SD_BUS_PROPERTY("Privacy", "b", bss_get, 0, 0),
    SD_BUS_PROPERTY("Mode", "s", bss_get, 0, 0),
    SD_BUS_PROPERTY("Frequency", "q", bss_get, 0, 0),
    SD_BUS_PROPERTY("Signal", "n", bss_get, 0, 0),
    SD_BUS_PROPERTY("Age", "u", bss_get, 0, 0),
    SD_BUS_PROPERTY("Rates", "au", bss_get, 0, 0),
    SD_BUS_PROPERTY("WPS", "a{sv}", bss_get, 0, 0),
    SD_BUS_PROPERTY("RSN", "a{sv}", bss_get, 0, 0),
    SD_BUS_PROPERTY("WPA", "a{sv}", bss_get, 0, 0),
    SD_BUS_SIGNAL("PropertiesChanged", "a{sv}", 0),
    SD_BUS_VTABLE_END
};

// ---------------------------------------------------------------- the supplicant itself

static int root_get(sd_bus *b, const char *path, const char *iface, const char *prop, sd_bus_message *r, void *u, sd_bus_error *e) {
    if (!strcmp(prop, "Interfaces")) return sd_bus_message_append(r, "ao", 1, IF);
    if (!strcmp(prop, "DebugLevel")) return sd_bus_message_append(r, "s", "info");
    if (!strcmp(prop, "EapMethods")) return sd_bus_message_append(r, "as", 6, "MD5", "TLS", "MSCHAPV2", "PEAP", "TTLS", "GTC");
    if (!strcmp(prop, "Capabilities")) return sd_bus_message_append(r, "as", 2, "ap", "pmf");
    return sd_bus_error_set(e, WPA ".InvalidArgs", "unknown property");
}

static int m_get_interface(sd_bus_message *m, void *u, sd_bus_error *e) {
    const char *name;
    sd_bus_message_read(m, "s", &name);
    if (strcmp(name, "wlan0")) return sd_bus_error_set(e, WPA ".InterfaceUnknown", "wpa_supplicant knows nothing about this interface.");
    return sd_bus_reply_method_return(m, "o", IF);
}

static int m_create_interface(sd_bus_message *m, void *u, sd_bus_error *e) {
    return sd_bus_error_set(e, WPA ".InterfaceExists", "wpa_supplicant already controls this interface.");
}

static const sd_bus_vtable root_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("GetInterface", "s", "o", m_get_interface, 0),
    SD_BUS_METHOD("CreateInterface", "a{sv}", "o", m_create_interface, 0),
    SD_BUS_PROPERTY("Interfaces", "ao", root_get, 0, 0),
    SD_BUS_PROPERTY("DebugLevel", "s", root_get, 0, 0),
    SD_BUS_PROPERTY("EapMethods", "as", root_get, 0, 0),
    SD_BUS_PROPERTY("Capabilities", "as", root_get, 0, 0),
    SD_BUS_SIGNAL("InterfaceAdded", "oa{sv}", 0),
    SD_BUS_SIGNAL("InterfaceRemoved", "o", 0),
    SD_BUS_SIGNAL("PropertiesChanged", "a{sv}", 0),
    SD_BUS_VTABLE_END
};

// ---------------------------------------------------------------- networkd's Manager

static const char *nd_state(const char *prop) {
    if (!strcmp(prop, "OnlineState")) return online ? "online" : "offline";
    if (!strcmp(prop, "CarrierState")) return online ? "carrier" : "no-carrier";
    if (!strcmp(prop, "IPv6AddressState")) return "off";
    if (!strcmp(prop, "OperationalState")) return online ? "routable" : "no-carrier";
    return online ? "routable" : "off";   // AddressState, IPv4AddressState
}

static int nd_get(sd_bus *b, const char *path, const char *iface, const char *prop, sd_bus_message *r, void *u, sd_bus_error *e) {
    if (!strcmp(prop, "NamespaceId")) return sd_bus_message_append(r, "t", (uint64_t)0);
    return sd_bus_message_append(r, "s", nd_state(prop));
}

static const sd_bus_vtable nd_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_PROPERTY("OperationalState", "s", nd_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CarrierState", "s", nd_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("AddressState", "s", nd_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("IPv4AddressState", "s", nd_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("IPv6AddressState", "s", nd_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("OnlineState", "s", nd_get, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("NamespaceId", "t", nd_get, 0, SD_BUS_VTABLE_PROPERTY_CONST),
    SD_BUS_VTABLE_END
};

// ---------------------------------------------------------------- main

static int is_network1;

static int poll_link(sd_event_source *s, uint64_t usec, void *u) {
    int now = wlan0_online();
    if (now != online) {
        online = now;
        LOG("wlan0 %s", online ? "has the default route: connected to " SSID : "is gone: disconnected");
        if (is_network1)
            sd_bus_emit_properties_changed(bus, "/org/freedesktop/network1", "org.freedesktop.network1.Manager",
                                           "OperationalState", "CarrierState", "AddressState", "IPv4AddressState", "OnlineState", NULL);
        else
            interface_changed();
    }
    sd_event_source_set_time(s, usec + 2000000);
    sd_event_source_set_enabled(s, SD_EVENT_ON);
    return 0;
}

int main(int argc, char **argv) {
    is_network1 = argc > 1 && !strcmp(argv[1], "network1");
    if (argc < 2 || (!is_network1 && strcmp(argv[1], "wpa"))) { fprintf(stderr, "usage: rmemu-wifi wpa|network1\n"); return 2; }
    setvbuf(stderr, NULL, _IOLBF, 0);
    sd_event *ev = NULL;
    int k = sd_event_default(&ev);
    if (k >= 0) k = sd_bus_open_system(&bus);
    if (k < 0) { LOG("bus: %s", strerror(-k)); return 1; }
    online = wlan0_online();
    if (is_network1) {
        sd_bus_add_object_vtable(bus, NULL, "/org/freedesktop/network1", "org.freedesktop.network1.Manager", nd_vtable, NULL);
        k = sd_bus_request_name(bus, "org.freedesktop.network1", 0);
    } else {
        sd_bus_add_object_vtable(bus, NULL, ROOT, WPA, root_vtable, NULL);
        sd_bus_add_object_vtable(bus, NULL, IF, WPA ".Interface", if_vtable, NULL);
        sd_bus_add_object_vtable(bus, NULL, BSS, WPA ".BSS", bss_vtable, NULL);
        struct net *n = net_add();   // the tablet remembers one network, and it's in range
        kv_set(n, "ssid", "\"" SSID "\"");
        kv_set(n, "key_mgmt", "NONE");
        kv_set(n, "priority", "0");
        kv_set(n, "scan_ssid", "0");
        current = 0;
        k = sd_bus_request_name(bus, WPA, 0);
    }
    if (k < 0) { LOG("can't own the name: %s", strerror(-k)); return 1; }
    sd_bus_attach_event(bus, ev, 0);
    uint64_t t;
    sd_event_now(ev, CLOCK_MONOTONIC, &t);
    sd_event_add_time(ev, NULL, CLOCK_MONOTONIC, t + 2000000, 0, poll_link, NULL);
    LOG("%s up; wlan0 %s", is_network1 ? "org.freedesktop.network1" : WPA, online ? "connected to " SSID : "offline");
    k = sd_event_loop(ev);
    return k < 0 ? 1 : 0;
}
