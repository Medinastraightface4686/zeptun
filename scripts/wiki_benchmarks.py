import sys

src_path = sys.argv[1] if len(sys.argv) > 1 else "docs/bench/README.md"
dest_path = sys.argv[2] if len(sys.argv) > 2 else "docs/wiki/Benchmarks.md"

with open(src_path) as handle:
    src = handle.read()


def section(name):
    return src.split(f"## {name}\n", 1)[1].split("\n## ", 1)[0].strip()


page = f"""# Benchmarks

Every number here is produced by the `benchmark` workflow in the repository, on a GitHub-hosted runner, against hev-socks5-tunnel, sing-box and tun2socks over the same SOCKS5 server.

## Machine

{section("Machine")}

## Method

{section("Method")}

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

{section("Raw results")}

## Reproducing

```sh
gh workflow run benchmark.yml --repo Noisemux/zeptun -f duration=10 -f repeat=3
```
"""

with open(dest_path, "w") as handle:
    handle.write(page)
