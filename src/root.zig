const std = @import("std");
const build_options = @import("build_options");

pub const version = build_options.version;

pub const addr = @import("addr.zig");
pub const config = @import("config.zig");
pub const config_json = @import("config_json.zig");
pub const config_toml = @import("config_toml.zig");
pub const engine = @import("engine.zig");
pub const errors = @import("errors.zig");
pub const log = @import("log.zig");
pub const queue = @import("queue.zig");
pub const stats = @import("stats.zig");
pub const elastic = @import("elastic.zig");

pub const io = @import("io/io.zig");
pub const device = @import("device/device.zig");
pub const stack = @import("stack/stack.zig");
pub const handler = @import("handler/handler.zig");
pub const route = @import("route/route.zig");

pub const packet = struct {
    pub const checksum = @import("packet/checksum.zig");
    pub const parse = @import("packet/parse.zig");
    pub const pool = @import("packet/pool.zig");
    pub const gso = @import("packet/gso.zig");
};

pub const flow = struct {
    pub const table = @import("flow/table.zig");
    pub const timeouts = @import("flow/timeouts.zig");
    pub const verdict = @import("flow/verdict.zig");
    pub const nat = @import("flow/nat.zig");
    pub const slab = @import("flow/slab.zig");
};

pub const Engine = engine.Engine;
pub const Config = config.Config;

test {
    _ = addr;
    _ = config;
    _ = config_json;
    _ = config_toml;
    _ = engine;
    _ = errors;
    _ = log;
    _ = queue;
    _ = stats;
    _ = elastic;
    _ = io.sys;
    _ = io.file;
    if (io.sys.is_linux) {
        _ = @import("io/linux_loop.zig");
        _ = @import("device/tests.zig");
    }
    _ = @import("io/kqueue.zig");
    _ = @import("io/iocp.zig");
    _ = device;
    _ = device.linux;
    _ = device.external;
    _ = device.utun;
    _ = device.bsd;
    _ = stack;
    _ = stack.ip;
    _ = stack.icmp;
    _ = stack.dns;
    _ = handler.socks5;
    _ = handler.direct;
    _ = route.linux;
    _ = route.android;
    _ = route.nftables;
    _ = route.monitor;
    _ = route.macos;
    _ = route.resolved;
    _ = packet.checksum;
    _ = packet.parse;
    _ = packet.pool;
    _ = packet.gso;
    _ = flow.table;
    _ = flow.timeouts;
    _ = flow.nat;
    _ = flow.slab;
    _ = @import("tests/engine_tests.zig");
    _ = @import("tests/tcp_sim.zig");
}
