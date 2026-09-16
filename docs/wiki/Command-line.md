# Command line

```
usage: zeptun [run|probe|version|help] [options]

device:
  --tun NAME                 TUN interface name (default zeptun0)
  --tun-fd FD                use an existing TUN file descriptor
  --netns NAME               create the interface inside this network namespace
  --udp-nat MODE             endpoint-independent (default), address or address-port
  --mtu N                    interface MTU (default 1500)
  --queues N                 most queues and workers, 0 = automatic (one per CPU while elastic, else CPUs / 4)
  --elastic MODE             auto | on | off | rotate: start with one queue, attach more only when they add throughput
  --address CIDR             interface address, repeatable (IPv4 and IPv6)
  --no-address               do not assign default addresses
  --no-offload               disable IFF_VNET_HDR and TSO/USO offloads
  --no-multi-queue           single queue device
  --persist                  keep the device after exit
  --tun-napi                 deliver injected packets through NAPI with GRO (IFF_NAPI)
  --no-jumbo                 without offloads, keep TCP segments to the client within the MTU
  --txqueuelen N             device queue length (default: 1000-4096 packets without offloads)
  --no-configure             do not configure link, addresses or routes
stack:
  --stack MODE               userspace (default) | hybrid | system
  --preset NAME              desktop | mobile | server
  --max-tcp N                TCP session cap
  --max-udp N                UDP session cap
  --tcp-rx-window BYTES      largest per connection receive window
  --tcp-rx-budget BYTES      per worker memory windows may grow into beyond their 128K start
  --tcp-tx-buffer BYTES      per connection send buffer
  --tcp-idle-timeout MS
  --tcp-delayed-ack MS       piggyback ACKs for small segments up to MS, 0 = ACK immediately
  --tcp-early-accept         complete the client handshake before the upstream connects (default with socks5)
  --no-tcp-early-accept      wait for the upstream before completing the client handshake
  --udp-timeout MS
  --congestion ALG           cubic | newreno
  --no-udp                   reject UDP flows
  --icmp MODE                auto (forward with direct, local with socks5) | forward | local | drop
handler:
  --handler KIND             direct | socks5
  --socks5 HOST:PORT         SOCKS5 server, implies --handler socks5
  --socks5-user USER
  --socks5-pass PASS
  --socks5-no-udp            disable UDP ASSOCIATE
  --socks5-udp-mode MODE     udp (UDP ASSOCIATE, default) | tcp (datagrams framed over the control connection)
  --socks5-udp-address ADDR  use this address instead of the relay address the server reports
  --socks5-pipeline          send greeting, auth and request in one write (default without auth)
  --socks5-no-pipeline       wait for each SOCKS5 reply before the next message
  --socks5-no-optimistic     do not send buffered client data together with the CONNECT request
  --socks5-pool N            pre-connected, pre-authenticated proxy connections per worker (default 4, 0 = off)
  --socks5-pool-idle MS      recycle idle pooled connections after MS (default 3000)
  --tcp-fastopen             use TCP Fast Open for upstream connections
  --no-dscp                  do not copy the client DSCP marking to upstream sockets
  --fwmark N                 SO_MARK for upstream sockets
  --bind-interface NAME      bind upstream sockets to an interface
dns:
  --fake-ip                  answer A/AAAA queries with fake addresses and send domains to the SOCKS5 proxy
  --fake-ip-range CIDR       fake address pool, repeatable for IPv4 and IPv6 (default 198.18.0.0/15, fc00::/18)
  --fake-ip-cache N          remembered domains (default 16384)
  --fake-ip-ttl SECONDS      TTL of fake answers (default 1)
  --dns-address ADDR         in-tunnel DNS server address (default second address of the TUN prefix)
  --dns-hijack               capture DNS sent to any address
  --systemd-resolved MODE    auto | on | off: point systemd-resolved at the in-tunnel resolver while the tunnel is up
  --dns-upstream HOST:PORT   resolver for hijacked or non-address queries
routing:
  --auto-route               install policy routing through the tunnel
  --route CIDR               route only this prefix through the tunnel, repeatable, implies --auto-route
  --exclude CIDR             keep this prefix off the tunnel, repeatable
  --route-file FILE          read tunnel prefixes from FILE, one per line
  --exclude-file FILE        read excluded prefixes from FILE, one per line
  --strict-route             block address families the tunnel does not carry instead of leaking them
  --auto-redirect            send TCP headed for the tunnel to a kernel socket with nftables instead (Linux)
  --redirect-port N          port of the redirect listener (default: chosen by the kernel)
  --include-uid UID[-UID]    only route these users through the tunnel, repeatable (Linux)
  --exclude-uid UID[-UID]    keep these users off the tunnel, repeatable (Linux)
  --include-package NAME     only route this Android app through the tunnel, repeatable (Android root)
  --exclude-package NAME     keep this Android app off the tunnel, repeatable (Android root)
  --android-user N           only route these Android users, repeatable (Android root)
  --include-interface NAME   only route traffic arriving on NAME, repeatable (Linux)
  --exclude-interface NAME   keep traffic arriving on NAME off the tunnel, repeatable (Linux)
  --table N                  routing table (default 2022)
  --rule-priority N          first of ten rule priorities (default 9000)
io:
  --io BACKEND               auto | io_uring | epoll
  --sqpoll                   enable io_uring SQPOLL
  --ring-entries N
  --rx-parallel N            concurrent device reads per queue
  --tx-slots N               in-flight device writes per queue
  --busy-poll MICROS         keep polling this long after activity before sleeping
  --no-multishot             read the TUN with parallel reads instead of io_uring multishot
  --no-network-monitor       do not watch for default route changes
  --pin                      pin each worker to one CPU
  --no-pin                   do not pin workers to CPUs (default)
  --memory-budget BYTES      bound buffer pools and sessions
  --buffers N                packet buffers per worker
misc:
  -c, --config FILE          JSON configuration file
  --log-level LEVEL          err | warn | info | debug
  --log-file FILE            append logs to FILE instead of stderr
  --pid-file FILE            write the process id to FILE while running
  --post-up SCRIPT           run /bin/sh SCRIPT IFNAME after the tunnel is up
  --pre-down SCRIPT          run /bin/sh SCRIPT IFNAME before the tunnel is torn down
  --stats SECONDS            print counters periodically
  -h, --help
```

## Subcommands

| Command | Purpose |
|---|---|
| `zeptun run` | create the tunnel and forward traffic until interrupted |
| `zeptun probe` | report what the machine supports: TUN, offloads, io_uring, namespaces |
| `zeptun version` | version of the binary and the Zig toolchain that built it |
| `zeptun help` | the list above |

## Notes

* Any flag can be written in the configuration file instead; see [Configuration](Configuration).
* `-c FILE` loads a TOML or JSON document, and flags after it override single keys.
* `SIGINT` and `SIGTERM` tear the tunnel down cleanly, removing every address, route, rule and nftables table the engine installed.
* `--stats N` prints the counters of every worker every N seconds; the same counters are available through the C API.
