# Benchmarks

Every number here is produced by the `benchmark` workflow in the repository, on a GitHub-hosted runner, against hev-socks5-tunnel, sing-box and tun2socks over the same SOCKS5 server.

## Machine

| property | value |
|---|---|
| runner image | ubuntu24 20260907.300.1 |
| cpu | INTEL(R) XEON(R) PLATINUM 8573C |
| cpu cores | 4 |
| memory | 15.6 GB |
| kernel | Linux 6.17.0-1022-azure |
| zig | 0.16.0 |
| date | 2026-09-17 |

## Method

Two network namespaces joined by a veth pair. Traffic enters the tunnel device (MTU 8500), leaves through the same SOCKS5 server (hev-socks5-server) for every engine, and reaches the servers in the second namespace. Engines are interleaved: each round starts every engine once and runs every scenario against it, so background noise spreads evenly. CPU comes from `/proc/<pid>/stat` and memory from `VmRSS`, summed over all processes of an engine.

Duration 10 s per scenario, 3 rounds, 4 queues.

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
| zeptun-userspace | tcp-up-1 | 23.589 Gbit/s | 94 | 17.0 |
| zeptun-userspace | tcp-up-10 | 24.333 Gbit/s | 106 | 25.0 |
| zeptun-userspace | tcp-down-1 | 18.959 Gbit/s | 100 | 25.1 |
| zeptun-userspace | tcp-down-10 | 16.673 Gbit/s | 99 | 33.1 |
| zeptun-userspace | rr | 10352 tps p50=94us p99=136us p99.9=158us  | 26 | 33.1 |
| zeptun-userspace | rr-8x1k | 67285 tps p50=114us p99=218us p99.9=292us  | 78 | 33.1 |
| zeptun-userspace | crr | 2964 tps p50=328us p99=396us p99.9=444us  | 29 | 33.1 |
| zeptun-userspace | udp-100k | 99971 echo pps (100.0% of 99990 sent)  | 46 | 35.1 |
| zeptun-userspace | udp-gso-100k | 99984 echo pps (100.0% of 99994 sent)  | 33 | 35.1 |
| hev | tcp-up-1 | 11.809 Gbit/s | 88 | 15.3 |
| hev | tcp-up-10 | 24.611 Gbit/s | 214 | 16.7 |
| hev | tcp-down-1 | 10.232 Gbit/s | 96 | 16.0 |
| hev | tcp-down-10 | 21.064 Gbit/s | 207 | 16.6 |
| hev | rr | 10550 tps p50=93us p99=128us p99.9=152us  | 29 | 15.9 |
| hev | rr-8x1k | 70716 tps p50=107us p99=232us p99.9=308us  | 118 | 16.4 |
| hev | crr | 2766 tps p50=352us p99=428us p99.9=576us  | 54 | 16.0 |
| hev | udp-100k | 99983 echo pps (100.0% of 99994 sent)  | 60 | 16.6 |
| hev | udp-gso-100k | 99977 echo pps (100.0% of 99987 sent)  | 61 | 17.3 |
| zeptun-hybrid | tcp-up-1 | 19.943 Gbit/s | 100 | 17.4 |
| zeptun-hybrid | tcp-up-10 | 32.490 Gbit/s | 187 | 27.6 |
| zeptun-hybrid | tcp-down-1 | 17.620 Gbit/s | 100 | 27.6 |
| zeptun-hybrid | tcp-down-10 | 31.769 Gbit/s | 198 | 27.6 |
| zeptun-hybrid | rr | 10132 tps p50=96us p99=140us p99.9=180us  | 30 | 27.6 |
| zeptun-hybrid | rr-8x1k | 70422 tps p50=109us p99=228us p99.9=300us  | 132 | 27.6 |
| zeptun-hybrid | crr | 2316 tps p50=420us p99=544us p99.9=712us  | 56 | 34.3 |
| zeptun-hybrid | udp-100k | 99977 echo pps (100.0% of 99994 sent)  | 46 | 38.3 |
| zeptun-hybrid | udp-gso-100k | 99977 echo pps (100.0% of 99987 sent)  | 33 | 40.3 |
| singbox-system | tcp-up-1 | 10.046 Gbit/s | 146 | 61.4 |
| singbox-system | tcp-up-10 | 8.309 Gbit/s | 164 | 62.2 |
| singbox-system | tcp-down-1 | 8.975 Gbit/s | 143 | 62.1 |
| singbox-system | tcp-down-10 | 7.101 Gbit/s | 130 | 61.8 |
| singbox-system | rr | 9249 tps p50=106us p99=154us p99.9=178us  | 46 | 62.3 |
| singbox-system | rr-8x1k | 45750 tps p50=166us p99=332us p99.9=484us  | 152 | 62.3 |
| singbox-system | crr | 2146 tps p50=456us p99=560us p99.9=1040us  | 86 | 81.2 |
| singbox-system | udp-100k | 0 echo pps (0.0% of 99990 sent)  | 50 | 81.7 |
| singbox-system | udp-gso-100k | 0 echo pps (0.0% of 99994 sent)  | 50 | 81.8 |
| tun2socks | tcp-up-1 | 7.109 Gbit/s | 207 | 21.4 |
| tun2socks | tcp-up-10 | 10.112 Gbit/s | 286 | 38.4 |
| tun2socks | tcp-down-1 | 5.073 Gbit/s | 162 | 44.5 |
| tun2socks | tcp-down-10 | 10.328 Gbit/s | 265 | 151.1 |
| tun2socks | rr | 7072 tps p50=138us p99=188us p99.9=224us  | 53 | 151.6 |
| tun2socks | rr-8x1k | 37815 tps p50=200us p99=424us p99.9=776us  | 167 | 151.7 |
| tun2socks | crr | 1652 tps p50=592us p99=712us p99.9=1936us  | 87 | 45.8 |
| tun2socks | udp-100k | 72015 echo pps (72.0% of 99990 sent)  | 228 | 54.6 |
| tun2socks | udp-gso-100k | 73158 echo pps (73.2% of 99990 sent)  | 229 | 38.2 |
| singbox-gvisor | tcp-up-1 | 14.466 Gbit/s | 164 | 71.4 |
| singbox-gvisor | tcp-up-10 | 21.125 Gbit/s | 216 | 80.3 |
| singbox-gvisor | tcp-down-1 | 5.547 Gbit/s | 180 | 80.3 |
| singbox-gvisor | tcp-down-10 | 9.241 Gbit/s | 257 | 86.7 |
| singbox-gvisor | rr | 6552 tps p50=150us p99=204us p99.9=240us  | 61 | 86.7 |
| singbox-gvisor | rr-8x1k | 35383 tps p50=216us p99=428us p99.9=808us  | 170 | 74.7 |
| singbox-gvisor | crr | 1752 tps p50=560us p99=696us p99.9=1568us  | 100 | 79.7 |
| singbox-gvisor | udp-100k | 0 echo pps (0.0% of 99996 sent)  | 154 | 81.6 |
| singbox-gvisor | udp-gso-100k | 0  | 0 | 81.3 |

