const std = @import("std");
const device = @import("device.zig");
const linux = @import("linux.zig");
const sys = @import("../io/sys.zig");

pub const ProtectFn = *const fn (ctx: ?*anyopaque, fd: c_int) callconv(.c) bool;

pub const Protector = struct {
    func: ?ProtectFn = null,
    ctx: ?*anyopaque = null,

    pub fn protect(p: Protector, fd: sys.fd_t) bool {
        const f = p.func orelse return true;
        if (sys.is_windows) return true;
        return f(p.ctx, @intCast(fd));
    }
};

pub fn capabilities(mtu: u32) device.Capabilities {
    return .{
        .vnet_hdr = false,
        .tso = false,
        .uso = false,
        .csum_offload = false,
        .af_prefix = sys.is_darwin,
        .jumbo_tx = sys.is_linux,
        .mtu = mtu,
        .queues = 1,
    };
}

pub fn prepareFd(fd: sys.fd_t) !void {
    if (fd < 0) return error.InvalidArgument;
    try sys.setNonblocking(fd);
}

pub fn Queue(comptime W: type) type {
    return linux.Queue(W);
}

pub fn queueOptions(fd: sys.fd_t, mtu: u32) linux.QueueOptions {
    return .{
        .fd = fd,
        .caps = capabilities(mtu),
        .rx_parallel = 4,
        .tx_slots = 128,
        .coalesce = false,
        .owns_fd = false,
    };
}
