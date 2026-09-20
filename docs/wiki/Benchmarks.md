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
| date | 2026-09-20 |

## Method

Two network namespaces joined by a veth pair. Traffic enters the tunnel device (MTU 8500), leaves through the same SOCKS5 server (hev-socks5-server) for every engine, and reaches the servers in the second namespace. Engines are interleaved: each round starts every engine once and runs every scenario against it, so background noise spreads evenly. CPU comes from `/proc/<pid>/stat` and memory from `VmRSS`, summed over all processes of an engine.

Duration 8 s per scenario, 2 rounds, 4 queues. Memory is read twice: the highest sample while the scenario runs, and again after 5 s of idle, which shows whether an engine gives the memory back.

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

Memory is read twice per scenario: the highest sample while the load runs, and
again after a few seconds of idle. The second reading is what shows whether an
engine hands the memory back or keeps it for the life of the process.

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

| engine | scenario | median | cpu % | max rss MB | rss after idle MB |
|---|---|---:|---:|---:|---:|
| zeptun-userspace | tcp-up-1 | 18.323 Gbit/s | 80 | 6.8 | 5.4 |
| zeptun-userspace | tcp-up-10 | 22.156 Gbit/s | 129 | 11.4 | 7.9 |
| zeptun-userspace | tcp-down-1 | 12.295 Gbit/s | 99 | 10.2 | 10.2 |
| zeptun-userspace | tcp-down-10 | 19.835 Gbit/s | 175 | 13.9 | 10.5 |
| zeptun-userspace | rr | 7260 tps p50=132us p99=172us p99.9=190us  | 36 | 10.6 | 10.4 |
| zeptun-userspace | rr-8x1k | 33578 tps p50=228us p99=444us p99.9=560us  | 101 | 10.6 | 10.5 |
| zeptun-userspace | crr | 1920 tps p50=504us p99=576us p99.9=680us  | 45 | 12.4 | 12.3 |
| zeptun-userspace | udp-100k | 78867 echo pps (78.9% of 99992 sent)  | 73 | 13.1 | 12.4 |
| zeptun-userspace | udp-gso-100k | 79052 echo pps (79.1% of 99992 sent)  | 54 | 13.2 | 12.2 |
| hev | tcp-up-1 | 5.939 Gbit/s | 96 | 14.8 | 14.6 |
| hev | tcp-up-10 | 13.056 Gbit/s | 216 | 16.2 | 15.3 |
| hev | tcp-down-1 | 6.377 Gbit/s | 99 | 15.4 | 15.3 |
| hev | tcp-down-10 | 10.867 Gbit/s | 199 | 16.1 | 15.3 |
| hev | rr | 7176 tps p50=132us p99=172us p99.9=190us  | 39 | 15.3 | 15.3 |
| hev | rr-8x1k | 32110 tps p50=238us p99=476us p99.9=608us  | 124 | 15.9 | 15.3 |
| hev | crr | 1744 tps p50=560us p99=632us p99.9=760us  | 64 | 15.6 | 15.3 |
| hev | udp-100k | 75909 echo pps (75.9% of 99996 sent)  | 99 | 18.0 | 18.0 |
| hev | udp-gso-100k | 75051 echo pps (75.1% of 99988 sent)  | 99 | 20.7 | 20.7 |
| zeptun-hybrid | tcp-up-1 | 11.469 Gbit/s | 99 | 6.0 | 5.8 |
| zeptun-hybrid | tcp-up-10 | 20.121 Gbit/s | 180 | 11.5 | 10.6 |
| zeptun-hybrid | tcp-down-1 | 12.749 Gbit/s | 99 | 10.9 | 10.5 |
| zeptun-hybrid | tcp-down-10 | 21.393 Gbit/s | 193 | 11.6 | 10.7 |
| zeptun-hybrid | rr | 6551 tps p50=148us p99=184us p99.9=202us  | 41 | 12.3 | 12.3 |
| zeptun-hybrid | rr-8x1k | 29610 tps p50=260us p99=552us p99.9=712us  | 142 | 14.6 | 14.3 |
| zeptun-hybrid | crr | 1544 tps p50=632us p99=736us p99.9=808us  | 66 | 23.2 | 23.0 |
| zeptun-hybrid | udp-100k | 79903 echo pps (79.9% of 99992 sent)  | 94 | 25.4 | 26.8 |
| zeptun-hybrid | udp-gso-100k | 80101 echo pps (80.1% of 99992 sent)  | 55 | 32.6 | 32.2 |
| singbox-system | tcp-up-1 | 6.045 Gbit/s | 146 | 62.1 | 61.4 |
| singbox-system | tcp-up-10 | 4.581 Gbit/s | 171 | 62.2 | 62.2 |
| singbox-system | tcp-down-1 | 5.370 Gbit/s | 153 | 62.3 | 62.2 |
| singbox-system | tcp-down-10 | 3.899 Gbit/s | 138 | 64.3 | 64.3 |
| singbox-system | rr | 5696 tps p50=172us p99=202us p99.9=220us  | 62 | 64.3 | 64.3 |
| singbox-system | rr-8x1k | 22104 tps p50=344us p99=688us p99.9=944us  | 156 | 64.2 | 64.2 |
| singbox-system | crr | 1290 tps p50=760us p99=864us p99.9=1472us  | 100 | 72.9 | 72.9 |
| singbox-system | udp-100k | 0 echo pps (0.0% of 99992 sent)  | 87 | 75.2 | 75.0 |
| singbox-system | udp-gso-100k | 0 echo pps (0.0% of 99984 sent)  | 79 | 75.0 | 74.6 |
| tun2socks | tcp-up-1 | 5.085 Gbit/s | 174 | 21.4 | 21.2 |
| tun2socks | tcp-up-10 | 7.892 Gbit/s | 261 | 40.5 | 38.6 |
| tun2socks | tcp-down-1 | 2.582 Gbit/s | 172 | 42.6 | 25.4 |
| tun2socks | tcp-down-10 | 6.205 Gbit/s | 263 | 119.7 | 119.8 |
| tun2socks | rr | 4643 tps p50=214us p99=246us p99.9=324us  | 73 | 133.7 | 133.7 |
| tun2socks | rr-8x1k | 18427 tps p50=412us p99=832us p99.9=1152us  | 167 | 144.4 | 144.4 |
| tun2socks | crr | 1186 tps p50=816us p99=1024us p99.9=1952us  | 91 | 67.6 | 34.2 |
| tun2socks | udp-100k | 40116 echo pps (40.1% of 99984 sent)  | 216 | 39.8 | 36.0 |
| tun2socks | udp-gso-100k | 43582 echo pps (43.6% of 99992 sent)  | 231 | 38.8 | 41.5 |
| singbox-gvisor | tcp-up-1 | 9.131 Gbit/s | 160 | 69.7 | 69.7 |
| singbox-gvisor | tcp-up-10 | 15.056 Gbit/s | 199 | 80.7 | 80.7 |
| singbox-gvisor | tcp-down-1 | 3.193 Gbit/s | 183 | 80.8 | 80.4 |
| singbox-gvisor | tcp-down-10 | 5.857 Gbit/s | 249 | 86.9 | 86.7 |
| singbox-gvisor | rr | 4421 tps p50=224us p99=300us p99.9=356us  | 80 | 86.3 | 75.3 |
| singbox-gvisor | rr-8x1k | 17724 tps p50=436us p99=824us p99.9=1216us  | 171 | 74.2 | 72.8 |
| singbox-gvisor | crr | 1151 tps p50=848us p99=1016us p99.9=1872us  | 104 | 76.6 | 76.6 |
| singbox-gvisor | udp-100k | 0 echo pps (0.0% of 100000 sent)  | 169 | 77.4 | 76.7 |
| singbox-gvisor | udp-gso-100k | 0  | 0 | 76.7 | 76.7 |

