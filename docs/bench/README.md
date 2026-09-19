# Benchmarks

Every number on this page comes from the `benchmark` workflow in this repository, run on a GitHub-hosted runner.

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

| engine | scenario | median | cpu % | max rss MB | rss after idle MB |
|---|---|---:|---:|---:|---:|
| zeptun-userspace | tcp-up-1 | 18.411 Gbit/s | 78 | 11.5 | 11.4 |
| zeptun-userspace | tcp-up-10 | 23.189 Gbit/s | 116 | 20.1 | 15.7 |
| zeptun-userspace | tcp-down-1 | 12.202 Gbit/s | 99 | 20.7 | 19.9 |
| zeptun-userspace | tcp-down-10 | 20.485 Gbit/s | 180 | 26.2 | 18.3 |
| zeptun-userspace | rr | 7363 tps p50=128us p99=170us p99.9=188us  | 36 | 19.2 | 19.2 |
| zeptun-userspace | rr-8x1k | 32848 tps p50=232us p99=476us p99.9=624us  | 100 | 19.3 | 19.0 |
| zeptun-userspace | crr | 1922 tps p50=504us p99=584us p99.9=720us  | 46 | 21.9 | 21.9 |
| zeptun-userspace | udp-100k | 80152 echo pps (80.2% of 99984 sent)  | 73 | 26.1 | 24.8 |
| zeptun-userspace | udp-gso-100k | 80616 echo pps (80.6% of 99988 sent)  | 55 | 25.3 | 24.8 |
| hev | tcp-up-1 | 6.144 Gbit/s | 96 | 14.8 | 14.6 |
| hev | tcp-up-10 | 13.689 Gbit/s | 222 | 16.2 | 15.3 |
| hev | tcp-down-1 | 6.587 Gbit/s | 99 | 15.5 | 15.3 |
| hev | tcp-down-10 | 11.111 Gbit/s | 207 | 16.1 | 15.3 |
| hev | rr | 7158 tps p50=134us p99=174us p99.9=190us  | 40 | 15.4 | 15.3 |
| hev | rr-8x1k | 31154 tps p50=242us p99=512us p99.9=656us  | 123 | 15.9 | 15.3 |
| hev | crr | 1748 tps p50=552us p99=656us p99.9=784us  | 65 | 15.6 | 15.3 |
| hev | udp-100k | 74583 echo pps (74.6% of 99992 sent)  | 98 | 18.0 | 18.0 |
| hev | udp-gso-100k | 74998 echo pps (75.0% of 99988 sent)  | 98 | 20.7 | 20.7 |
| zeptun-hybrid | tcp-up-1 | 16.088 Gbit/s | 98 | 15.5 | 15.5 |
| zeptun-hybrid | tcp-up-10 | 21.746 Gbit/s | 138 | 25.7 | 27.4 |
| zeptun-hybrid | tcp-down-1 | 14.020 Gbit/s | 99 | 27.7 | 27.4 |
| zeptun-hybrid | tcp-down-10 | 23.375 Gbit/s | 200 | 27.7 | 27.1 |
| zeptun-hybrid | rr | 6515 tps p50=148us p99=188us p99.9=206us  | 41 | 28.9 | 28.9 |
| zeptun-hybrid | rr-8x1k | 29838 tps p50=252us p99=584us p99.9=752us  | 140 | 30.4 | 30.1 |
| zeptun-hybrid | crr | 1560 tps p50=624us p99=736us p99.9=872us  | 69 | 33.7 | 32.2 |
| zeptun-hybrid | udp-100k | 80004 echo pps (80.0% of 99988 sent)  | 74 | 34.5 | 34.2 |
| zeptun-hybrid | udp-gso-100k | 80743 echo pps (80.8% of 99988 sent)  | 55 | 36.5 | 36.2 |
| singbox-system | tcp-up-1 | 6.132 Gbit/s | 152 | 61.2 | 61.2 |
| singbox-system | tcp-up-10 | 4.680 Gbit/s | 172 | 63.2 | 63.3 |
| singbox-system | tcp-down-1 | 5.515 Gbit/s | 153 | 63.8 | 63.6 |
| singbox-system | tcp-down-10 | 3.995 Gbit/s | 138 | 63.6 | 63.6 |
| singbox-system | rr | 5664 tps p50=172us p99=206us p99.9=226us  | 61 | 63.6 | 63.6 |
| singbox-system | rr-8x1k | 22107 tps p50=344us p99=696us p99.9=1056us  | 153 | 63.7 | 63.7 |
| singbox-system | crr | 1289 tps p50=760us p99=872us p99.9=1504us  | 101 | 72.7 | 72.7 |
| singbox-system | udp-100k | 0 echo pps (0.0% of 99992 sent)  | 86 | 75.1 | 75.1 |
| singbox-system | udp-gso-100k | 0 echo pps (0.0% of 99992 sent)  | 75 | 75.1 | 74.7 |
| tun2socks | tcp-up-1 | 5.138 Gbit/s | 173 | 21.5 | 21.3 |
| tun2socks | tcp-up-10 | 7.846 Gbit/s | 259 | 40.4 | 40.3 |
| tun2socks | tcp-down-1 | 2.624 Gbit/s | 172 | 44.6 | 26.3 |
| tun2socks | tcp-down-10 | 6.306 Gbit/s | 263 | 121.7 | 121.7 |
| tun2socks | rr | 4582 tps p50=216us p99=254us p99.9=544us  | 73 | 130.3 | 130.3 |
| tun2socks | rr-8x1k | 18433 tps p50=412us p99=840us p99.9=1168us  | 166 | 146.8 | 142.3 |
| tun2socks | crr | 1188 tps p50=808us p99=1008us p99.9=2496us  | 92 | 144.4 | 33.9 |
| tun2socks | udp-100k | 40603 echo pps (40.6% of 99988 sent)  | 216 | 40.6 | 38.9 |
| tun2socks | udp-gso-100k | 44129 echo pps (44.1% of 100000 sent)  | 229 | 38.3 | 44.5 |
| singbox-gvisor | tcp-up-1 | 9.322 Gbit/s | 159 | 69.1 | 69.1 |
| singbox-gvisor | tcp-up-10 | 15.307 Gbit/s | 197 | 81.5 | 81.5 |
| singbox-gvisor | tcp-down-1 | 3.234 Gbit/s | 183 | 81.6 | 81.6 |
| singbox-gvisor | tcp-down-10 | 5.828 Gbit/s | 249 | 86.5 | 86.2 |
| singbox-gvisor | rr | 4369 tps p50=226us p99=324us p99.9=364us  | 80 | 86.2 | 71.4 |
| singbox-gvisor | rr-8x1k | 17599 tps p50=436us p99=832us p99.9=1184us  | 168 | 74.0 | 72.7 |
| singbox-gvisor | crr | 1147 tps p50=848us p99=1024us p99.9=1792us  | 104 | 77.3 | 77.3 |
| singbox-gvisor | udp-100k | 0 echo pps (0.0% of 99988 sent)  | 169 | 77.2 | 76.8 |
| singbox-gvisor | udp-gso-100k | 0  | 0 | 76.8 | 76.8 |

