/*
 * wifiwatch — read Apple Watch battery from a paired iPhone over Wi-Fi.
 *
 * The Apple MobileDevice / CoreDevice transports refuse to start
 * com.apple.companion_proxy over the modern Wi-Fi pairing, but the classic
 * lockdown service still listens on TCP 62078 and will happily start the
 * companion proxy once a session is established with the host pair record.
 *
 * This helper talks to lockdownd directly:
 *   plaintext QueryType -> StartSession -> TLS -> StartService
 * and then opens a fresh (TLS) connection to the companion proxy for every
 * request, because the service closes the socket after each reply.
 *
 * Output: one JSON object per line on stdout; diagnostics on stderr.
 * Exits when the parent closes stdin.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <dns_sd.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <plist/plist.h>
#include <usbmuxd.h>
#include "watchlog.h"

#define POLL_S        30
#define TCP_TIMEOUT   6000
#define READ_TIMEOUT  10
#define PHONE_PORT    62078
#define CACHE_PATH    "/Library/Application Support/Barttery/wifi-ip"

static void dbg(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("[wifiwatch] ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(ap);
}

/* ── connection wrapper ──────────────────────────────────────────────────── */

typedef struct {
    int  fd;
    SSL *ssl;
} conn_t;

static int conn_read(conn_t *c, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        int r;
        if (c->ssl) r = SSL_read(c->ssl, (char *)buf + got, (int)(n - got));
        else        r = (int)read(c->fd, (char *)buf + got, n - got);
        if (r <= 0) return -1;
        got += (size_t)r;
    }
    return 0;
}

static int conn_write(conn_t *c, const void *buf, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        int r;
        if (c->ssl) r = SSL_write(c->ssl, (const char *)buf + sent, (int)(n - sent));
        else        r = (int)send(c->fd, (const char *)buf + sent, n - sent, 0);
        if (r <= 0) return -1;
        sent += (size_t)r;
    }
    return 0;
}

static int conn_send_plist(conn_t *c, plist_t p, int binary) {
    char *buf = NULL;
    uint32_t len = 0;
    if (binary) plist_to_bin(p, &buf, &len);
    else        plist_to_xml(p, &buf, &len);
    if (!buf || !len) return -1;

    uint32_t be = htonl(len);
    int rc = conn_write(c, &be, 4) || conn_write(c, buf, len);
    free(buf);
    return rc ? -1 : 0;
}

static plist_t conn_recv_plist(conn_t *c) {
    uint32_t be = 0;
    if (conn_read(c, &be, 4) != 0) return NULL;
    uint32_t len = ntohl(be);
    if (len == 0 || len > 4 * 1024 * 1024) return NULL;

    char *buf = malloc(len);
    if (!buf) return NULL;
    if (conn_read(c, buf, len) != 0) { free(buf); return NULL; }

    plist_t p = NULL;
    plist_from_memory(buf, len, &p, NULL);
    free(buf);
    return p;
}

static void conn_close(conn_t *c, SSL_CTX *ctx) {
    if (!c) return;
    if (c->ssl) {
        SSL_shutdown(c->ssl);
        SSL_free(c->ssl);
        c->ssl = NULL;
    }
    if (c->fd >= 0) { close(c->fd); c->fd = -1; }
    (void)ctx;
}

static int conn_start_tls(conn_t *c, SSL_CTX *ctx) {
    c->ssl = SSL_new(ctx);
    if (!c->ssl) return -1;
    SSL_set_fd(c->ssl, c->fd);
    if (SSL_connect(c->ssl) != 1) {
        dbg("TLS handshake failed: %s", ERR_error_string(ERR_get_error(), NULL));
        SSL_free(c->ssl);
        c->ssl = NULL;
        return -1;
    }
    return 0;
}

