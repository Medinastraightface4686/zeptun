#!/bin/sh
set -u

if [ "${ZEPTUN_FOOTPRINT_INNER:-}" != "1" ]; then
    export ZEPTUN_FOOTPRINT_INNER=1
    exec unshare --user --map-root-user --net --fork -- sh "$0" "$@"
fi

SCRIPT_DIR=$(dirname "$(realpath "$0")")
. "$SCRIPT_DIR/netns_lib.sh"

ZEPTUN=$(realpath "${ZEPTUN:-zig-out/bin/zeptun}")
BENCH=$(realpath "${BENCH:-zig-out/bin/zeptun-bench}")
HEV=${HEV:-}
TUN2SOCKS=${TUN2SOCKS:-}
SINGBOX=${SINGBOX:-}
SOCKS_SERVER=${SOCKS_SERVER:-}
QUEUES=${QUEUES:-1}
MTU=${MTU:-8500}
ENGINES=${ENGINES:-"zeptun hev"}
TESTS=${TESTS:-"tcp:1000 tcp:10000 udp:1000 udp:10000"}
IDLE_SECONDS=${IDLE_SECONDS:-20}
HOLD_MS=${HOLD_MS:-4000}
OUT_DIR=${OUT_DIR:-footprint-results}
mkdir -p "$OUT_DIR"
OUT_DIR=$(realpath "$OUT_DIR")

ns_setup
for knob in "net.ipv4.tcp_tw_reuse=1" "net.ipv4.ip_local_port_range=1024 65000" "net.core.somaxconn=65535" "net.ipv4.tcp_max_syn_backlog=65535"; do
    sysctl -qw "$knob" 2> /dev/null || true
    in_server sysctl -qw "$knob" 2> /dev/null || true
done
ulimit -n 1048576 2> /dev/null || ulimit -n 65536
cleanup() {
    for pid in ${PIDS:-}; do kill -9 "$pid" 2> /dev/null || true; done
    ns_teardown
}
trap cleanup EXIT INT TERM

bg_server "$BENCH" tcp-server --listen "$SERVER_ADDR:5201"
bg_server "$BENCH" udp-server --listen "$SERVER_ADDR:5202" --echo
if [ -n "$SOCKS_SERVER" ]; then
    printf "main:\n  workers: 4\n  port: 1080\n  listen-address: '%s'\nmisc:\n  limit-nofile: 1048576\n" "$VETH_SERVER" > "$OUT_DIR/socks5-server.yml"
    bg_server "$SOCKS_SERVER" "$OUT_DIR/socks5-server.yml"
else
    bg_server "$BENCH" socks5-server --listen "$VETH_SERVER:1080"
fi
wait_port 5201
wait_port 1080

pss_of() {
    total=0
    for p in $1; do
        v=$(awk '/^Pss:/ {print $2}' "/proc/$p/smaps_rollup" 2> /dev/null)
        total=$((total + ${v:-0}))
    done
    echo "$total"
}

