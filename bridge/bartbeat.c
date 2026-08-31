/*
 * bartbeat — persistent libimobiledevice battery monitor with heartbeat.
 *
 * Subscribes to usbmuxd device events. For each connected device:
 *   - Connects to lockdownd (ld_bat) for battery polling every 30 s
 *   - Opens a SEPARATE lockdownd connection (ld_hb) to start heartbeat service
 *     so that StartService doesn't invalidate the battery session
 *   - Outputs JSON lines to stdout; debug lines to stderr
 *
 * Exits cleanly when parent closes stdin.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>

#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/heartbeat.h>
#include <libimobiledevice/companion_proxy.h>
#include <plist/plist.h>
#include <usbmuxd.h>

#define MAX_DEVS  8
#define POLL_S    30
#define HB_MS     40000   /* heartbeat receive timeout — iOS sends Marco ~every 30 s */

/* ── thread-safe stdout ─────────────────────────────────────────────────── */

static pthread_mutex_t out_lock = PTHREAD_MUTEX_INITIALIZER;

static void emit(const char *s) {
    pthread_mutex_lock(&out_lock);
    puts(s);
    fflush(stdout);
    pthread_mutex_unlock(&out_lock);
}

static void dbg(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[bartbeat] ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(ap);
}

#include <stdarg.h>  /* for va_list above — must follow stdio.h */

/* ── JSON helper ─────────────────────────────────────────────────────────── */

static void jstr(char *dst, size_t cap, const char *src) {
    size_t j = 0;
    for (size_t i = 0; src && src[i] && j + 3 < cap; i++) {
        if (src[i] == '"' || src[i] == '\\') dst[j++] = '\\';
        dst[j++] = src[i];
    }
    dst[j] = '\0';
}

/* ── lockdownd string helper ─────────────────────────────────────────────── */

static char *ld_str(lockdownd_client_t ld, const char *dom, const char *key) {
    plist_t v = NULL;
    if (lockdownd_get_value(ld, dom, key, &v) != LOCKDOWN_E_SUCCESS || !v) return NULL;
    char *s = NULL;
    if (plist_get_node_type(v) == PLIST_STRING) plist_get_string_val(v, &s);
    plist_free(v);
    return s;   /* caller must free */
}

/* ── battery query (uses caller-provided lockdownd client) ───────────────── */

static int get_battery(lockdownd_client_t ld, int *chg) {
    *chg = 0;
    plist_t v = NULL;
    lockdownd_error_t err = lockdownd_get_value(ld, "com.apple.mobile.battery", NULL, &v);
    if (err != LOCKDOWN_E_SUCCESS || !v) {
        dbg("battery get_value error %d, v=%p", (int)err, (void*)v);
        if (v) plist_free(v);
        return -1;
    }
    int lvl = -1;
    if (plist_get_node_type(v) == PLIST_DICT) {
        plist_t cap = plist_dict_get_item(v, "BatteryCurrentCapacity");
        if (cap) {
            plist_type pt = plist_get_node_type(cap);
            if (pt == PLIST_UINT) {
                uint64_t u = 0; plist_get_uint_val(cap, &u); lvl = (int)u;
            } else if (pt == PLIST_INT) {
                int64_t i = 0; plist_get_int_val(cap, &i); lvl = (int)i;
            } else {
                dbg("BatteryCurrentCapacity unexpected plist type %d", (int)pt);
            }
        } else {
            dbg("BatteryCurrentCapacity key not found in dict");
        }
        plist_t bic = plist_dict_get_item(v, "BatteryIsCharging");
        if (bic && plist_get_node_type(bic) == PLIST_BOOLEAN) {
            uint8_t b = 0; plist_get_bool_val(bic, &b); *chg = b;
        }
    } else {
        dbg("battery domain plist type %d (expected PLIST_DICT=%d)", (int)plist_get_node_type(v), (int)PLIST_DICT);
    }
    plist_free(v);
    return lvl;
}

/* ── Watch battery via companion_proxy (reuses ld_bat session) ───────────── */