static int tcp_connect_ip(const char *ip, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port   = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &sa.sin_addr) != 1) { close(fd); return -1; }

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int r = connect(fd, (struct sockaddr *)&sa, sizeof sa);
    if (r < 0 && errno == EINPROGRESS) {
        fd_set w;
        FD_ZERO(&w); FD_SET(fd, &w);
        struct timeval tv = { TCP_TIMEOUT / 1000, (TCP_TIMEOUT % 1000) * 1000 };
        r = select(fd + 1, NULL, &w, NULL, &tv);
        if (r > 0) {
            int err = 0; socklen_t elen = sizeof err;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen);
            if (err != 0) { close(fd); return -1; }
            r = 0;
        } else {
            close(fd);
            return -1;
        }
    } else if (r < 0) {
        close(fd);
        return -1;
    }
    fcntl(fd, F_SETFL, flags);

    struct timeval rtv = { READ_TIMEOUT, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof rtv);
    struct timeval stv = { READ_TIMEOUT, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stv, sizeof stv);
    return fd;
}

/* ── device discovery ────────────────────────────────────────────────────── */

static char g_host[256];
static int  g_found;
#define MAX_WIFI_IPS 32
static char g_ips[MAX_WIFI_IPS][64];
static int g_ip_count;

static void resolve_cb(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t ifIndex,
                       DNSServiceErrorType err, const char *fullname,
                       const char *hosttarget, uint16_t port, uint16_t txtLen,
                       const unsigned char *txt, void *ctx) {
    (void)sdRef; (void)flags; (void)ifIndex; (void)fullname; (void)port;
    (void)txtLen; (void)txt; (void)ctx;
    if (err == kDNSServiceErr_NoError && hosttarget) {
        snprintf(g_host, sizeof g_host, "%s", hosttarget);
        g_found = 1;
    }
}

static void browse_cb(DNSServiceRef sdRef, DNSServiceFlags flags, uint32_t ifIndex,
                      DNSServiceErrorType err, const char *name,
                      const char *regtype, const char *domain, void *ctx) {
    (void)sdRef; (void)ctx;
    if (err != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd)) return;

    g_found = 0;
    g_host[0] = 0;

    DNSServiceRef r = NULL;
    if (DNSServiceResolve(&r, 0, ifIndex, name, regtype, domain, resolve_cb, NULL) != kDNSServiceErr_NoError)
        return;

    int fd = DNSServiceRefSockFD(r);
    for (int i = 0; i < 40 && !g_found; i++) {
        fd_set f;
        FD_ZERO(&f); FD_SET(fd, &f);
        struct timeval tv = { 0, 100000 };
        if (select(fd + 1, &f, NULL, NULL, &tv) > 0) DNSServiceProcessResult(r);
    }
    DNSServiceRefDeallocate(r);

    if (!g_found) return;
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(g_host, NULL, &hints, &addresses) != 0) return;
    for (struct addrinfo *a = addresses; a; a = a->ai_next) {
        char ip[64];
        struct sockaddr_in *sa = (struct sockaddr_in *)a->ai_addr;
        if (!inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof ip)) continue;
        int duplicate = 0;
        for (int i = 0; i < g_ip_count; i++)
            if (strcmp(ip, g_ips[i]) == 0) duplicate = 1;
        if (!duplicate && g_ip_count < MAX_WIFI_IPS)
            snprintf(g_ips[g_ip_count++], sizeof g_ips[0], "%s", ip);
    }
    freeaddrinfo(addresses);
}

static int discover_ips(void) {
    static const char *types[] = { "_apple-mobdev2._tcp", "_remotepairing._tcp" };
    g_ip_count = 0;

    for (size_t t = 0; t < sizeof types / sizeof types[0]; t++) {
        g_found = 0;
        g_host[0] = 0;

        DNSServiceRef browse = NULL;
        if (DNSServiceBrowse(&browse, 0, 0, types[t], "local.", browse_cb, NULL)
            != kDNSServiceErr_NoError)
            continue;

        int fd = DNSServiceRefSockFD(browse);
        for (int i = 0; i < 30; i++) {
            fd_set f;
            FD_ZERO(&f); FD_SET(fd, &f);
            struct timeval tv = { 0, 100000 };
            if (select(fd + 1, &f, NULL, NULL, &tv) > 0) DNSServiceProcessResult(browse);
        }
        DNSServiceRefDeallocate(browse);

    }

    if (!g_ip_count) dbg("no usable mDNS advertisement found");
    return g_ip_count;
}

static void cache_path(char *out, size_t outlen) {
    const char *home = getenv("HOME");
    snprintf(out, outlen, "%s%s", home ? home : "", CACHE_PATH);
}

