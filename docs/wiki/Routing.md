# Routing

With `--auto-route` the engine owns everything outside the interface as well: addresses, routes, policy rules and firewall marks. All of it is removed when the process stops, including after a crash, because the rules carry a priority range the engine claims on startup.

## Linux

| Object | Default | Purpose |
|---|---|---|
| table | 2022 | default routes through the tunnel |
| rules | 9000 to 9009 | selection, exclusions, DNS, strict route |
| mark | 0x2022 | upstream sockets bypass the tunnel |

Rule 9004 keeps a more specific route in the main table, 9005 sends everything unmarked to the tunnel table, and 9009 terminates the chain. Upstream sockets carry `SO_MARK`, so proxy traffic never re-enters the tunnel; this is what makes a loop impossible without the user writing a single `ip rule`.

`--include-uid`, `--exclude-uid`, `--include-interface` and `--exclude-interface` add rules in the same range. `--route` and `--exclude` add prefixes, `--route-file` and `--exclude-file` read them from files without a size limit.

The reverse path filter of the tunnel interface is relaxed from strict to loose when the system had it strict, which is what other tunnels ask the user to do by hand.

## Automatic redirect

`--auto-redirect` installs an nftables table that redirects TCP headed for the tunnel to a local listening socket before it reaches the device, so those connections never cross the TUN device at all. The engine writes the rules through raw netlink, without calling `nft`, and removes the table on exit. An input rule rejects traffic that reaches the redirect port without having been redirected.

## DNS

| Option | Effect |
|---|---|
| `--dns-address` | the tunnel answers DNS on this address |
| `--dns-hijack` | queries to any address are captured, and port 53 is routed into the tunnel even where the main table is more specific |
| `--fake-ip` | A and AAAA answers come from a private pool, and the proxy is dialled by domain name instead of by address |
| `--dns-upstream` | resolver for hijacked queries and record types the fake-IP table does not answer |
| `--systemd-resolved` | `resolvectl` points the interface at the in-tunnel resolver, with `~.` as the routing domain, reverted on exit |

The systemd-resolved handover only runs when the resolver answers in the same network namespace as the engine, so a tunnel inside a namespace can never reconfigure the host.

## Network namespace

`--netns NAME` creates the interface, its addresses and its routes inside another network namespace, given as a name under `/run/netns` or as a path. Upstream sockets stay in the namespace the engine was started in, so the tunnel can serve a namespace while reaching the network through the host.

```sh
ip netns add office
sudo zeptun run --netns office --tun zeptun0 --socks5 127.0.0.1:1080 --auto-route
ip netns exec office curl https://example.com
```

## macOS, FreeBSD and Windows

On macOS and FreeBSD the tunnel receives split default routes, exclusions go through the previous gateway, and upstream sockets are bound to the physical interface with `IP_BOUND_IF`. On Windows routes and DNS go through IP Helper and upstream sockets use `IP_UNICAST_IF`.

`--strict-route` on Windows also installs a Windows Filtering Platform session that permits the engine and the tunnel interface, blocks IPv6 while the tunnel carries none, and blocks port 53 outside the tunnel while DNS is hijacked. The filters disappear with the process.

## Android

With root, `--include-package` and `--exclude-package` read `/data/system/packages.list` and turn app names into UID rules for every Android user, or only the users given with `--android-user`. The mark bit 0x200000 leaves netd's own network selection intact. Without root the descriptor from `VpnService` is used instead and the system owns the routes; see [Android](Android).

## Network changes

The engine watches for default route changes through netlink on Linux, the route socket on macOS and `NotifyRouteChange2` on Windows. When the network moves, upstream sockets are rebound, cached proxy connections are dropped, and routes are refreshed. Embedders can report the change themselves with `zeptun_network_changed`.
