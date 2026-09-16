FROM alpine:3.21 AS builder

ARG ZIG_VERSION=0.16.0

RUN apk add --update --no-cache curl xz tar

RUN set -eu; \
    case "$(uname -m)" in \
      x86_64) ZIG_ARCH=x86_64 ;; \
      aarch64) ZIG_ARCH=aarch64 ;; \
      armv7l) ZIG_ARCH=armv7a ;; \
      riscv64) ZIG_ARCH=riscv64 ;; \
      i386|i686) ZIG_ARCH=x86 ;; \
      *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig

WORKDIR /src
COPY . /src

RUN zig build -Doptimize=ReleaseFast

FROM alpine:3.21
LABEL org.opencontainers.image.source="https://github.com/noisemux/zeptun"
LABEL org.opencontainers.image.title="zeptun"
LABEL org.opencontainers.image.description="Zeptun userspace TUN network engine"

RUN apk add --update --no-cache iproute2

ENV TUN=zeptun0 \
    MTU=8500 \
    IPV4=172.19.0.1/30 \
    IPV6=fdfe:dcba:9876::1/126 \
    STACK=userspace \
    HANDLER=socks5 \
    SOCKS5_ADDR=172.17.0.1 \
    SOCKS5_PORT=1080 \
    SOCKS5_USERNAME='' \
    SOCKS5_PASSWORD='' \
    SOCKS5_UDP_MODE=udp \
    SOCKS5_UDP_ADDR='' \
    SOCKS5_POOL=4 \
    QUEUES=0 \
    ELASTIC=auto \
    UDP_NAT=endpoint-independent \
    AUTO_ROUTE=1 \
    AUTO_REDIRECT=0 \
    FAKE_IP=0 \
    DNS_HIJACK=0 \
    INCLUDED_ROUTES='' \
    EXCLUDED_ROUTES='' \
    FWMARK=0x2022 \
    ICMP=auto \
    LOG_LEVEL=warn \
    STATS_INTERVAL=0 \
    CONFIG=''

HEALTHCHECK --start-period=5s --interval=10s --timeout=2s --retries=3 CMD ["zeptun", "probe"]

COPY --chmod=755 docker/entrypoint.sh /entrypoint.sh
COPY --from=builder /src/zig-out/bin/zeptun /usr/bin/zeptun
COPY conf/zeptun.toml /etc/zeptun/zeptun.toml

ENTRYPOINT ["/entrypoint.sh"]
