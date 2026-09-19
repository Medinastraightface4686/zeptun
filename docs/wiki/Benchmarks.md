# Benchmarks

Every number here is produced by the `benchmark` workflow in the repository, on a GitHub-hosted runner, against hev-socks5-tunnel, sing-box and tun2socks over the same SOCKS5 server.

## Machine

| property | value |
|---|---|
| runner image | ubuntu24 20260907.300.1 |
| cpu | AMD EPYC 7763 64-Core Processor |
| cpu cores | 4 |
| memory | 15.6 GB |
| kernel | Linux 6.17.0-1022-azure |
| zig | 0.16.0 |
| date | 2026-09-19 |

## Method

Two network namespaces joined by a veth pair. Traffic enters the tunnel device (MTU 8500), leaves through the same SOCKS5 server (hev-socks5-server) for every engine, and reaches the servers in the second namespace. Engines are interleaved: each round starts every engine once and runs every scenario against it, so background noise spreads evenly. CPU comes from `/proc/<pid>/stat` and memory from `VmRSS`, summed over all processes of an engine.

Duration 8 s per scenario, 2 rounds, 4 queues.

## Throughput

![throughput](res/throughput.svg)

## CPU

![cpu](res/cpu.svg)

## Request and response

![transactions](res/transactions.svg)

![latency](res/latency.svg)

## UDP

![udp](res/udp.svg)

## Memory

![memory](res/memory.svg)

## Scenarios

| Scenario | What it measures |
|---|---|
| `tcp-up-1`, `tcp-up-10` | bulk upload over one and ten streams |
| `tcp-down-1`, `tcp-down-10` | the same downstream |
| `rr` | request and response on a held connection, one at a time |
| `rr-8x1k` | eight connections exchanging 1 KB messages |
| `crr` | connect, exchange, close, repeatedly |
| `udp-100k` | 100k datagrams per second, echoed |
| `udp-gso-100k` | the same with segmentation offload on the client |

## Raw results

