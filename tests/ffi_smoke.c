#define _POSIX_C_SOURCE 200809L

#include "zeptun.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

_Static_assert(sizeof(ZeptunConfig) == 848, "ZeptunConfig layout");
_Static_assert(sizeof(ZeptunStats) == 312, "ZeptunStats layout");

static atomic_int received = 0;
static atomic_int judged = 0;
static atomic_int rst_seen = 0;

static void on_packets(void *ctx, const ZeptunPacket *packets, size_t count) {
    (void)ctx;
    for (size_t i = 0; i < count; i++) {
        const unsigned char *p = packets[i].data;
        if (packets[i].len >= 34 && p[9] == 6 && (p[33] & 0x04) != 0) atomic_fetch_add(&rst_seen, 1);
    }
    atomic_fetch_add(&received, (int)count);
}

static atomic_int direct_port = 0;

static uint32_t on_flow(void *ctx, const ZeptunFlow *flow) {
    (void)ctx;
    if (flow->protocol == 6 && flow->destination_port == 9) {
        atomic_fetch_add(&judged, 1);
        return ZEPTUN_FLOW_REJECT;
    }
    if (flow->protocol == 6 && flow->destination_port == atomic_load(&direct_port)) return ZEPTUN_FLOW_DIRECT;
    return ZEPTUN_FLOW_PROXY;
}

static unsigned char tcp_syn[] = {
    0x45, 0x00, 0x00, 0x28, 0x00, 0x02, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00,
    10, 0, 0, 2, 1, 1, 1, 1,
    0x30, 0x39, 0x00, 0x09, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x50, 0x02, 0x20, 0x00, 0x00, 0x00, 0x00, 0x00,
};

static unsigned char icmp_echo[] = {
    0x45, 0x00, 0x00, 0x1c, 0x00, 0x01, 0x40, 0x00, 0x40, 0x01, 0x00, 0x00,
    10, 0, 0, 2, 1, 1, 1, 1,
    0x08, 0x00, 0xf7, 0xfe, 0x00, 0x01, 0x00, 0x00,
};

static void fix_ipv4_checksum(unsigned char *hdr) {
    unsigned long sum = 0;
    hdr[10] = 0;
    hdr[11] = 0;
    for (int i = 0; i < 20; i += 2) sum += (unsigned long)((hdr[i] << 8) | hdr[i + 1]);
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    sum = ~sum & 0xffff;
    hdr[10] = (unsigned char)(sum >> 8);
    hdr[11] = (unsigned char)(sum & 0xff);
}

static int bypasses_proxy(void) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) return 40;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(0x7f000001u);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof sa) != 0 || listen(lfd, 4) != 0) return 41;
    socklen_t len = sizeof sa;
    if (getsockname(lfd, (struct sockaddr *)&sa, &len) != 0) return 42;
    uint16_t port = ntohs(sa.sin_port);
    atomic_store(&direct_port, port);
    fcntl(lfd, F_SETFL, O_NONBLOCK);

    ZeptunConfig cfg;
    if (zeptun_config_init(&cfg, ZEPTUN_PRESET_DESKTOP) != ZEPTUN_OK) return 43;
    cfg.device_kind = ZEPTUN_DEVICE_EXTERNAL;
    cfg.handler_kind = ZEPTUN_HANDLER_SOCKS5;
    cfg.log_level = ZEPTUN_LOG_ERROR;
    snprintf(cfg.socks5_server, sizeof cfg.socks5_server, "127.0.0.1:1");
    Zeptun *tun = NULL;
    if (zeptun_create(&cfg, &tun) != ZEPTUN_OK || tun == NULL) return 44;
    if (zeptun_set_flow_callback(tun, on_flow, NULL) != ZEPTUN_OK) return 45;
    if (zeptun_start(tun) != ZEPTUN_OK) return 46;

    unsigned char syn[sizeof tcp_syn];
    memcpy(syn, tcp_syn, sizeof syn);
    syn[16] = 127;
    syn[17] = 0;
    syn[18] = 0;
    syn[19] = 1;
    syn[22] = (unsigned char)(port >> 8);
    syn[23] = (unsigned char)(port & 0xff);
    fix_ipv4_checksum(syn);
    ZeptunPacket pkt = { .data = syn, .len = sizeof syn };
    if (zeptun_write_packets(tun, &pkt, 1) != 1) return 47;

    struct timespec pause = { .tv_sec = 0, .tv_nsec = 10000000 };
    int accepted = -1;
    for (int i = 0; i < 300 && accepted < 0; i++) {
        accepted = accept(lfd, NULL, NULL);
        if (accepted < 0) nanosleep(&pause, NULL);
    }
    zeptun_stop(tun);
    zeptun_destroy(tun);
    if (accepted >= 0) close(accepted);
    close(lfd);
    return accepted >= 0 ? 0 : 48;
}