static int read_cached_ip(char *out, size_t outlen) {
    char path[1024];
    cache_path(path, sizeof path);
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int ok = fgets(out, (int)outlen, f) != NULL;
    fclose(f);
    if (!ok) return -1;
    out[strcspn(out, "\r\n")] = 0;
    return out[0] ? 0 : -1;
}

static void write_cached_ip(const char *ip) {
    char path[1024];
    cache_path(path, sizeof path);
    char dir[1024];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash) {
        *slash = 0;
        /* mkdir -p */
        for (char *p = dir + 1; *p; p++) {
            if (*p == '/') {
                *p = 0;
                mkdir(dir, 0700);
                *p = '/';
            }
        }
        mkdir(dir, 0700);
    }
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%s\n", ip);
    fclose(f);
}

/* ── pair record + TLS context ───────────────────────────────────────────── */

static char *dict_string(plist_t dict, const char *key) {
    plist_t node = plist_dict_get_item(dict, key);
    if (!node) return NULL;

    plist_type type = plist_get_node_type(node);
    if (type == PLIST_STRING) {
        char *s = NULL;
        plist_get_string_val(node, &s);
        return s;
    }
    if (type == PLIST_DATA) {
        char *data = NULL;
        uint64_t len = 0;
        plist_get_data_val(node, &data, &len);
        if (!data) return NULL;
        char *s = malloc((size_t)len + 1);
        if (s) {
            memcpy(s, data, (size_t)len);
            s[len] = 0;
        }
        free(data);
        return s;
    }
    return NULL;
}

static SSL_CTX *make_tls_context(const char *cert_pem, const char *key_pem) {
    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) return NULL;

    SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(ctx, TLS1_2_VERSION);
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    SSL_CTX_set_mode(ctx, SSL_MODE_AUTO_RETRY);

    BIO *cb = BIO_new_mem_buf(cert_pem, -1);
    X509 *cert = cb ? PEM_read_bio_X509(cb, NULL, NULL, NULL) : NULL;
    if (cb) BIO_free(cb);
    if (!cert || SSL_CTX_use_certificate(ctx, cert) != 1) {
        dbg("cannot load host certificate");
        if (cert) X509_free(cert);
        SSL_CTX_free(ctx);
        return NULL;
    }
    X509_free(cert);

    BIO *kb = BIO_new_mem_buf(key_pem, -1);
    EVP_PKEY *pkey = kb ? PEM_read_bio_PrivateKey(kb, NULL, NULL, NULL) : NULL;
    if (kb) BIO_free(kb);
    if (!pkey || SSL_CTX_use_PrivateKey(ctx, pkey) != 1) {
        dbg("cannot load host private key");
        if (pkey) EVP_PKEY_free(pkey);
        SSL_CTX_free(ctx);
        return NULL;
    }
    EVP_PKEY_free(pkey);
    return ctx;
}

/* ── lockdown ────────────────────────────────────────────────────────────── */

static plist_t xml_request(const char *request) {
    plist_t p = plist_new_dict();
    plist_dict_set_item(p, "Label",   plist_new_string("Barttery"));
    plist_dict_set_item(p, "Request", plist_new_string(request));
    return p;
}

static int lockdown_open(const char *ip, const char *host_id, const char *buid,
                         SSL_CTX *ctx, conn_t *c) {
    memset(c, 0, sizeof *c);
    c->fd = tcp_connect_ip(ip, PHONE_PORT);
    if (c->fd < 0) { dbg("cannot connect to %s:%d", ip, PHONE_PORT); return -1; }

    plist_t q = xml_request("QueryType");
    int rc = conn_send_plist(c, q, 0);
    plist_free(q);
    plist_t resp = rc == 0 ? conn_recv_plist(c) : NULL;
    if (!resp) { dbg("QueryType failed"); conn_close(c, ctx); return -1; }
    plist_free(resp);

    plist_t s = xml_request("StartSession");
    plist_dict_set_item(s, "HostID",     plist_new_string(host_id));
    plist_dict_set_item(s, "SystemBUID", plist_new_string(buid));
    rc = conn_send_plist(c, s, 0);
    plist_free(s);
    resp = rc == 0 ? conn_recv_plist(c) : NULL;
    if (!resp) { dbg("StartSession failed"); conn_close(c, ctx); return -1; }

    plist_t err = plist_dict_get_item(resp, "Error");
    int enable_ssl = 0;
    plist_t ssl_node = plist_dict_get_item(resp, "EnableSessionSSL");
    if (ssl_node) enable_ssl = plist_bool_val_is_true(ssl_node);
    if (err) {
        char *msg = NULL;
        plist_get_string_val(err, &msg);
        dbg("StartSession error: %s", msg ? msg : "?");
        free(msg);
        plist_free(resp);
        conn_close(c, ctx);
        return -1;
    }
    plist_free(resp);

    if (enable_ssl && conn_start_tls(c, ctx) != 0) {
        conn_close(c, ctx);
        return -1;
    }
    return 0;
}