/* Open a companion_proxy client via the existing lockdownd session. */
static int cp_open(idevice_t device, lockdownd_client_t ld,
                   companion_proxy_client_t *out) {
    lockdownd_service_descriptor_t svc = NULL;
    if (lockdownd_start_service(ld, COMPANION_PROXY_SERVICE_NAME, &svc) != LOCKDOWN_E_SUCCESS)
        return -1;
    companion_proxy_error_t err = companion_proxy_client_new(device, svc, out);
    lockdownd_service_descriptor_free(svc);
    return (err == COMPANION_PROXY_E_SUCCESS) ? 0 : -1;
}

/* Get one value from the companion registry. Each call needs a fresh client
 * because the device closes the connection after replying. */
static plist_t cp_get(idevice_t device, lockdownd_client_t ld,
                      const char *watch_udid, const char *key) {
    companion_proxy_client_t cp = NULL;
    if (cp_open(device, ld, &cp) != 0) {
        dbg("cp_get(%s): cp_open failed", key);
        return NULL;
    }
    plist_t val = NULL;
    companion_proxy_error_t err = companion_proxy_get_value_from_registry(cp, watch_udid, key, &val);
    companion_proxy_client_free(cp);
    if (err != COMPANION_PROXY_E_SUCCESS) {
        dbg("cp_get(%s): error %d", key, (int)err);
    } else if (val) {
        /* debug only */
    } else {
        dbg("cp_get(%s): success but val=NULL", key);
    }
    return val;
}

/* Unwrap a single-element PLIST_ARRAY, return the inner node (not freed). */
static plist_t plist_unwrap(plist_t v) {
    if (!v) return NULL;
    if (plist_get_node_type(v) == PLIST_ARRAY && plist_array_get_size(v) > 0)
        return plist_array_get_item(v, 0);
    return v;
}

/* Extract int from a plist that may be UINT, INT, STRING, or single-element ARRAY. */
static int plist_int_val(plist_t v) {
    v = plist_unwrap(v);
    if (!v) return -1;
    plist_type pt = plist_get_node_type(v);
    if (pt == PLIST_UINT)   { uint64_t u = 0; plist_get_uint_val(v, &u); return (int)u; }
    if (pt == PLIST_INT)    { int64_t  i = 0; plist_get_int_val(v,  &i); return (int)i; }
    if (pt == PLIST_STRING) { char *s = NULL; plist_get_string_val(v, &s);
                              int r = s ? atoi(s) : -1; free(s); return r; }
    return -1;
}

/*
 * Queries Apple Watch battery via companion_proxy and emits
 * {"type":"watch",...} to stdout if data is available.
 * Uses ld_bat so no new lockdownd session is opened.
 */