zeptun: startup 3 ms, idle 2872 KB, 5 wakeups in 20 s | tcp 1000: 6068 KB (conns: 1000/1000 established, 0 failed, 1794 conn/s) | udp 1000: 4216 KB (udp flows: 1000/1000 answered, 8652 flows/s)
hev: startup 3 ms, idle 2221 KB, 2 wakeups in 20 s | tcp 1000: 78798 KB (conns: 1000/1000 established, 0 failed, 1897 conn/s) | udp 1000: 27322 KB (udp flows: 1000/1000 answered, 7295 flows/s)
singbox-system: startup 44 ms, idle 60565 KB, 6 wakeups in 20 s | tcp 1000: 73524 KB (conns: 1000/1000 established, 0 failed, 1321 conn/s) | udp 1000: 67792 KB (udp flows: 0/1000 answered, 0 flows/s)
singbox-gvisor: startup 49 ms, idle 60657 KB, 125 wakeups in 20 s | tcp 1000: 99064 KB (conns: 1000/1000 established, 0 failed, 1248 conn/s) | udp 1000: 101260 KB (udp flows: 0/1000 answered, 0 flows/s)
tun2socks: startup 5 ms, idle 13784 KB, 199 wakeups in 20 s | tcp 1000: 109232 KB (conns: 1000/1000 established, 0 failed, 1181 conn/s) | udp 1000: 183884 KB (udp flows: 1000/1000 answered, 6012 flows/s)

## Reproducing

```sh
gh workflow run benchmark.yml --repo Noisemux/zeptun -f duration=8 -f repeat=2
```
