#!/bin/sh
set -eu

if [ "${ZEPTUN_NETNS_INNER:-}" != "1" ]; then
    export ZEPTUN_NETNS_INNER=1
    exec unshare --user --map-root-user --net --fork -- sh "$0" "$@"
fi

ZEPTUN=$(realpath "$1")
BENCH=$(realpath "$2")
SCRIPT_DIR=$(dirname "$(realpath "$0")")
LOG_DIR=${LOG_DIR:-$(mktemp -d)}
. "$SCRIPT_DIR/netns_lib.sh"

PASSED=0
FAILED=0
FAILURES=""

check() {
    label=$1
    shift
    if timeout 60 "$@" > "$LOG_DIR/step.log" 2>&1; then
        PASSED=$((PASSED + 1))
        printf "  ok    %-48s %s\n" "$label" "$(tail -n 1 "$LOG_DIR/step.log")"
    else
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $label"
        printf "  FAIL  %s\n" "$label"
        sed 's/^/        /' "$LOG_DIR/step.log" | tail -n 15
    fi
}

run_case() {
    name=$1
    shift
    printf "case %s\n" "$name"
    "$ZEPTUN" run --tun "$TUN_NAME" --mtu 8500 --auto-route --log-level warn "$@" > "$LOG_DIR/$name.log" 2>&1 &
    engine=$!
    if ! wait_tun; then
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $name: tunnel did not come up"
        printf "  FAIL  tunnel did not come up\n"
        sed 's/^/        /' "$LOG_DIR/$name.log" | tail -n 20
        kill "$engine" 2> /dev/null || true
        wait "$engine" 2> /dev/null || true
        return
    fi
    check "$name tcp upload" "$BENCH" tcp-client --connect "$SERVER_ADDR:5201" --seconds 2
    check "$name tcp download" "$BENCH" tcp-client --connect "$SERVER_ADDR:5201" --seconds 2 --reverse
    check "$name tcp 4 streams" "$BENCH" tcp-client --connect "$SERVER_ADDR:5201" --seconds 2 --streams 4
    check "$name integrity 64MiB echo" "$BENCH" verify --connect "$SERVER_ADDR:5201" --bytes 67108864
    check "$name request/response" "$BENCH" rr-client --connect "$SERVER_ADDR:5201" --seconds 2 --conns 4 --size 256
    check "$name 500 concurrent connections" "$BENCH" conns --connect "$SERVER_ADDR:5201" --count 500 --hold-ms 200
    check "$name udp echo" "$BENCH" udp-client --connect "$SERVER_ADDR:5202" --seconds 2 --size 1200 --pps 2000 --echo
    check "$name udp gso bursts" "$BENCH" udp-client --connect "$SERVER_ADDR:5202" --seconds 2 --size 1300 --pps 20000 --echo --gso
    if command -v ping > /dev/null 2>&1; then
        check "$name icmp echo" ping -c 3 -i 0.2 -W 2 "$SERVER_ADDR"
    fi
    kill -INT "$engine"
    if ! wait "$engine"; then
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $name: engine exited with failure"
        printf "  FAIL  engine exit status\n"
        sed 's/^/        /' "$LOG_DIR/$name.log" | tail -n 20
    fi
    if command -v nft > /dev/null 2>&1 && nft list tables 2> /dev/null | grep -q zeptun; then
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $name: nftables table left behind"
        printf "  FAIL  nftables table left behind\n"
    fi
    if ip rule show | grep -q "^900[0-9]:" || ip -6 rule show | grep -q "^900[0-9]:"; then
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $name: policy rules left behind"
        printf "  FAIL  policy rules left behind\n"
    fi
}

ns_setup
trap ns_teardown EXIT INT TERM
sysctl -qw net.ipv4.ping_group_range="0 0" 2> /dev/null || true
bg_server "$BENCH" tcp-server --listen "$SERVER_ADDR:5201"
bg_server "$BENCH" udp-server --listen "$SERVER_ADDR:5202" --echo
bg_server "$BENCH" socks5-server --listen "$VETH_SERVER:1080"
bg_server "$BENCH" socks5-server --listen "$VETH_SERVER:1081" --map-host "$SERVER_ADDR"
wait_port 5201
wait_port 5202
wait_port 1080
wait_port 1081

check "baseline direct tcp without tunnel" "$BENCH" tcp-client --connect "$SERVER_ADDR:5201" --seconds 1