switches_of() {
    total=0
    for p in $1; do
        for t in /proc/"$p"/task/*; do
            v=$(awk '/^voluntary_ctxt_switches|^nonvoluntary_ctxt_switches/ {s += $2} END {print s + 0}' "$t/status" 2> /dev/null)
            total=$((total + ${v:-0}))
        done
    done
    echo "$total"
}

start_engine() {
    name=$1
    PIDS=""
    DEV=""
    t0=$(date +%s%N)
    case "$name" in
        zeptun)
            "$ZEPTUN" run --tun zep0 --mtu "$MTU" --auto-route --socks5 "$VETH_SERVER:1080" --log-level warn --queues "$QUEUES" > "$OUT_DIR/zeptun.log" 2>&1 &
            PIDS=$!
            DEV=zep0
            ;;
        hev)
            [ -n "$HEV" ] || return 1
            printf "tunnel:\n  name: hev0\n  mtu: %s\n  multi-queue: false\n  ipv4: 198.18.0.1\nsocks5:\n  port: 1080\n  address: %s\n  udp: 'udp'\n  pipeline: true\nmisc:\n  log-level: error\n  limit-nofile: 1048576\n" "$MTU" "$VETH_SERVER" > "$OUT_DIR/hev.yml"
            "$HEV" "$OUT_DIR/hev.yml" > "$OUT_DIR/hev.log" 2>&1 &
            PIDS=$!
            DEV=hev0
            ;;
        singbox-*)
            [ -n "$SINGBOX" ] || return 1
            stack=${name#singbox-}
            printf '{"log":{"level":"error"},"inbounds":[{"type":"tun","tag":"tun-in","interface_name":"sb0","address":["172.18.0.1/30"],"mtu":%s,"auto_route":false,"stack":"%s"}],"outbounds":[{"type":"socks","tag":"proxy","server":"%s","server_port":1080}],"route":{"final":"proxy"}}' "$MTU" "$stack" "$VETH_SERVER" > "$OUT_DIR/singbox.json"
            "$SINGBOX" run -c "$OUT_DIR/singbox.json" > "$OUT_DIR/singbox.log" 2>&1 &
            PIDS=$!
            DEV=sb0
            ;;
        tun2socks)
            [ -n "$TUN2SOCKS" ] || return 1
            "$TUN2SOCKS" -d tun://t2s0 -p "socks5://$VETH_SERVER:1080" --mtu "$MTU" --loglevel error > "$OUT_DIR/tun2socks.log" 2>&1 &
            PIDS=$!
            DEV=t2s0
            ;;
        *) return 1 ;;
    esac
    for _ in $(seq 1 400); do
        ip -o link show "$DEV" 2> /dev/null | grep -q UP && break
        if [ "$name" = "tun2socks" ] && ip -o link show "$DEV" > /dev/null 2>&1; then break; fi
        sleep 0.005
    done
    t1=$(date +%s%N)
    STARTUP_MS=$(( (t1 - t0) / 1000000 ))
    if [ "$name" = "tun2socks" ]; then
        ip addr add 198.18.0.1/15 dev t2s0 2> /dev/null
        ip link set t2s0 up
    fi
    case "$name" in
        zeptun) TUN_NAME=zep0; wait_tun ;;
        *)
            ip route replace default dev "$DEV" table 2022
            ip rule add pref 9000 lookup main suppress_prefixlength 0
            ip rule add pref 9001 lookup 2022
            ;;
    esac
}

stop_engine() {
    case "$1" in
        zeptun) ;;
        *)
            ip rule del pref 9001 2> /dev/null
            ip rule del pref 9000 2> /dev/null
            ip route flush table 2022 2> /dev/null
            ;;
    esac
    for p in $PIDS; do kill -INT "$p" 2> /dev/null; done
    for p in $PIDS; do
        for _ in $(seq 1 50); do kill -0 "$p" 2> /dev/null || break; sleep 0.1; done
        kill -9 "$p" 2> /dev/null
        wait "$p" 2> /dev/null
    done
    PIDS=""
    sleep 0.5
}

peak_during() {
    PEAK=0
    while kill -0 "$1" 2> /dev/null; do
        v=$(pss_of "$PIDS")
        [ "$v" -gt "$PEAK" ] && PEAK=$v
        sleep 0.5
    done
    wait "$1" 2> /dev/null
}

for name in $ENGINES; do
    if ! start_engine "$name"; then
        printf "%s: not available\n" "$name"
        continue
    fi
    sleep 2
    idle=$(pss_of "$PIDS")
    a=$(switches_of "$PIDS")
    sleep "$IDLE_SECONDS"
    b=$(switches_of "$PIDS")
    line="$name: startup ${STARTUP_MS} ms, idle ${idle} KB, $((b - a)) wakeups in ${IDLE_SECONDS} s"
    stop_engine "$name"
    for test in $TESTS; do
        kind=${test%%:*}
        count=${test#*:}
        start_engine "$name" || continue
        sleep 2
        if [ "$kind" = "tcp" ]; then
            timeout 900 "$BENCH" conns --connect "$SERVER_ADDR:5201" --count "$count" --hold-ms "$HOLD_MS" > "$OUT_DIR/client.out" 2>&1 &
        else
            timeout 900 "$BENCH" udp-flows --connect "$SERVER_ADDR:5202" --count "$count" --hold-ms "$HOLD_MS" > "$OUT_DIR/client.out" 2>&1 &
        fi
        peak_during $!
        line="$line | $kind $count: ${PEAK} KB ($(tail -n 1 "$OUT_DIR/client.out"))"
        stop_engine "$name"
    done
    printf "%s\n" "$line" | tee -a "$OUT_DIR/footprint.txt"
done