static int lockdown_start_service(conn_t *c, const char *service, int *port, int *ssl) {
    plist_t req = xml_request("StartService");
    plist_dict_set_item(req, "Service", plist_new_string(service));
    int rc = conn_send_plist(c, req, 0);
    plist_free(req);
    if (rc != 0) return -1;

    plist_t resp = conn_recv_plist(c);
    if (!resp) { dbg("StartService(%s) failed", service); return -1; }

    plist_t err = plist_dict_get_item(resp, "Error");
    plist_t port_node = plist_dict_get_item(resp, "Port");
    if (err || !port_node) {
        char *msg = NULL;
        if (err) plist_get_string_val(err, &msg);
        dbg("StartService(%s) error: %s", service, msg ? msg : "no port");
        free(msg);
        plist_free(resp);
        return -1;
    }
    uint64_t p = 0;
    plist_get_uint_val(port_node, &p);
    plist_t ssl_node = plist_dict_get_item(resp, "EnableServiceSSL");
    *port = (int)p;
    *ssl  = ssl_node ? plist_bool_val_is_true(ssl_node) : 0;
    plist_free(resp);
    return 0;
}

/* ── companion proxy ─────────────────────────────────────────────────────── */

static plist_t companion_request(conn_t *ld, SSL_CTX *ctx, const char *ip,
                                 plist_t request) {
    int port = 0, ssl = 0;
    if (lockdown_start_service(ld, "com.apple.companion_proxy", &port, &ssl) != 0)
        return NULL;

    conn_t c;
    memset(&c, 0, sizeof c);
    c.fd = tcp_connect_ip(ip, port);
    if (c.fd < 0) { dbg("cannot connect to service port %d", port); return NULL; }
    if (ssl && conn_start_tls(&c, ctx) != 0) { conn_close(&c, ctx); return NULL; }

    plist_t out = NULL;
    if (conn_send_plist(&c, request, 1) == 0) {
        out = conn_recv_plist(&c);
        if (!out) dbg("no reply from companion service (port %d)", port);
    } else {
        dbg("cannot send companion request (port %d)", port);
    }
    conn_close(&c, ctx);
    return out;
}

typedef struct {
    SSL_CTX *ctx;
    conn_t   ld;
    int      ld_open;
    char     ip[64];
    char     host_id[128];
    char     buid[128];
} wifi_state_t;

static void wifi_reset(wifi_state_t *st) {
    if (st->ld_open) { conn_close(&st->ld, st->ctx); st->ld_open = 0; }
    if (st->ctx) { SSL_CTX_free(st->ctx); st->ctx = NULL; }
}