run_case hybrid-io_uring-direct --stack hybrid --io io_uring --queues 4
run_case userspace-io_uring-direct --stack userspace --io io_uring
run_case userspace-epoll-direct --stack userspace --io epoll
run_case system-epoll-direct --stack system --io epoll --queues 4
run_case userspace-io_uring-socks5 --stack userspace --io io_uring --queues 4 --socks5 "$VETH_SERVER:1080"
run_case userspace-fixed-queues-socks5 --stack userspace --io io_uring --queues 4 --elastic off --socks5 "$VETH_SERVER:1080"
run_case userspace-elastic-rotate-socks5 --stack userspace --queues 4 --elastic rotate --socks5 "$VETH_SERVER:1080"
run_case userspace-epoll-socks5-nopool --stack userspace --io epoll --socks5 "$VETH_SERVER:1080" --socks5-pool 0 --tcp-fastopen
run_case hybrid-epoll-socks5 --stack hybrid --io epoll --queues 4 --socks5 "$VETH_SERVER:1080"
run_case userspace-socks5-udp-over-tcp --stack userspace --socks5 "$VETH_SERVER:1080" --socks5-udp-mode tcp
printf "# tunnel prefixes\n%s/32\n" "$SERVER_ADDR" > "$LOG_DIR/routes.txt"
run_case userspace-strict-route-file --stack userspace --strict-route --route-file "$LOG_DIR/routes.txt" --exclude-interface veth0 --socks5 "$VETH_SERVER:1080" --socks5-udp-address "$VETH_SERVER"
run_case userspace-auto-redirect-socks5 --stack userspace --auto-redirect --socks5 "$VETH_SERVER:1080"
run_case hybrid-auto-redirect-direct --stack hybrid --auto-redirect --queues 4
run_case userspace-udp-nat-address-port --stack userspace --udp-nat address-port --socks5 "$VETH_SERVER:1080"
run_case userspace-no-offload --stack userspace --no-offload --queues 1
run_case userspace-io_uring-slots --stack userspace --io io_uring --no-multishot

elastic_case() {
    name=$1
    shift
    printf "case %s\n" "$name"
    "$ZEPTUN" run --tun "$TUN_NAME" --mtu 8500 --auto-route --log-level info --queues 4 --elastic rotate --stats 1 "$@" > "$LOG_DIR/$name.log" 2>&1 &
    engine=$!
    if ! wait_tun; then
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $name: tunnel did not come up"
        printf "  FAIL  tunnel did not come up\n"
        kill "$engine" 2> /dev/null || true
        wait "$engine" 2> /dev/null || true
        return
    fi
    verifiers=""
    for seed in 1 2; do
        timeout 120 "$BENCH" verify --connect "$SERVER_ADDR:5201" --bytes 1500000000 --seed "$seed" > "$LOG_DIR/$name-verify$seed.log" 2>&1 &
        verifiers="$verifiers $!"
    done
    check "$name 8 streams while queues rotate" "$BENCH" tcp-client --connect "$SERVER_ADDR:5201" --seconds 6 --streams 8
    check "$name download while queues rotate" "$BENCH" tcp-client --connect "$SERVER_ADDR:5201" --seconds 3 --streams 4 --reverse
    check "$name request/response while queues rotate" "$BENCH" rr-client --connect "$SERVER_ADDR:5201" --seconds 3 --conns 8 --size 256
    check "$name udp echo while queues rotate" "$BENCH" udp-client --connect "$SERVER_ADDR:5202" --seconds 3 --size 1200 --pps 2000 --echo
    for pid in $verifiers; do wait "$pid" || true; done
    check "$name integrity of moved connections" sh -c "grep -q '^verify: OK' '$LOG_DIR/$name-verify1.log' && grep -q '^verify: OK' '$LOG_DIR/$name-verify2.log'"
    kill -INT "$engine"
    wait "$engine" || true
    check "$name queues grew to four" grep -q "elastic: queue 3 attached" "$LOG_DIR/$name.log"
    check "$name queues shrank again" grep -q "elastic: queue 1 detached" "$LOG_DIR/$name.log"
    check "$name tcp connections migrated" grep -Eq "migrated tcp [1-9]" "$LOG_DIR/$name.log"
    check "$name udp sessions migrated" grep -Eq "migrated tcp [0-9]+ udp [1-9]" "$LOG_DIR/$name.log"
}