static void query_watch(idevice_t device, lockdownd_client_t ld_bat) {
    /* 1. Get paired Watch UDIDs */
    companion_proxy_client_t cp = NULL;
    if (cp_open(device, ld_bat, &cp) != 0) {
        dbg("companion_proxy open failed");
        return;
    }
    plist_t registry = NULL;
    companion_proxy_error_t reg_err = companion_proxy_get_device_registry(cp, &registry);
    companion_proxy_client_free(cp);

    if (reg_err != COMPANION_PROXY_E_SUCCESS || !registry) {
        dbg("companion get_device_registry error %d", (int)reg_err);
        plist_free(registry);
        return;
    }

    /* registry = PLIST_ARRAY of UDID strings */
    char *watch_udid = NULL;
    if (plist_get_node_type(registry) == PLIST_ARRAY) {
        uint32_t n = plist_array_get_size(registry);
        for (uint32_t i = 0; i < n; i++) {
            plist_t item = plist_array_get_item(registry, i);
            if (plist_get_node_type(item) == PLIST_STRING) {
                plist_get_string_val(item, &watch_udid);
                break;
            }
        }
    }
    plist_free(registry);

    if (!watch_udid) { dbg("no watch UDID in registry"); return; }
    dbg("watch UDID: %s", watch_udid);

    /* 2. Query individual values — each call needs a fresh cp client */
    plist_t lv_raw = cp_get(device, ld_bat, watch_udid, "BatteryCurrentCapacity");
    plist_t cv_raw = cp_get(device, ld_bat, watch_udid, "BatteryIsCharging");
    plist_t nv_raw = cp_get(device, ld_bat, watch_udid, "DeviceName");

    /* companion_proxy returns {"Key": value} — extract the inner node */
    plist_t lv = lv_raw ? plist_dict_get_item(lv_raw, "BatteryCurrentCapacity") : NULL;
    plist_t cv = cv_raw ? plist_dict_get_item(cv_raw, "BatteryIsCharging")      : NULL;
    plist_t nv = nv_raw ? plist_dict_get_item(nv_raw, "DeviceName")             : NULL;

    int  lvl = plist_int_val(lv);
    int  chg = 0;
    char *wname = NULL;

    if (cv) {
        plist_type pt = plist_get_node_type(cv);
        if (pt == PLIST_BOOLEAN) { uint8_t b = 0; plist_get_bool_val(cv, &b); chg = b; }
        else if (pt == PLIST_STRING) { char *s = NULL; plist_get_string_val(cv, &s);
            chg = s && (s[0]=='1' || s[0]=='t' || s[0]=='T'); free(s); }
    }
    if (nv) {
        if (plist_get_node_type(nv) == PLIST_STRING) plist_get_string_val(nv, &wname);
    }

    /* wname allocated before raw frees (plist_get_string_val allocates a copy) */
    plist_free(lv_raw); plist_free(cv_raw); plist_free(nv_raw);

    if (lvl >= 0) {
        char su[256], sn[512], buf[1024];
        jstr(su, sizeof su, watch_udid);
        jstr(sn, sizeof sn, wname ? wname : "Apple Watch");
        snprintf(buf, sizeof buf,
            "{\"type\":\"watch\",\"udid\":\"%s\",\"name\":\"%s\",\"level\":%d,\"charging\":%s}",
            su, sn, lvl, chg ? "true" : "false");
        emit(buf);
        dbg("watch: %d%% charging=%d", lvl, chg);
    } else {
        dbg("watch battery not available (lvl=%d)", lvl);
    }

    free(watch_udid);
    free(wname);
}

/* ── heartbeat thread ────────────────────────────────────────────────────── */

/* ── heartbeat manager — self-restarting, independent of battery poll ──────── */

typedef struct { idevice_t device; volatile int *alive; } HBManagerArg;

static void hb_run_once(idevice_t device, volatile int *alive) {
    lockdownd_client_t ld_hb = NULL;
    if (lockdownd_client_new_with_handshake(device, &ld_hb, "bartbeat-hb") != LOCKDOWN_E_SUCCESS) {
        dbg("heartbeat lockdown handshake failed");
        return;
    }
    lockdownd_service_descriptor_t hb_svc = NULL;
    heartbeat_client_t hb = NULL;
    if (lockdownd_start_service(ld_hb, HEARTBEAT_SERVICE_NAME, &hb_svc) == LOCKDOWN_E_SUCCESS) {
        heartbeat_client_new(device, hb_svc, &hb);
        lockdownd_service_descriptor_free(hb_svc);
    }
    lockdownd_client_free(ld_hb);

    if (!hb) { dbg("heartbeat_client_new failed"); return; }

    plist_t polo = plist_new_dict();
    plist_dict_set_item(polo, "Command", plist_new_string("Polo"));
    dbg("heartbeat running");
    while (*alive) {
        plist_t marco = NULL;
        heartbeat_error_t err = heartbeat_receive_with_timeout(hb, &marco, HB_MS);
        plist_free(marco);
        if (err != HEARTBEAT_E_SUCCESS) {
            dbg("heartbeat receive error %d", (int)err);
            break;
        }
        heartbeat_send(hb, polo);
    }
    plist_free(polo);
    heartbeat_client_free(hb);
}