static int wifi_prepare(wifi_state_t *st, const char *udid, const char *ip_override) {
    if (!st->ctx) {
        char *pdata = NULL;
        uint32_t psize = 0;
        if (usbmuxd_read_pair_record(udid, &pdata, &psize) != 0 || !pdata) {
            dbg("cannot read pair record for %s", udid);
            return -1;
        }

        plist_t pair = NULL;
        plist_from_memory(pdata, psize, &pair, NULL);
        free(pdata);
        if (!pair) { dbg("cannot parse pair record"); return -1; }

        char *cert = dict_string(pair, "HostCertificate");
        char *key  = dict_string(pair, "HostPrivateKey");
        char *hid  = dict_string(pair, "HostID");
        char *buid = dict_string(pair, "SystemBUID");
        if (!cert || !key || !hid || !buid) {
            dbg("pair record is incomplete (cert=%d key=%d host=%d buid=%d)",
                cert != NULL, key != NULL, hid != NULL, buid != NULL);
            free(cert); free(key); free(hid); free(buid);
            plist_free(pair);
            return -1;
        }

        st->ctx = make_tls_context(cert, key);
        free(cert); free(key);
        if (!st->ctx) {
            free(hid); free(buid); plist_free(pair);
            return -1;
        }
        snprintf(st->host_id, sizeof st->host_id, "%s", hid);
        snprintf(st->buid,    sizeof st->buid,    "%s", buid);
        free(hid); free(buid); plist_free(pair);
    }

    if (!st->ld_open) {
        char cached[64] = "";
        const char *ip = ip_override;
        if (!ip && read_cached_ip(cached, sizeof cached) == 0) ip = cached;
        if (ip && lockdown_open(ip, st->host_id, st->buid, st->ctx, &st->ld) == 0) {
            snprintf(st->ip, sizeof st->ip, "%s", ip);
            st->ld_open = 1;
            write_cached_ip(ip);
            return 0;
        }
        /* Bonjour includes other phones and iPads. A successful session with
         * this UDID's pair record authenticates the candidate before caching. */
        if (!ip_override) {
            discover_ips();
            for (int i = 0; i < g_ip_count; i++) {
                if (ip && strcmp(ip, g_ips[i]) == 0) continue;
                if (lockdown_open(g_ips[i], st->host_id, st->buid, st->ctx, &st->ld) != 0)
                    continue;
                snprintf(st->ip, sizeof st->ip, "%s", g_ips[i]);
                st->ld_open = 1;
                write_cached_ip(st->ip);
                dbg("authenticated paired iPhone at %s", st->ip);
                return 0;
            }
        }
        wifi_reset(st);
        return -1;
    }
    return 0;
}

static int read_watch(wifi_state_t *st, const char *udid, const char *ip_override,
                      char *name, size_t name_len,
                      char *model, size_t model_len,
                      int *level, int *charging, char *watch_udid, size_t watch_len) {
    if (wifi_prepare(st, udid, ip_override) != 0) return -1;

    plist_t reg_req = plist_new_dict();
    plist_dict_set_item(reg_req, "Command", plist_new_string("GetDeviceRegistry"));
    plist_t reg = companion_request(&st->ld, st->ctx, st->ip, reg_req);
    plist_free(reg_req);
    if (!reg) {
        dbg("GetDeviceRegistry failed");
        wifi_reset(st);
        return -1;
    }

    plist_t arr = plist_dict_get_item(reg, "PairedDevicesArray");
    if (!arr || plist_array_get_size(arr) == 0) {
        dbg("no paired watch in registry");
        plist_free(reg);
        return -1;
    }
    plist_t first = plist_array_get_item(arr, 0);
    char *wid = NULL;
    plist_get_string_val(first, &wid);
    if (!wid) { plist_free(reg); return -1; }
    snprintf(watch_udid, watch_len, "%s", wid);

    int got_level = 0;
    const char *keys[] = { "DeviceName", "ProductType", "BatteryCurrentCapacity", "BatteryIsCharging" };
    for (int i = 0; i < 4; i++) {
        plist_t req = plist_new_dict();
        plist_dict_set_item(req, "Command", plist_new_string("GetValueFromRegistry"));
        plist_dict_set_item(req, "GetValueGizmoUDIDKey", plist_new_string(wid));
        plist_dict_set_item(req, "GetValueKeyKey", plist_new_string(keys[i]));

        plist_t resp = companion_request(&st->ld, st->ctx, st->ip, req);
        plist_free(req);
        if (!resp) {
            dbg("request for %s failed", keys[i]);
            free(wid);
            plist_free(reg);
            wifi_reset(st);
            return -1;
        }
        plist_t dict = plist_dict_get_item(resp, "RetrievedValueDictionary");
        plist_t val = dict ? plist_dict_get_item(dict, keys[i]) : NULL;
        if (val) {
            switch (i) {
            case 0: {
                char *s = NULL;
                plist_get_string_val(val, &s);
                if (s) { snprintf(name, name_len, "%s", s); free(s); }
                break;
            }
            case 1: {
                char *s = NULL;
                plist_get_string_val(val, &s);
                if (s) { snprintf(model, model_len, "%s", s); free(s); }
                break;
            }
            case 2: {
                uint64_t u = 0;
                if (plist_get_node_type(val) == PLIST_UINT) {
                    plist_get_uint_val(val, &u);
                    *level = (int)u;
                } else {
                    int64_t sval = 0;
                    plist_get_int_val(val, &sval);
                    *level = (int)sval;
                }
                got_level = 1;
                break;
            }
            case 3:
                *charging = plist_bool_val_is_true(val) ? 1 : 0;
                break;
            }
        }
        plist_free(resp);
    }
    free(wid);
    plist_free(reg);
    return got_level ? 0 : -1;
}

