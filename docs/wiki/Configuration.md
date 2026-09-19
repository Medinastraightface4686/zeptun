# Configuration

`zeptun run -c FILE` reads TOML and JSON, told apart by content, so either extension works. `conf/zeptun.toml` in the repository carries every key with its default. Unknown keys are rejected instead of being ignored, and dotted keys (`tun.name = "zeptun0"`) are accepted.

```toml
preset = "desktop"
log_level = "warn"

[tun]
name = "zeptun0"
mtu = 8500
address = ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]

[handler]
kind = "socks5"

[handler.socks5]
server = "127.0.0.1:1080"
pool_size = 4

[route]
auto_route = true
```

## Presets

| Preset | Intent |
|---|---|
| `desktop` | default: MTU 8500, 64 Ki TCP sessions, 512 KB windows |
| `server` | MTU 9000, 256 Ki TCP sessions, 4 MB windows, 32 parallel reads |
| `mobile` | single queue, no offload, userspace stack, 64 KB windows, 24 MB memory budget |

A preset sets the defaults; every key after it in the document wins.

## Top level

| Key | Default | Meaning |
|---|---|---|
| `preset` | `desktop` | starting point for all other defaults |
| `log_level` | `warn` | `debug`, `info`, `warn`, `error` |
| `log_file` | | append logs to this path |
| `pid_file` | | write the process id while running |
| `stats_interval_s` | 0 | print counters every N seconds |
| `post_up_script` | | `/bin/sh SCRIPT IFNAME` once the tunnel is up |
| `pre_down_script` | | the same before it is torn down |

## `[tun]`

| Key | Default | Meaning |
|---|---|---|
| `name` | `zeptun0` | interface name |
| `fd` | -1 | use an existing descriptor instead of creating a device |
| `mtu` | 1500 | interface MTU; 8500 or more pays off with offloads |
| `queues` | CPUs | upper bound for queues and workers |
| `offload` | true | virtio-net header, TSO, USO, checksum offload |
| `multi_queue` | true | `IFF_MULTI_QUEUE` |
| `persist` | false | keep the device after the process exits |
| `napi` | false | deliver injected packets through NAPI with GRO |
| `jumbo` | true | allow segments larger than the MTU towards the client |
| `txqueuelen` | 1000 to 4096 | transmit queue length in packets |
| `configure` | true | assign addresses and bring the link up |
| `netns` | | name under `/run/netns` or a path; the interface is created there |
| `guid` | | fixed GUID for the Wintun adapter on Windows, `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}` or the same without braces; empty means the driver picks one |
| `address` | one v4 and one v6 prefix | repeat for more addresses per family |

## `[stack]`

| Key | Default | Meaning |
|---|---|---|
| `mode` | `userspace` | `userspace`, `hybrid`, `system` |
| `tcp_rx_window` | 512 KB | largest receive window per connection; a flow starts at 128 KB and grows only while it drains its queue |
| `tcp_tx_buffer` | 256 KB | largest send buffer per connection; flows start at a small floor and grow into `tcp_tx_budget` |
| `tcp_rx_budget` | 1 MB | per-worker memory that windows may grow into |
| `tcp_tx_budget` | 16 MB | per-worker memory that downlink queues share; each flow gets an equal slice of it |
| `tcp_mss_clamp` | 0 | clamp the advertised MSS |
| `tcp_initial_cwnd` | 10 | initial congestion window in segments |
| `congestion` | `cubic` | `cubic` or `newreno` |
| `sack`, `timestamps`, `window_scaling` | true | TCP options |
| `tcp_connect_timeout_ms` | 10000 | upstream connect timeout |
| `tcp_idle_timeout_ms` | 7200000 | idle connection lifetime |
| `tcp_delayed_ack_ms` | 1 | how long an ACK may wait for outgoing data |
| `tcp_early_accept` | `auto` | answer the handshake before the upstream is ready |
| `udp_idle_timeout_ms` | 60000 | idle session lifetime |
| `udp` | true | carry UDP at all |
| `udp_nat` | `endpoint_independent` | also `address`, `address_port` |
| `icmp` | `auto` | `forward`, `local`, `drop` |
| `max_tcp_sessions` | 65536 | least recently used are evicted |
| `max_udp_sessions` | 16384 | the same for UDP |
| `nat_port_base`, `nat_port_limit` | 20000, 65000 | port range of the system stack |