static void *hb_manager_run(void *p) {
    HBManagerArg *a = p;
    while (*a->alive) {
        hb_run_once(a->device, a->alive);
        /* brief pause before retry so we don't hammer lockdownd */
        for (int i = 0; i < 5 && *a->alive; i++) sleep(1);
    }
    free(a);
    return NULL;
}

/* ── device slots ────────────────────────────────────────────────────────── */

typedef struct {
    char         udid[256];
    volatile int alive;
    volatile int in_use;
} Dev;

static Dev              devs[MAX_DEVS];
static pthread_mutex_t  devs_lock = PTHREAD_MUTEX_INITIALIZER;

/* ── device thread ───────────────────────────────────────────────────────── */

static void *dev_run(void *p) {
    Dev *dev = p;
    char buf[1024], su[256], sn[512];
    jstr(su, sizeof su, dev->udid);
    sn[0] = '\0';

    idevice_t           device = NULL;
    lockdownd_client_t  ld_bat = NULL;   /* kept open for battery polling */
    const char         *type   = "phone";

    dbg("connecting to %s", su);

    idevice_error_t ierr = idevice_new_with_options(&device, dev->udid,
            IDEVICE_LOOKUP_NETWORK | IDEVICE_LOOKUP_USBMUX);
    if (ierr != IDEVICE_E_SUCCESS) {
        dbg("idevice_new error %d for %s", (int)ierr, su);
        goto out;
    }

    /* battery lockdownd session — kept open for the lifetime of this thread */
    {
        lockdownd_error_t lerr = lockdownd_client_new_with_handshake(device, &ld_bat, "bartbeat-bat");
        if (lerr != LOCKDOWN_E_SUCCESS) {
            dbg("battery lockdown handshake error %d", (int)lerr);
            goto out;
        }
        dbg("battery lockdownd session OK");
    }

    /* read device name / class using the battery session (root domain is fine) */
    {
        char *name  = ld_str(ld_bat, NULL, "DeviceName");
        char *klass = ld_str(ld_bat, NULL, "DeviceClass");
        if (klass && strcasecmp(klass, "ipad") == 0) type = "pad";
        free(klass);
        jstr(sn, sizeof sn, name ? name : "");
        free(name);
        dbg("device: %s (%s)", sn, type);
    }

    /* heartbeat manager — self-restarting thread, independent of battery poll */
    {
        HBManagerArg *a = malloc(sizeof *a);
        a->device = device;  a->alive = &dev->alive;
        pthread_t t;
        pthread_create(&t, NULL, hb_manager_run, a);
        pthread_detach(t);
    }

    /* initial battery read */
    {
        int chg = 0;
        int lvl = get_battery(ld_bat, &chg);
        dbg("initial battery: %d%% charging=%d", lvl, chg);

        snprintf(buf, sizeof buf,
            "{\"type\":\"connected\",\"udid\":\"%s\",\"name\":\"%s\",\"device_type\":\"%s\"}",
            su, sn, type);
        emit(buf);

        if (lvl >= 0) {
            snprintf(buf, sizeof buf,
                "{\"type\":\"%s\",\"udid\":\"%s\",\"name\":\"%s\",\"level\":%d,\"charging\":%s}",
                type, su, sn, lvl, chg ? "true" : "false");
            emit(buf);
        }
    }

    /* battery poll loop — reuse ld_bat; reconnect after 3 consecutive failures */
    int fails = 0;
    for (int i = 0; i < POLL_S && dev->alive; i++) sleep(1);

    while (dev->alive) {
        int chg = 0;
        int lvl = get_battery(ld_bat, &chg);
        if (lvl >= 0) {
            fails = 0;
            snprintf(buf, sizeof buf,
                "{\"type\":\"%s\",\"udid\":\"%s\",\"name\":\"%s\",\"level\":%d,\"charging\":%s}",
                type, su, sn, lvl, chg ? "true" : "false");
            emit(buf);
            /* query Watch only from iPhone (Watch pairs to phone, not iPad) */
            if (strcmp(type, "phone") == 0)
                query_watch(device, ld_bat);
        } else {
            dbg("battery fail %d/3", ++fails);
            if (fails >= 3) break;   /* force reconnect */
        }
        for (int i = 0; i < POLL_S && dev->alive; i++) sleep(1);
    }

out:
    if (ld_bat) lockdownd_client_free(ld_bat);
    if (device)  idevice_free(device);

    snprintf(buf, sizeof buf, "{\"type\":\"disconnected\",\"udid\":\"%s\"}", su);
    emit(buf);

    pthread_mutex_lock(&devs_lock);
    dev->in_use = 0;
    pthread_mutex_unlock(&devs_lock);
    return NULL;
}