/* ── JSON output ─────────────────────────────────────────────────────────── */

static void json_escape(const char *in, char *out, size_t outlen) {
    size_t o = 0;
    for (const unsigned char *p = (const unsigned char *)in; *p && o + 6 < outlen; p++) {
        if (*p == '"' || *p == '\\') { out[o++] = '\\'; out[o++] = (char)*p; }
        else if (*p < 0x20)          { o += (size_t)snprintf(out + o, outlen - o, "\\u%04x", *p); }
        else                         { out[o++] = (char)*p; }
    }
    out[o] = 0;
}

static void emit_watch(const char *watch_udid, const char *name,
                       const char *model, int level, int charging) {
    char ename[1024], emodel[256];
    json_escape(name, ename, sizeof ename);
    json_escape(model, emodel, sizeof emodel);
    printf("{\"type\":\"watch\",\"udid\":\"%s\",\"name\":\"%s\",\"model\":\"%s\","
           "\"level\":%d,\"charging\":%s}\n",
           watch_udid, ename, emodel, level, charging ? "true" : "false");
    fflush(stdout);
}

/* ── main ────────────────────────────────────────────────────────────────── */

static int stdin_alive(void) {
    fd_set f;
    FD_ZERO(&f); FD_SET(STDIN_FILENO, &f);
    struct timeval tv = { 0, 0 };
    if (select(STDIN_FILENO + 1, &f, NULL, NULL, &tv) > 0) {
        char buf[64];
        ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
        if (n <= 0) return 0;
    }
    return 1;
}

/* The phone battery must not depend on MobileDevice's discovery run loop.
 * Use the authenticated lockdown session independently of Watch events. */
static void poll_phone(wifi_state_t *st, const char *udid) {
    if (!st->ld_open) {
        if (lockdown_open(st->ip, st->host_id, st->buid, st->ctx, &st->ld) != 0)
            return;
        st->ld_open = 1;
    }
    plist_t req = xml_request("GetValue");
    plist_dict_set_item(req, "Domain", plist_new_string("com.apple.mobile.battery"));
    int rc = conn_send_plist(&st->ld, req, 0);
    plist_free(req);
    plist_t resp = rc == 0 ? conn_recv_plist(&st->ld) : NULL;
    plist_t value = resp ? plist_dict_get_item(resp, "Value") : NULL;
    plist_t capacity = value && plist_get_node_type(value) == PLIST_DICT
        ? plist_dict_get_item(value, "BatteryCurrentCapacity") : NULL;
    uint64_t level = 101;
    if (capacity && plist_get_node_type(capacity) == PLIST_UINT)
        plist_get_uint_val(capacity, &level);
    if (level <= 100) {
        plist_t charging = plist_dict_get_item(value, "BatteryIsCharging");
        printf("{\"type\":\"phone\",\"udid\":\"%s\",\"level\":%llu",
               udid, (unsigned long long)level);
        if (charging && plist_get_node_type(charging) == PLIST_BOOLEAN)
            printf(",\"charging\":%s", plist_bool_val_is_true(charging) ? "true" : "false");
        puts("}");
        fflush(stdout);
    } else {
        dbg("phone battery query failed; will reopen lockdown session");
        conn_close(&st->ld, st->ctx);
        st->ld_open = 0;
    }
    if (resp) plist_free(resp);
}

/* syslog_relay streams new events; do not request an archive or replay a file.
 * Keep this connection for a few minutes, then retry the primary service.
 * No raw phone logs are stored or forwarded to the app. */
