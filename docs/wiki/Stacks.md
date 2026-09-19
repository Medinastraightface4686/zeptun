# Stacks

| Mode | TCP | UDP | Notes |
|---|---|---|---|
| `userspace` | own terminator | own sessions | works on every platform, keeps no kernel state, required for elastic queues |
| `system` | kernel sockets behind NAT | kernel sockets | Linux only, lowest CPU for bulk transfer |
| `hybrid` | kernel NAT with a userspace fallback | own sessions | default where the system stack exists |

## Userspace terminator

The engine terminates TCP itself: SACK, timestamps, window scaling, delayed ACK, CUBIC or NewReno, RTO with a configurable floor and ceiling, and a receive window that grows within a per-worker budget. Data from the client is streamed into the upstream connection while the SOCKS5 handshake is still in flight, so the first request leaves with the handshake instead of after it.

A connection starts with a small send buffer and receive window and grows into the per-worker budgets only while it keeps its queues drained, so memory follows the traffic rather than the connection count. Idle packet buffers are handed back to the kernel a few seconds after a burst.

Relevant keys: `tcp_rx_window`, `tcp_tx_buffer`, `tcp_rx_budget`, `tcp_tx_budget`, `tcp_mss_clamp`, `tcp_initial_cwnd`, `congestion`, `sack`, `timestamps`, `window_scaling`, `tcp_delayed_ack_ms`, `tcp_min_rto_ms`, `tcp_max_rto_ms`, `tcp_early_accept`.

## System stack

On Linux the engine can rewrite packets and let the kernel own the connection. TCP is redirected to a listening socket through NAT, UDP uses kernel sockets, and the port range comes from `nat_port_base` and `nat_port_limit`. This is the cheapest path for bulk transfer but it keeps conntrack state and cannot migrate flows between queues.

## Hybrid

Hybrid uses the kernel NAT path and falls back to the userspace terminator for anything the kernel path cannot take, which keeps the system stack's efficiency without losing flows.

## Elastic queues

With the userspace stack on Linux the engine starts with a single worker and one attached TUN queue. A queue is added only while the extra worker raises throughput and is released when the load drops again, up to `--queues`.

* Queue index and worker id are the same, so attach and detach are strictly last in, first out.
* A worker that takes over a flow receives the connection state and its buffers through a lock-free inbox; the previous owner keeps a forwarding entry until the transfer is acknowledged.
* A queue is detached only after its receive side goes quiet, because detaching purges whatever the kernel still holds in that queue's ring.
* Peers are found through seqlock reads of the other workers' flow tables, so no global directory is needed.

`--elastic off` keeps every queue attached, `--elastic rotate` grows and shrinks continuously and exists to exercise migration in tests.

## Offloads

With a virtio-net header the device negotiates TSO, USO and checksum offload. Super-packets are segmented only when the peer cannot take them, and downstream traffic is coalesced into one large write per flow. UDP uses `UDP_SEGMENT` towards the proxy and `UDP_GRO` on the way back, including through a SOCKS5 UDP association, where each datagram keeps its own header inside the same `sendmsg`.
