# Zeptun

A userspace network engine for TUN devices, written in Zig with no dependencies. It turns the packets an operating system routes into a tunnel interface back into TCP, UDP and ICMP flows, and forwards them through a SOCKS5 proxy, directly, or to the embedding application.

## Pages

| Page | Contents |
|---|---|
| [Building](Building) | every platform, cross compilation, packaging |
| [Configuration](Configuration) | the TOML and JSON document, key by key |
| [Command line](Command-line) | every flag and subcommand |
| [Routing](Routing) | automatic routes, exclusions, DNS, namespaces |
| [Stacks](Stacks) | userspace, system and hybrid, elastic queues |
| [C API](C-API) | functions, structs, callbacks, thread safety |
| [Android](Android) | NDK build, JNI bridge, Kotlin usage |
| [Apple](Apple) | XCFramework, NetworkExtension |
| [Container](Container) | image, environment variables, compose |
| [Benchmarks](Benchmarks) | method, runner, charts, raw numbers |
| [Testing](Testing) | unit, simulation, namespace and ABI tests |

## Quick start

```sh
git clone https://github.com/Noisemux/zeptun
cd zeptun
make
sudo make install
sudo zeptun run --tun zeptun0 --mtu 8500 --socks5 127.0.0.1:1080 --auto-route
```

Everything the tunnel touches is removed when the process stops, including addresses, routes and policy rules.