int main(void) {
    if (zeptun_version() != ((ZEPTUN_VERSION_MAJOR << 16) | (ZEPTUN_VERSION_MINOR << 8) | ZEPTUN_VERSION_PATCH)) return 10;
    if (strcmp(zeptun_strerror(ZEPTUN_ERR_TIMEOUT), "timeout") != 0) return 11;
    ZeptunConfig cfg;
    if (zeptun_config_init(&cfg, ZEPTUN_PRESET_MOBILE) != ZEPTUN_OK) return 12;
    cfg.device_kind = ZEPTUN_DEVICE_EXTERNAL;
    cfg.handler_kind = ZEPTUN_HANDLER_SOCKS5;
    cfg.log_level = ZEPTUN_LOG_WARN;
    snprintf(cfg.socks5_server, sizeof cfg.socks5_server, "127.0.0.1:1");
    Zeptun *tun = NULL;
    int rc = zeptun_create(&cfg, &tun);
    if (rc != ZEPTUN_OK || tun == NULL) {
        fprintf(stderr, "create failed: %s\n", zeptun_strerror(rc));
        return 13;
    }
    if (zeptun_set_read_callback(tun, on_packets, NULL) != ZEPTUN_OK) return 14;
    if (zeptun_set_flow_callback(tun, on_flow, NULL) != ZEPTUN_OK) return 26;
    if (zeptun_start(tun) != ZEPTUN_OK) return 15;
    if (zeptun_start(tun) != ZEPTUN_ERR_ALREADY_RUNNING) return 16;
    fix_ipv4_checksum(icmp_echo);
    ZeptunPacket pkt = { .data = icmp_echo, .len = sizeof(icmp_echo) };
    if (zeptun_write_packets(tun, &pkt, 1) != 1) return 17;
    struct timespec pause = { .tv_sec = 0, .tv_nsec = 10000000 };
    for (int i = 0; i < 300 && atomic_load(&received) == 0; i++) nanosleep(&pause, NULL);
    fix_ipv4_checksum(tcp_syn);
    ZeptunPacket syn = { .data = tcp_syn, .len = sizeof(tcp_syn) };
    if (zeptun_write_packets(tun, &syn, 1) != 1) return 27;
    for (int i = 0; i < 300 && atomic_load(&rst_seen) == 0; i++) nanosleep(&pause, NULL);
    if (zeptun_network_changed(tun, 0) != ZEPTUN_OK) return 25;
    ZeptunStats stats;
    if (zeptun_stats(tun, &stats) != ZEPTUN_OK) return 18;
    if (zeptun_stop(tun) != ZEPTUN_OK) return 19;
    zeptun_destroy(tun);
    if (atomic_load(&received) != 2) {
        fprintf(stderr, "expected an echo reply and a reset, got %d\n", atomic_load(&received));
        return 20;
    }
    if (atomic_load(&judged) != 1 || atomic_load(&rst_seen) != 1) {
        fprintf(stderr, "flow callback judged %d, resets %d\n", atomic_load(&judged), atomic_load(&rst_seen));
        return 28;
    }
    if (stats.icmp_echo != 1 || stats.rx_packets != 2) return 21;
    if (stats.version != 3) return 22;
    static const char json[] = "{\"preset\":\"mobile\",\"tun\":{\"configure\":false},\"handler\":{\"kind\":\"socks5\",\"socks5\":{\"server\":\"127.0.0.1:1080\",\"udp_mode\":\"tcp\"}},\"dns\":{\"fake_ip\":true}}";
    Zeptun *from_json = NULL;
    rc = zeptun_create_from_json(json, sizeof(json) - 1, &from_json);
    if (rc != ZEPTUN_OK || from_json == NULL) {
        fprintf(stderr, "json create failed: %s\n", zeptun_strerror(rc));
        return 23;
    }
    zeptun_destroy(from_json);
    Zeptun *bad = NULL;
    if (zeptun_create_from_json("{\"nope\":1}", 11, &bad) != ZEPTUN_ERR_CONFIG || bad != NULL) return 24;
    int bypass = bypasses_proxy();
    if (bypass != 0) {
        fprintf(stderr, "direct verdict did not bypass the proxy: %d\n", bypass);
        return bypass;
    }
    printf("ffi smoke ok: %s\n", zeptun_version_string());
    return 0;
}
