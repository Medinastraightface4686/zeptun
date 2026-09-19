# C API

`include/zeptun.h` is hand written and stable: integer error codes, fixed-size structs checked at compile time, and no Zig types in the interface. Link against `libzeptun.a` or the shared library.

```c
#include <zeptun.h>

ZeptunConfig config;
zeptun_config_init(&config, ZEPTUN_PRESET_DESKTOP);
config.handler_kind = ZEPTUN_HANDLER_SOCKS5;
config.auto_route = 1;
snprintf(config.socks5_server, sizeof config.socks5_server, "127.0.0.1:1080");

Zeptun *tun = NULL;
int rc = zeptun_create(&config, &tun);
if (rc != ZEPTUN_OK) {
    fprintf(stderr, "%s\n", zeptun_strerror(rc));
    return 1;
}
zeptun_start(tun);
...
zeptun_stop(tun);
zeptun_destroy(tun);
```

## Lifecycle

| Function | Purpose |
|---|---|
| `zeptun_config_init(config, preset)` | fill the struct with the defaults of `ZEPTUN_PRESET_DESKTOP`, `_SERVER` or `_MOBILE` |
| `zeptun_create(config, out)` | create an engine from the struct |
| `zeptun_create_from_toml(text, len, out)` | create an engine from a TOML document |
| `zeptun_create_from_json(text, len, out)` | the same document as JSON |
| `zeptun_start(tun)` | spawn the workers; with a TUN device it returns once every queue is ready and the routes are installed |
| `zeptun_run(tun)` | run a single worker on the calling thread until `zeptun_stop`; used where the host owns its threads |
| `zeptun_stop(tun)` | stop from any thread, including from inside a callback; returns immediately |
| `zeptun_destroy(tun)` | join the workers, remove routes, free everything |

## Device

| Function | Purpose |
|---|---|
| `zeptun_set_device_fd(tun, fd)` | adopt an existing TUN descriptor, as `VpnService` and `NEPacketTunnelProvider` hand out |
| `zeptun_set_adapter_guid(tun, guid)` | pin the Wintun adapter GUID on Windows; it is only honoured when the adapter is created, so an existing adapter keeps its identity |
| `zeptun_set_read_callback(tun, cb, ctx)` | receive the packets the engine sends to the client, in batches of up to 128 |
| `zeptun_write_packet(tun, data, len)` | inject one packet |
| `zeptun_write_packets(tun, packets, count)` | inject a batch |
| `zeptun_inject_packets(tun, packets, count)` | inject packets that skip the stack, for passthrough mode |
| `zeptun_interface_name(tun, buffer, len)` | name of the created interface |

Set `device_kind` to `ZEPTUN_DEVICE_TUN` to create a device, `ZEPTUN_DEVICE_FD` to adopt one, or `ZEPTUN_DEVICE_EXTERNAL` to drive the engine entirely through the packet callbacks.

## Policy

| Function | Purpose |
|---|---|
| `zeptun_set_protect_callback(tun, cb, ctx)` | called with every upstream socket before it connects; return `false` to fail the connection |
| `zeptun_set_flow_callback(tun, cb, ctx)` | called once per new TCP connection and UDP session |
| `zeptun_set_log_callback(cb, ctx, level)` | process-wide log sink; the message is not NUL terminated |
| `zeptun_network_changed(tun, index)` | the default route moved to this interface index |

```c
static uint32_t judge(void *ctx, const ZeptunFlow *flow) {
    if (flow->protocol == 17 && flow->destination_port == 443) return ZEPTUN_FLOW_DIRECT;
    if (flow->destination_port == 25) return ZEPTUN_FLOW_REJECT;
    return ZEPTUN_FLOW_PROXY;
}
```

`ZeptunFlow` carries `protocol` (6 or 17), `family` (4 or 6), `source`, `destination`, `source_port` and `destination_port`. The verdicts are `ZEPTUN_FLOW_PROXY` (treat it as configured), `ZEPTUN_FLOW_DIRECT` (dial it directly even when a proxy is set), `ZEPTUN_FLOW_DROP` (discard silently) and `ZEPTUN_FLOW_REJECT` (answer with a TCP reset or an ICMP port unreachable).

## Statistics

`zeptun_stats(tun, &stats)` fills a `ZeptunStats` snapshot. `version` is 3. Besides packet and byte counters it reports `tcp_active`, `tcp_opened`, `tcp_retransmits`, `udp_active`, `nat_active`, `gso_segments`, `gro_merged`, `socks5_pool_hits`, `dns_fake_answers`, `dns_hijacked`, `tcp_migrated`, `udp_migrated`, `icmp_echo`, `icmp_time_exceeded` and `workers`. The snapshot is lock-free, so counters may be momentarily inconsistent with each other.

`zeptun_memory(tun, &memory)` fills a `ZeptunMemory` snapshot of the packet pool: `buffers` and `in_use` count buffers, `resident_bytes` is how much of the pool is still backed by physical pages, `released_bytes` is how much has been handed back to the kernel since start, `starved_flows` is how many flows are waiting for a buffer and `exhausted` counts failed allocations. The pool releases idle pages a few seconds after a burst, so `resident_bytes` falls on its own.

## Errors

`ZEPTUN_OK` is zero and every error is negative: `INVALID_ARGUMENT`, `OUT_OF_MEMORY`, `PERMISSION_DENIED`, `NOT_SUPPORTED`, `DEVICE`, `IO`, `ALREADY_RUNNING`, `NOT_RUNNING`, `WOULD_BLOCK`, `NOT_FOUND`, `LIMIT_EXCEEDED`, `ADDRESS_IN_USE`, `SYSTEM_OUTDATED`, `CLOSED`, `TIMEOUT`, `CONFIG`, `ROUTE`, `BUSY`. `zeptun_strerror` turns a code into a message.

## Thread safety

| Function | Rules |
|---|---|
| `zeptun_version`, `zeptun_strerror`, `zeptun_config_init` | pure, any thread, any time |
| `zeptun_set_log_callback` | process wide; call before creating engines |
| `zeptun_create` | any thread; handles are independent |
| every other setter | before `zeptun_start` or `zeptun_run`, otherwise `ZEPTUN_ERR_ALREADY_RUNNING` |
| `zeptun_write_packet`, `zeptun_write_packets`, `zeptun_inject_packets` | any number of threads at once; a full queue returns `ZEPTUN_ERR_WOULD_BLOCK` or a short count |
| `zeptun_stats`, `zeptun_memory`, `zeptun_stop` | any thread, including from callbacks |
| `zeptun_destroy` | once, never concurrently with another call on the same handle, never from a callback |

Callbacks run on worker threads and must not block.

## Linking

On Linux the libraries link libc so worker threads work in any C host. The Android library is libc-free unless built with `-Dandroid-libc`; without it, call `zeptun_run` on a thread you own, which runs a single worker.
