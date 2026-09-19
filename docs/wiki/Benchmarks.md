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
| zeptun-userspace | tcp-up-1 | 19.242 Gbit/s | 82 | 6.8 | 5.4 |
| zeptun-userspace | tcp-up-10 | 23.314 Gbit/s | 132 | 15.6 | 12.6 |
| zeptun-userspace | tcp-down-1 | 12.028 Gbit/s | 98 | 12.7 | 12.7 |
| zeptun-userspace | tcp-down-10 | 20.250 Gbit/s | 176 | 18.5 | 16.2 |
| zeptun-userspace | rr | 7303 tps p50=132us p99=166us p99.9=180us  | 36 | 16.3 | 16.2 |
| zeptun-userspace | rr-8x1k | 33473 tps p50=226us p99=464us p99.9=616us  | 101 | 16.3 | 16.2 |
| zeptun-userspace | crr | 1969 tps p50=492us p99=560us p99.9=624us  | 46 | 17.7 | 17.7 |
| zeptun-userspace | udp-100k | 80308 echo pps (80.3% of 99988 sent)  | 74 | 18.4 | 17.6 |
| zeptun-userspace | udp-gso-100k | 82385 echo pps (82.4% of 99984 sent)  | 56 | 18.5 | 17.6 |
| hev | tcp-up-1 | 5.984 Gbit/s | 96 | 14.7 | 14.5 |
| hev | tcp-up-10 | 13.825 Gbit/s | 222 | 16.2 | 15.3 |
| hev | tcp-down-1 | 6.907 Gbit/s | 98 | 15.4 | 15.3 |
| hev | tcp-down-10 | 11.146 Gbit/s | 210 | 16.1 | 15.3 |
| hev | rr | 7193 tps p50=136us p99=166us p99.9=178us  | 40 | 15.3 | 15.3 |
| hev | rr-8x1k | 31481 tps p50=240us p99=512us p99.9=656us  | 123 | 15.9 | 15.3 |
| hev | crr | 1788 tps p50=544us p99=616us p99.9=696us  | 65 | 15.6 | 15.3 |
| hev | udp-100k | 76054 echo pps (76.1% of 99996 sent)  | 99 | 18.0 | 18.0 |
| hev | udp-gso-100k | 75252 echo pps (75.3% of 99984 sent)  | 98 | 20.7 | 20.7 |
| zeptun-hybrid | tcp-up-1 | 11.351 Gbit/s | 99 | 5.9 | 5.7 |
| zeptun-hybrid | tcp-up-10 | 20.695 Gbit/s | 182 | 13.5 | 12.6 |
| zeptun-hybrid | tcp-down-1 | 12.591 Gbit/s | 100 | 12.8 | 12.3 |
| zeptun-hybrid | tcp-down-10 | 23.098 Gbit/s | 200 | 13.5 | 12.6 |
| zeptun-hybrid | rr | 6646 tps p50=146us p99=180us p99.9=198us  | 40 | 12.6 | 14.4 |
| zeptun-hybrid | rr-8x1k | 29969 tps p50=250us p99=560us p99.9=728us  | 142 | 16.5 | 16.2 |
| zeptun-hybrid | crr | 1554 tps p50=624us p99=736us p99.9=840us  | 68 | 21.5 | 22.9 |
| zeptun-hybrid | udp-100k | 77898 echo pps (77.9% of 99988 sent)  | 93 | 26.9 | 28.1 |
| zeptun-hybrid | udp-gso-100k | 81768 echo pps (81.8% of 99988 sent)  | 56 | 32.4 | 32.0 |
| singbox-system | tcp-up-1 | 6.195 Gbit/s | 151 | 61.3 | 61.3 |
| singbox-system | tcp-up-10 | 4.691 Gbit/s | 171 | 62.0 | 62.0 |
| singbox-system | tcp-down-1 | 5.498 Gbit/s | 152 | 62.1 | 62.1 |
| singbox-system | tcp-down-10 | 4.013 Gbit/s | 138 | 63.9 | 63.9 |
| singbox-system | rr | 5708 tps p50=170us p99=198us p99.9=214us  | 61 | 63.9 | 63.9 |
| singbox-system | rr-8x1k | 22459 tps p50=340us p99=680us p99.9=960us  | 157 | 63.9 | 63.2 |
| singbox-system | crr | 1316 tps p50=744us p99=840us p99.9=1376us  | 101 | 72.9 | 72.9 |
| singbox-system | udp-100k | 0 echo pps (0.0% of 99992 sent)  | 85 | 75.3 | 75.0 |
| singbox-system | udp-gso-100k | 0 echo pps (0.0% of 99992 sent)  | 75 | 75.0 | 75.0 |
| tun2socks | tcp-up-1 | 5.195 Gbit/s | 174 | 20.8 | 20.7 |
| tun2socks | tcp-up-10 | 8.251 Gbit/s | 260 | 40.6 | 40.6 |
| tun2socks | tcp-down-1 | 2.782 Gbit/s | 171 | 42.7 | 26.7 |
| tun2socks | tcp-down-10 | 6.298 Gbit/s | 263 | 129.7 | 129.8 |
| tun2socks | rr | 4722 tps p50=210us p99=244us p99.9=324us  | 73 | 132.2 | 132.2 |
| tun2socks | rr-8x1k | 18743 tps p50=404us p99=824us p99.9=1104us  | 167 | 143.0 | 132.7 |
| tun2socks | crr | 1212 tps p50=792us p99=984us p99.9=2032us  | 91 | 132.7 | 38.2 |
| tun2socks | udp-100k | 41476 echo pps (41.5% of 99988 sent)  | 215 | 39.3 | 36.4 |
| tun2socks | udp-gso-100k | 44601 echo pps (44.6% of 99940 sent)  | 232 | 38.1 | 37.3 |
| singbox-gvisor | tcp-up-1 | 9.428 Gbit/s | 160 | 70.9 | 70.9 |
| singbox-gvisor | tcp-up-10 | 15.477 Gbit/s | 197 | 82.0 | 82.0 |
| singbox-gvisor | tcp-down-1 | 3.271 Gbit/s | 183 | 82.1 | 80.0 |
| singbox-gvisor | tcp-down-10 | 5.980 Gbit/s | 249 | 86.3 | 85.5 |
| singbox-gvisor | rr | 4520 tps p50=220us p99=268us p99.9=348us  | 80 | 85.5 | 70.8 |
| singbox-gvisor | rr-8x1k | 17684 tps p50=436us p99=816us p99.9=1104us  | 167 | 72.7 | 72.1 |
| singbox-gvisor | crr | 1170 tps p50=832us p99=992us p99.9=1744us  | 104 | 76.2 | 76.2 |
| singbox-gvisor | udp-100k | 0 echo pps (0.0% of 99991 sent)  | 169 | 76.9 | 75.8 |
| singbox-gvisor | udp-gso-100k | 0  | 0 | 75.8 | 75.8 |

