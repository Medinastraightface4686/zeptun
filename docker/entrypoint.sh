#!/bin/sh
set -eu

CONFIG_FILE="${CONFIG_FILE:-/run/zeptun.toml}"

quote() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

bool() {
    case "$1" in
        1|true|yes|on) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

list() {
    out=""
    for item in $(printf '%s' "$1" | tr ',' ' '); do
        if [ -n "$out" ]; then
            out="$out, "
        fi
        out="$out$(quote "$item")"
    done
    printf '[%s]' "$out"
}

write_config() {
    {
        printf 'log_level = %s\n' "$(quote "$LOG_LEVEL")"
        printf 'stats_interval_s = %s\n' "$STATS_INTERVAL"
        printf '\n[tun]\n'
        printf 'name = %s\n' "$(quote "$TUN")"
        printf 'mtu = %s\n' "$MTU"
        printf 'queues = %s\n' "$QUEUES"
        if [ -n "$IPV6" ]; then
            printf 'address = [%s, %s]\n' "$(quote "$IPV4")" "$(quote "$IPV6")"
        else
            printf 'address = [%s]\n' "$(quote "$IPV4")"
        fi
        printf '\n[stack]\n'
        printf 'mode = %s\n' "$(quote "$STACK")"
        printf 'icmp = %s\n' "$(quote "$ICMP")"
        printf 'udp_nat = %s\n' "$(quote "$(printf '%s' "$UDP_NAT" | tr '-' '_')")"
        printf '\n[io]\n'
        printf 'elastic = %s\n' "$(quote "$ELASTIC")"
        printf '\n[handler]\n'
        printf 'kind = %s\n' "$(quote "$HANDLER")"
        if [ "$HANDLER" = "socks5" ]; then
            printf '\n[handler.socks5]\n'
            printf 'server = %s\n' "$(quote "$SOCKS5_ADDR:$SOCKS5_PORT")"
            printf 'udp_mode = %s\n' "$(quote "$SOCKS5_UDP_MODE")"
            printf 'pool_size = %s\n' "$SOCKS5_POOL"
            if [ -n "$SOCKS5_USERNAME" ]; then
                printf 'username = %s\n' "$(quote "$SOCKS5_USERNAME")"
            fi
            if [ -n "$SOCKS5_PASSWORD" ]; then
                printf 'password = %s\n' "$(quote "$SOCKS5_PASSWORD")"
            fi
            if [ -n "$SOCKS5_UDP_ADDR" ]; then
                printf 'udp_address = %s\n' "$(quote "$SOCKS5_UDP_ADDR")"
            fi
        fi
        printf '\n[handler.direct]\n'
        printf 'fwmark = %s\n' "$FWMARK"
        printf '\n[route]\n'
        printf 'auto_route = %s\n' "$(bool "$AUTO_ROUTE")"
        printf 'auto_redirect = %s\n' "$(bool "$AUTO_REDIRECT")"
        printf 'fwmark = %s\n' "$FWMARK"
        if [ -n "$INCLUDED_ROUTES" ]; then
            printf 'include = %s\n' "$(list "$INCLUDED_ROUTES")"
        fi
        if [ -n "$EXCLUDED_ROUTES" ]; then
            printf 'exclude = %s\n' "$(list "$EXCLUDED_ROUTES")"
        fi
        printf '\n[dns]\n'
        printf 'fake_ip = %s\n' "$(bool "$FAKE_IP")"
        printf 'hijack = %s\n' "$(bool "$DNS_HIJACK")"
    } > "$CONFIG_FILE"
}

if [ "$#" -gt 0 ]; then
    exec zeptun "$@"
fi

if [ -n "$CONFIG" ]; then
    exec zeptun run -c "$CONFIG"
fi

write_config
exec zeptun run -c "$CONFIG_FILE"