zeptun: startup 4 ms, idle 852 KB, 2 wakeups in 20 s | tcp 1000: 6040 KB (conns: 1000/1000 established, 0 failed, 1882 conn/s) | udp 1000: 13976 KB (udp flows: 1000/1000 answered, 8052 flows/s)
hev: startup 3 ms, idle 2221 KB, 2 wakeups in 20 s | tcp 1000: 78794 KB (conns: 1000/1000 established, 0 failed, 1885 conn/s) | udp 1000: 27322 KB (udp flows: 1000/1000 answered, 7416 flows/s)
singbox-system: startup 42 ms, idle 59977 KB, 6 wakeups in 20 s | tcp 1000: 74344 KB (conns: 1000/1000 established, 0 failed, 1329 conn/s) | udp 1000: 69996 KB (udp flows: 0/1000 answered, 0 flows/s)
singbox-gvisor: startup 49 ms, idle 60193 KB, 125 wakeups in 20 s | tcp 1000: 96100 KB (conns: 1000/1000 established, 0 failed, 1271 conn/s) | udp 1000: 103980 KB (udp flows: 0/1000 answered, 0 flows/s)
tun2socks: startup 5 ms, idle 15844 KB, 213 wakeups in 20 s | tcp 1000: 109312 KB (conns: 1000/1000 established, 0 failed, 1212 conn/s) | udp 1000: 183812 KB (udp flows: 1000/1000 answered, 5852 flows/s)