zeptun: startup 3 ms, idle 840 KB, 4 wakeups in 20 s | tcp 1000: 5192 KB (conns: 1000/1000 established, 0 failed, 1839 conn/s) | udp 1000: 5668 KB (udp flows: 1000/1000 answered, 8361 flows/s)
hev: startup 3 ms, idle 2221 KB, 2 wakeups in 20 s | tcp 1000: 78798 KB (conns: 1000/1000 established, 0 failed, 1931 conn/s) | udp 1000: 27330 KB (udp flows: 1000/1000 answered, 7361 flows/s)
singbox-system: startup 43 ms, idle 57479 KB, 6 wakeups in 20 s | tcp 1000: 73568 KB (conns: 1000/1000 established, 0 failed, 1370 conn/s) | udp 1000: 73192 KB (udp flows: 0/1000 answered, 0 flows/s)
singbox-gvisor: startup 49 ms, idle 60941 KB, 123 wakeups in 20 s | tcp 1000: 95260 KB (conns: 1000/1000 established, 0 failed, 1280 conn/s) | udp 1000: 109308 KB (udp flows: 0/1000 answered, 0 flows/s)
tun2socks: startup 5 ms, idle 15856 KB, 259 wakeups in 20 s | tcp 1000: 111292 KB (conns: 1000/1000 established, 0 failed, 1230 conn/s) | udp 1000: 183744 KB (udp flows: 1000/1000 answered, 6004 flows/s)

## Reproducing

```sh
gh workflow run benchmark.yml --repo Noisemux/zeptun -f duration=8 -f repeat=2
```