| engine | scenario | median | cpu % | max rss MB |
|---|---|---:|---:|---:|
| zeptun-userspace | tcp-up-1 | 18.642 Gbit/s | 78 | 10.0 |
| zeptun-userspace | tcp-up-10 | 22.990 Gbit/s | 121 | 20.1 |
| zeptun-userspace | tcp-down-1 | 11.686 Gbit/s | 99 | 20.1 |
| zeptun-userspace | tcp-down-10 | 21.141 Gbit/s | 180 | 28.8 |
| zeptun-userspace | rr | 6942 tps p50=140us p99=178us p99.9=202us  | 36 | 28.8 |
| zeptun-userspace | rr-8x1k | 32706 tps p50=232us p99=476us p99.9=616us  | 102 | 20.9 |
| zeptun-userspace | crr | 1902 tps p50=508us p99=584us p99.9=648us  | 45 | 24.6 |
| zeptun-userspace | udp-100k | 77904 echo pps (77.9% of 99992 sent)  | 75 | 24.9 |
| zeptun-userspace | udp-gso-100k | 81219 echo pps (81.2% of 99992 sent)  | 55 | 27.7 |
| hev | tcp-up-1 | 5.979 Gbit/s | 96 | 14.8 |
| hev | tcp-up-10 | 13.318 Gbit/s | 212 | 16.2 |
| hev | tcp-down-1 | 6.573 Gbit/s | 99 | 15.3 |
| hev | tcp-down-10 | 11.089 Gbit/s | 205 | 16.0 |
| hev | rr | 6806 tps p50=142us p99=182us p99.9=340us  | 39 | 15.3 |
| hev | rr-8x1k | 30608 tps p50=248us p99=512us p99.9=656us  | 127 | 15.8 |
| hev | crr | 1724 tps p50=560us p99=648us p99.9=784us  | 65 | 15.5 |
| hev | udp-100k | 74205 echo pps (74.2% of 100000 sent)  | 99 | 17.9 |
| hev | udp-gso-100k | 73974 echo pps (74.0% of 99988 sent)  | 98 | 20.7 |
| zeptun-hybrid | tcp-up-1 | 17.002 Gbit/s | 97 | 10.1 |
| zeptun-hybrid | tcp-up-10 | 22.056 Gbit/s | 155 | 19.9 |
| zeptun-hybrid | tcp-down-1 | 13.647 Gbit/s | 99 | 19.9 |
| zeptun-hybrid | tcp-down-10 | 22.963 Gbit/s | 198 | 23.2 |
| zeptun-hybrid | rr | 6248 tps p50=156us p99=190us p99.9=218us  | 40 | 23.2 |
| zeptun-hybrid | rr-8x1k | 29828 tps p50=256us p99=496us p99.9=640us  | 144 | 22.6 |
| zeptun-hybrid | crr | 1532 tps p50=640us p99=760us p99.9=880us  | 67 | 27.0 |
| zeptun-hybrid | udp-100k | 79664 echo pps (79.7% of 99992 sent)  | 74 | 30.3 |
| zeptun-hybrid | udp-gso-100k | 81187 echo pps (81.2% of 99992 sent)  | 56 | 32.4 |
| singbox-system | tcp-up-1 | 6.083 Gbit/s | 140 | 61.6 |
| singbox-system | tcp-up-10 | 4.618 Gbit/s | 167 | 62.4 |
| singbox-system | tcp-down-1 | 5.423 Gbit/s | 152 | 62.4 |
| singbox-system | tcp-down-10 | 3.900 Gbit/s | 138 | 62.0 |
| singbox-system | rr | 5477 tps p50=178us p99=210us p99.9=238us  | 60 | 61.9 |
| singbox-system | rr-8x1k | 22005 tps p50=344us p99=688us p99.9=1008us  | 155 | 62.4 |
| singbox-system | crr | 1271 tps p50=768us p99=896us p99.9=1360us  | 100 | 73.2 |
| singbox-system | udp-100k | 0 echo pps (0.0% of 99996 sent)  | 87 | 74.9 |
| singbox-system | udp-gso-100k | 0 echo pps (0.0% of 99992 sent)  | 76 | 74.2 |
| tun2socks | tcp-up-1 | 5.089 Gbit/s | 174 | 21.5 |
| tun2socks | tcp-up-10 | 7.838 Gbit/s | 258 | 40.4 |
| tun2socks | tcp-down-1 | 2.593 Gbit/s | 171 | 41.5 |
| tun2socks | tcp-down-10 | 6.223 Gbit/s | 265 | 123.5 |
| tun2socks | rr | 4447 tps p50=224us p99=260us p99.9=344us  | 72 | 128.0 |
| tun2socks | rr-8x1k | 18270 tps p50=416us p99=848us p99.9=1232us  | 168 | 148.9 |
| tun2socks | crr | 1171 tps p50=824us p99=1024us p99.9=1936us  | 92 | 136.7 |
| tun2socks | udp-100k | 40710 echo pps (40.7% of 99960 sent)  | 216 | 50.0 |
| tun2socks | udp-gso-100k | 42791 echo pps (42.8% of 99980 sent)  | 230 | 39.5 |
| singbox-gvisor | tcp-up-1 | 9.224 Gbit/s | 160 | 70.9 |
| singbox-gvisor | tcp-up-10 | 15.163 Gbit/s | 200 | 81.9 |
| singbox-gvisor | tcp-down-1 | 3.143 Gbit/s | 182 | 81.8 |
| singbox-gvisor | tcp-down-10 | 5.631 Gbit/s | 249 | 86.3 |
| singbox-gvisor | rr | 4243 tps p50=234us p99=336us p99.9=368us  | 80 | 85.8 |
| singbox-gvisor | rr-8x1k | 17339 tps p50=444us p99=840us p99.9=1184us  | 171 | 72.9 |
| singbox-gvisor | crr | 1128 tps p50=864us p99=1056us p99.9=1904us  | 103 | 75.9 |
| singbox-gvisor | udp-100k | 0 echo pps (0.0% of 100003 sent)  | 170 | 76.8 |
| singbox-gvisor | udp-gso-100k | 0  | 0 | 75.9 |

zeptun: startup 3 ms, idle 2888 KB, 3 wakeups in 20 s | tcp 1000: 8112 KB (conns: 1000/1000 established, 0 failed, 1829 conn/s) | udp 1000: 17456 KB (udp flows: 1000/1000 answered, 7843 flows/s)
hev: startup 3 ms, idle 2225 KB, 2 wakeups in 20 s | tcp 1000: 78794 KB (conns: 1000/1000 established, 0 failed, 1884 conn/s) | udp 1000: 27318 KB (udp flows: 1000/1000 answered, 7103 flows/s)
singbox-system: startup 42 ms, idle 58521 KB, 6 wakeups in 20 s | tcp 1000: 74404 KB (conns: 1000/1000 established, 0 failed, 1312 conn/s) | udp 1000: 70956 KB (udp flows: 0/1000 answered, 0 flows/s)
singbox-gvisor: startup 49 ms, idle 61553 KB, 124 wakeups in 20 s | tcp 1000: 96496 KB (conns: 1000/1000 established, 0 failed, 1240 conn/s) | udp 1000: 105640 KB (udp flows: 0/1000 answered, 0 flows/s)
tun2socks: startup 5 ms, idle 15852 KB, 204 wakeups in 20 s | tcp 1000: 109244 KB (conns: 1000/1000 established, 0 failed, 1194 conn/s) | udp 1000: 183800 KB (udp flows: 1000/1000 answered, 6003 flows/s)

## Reproducing

```sh
gh workflow run benchmark.yml --repo Noisemux/zeptun -f duration=8 -f repeat=2
```
