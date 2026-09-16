# Benchmarks

Every number on this page comes from the `benchmark` workflow in this repository, run on a GitHub-hosted runner.

## Machine

| property | value |
|---|---|
| runner image | ubuntu24 20260907.300.1 |
| cpu | AMD EPYC 7763 64-Core Processor |
| cpu cores | 2 |
| memory | 7.8 GB |
| kernel | Linux 6.17.0-1022-azure |
| zig | 0.16.0 |
| date | 2026-09-16 |

## Method

Two network namespaces joined by a veth pair. Traffic enters the tunnel device (MTU 8500), leaves through the same SOCKS5 server (hev-socks5-server) for every engine, and reaches the servers in the second namespace. Engines are interleaved: each round starts every engine once and runs every scenario against it, so background noise spreads evenly. CPU comes from `/proc/<pid>/stat` and memory from `VmRSS`, summed over all processes of an engine.

Duration 8 s per scenario, 2 rounds, 4 queues.

## Throughput

![throughput](throughput.svg)

## CPU

![cpu](cpu.svg)

## Request/response

![transactions](transactions.svg)

![latency](latency.svg)

## UDP

![udp](udp.svg)

## Memory

![memory](memory.svg)

## Raw results

| engine | scenario | median | cpu % | max rss MB |
|---|---|---:|---:|---:|
| zeptun-userspace | tcp-up-1 | 15.487 Gbit/s | 67 | 10.8 |
| zeptun-userspace | tcp-up-10 | 11.443 Gbit/s | 62 | 16.9 |
| zeptun-userspace | tcp-down-1 | 10.966 Gbit/s | 90 | 16.9 |
| zeptun-userspace | tcp-down-10 | 10.107 Gbit/s | 87 | 22.9 |
| zeptun-userspace | rr | 6183 tps p50=160us p99=176us p99.9=254us  | 38 | 22.9 |
| zeptun-userspace | rr-8x1k | 21540 tps p50=356us p99=720us p99.9=1120us  | 55 | 22.9 |
| zeptun-userspace | crr | 1617 tps p50=600us p99=680us p99.9=1088us  | 38 | 22.9 |
| zeptun-userspace | udp-100k | 47127 echo pps (47.1% of 99976 sent)  | 48 | 22.9 |
| zeptun-userspace | udp-gso-100k | 65874 echo pps (65.9% of 99959 sent)  | 35 | 22.9 |
| hev | tcp-up-1 | 4.842 Gbit/s | 94 | 14.7 |
| hev | tcp-up-10 | 7.093 Gbit/s | 113 | 16.3 |
| hev | tcp-down-1 | 4.511 Gbit/s | 83 | 15.4 |
| hev | tcp-down-10 | 5.621 Gbit/s | 108 | 16.0 |
| hev | rr | 5979 tps p50=166us p99=186us p99.9=296us  | 41 | 15.3 |
| hev | rr-8x1k | 20000 tps p50=368us p99=968us p99.9=1648us  | 74 | 15.8 |
| hev | crr | 1393 tps p50=672us p99=792us p99.9=1600us  | 51 | 15.6 |
| hev | udp-100k | 36319 echo pps (36.3% of 99959 sent)  | 69 | 17.9 |
| hev | udp-gso-100k | 44055 echo pps (44.1% of 99992 sent)  | 74 | 20.6 |
| zeptun-hybrid | tcp-up-1 | 11.951 Gbit/s | 64 | 19.4 |
| zeptun-hybrid | tcp-up-10 | 11.277 Gbit/s | 75 | 27.6 |
| zeptun-hybrid | tcp-down-1 | 12.824 Gbit/s | 93 | 29.6 |
| zeptun-hybrid | tcp-down-10 | 12.005 Gbit/s | 98 | 29.6 |
| zeptun-hybrid | rr | 5601 tps p50=176us p99=194us p99.9=280us  | 42 | 29.6 |
| zeptun-hybrid | rr-8x1k | 18561 tps p50=408us p99=960us p99.9=1584us  | 83 | 29.6 |
| zeptun-hybrid | crr | 1326 tps p50=728us p99=1016us p99.9=1472us  | 59 | 31.7 |
| zeptun-hybrid | udp-100k | 45425 echo pps (45.5% of 99880 sent)  | 49 | 35.8 |
| zeptun-hybrid | udp-gso-100k | 65064 echo pps (65.1% of 99988 sent)  | 36 | 37.8 |
| singbox-system | tcp-up-1 | 4.499 Gbit/s | 103 | 60.8 |
| singbox-system | tcp-up-10 | 3.640 Gbit/s | 118 | 61.6 |
| singbox-system | tcp-down-1 | 4.329 Gbit/s | 128 | 61.6 |
| singbox-system | tcp-down-10 | 3.195 Gbit/s | 114 | 61.6 |
| singbox-system | rr | 5606 tps p50=174us p99=210us p99.9=300us  | 60 | 61.6 |
| singbox-system | rr-8x1k | 14349 tps p50=520us p99=1280us p99.9=1872us  | 90 | 61.6 |
| singbox-system | crr | 1074 tps p50=904us p99=1104us p99.9=2464us  | 78 | 68.7 |
| singbox-system | udp-100k | 0 echo pps (0.0% of 99988 sent)  | 60 | 71.1 |
| singbox-system | udp-gso-100k | 0 echo pps (0.0% of 99988 sent)  | 62 | 71.1 |
| tun2socks | tcp-up-1 | 3.592 Gbit/s | 118 | 19.6 |
| tun2socks | tcp-up-10 | 4.071 Gbit/s | 137 | 40.5 |
| tun2socks | tcp-down-1 | 2.496 Gbit/s | 123 | 52.8 |
| tun2socks | tcp-down-10 | 2.779 Gbit/s | 127 | 101.2 |
| tun2socks | rr | 4208 tps p50=232us p99=368us p99.9=520us  | 65 | 103.2 |
| tun2socks | rr-8x1k | 11061 tps p50=696us p99=1392us p99.9=1968us  | 91 | 129.8 |
| tun2socks | crr | 959 tps p50=1016us p99=1280us p99.9=2032us  | 74 | 134.4 |
| tun2socks | udp-100k | 15413 echo pps (15.4% of 99984 sent)  | 114 | 84.1 |
| tun2socks | udp-gso-100k | 18170 echo pps (18.2% of 99968 sent)  | 129 | 95.8 |
| singbox-gvisor | tcp-up-1 | 6.703 Gbit/s | 109 | 66.3 |
| singbox-gvisor | tcp-up-10 | 7.304 Gbit/s | 104 | 79.3 |
| singbox-gvisor | tcp-down-1 | 2.497 Gbit/s | 125 | 79.8 |
| singbox-gvisor | tcp-down-10 | 2.509 Gbit/s | 130 | 89.8 |
| singbox-gvisor | rr | 3774 tps p50=246us p99=384us p99.9=688us  | 70 | 89.8 |
| singbox-gvisor | rr-8x1k | 10535 tps p50=736us p99=1472us p99.9=2208us  | 97 | 70.6 |
| singbox-gvisor | crr | 881 tps p50=1104us p99=1440us p99.9=2592us  | 77 | 71.0 |
| singbox-gvisor | udp-100k | 0 echo pps (0.0% of 99994 sent)  | 121 | 72.2 |
| singbox-gvisor | udp-gso-100k | 0  | 0 | 71.7 |