elastic_case elastic-rotate-io_uring-socks5 --socks5 "$VETH_SERVER:1080"
elastic_case elastic-rotate-epoll-direct --io epoll

fake_ip_case() {
    name=$1
    shift
    printf "case %s\n" "$name"
    "$ZEPTUN" run --tun "$TUN_NAME" --mtu 8500 --auto-route --log-level warn --socks5 "$VETH_SERVER:1081" --fake-ip "$@" > "$LOG_DIR/$name.log" 2>&1 &
    engine=$!
    if ! wait_tun; then
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $name: tunnel did not come up"
        printf "  FAIL  tunnel did not come up\n"
        sed 's/^/        /' "$LOG_DIR/$name.log" | tail -n 20
        kill "$engine" 2> /dev/null || true
        wait "$engine" 2> /dev/null || true
        return
    fi
    check "$name A answer" "$BENCH" dns-client --server 172.19.0.2:53 --name echo.zeptun.test --count 50 --expect 198.18.0.1
    check "$name AAAA answer" "$BENCH" dns-client --server 172.19.0.2:53 --name echo.zeptun.test --type AAAA --expect fc00::1
    check "$name second name" "$BENCH" dns-client --server 172.19.0.2:53 --name udp.zeptun.test --expect 198.18.0.2
    check "$name hijacked resolver" "$BENCH" dns-client --server 9.9.9.9:53 --name echo.zeptun.test --expect 198.18.0.1
    check "$name tcp integrity by domain" "$BENCH" verify --connect 198.18.0.1:5201 --bytes 16777216
    check "$name request/response by domain" "$BENCH" rr-client --connect 198.18.0.1:5201 --seconds 1 --conns 2 --size 128 --crr
    check "$name udp echo by domain" "$BENCH" udp-client --connect 198.18.0.2:5202 --seconds 1 --size 300 --pps 500 --echo
    kill -INT "$engine"
    if ! wait "$engine"; then
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $name: engine exited with failure"
        printf "  FAIL  engine exit status\n"
    fi
}

fake_ip_case fake-ip-userspace --dns-hijack
fake_ip_case fake-ip-hybrid --stack hybrid --dns-hijack --socks5-pool 0
fake_ip_case fake-ip-udp-over-tcp --dns-hijack --socks5-udp-mode tcp

netns_case() {
    name=netns-userspace
    printf "case %s\n" "$name"
    unshare --net sh -c "ip link set lo up; sleep 60" &
    holder=$!
    nspath=/proc/$holder/ns/net
    i=0
    while [ $i -lt 50 ]; do
        nsenter --net="$nspath" true 2> /dev/null && break
        i=$((i + 1))
        sleep 0.1
    done
    "$ZEPTUN" run --tun zepns0 --netns "$nspath" --auto-route --stack userspace --log-level warn > "$LOG_DIR/$name.log" 2>&1 &
    engine=$!
    i=0
    while [ $i -lt 100 ]; do
        nsenter --net="$nspath" ip link show zepns0 > /dev/null 2>&1 && break
        i=$((i + 1))
        sleep 0.1
    done
    check "$name interface lives in the namespace" nsenter --net="$nspath" ip link show zepns0
    check "$name address applied in the namespace" sh -c "nsenter --net='$nspath' ip -o addr show dev zepns0 | grep -q 172.19.0.1"
    check "$name policy rules applied in the namespace" sh -c "nsenter --net='$nspath' ip rule show | grep -q '^900'"
    check "$name host namespace untouched" sh -c "! ip link show zepns0 > /dev/null 2>&1 && ! ip rule show | grep -q '^900'"
    kill -INT "$engine"
    if ! wait "$engine"; then
        FAILED=$((FAILED + 1))
        FAILURES="$FAILURES\n  $name: engine exited with failure"
        printf "  FAIL  engine exit status\n"
    fi
    check "$name interface removed on stop" sh -c "! nsenter --net='$nspath' ip link show zepns0 > /dev/null 2>&1"
    kill "$holder" 2> /dev/null || true
    wait "$holder" 2> /dev/null || true
}

if command -v nsenter > /dev/null 2>&1 && command -v unshare > /dev/null 2>&1; then
    netns_case
fi

printf "\nintegration: %d passed, %d failed\n" "$PASSED" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
    printf "failures:$FAILURES\n"
    printf "logs in %s\n" "$LOG_DIR"
    exit 1
fi