zeptun: startup 2 ms, idle 4936 KB, 3 wakeups in 20 s | tcp 1000: 9072 KB (conns: 1000/1000 established, 0 failed, 2529 conn/s) | udp 1000: 11940 KB (udp flows: 1000/1000 answered, 14355 flows/s)
hev: startup 2 ms, idle 2228 KB, 2 wakeups in 20 s | tcp 1000: 78797 KB (conns: 1000/1000 established, 0 failed, 2788 conn/s) | udp 1000: 27329 KB (udp flows: 1000/1000 answered, 13167 flows/s)
singbox-system: startup 45 ms, idle 58368 KB, 6 wakeups in 20 s | tcp 1000: 73403 KB (conns: 1000/1000 established, 0 failed, 2041 conn/s) | udp 1000: 71367 KB (udp flows: 0/1000 answered, 0 flows/s)
singbox-gvisor: startup 45 ms, idle 61336 KB, 68 wakeups in 20 s | tcp 1000: 94555 KB (conns: 1000/1000 established, 0 failed, 1816 conn/s) | udp 1000: 97027 KB (udp flows: 0/1000 answered, 0 flows/s)
tun2socks: startup 4 ms, idle 13784 KB, 296 wakeups in 20 s | tcp 1000: 109244 KB (conns: 1000/1000 established, 0 failed, 1619 conn/s) | udp 1000: 183736 KB (udp flows: 1000/1000 answered, 8837 flows/s)

## Reproducing

```sh
gh workflow run benchmark.yml --repo Noisemux/zeptun -f duration=10 -f repeat=3
```