zeptun: startup 4 ms, idle 2856 KB, 2 wakeups in 20 s | tcp 1000: 11092 KB (conns: 1000/1000 established, 0 failed, 1825 conn/s) | udp 1000: 19492 KB (udp flows: 1000/1000 answered, 5993 flows/s)
hev: startup 4 ms, idle 2221 KB, 2 wakeups in 20 s | tcp 1000: 78794 KB (conns: 1000/1000 established, 0 failed, 1610 conn/s) | udp 1000: 27325 KB (udp flows: 1000/1000 answered, 5120 flows/s)
singbox-system: startup 62 ms, idle 55339 KB, 6 wakeups in 20 s | tcp 1000: 73890 KB (conns: 1000/1000 established, 0 failed, 1155 conn/s) | udp 1000: 67519 KB (udp flows: 0/1000 answered, 0 flows/s)
singbox-gvisor: startup 62 ms, idle 60823 KB, 65 wakeups in 20 s | tcp 1000: 98042 KB (conns: 1000/1000 established, 0 failed, 1014 conn/s) | udp 1000: 103304 KB (udp flows: 0/1000 answered, 0 flows/s)
tun2socks: startup 7 ms, idle 13764 KB, 217 wakeups in 20 s | tcp 1000: 115424 KB (conns: 1000/1000 established, 0 failed, 1076 conn/s) | udp 1000: 183808 KB (udp flows: 1000/1000 answered, 3327 flows/s)
