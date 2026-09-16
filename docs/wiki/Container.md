# Container

The image builds Zeptun from source with Zig on Alpine and ships a single static binary plus `iproute2`.

```sh
docker run --rm --device /dev/net/tun --cap-add NET_ADMIN --cap-add NET_RAW \
  -e SOCKS5_ADDR=172.17.0.1 -e SOCKS5_PORT=1080 ghcr.io/noisemux/zeptun
```

`NET_ADMIN` and `/dev/net/tun` are required; `NET_RAW` is only needed for ICMP forwarding.

## Compose

```yaml
services:
  tun:
    image: ghcr.io/noisemux/zeptun
    cap_add:
      - NET_ADMIN
      - NET_RAW
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      SOCKS5_ADDR: a.b.c.d
      SOCKS5_PORT: 1080
      EXCLUDED_ROUTES: a.b.c.d/32
    dns:
      - 8.8.8.8

  client:
    image: alpine
    tty: true
    network_mode: "service:tun"
    depends_on:
      - tun
```

Everything that shares `network_mode: "service:tun"` reaches the network through the tunnel.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `TUN` | `zeptun0` | interface name |
| `MTU` | 8500 | interface MTU |
| `IPV4`, `IPV6` | `172.19.0.1/30`, `fdfe:dcba:9876::1/126` | interface addresses; empty disables the family |
| `STACK` | `userspace` | `userspace`, `hybrid`, `system` |
| `HANDLER` | `socks5` | `socks5` or `direct` |
| `SOCKS5_ADDR`, `SOCKS5_PORT` | `172.17.0.1`, 1080 | proxy endpoint |
| `SOCKS5_USERNAME`, `SOCKS5_PASSWORD` | | proxy authentication |
| `SOCKS5_UDP_MODE` | `udp` | `udp` or `tcp` |
| `SOCKS5_UDP_ADDR` | | override the relay address the proxy reports |
| `SOCKS5_POOL` | 4 | warm proxy connections per worker |
| `QUEUES` | 0 | TUN queues; 0 follows the CPU count |
| `ELASTIC` | `auto` | elastic queue mode |
| `UDP_NAT` | `endpoint-independent` | `address` or `address-port` to restrict the NAT |
| `AUTO_ROUTE` | 1 | install routes and policy rules inside the container |
| `AUTO_REDIRECT` | 0 | nftables redirect instead of the device for TCP |
| `FAKE_IP`, `DNS_HIJACK` | 0 | fake-IP answers, DNS capture |
| `INCLUDED_ROUTES`, `EXCLUDED_ROUTES` | | comma separated prefixes |
| `FWMARK` | 0x2022 | mark upstream sockets carry |
| `ICMP` | `auto` | `forward`, `local`, `drop` |
| `LOG_LEVEL` | `warn` | `debug`, `info`, `warn`, `error` |
| `STATS_INTERVAL` | 0 | print counters every N seconds |
| `CONFIG` | | path to your own TOML or JSON file; the variables above are then ignored |
| `CONFIG_FILE` | `/run/zeptun.toml` | where the generated document is written |

`docker/entrypoint.sh` turns these into a TOML document. Passing arguments to the container runs any subcommand instead: `docker run ... ghcr.io/noisemux/zeptun probe`.

## Images

| Tag | Content |
|---|---|
| `latest` | newest tagged release |
| `X.Y.Z`, `X.Y` | a specific release |

Images are built for `linux/amd64`, `linux/arm64` and `linux/riscv64`.