static int stream_watch(wifi_state_t *st, const char *udid, const char *ip_hint,
                        int once) {
    if (wifi_prepare(st, udid, ip_hint) != 0) return -1;
    poll_phone(st, udid);
    if (!st->ld_open && wifi_prepare(st, udid, ip_hint) != 0) return -1;
    int port = 0, ssl = 0;
    if (lockdown_start_service(&st->ld, "com.apple.syslog_relay", &port, &ssl) != 0) {
        wifi_reset(st);
        return -1;
    }
    conn_t c = { .fd = tcp_connect_ip(st->ip, port), .ssl = NULL };
    if (c.fd < 0) return -1;
    if (ssl && conn_start_tls(&c, st->ctx) != 0) {
        conn_close(&c, st->ctx);
        return -1;
    }
    dbg("listening for live Watch power-source events");
    time_t deadline = time(NULL) + (once ? 25 : 300);
    time_t next_phone_poll = time(NULL) + POLL_S;
    char line[16384], chunk[4096];
    size_t used = 0;
    int overflow = 0, emitted = 0;
    while (time(NULL) < deadline) {
        if (!once && !stdin_alive()) break;
        if (time(NULL) >= next_phone_poll) {
            poll_phone(st, udid);
            next_phone_poll = time(NULL) + POLL_S;
        }
        /* Check pending TLS plaintext before waiting on the socket. */
        if (!c.ssl || SSL_pending(c.ssl) == 0) {
            fd_set f;
            FD_ZERO(&f); FD_SET(c.fd, &f);
            struct timeval tv = { 1, 0 };
            int ready = select(c.fd + 1, &f, NULL, NULL, &tv);
            if (ready == 0) continue;
            if (ready < 0) { if (errno == EINTR) continue; break; }
        }
        int n = c.ssl ? SSL_read(c.ssl, chunk, sizeof chunk)
                      : (int)read(c.fd, chunk, sizeof chunk);
        if (n <= 0) break;
        for (int i = 0; i < n; i++) {
            unsigned char ch = (unsigned char)chunk[i];
            if (ch == '\n' || ch == 0) {
                line[used] = 0;
                int level = overflow ? -1 : watchlog_level(line);
                if (level >= 0) {
                    int charging = watchlog_charging(line);
                    /* No Watch UDID/name is available in this event. */
                    printf("{\"type\":\"watch\",\"level\":%d,\"source\":\"wifi-power-event\"", level);
                    if (charging >= 0)
                        printf(",\"charging\":%s", charging ? "true" : "false");
                    puts("}");
                    fflush(stdout);
                    emitted = 1;
                }
                used = 0;
                overflow = 0;
            } else if (used + 1 < sizeof line) {
                line[used++] = (char)ch;
            } else {
                overflow = 1;
            }
        }
        if (once && emitted) break;
    }
    conn_close(&c, st->ctx);
    /* Long-lived lockdown sessions can expire while the stream is active. */
    wifi_reset(st);
    return emitted ? 0 : -1;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);

    if (argc < 2) {
        fprintf(stderr, "usage: %s PHONE_UDID [PHONE_IP] [--once]\n", argv[0]);
        return 2;
    }
    const char *udid    = argv[1];
    const char *ip_hint = (argc > 2 && argv[2][0] != '-') ? argv[2] : NULL;
    int once = (argc > 2 && strcmp(argv[2], "--once") == 0) ||
               (argc > 3 && strcmp(argv[3], "--once") == 0);

    dbg("starting for %s", udid);
    char name[512] = "", model[128] = "", wid[128] = "";
    int level = -1, charging = 0;
    wifi_state_t st;
    memset(&st, 0, sizeof st);

    for (;;) {
        int rc = read_watch(&st, udid, ip_hint, name, sizeof name, model, sizeof model,
                            &level, &charging, wid, sizeof wid);
        if (rc == 0) {
            emit_watch(wid, name, model, level, charging);
            poll_phone(&st, udid);
        }
        else stream_watch(&st, udid, ip_hint, once);

        if (once) break;

        for (int i = 0; i < POLL_S; i++) {
            sleep(1);
            if (!stdin_alive()) { dbg("parent closed stdin, exiting"); return 0; }
        }
    }

    dbg("exiting");
    return 0;
}