/* ── connect a UDID (shared helper for events + scan) ───────────────────── */

static void connect_udid(const char *udid) {
    pthread_mutex_lock(&devs_lock);
    /* skip if already tracked */
    for (int i = 0; i < MAX_DEVS; i++)
        if (devs[i].in_use && strcmp(devs[i].udid, udid) == 0) goto done;
    /* find a free slot */
    for (int i = 0; i < MAX_DEVS; i++) {
        if (!devs[i].in_use) {
            memset(&devs[i], 0, sizeof devs[i]);
            strncpy(devs[i].udid, udid, sizeof(devs[i].udid) - 1);
            devs[i].alive = devs[i].in_use = 1;
            pthread_t t;
            pthread_create(&t, NULL, dev_run, &devs[i]);
            pthread_detach(t);
            break;
        }
    }
done:
    pthread_mutex_unlock(&devs_lock);
}

/* ── usbmuxd event callback ──────────────────────────────────────────────── */

static void on_ev(const usbmuxd_event_t *ev, void *ud) {
    (void)ud;
    if (ev->event == UE_DEVICE_ADD) {
        connect_udid(ev->device.udid);
    } else if (ev->event == UE_DEVICE_REMOVE) {
        /* Ignore Wi-Fi (NETWORK) removes — those are transient.
         * Only a USB remove means the device is truly gone. */
        if (ev->device.conn_type == CONNECTION_TYPE_USB) {
            pthread_mutex_lock(&devs_lock);
            for (int i = 0; i < MAX_DEVS; i++)
                if (devs[i].in_use && strcmp(devs[i].udid, ev->device.udid) == 0)
                    { devs[i].alive = 0; break; }
            pthread_mutex_unlock(&devs_lock);
        }
    }
}

/* ── periodic scan (fallback for missed events / reconnect after failure) ── */

static volatile int g_stop = 0;

static void *scan_run(void *p) {
    (void)p;
    while (!g_stop) {
        for (int i = 0; i < POLL_S && !g_stop; i++) sleep(1);
        if (g_stop) break;

        usbmuxd_device_info_t *list = NULL;
        int n = usbmuxd_get_device_list(&list);
        for (int i = 0; i < n; i++) connect_udid(list[i].udid);
        usbmuxd_device_list_free(&list);
    }
    return NULL;
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    dbg("starting");

    usbmuxd_subscription_context_t ctx = NULL;
    usbmuxd_events_subscribe(&ctx, on_ev, NULL);

    /* initial scan */
    {
        usbmuxd_device_info_t *list = NULL;
        int n = usbmuxd_get_device_list(&list);
        dbg("initial scan: %d device(s)", n);
        for (int i = 0; i < n; i++) connect_udid(list[i].udid);
        usbmuxd_device_list_free(&list);
    }

    /* periodic reconnect thread */
    pthread_t scan_t;
    pthread_create(&scan_t, NULL, scan_run, NULL);
    pthread_detach(scan_t);

    /* exit when parent closes stdin */
    char tmp[16];
    while (fgets(tmp, sizeof tmp, stdin)) {}

    g_stop = 1;
    pthread_mutex_lock(&devs_lock);
    for (int i = 0; i < MAX_DEVS; i++) devs[i].alive = 0;
    pthread_mutex_unlock(&devs_lock);

    usbmuxd_events_unsubscribe(ctx);
    dbg("exiting");
    return 0;
}