## `[handler]`

| Key | Default | Meaning |
|---|---|---|
| `kind` | `socks5` | `socks5`, `direct`, `passthrough` |
| `tcp_fastopen` | false | TCP Fast Open for upstream connections |
| `preserve_dscp` | true | copy the client's DSCP marking upstream |

### `[handler.socks5]`

| Key | Default | Meaning |
|---|---|---|
| `server` | | `host:port` of the proxy |
| `username`, `password` | | user and password authentication |
| `udp` | true | allow UDP through the proxy |
| `udp_mode` | `udp` | `udp` for UDP ASSOCIATE, `tcp` to frame datagrams over the control connection |
| `udp_address` | | use this relay address instead of the one the server reports |
| `pipeline` | auto | send the handshake and the request together |
| `optimistic_data` | auto | attach the first client bytes to the request |
| `pool_size` | 4 | warm connections and associations per worker; 0 disables |
| `pool_idle_ms` | 3000 | recycle pooled connections after this long |

### `[handler.direct]`

| Key | Default | Meaning |
|---|---|---|
| `fwmark` | 0x2022 with automatic routing | mark on upstream sockets so they bypass the tunnel |
| `bind_interface` | | bind upstream sockets to this interface |

## `[route]`

See [Routing](Routing) for what each rule does.

| Key | Default | Meaning |
|---|---|---|
| `auto_route` | false | install addresses, routes and policy rules |
| `table`, `rule_priority`, `fwmark` | 2022, 9000, 0x2022 | routing table, rule priority, socket mark |
| `include`, `exclude` | | prefixes carried by or kept off the tunnel |
| `include_file`, `exclude_file` | | the same as files, one prefix per line |
| `strict` | false | refuse traffic for a family the tunnel does not carry |
| `auto_redirect`, `redirect_port` | false, 0 | nftables redirect of TCP into a kernel socket |
| `include_uid`, `exclude_uid` | | user ranges such as `1000-1999` |
| `include_interface`, `exclude_interface` | | inbound interfaces, for routers |
| `include_package`, `exclude_package`, `android_user` | | Android package rules, with root |

## `[io]`

| Key | Default | Meaning |
|---|---|---|
| `backend` | `auto` | `io_uring` or `epoll` on Linux |
| `workers` | 0 | fixed worker count; 0 follows `queues` |
| `elastic` | `auto` | `on`, `off`, `rotate` |
| `rx_parallel` | 8 | concurrent device reads without multishot |
| `tx_slots` | 1024 | in-flight writes per queue |
| `multishot_rx` | true | io_uring multishot receive |
| `busy_poll_us` | 0 | keep polling after activity instead of sleeping |
| `pin_cpus` | false | pin every worker to one CPU |
| `monitor_network` | `auto` | watch for default route changes |

## `[dns]`

| Key | Default | Meaning |
|---|---|---|
| `fake_ip` | false | answer A and AAAA from a private pool and dial by domain |
| `fake_ranges` | `198.18.0.0/15`, `fc00::/18` | pools for fake addresses |
| `cache_size`, `ttl` | 16384, 1 | remembered domains and answer TTL |
| `address` | TUN prefix + 1 | in-tunnel resolver address |
| `hijack` | false | capture DNS sent to any address |
| `upstream` | | resolver for hijacked queries |
| `systemd_resolved` | `auto` | hand DNS to the tunnel through `resolvectl` |

## `[memory]`

| Key | Default | Meaning |
|---|---|---|
| `budget_bytes` | unlimited | bounds packet buffers and session tables |
| `buffers_per_worker` | derived | packet buffers each worker preallocates |
