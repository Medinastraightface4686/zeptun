const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const sys = @import("../io/sys.zig");
const config = @import("../config.zig");
const gso = @import("../packet/gso.zig");
const pool = @import("../packet/pool.zig");

pub const linux = @import("linux.zig");
pub const android = @import("android.zig");
pub const external = @import("external.zig");
pub const utun = @import("utun.zig");
pub const wintun = @import("wintun.zig");
pub const bsd = @import("bsd.zig");

pub const Kind = enum(u8) { tun, fd, external, utun, wintun, bsd };

pub const Capabilities = struct {
    vnet_hdr: bool = false,
    tso: bool = false,
    uso: bool = false,
    csum_offload: bool = false,
    af_prefix: bool = false,
    jumbo_tx: bool = false,
    mtu: u32 = 1500,
    queues: u16 = 1,

    pub fn maxPacket(c: Capabilities) u32 {
        if (c.tso or c.uso) return pool.max_super_packet + 40;
        return c.mtu;
    }

    pub fn bufferSize(c: Capabilities) u32 {
        const need = pool.default_headroom + @max(c.maxPacket(), pool.max_super_packet + 40) + 64;
        return @intCast(std.mem.alignForward(usize, need, 2048));
    }

    pub inline fn gsoWrite(c: Capabilities) bool {
        return c.vnet_hdr and build_options.enable_gso;
    }
};

pub const max_iov = 12;
pub const header_capacity = 192;

pub const PayloadRef = struct {
    buf: *pool.Buffer,
    off: u32,
    len: u32,
};

pub fn TxSlot(comptime Loop: type) type {
    return struct {
        c: Loop.Completion = .{},
        iov: [max_iov]sys.iovec_const = undefined,
        niov: u8 = 0,
        refs: [max_iov]*pool.Buffer = undefined,
        nrefs: u8 = 0,
        total: u32 = 0,
        hdr: [header_capacity]u8 = undefined,
        next: ?*@This() = null,
    };
}

pub fn SlotPool(comptime Loop: type) type {
    return struct {
        const Self = @This();
        const Slot = TxSlot(Loop);

        slots: []Slot,
        free: ?*Slot,
        fresh: u32 = 0,
        in_flight: u32 = 0,

        pub fn init(allocator: std.mem.Allocator, count: u32) !Self {
            return .{ .slots = try allocator.alloc(Slot, @max(count, 1)), .free = null };
        }

        pub fn deinit(p: *Self, allocator: std.mem.Allocator) void {
            allocator.free(p.slots);
        }

        pub inline fn get(p: *Self) ?*Slot {
            const s = p.free orelse blk: {
                if (p.fresh == p.slots.len) return null;
                const f = &p.slots[p.fresh];
                p.fresh += 1;
                f.* = .{};
                break :blk f;
            };
            p.free = s.next;
            s.next = null;
            s.niov = 0;
            s.nrefs = 0;
            s.total = 0;
            p.in_flight += 1;
            return s;
        }

        pub inline fn put(p: *Self, s: *Slot) void {
            s.next = p.free;
            p.free = s;
            p.in_flight -= 1;
        }
    };
}

pub fn FdQueue(comptime W: type) type {
    return linux.Queue(W);
}

pub const FdQueueOptions = linux.QueueOptions;

pub const Opened = struct {
    fds: [linux.max_queues]sys.fd_t = @splat(sys.invalid_fd),
    count: u16 = 0,
    caps: Capabilities = .{},
    name: [16]u8 = @splat(0),
    index: u32 = 0,
    native: Native = .none,

    pub const Native = union(enum) {
        none: void,
        linux: if (sys.is_linux) linux.Tun else void,
        utun: if (utun.supported) utun.Utun else void,
        bsd: if (bsd.supported) bsd.Tun else void,
        wintun: if (wintun.supported) *wintun.Adapter else void,
    };

    pub fn nameSlice(o: *const Opened) []const u8 {
        return std.mem.sliceTo(&o.name, 0);
    }

    pub fn close(o: *Opened) void {
        switch (o.native) {
            .linux => |*t| if (sys.is_linux) t.close(),
            .utun => |*t| if (utun.supported) t.close(),
            .bsd => |*t| if (bsd.supported) t.close(),
            .wintun => |a| if (wintun.supported) a.close(),
            .none => {},
        }
        o.native = .none;
        o.count = 0;
    }
};

pub const OpenOptions = struct {
    name: []const u8,
    queues: u16,
    mtu: u32,
    offload: bool,
    multi_queue: bool,
    persist: bool,
    napi: bool = false,
    guid: ?config.Guid = null,
};

pub fn openTun(options: OpenOptions) !Opened {
    var o: Opened = .{};
    if (sys.is_linux) {
        const t = try linux.Tun.open(.{
            .name = options.name,
            .queues = options.queues,
            .vnet_hdr = options.offload,
            .offload = options.offload,
            .multi_queue = options.multi_queue,
            .persist = options.persist,
            .mtu = options.mtu,
            .napi = options.napi,
        });
        for (t.fds[0..t.queue_count], 0..) |fd, i| o.fds[i] = fd;
        o.count = t.queue_count;
        o.caps = t.caps;
        o.name = t.name;
        o.native = .{ .linux = t };
        return o;
    }
    if (utun.supported) {
        const u = try utun.Utun.open(.{ .name = options.name, .mtu = options.mtu });
        o.fds[0] = u.fd;
        o.count = 1;
        o.caps = u.caps;
        o.name = u.name;
        o.index = u.index;
        o.native = .{ .utun = u };
        return o;
    }
    if (bsd.supported) {
        const t = try bsd.Tun.open(.{ .name = options.name, .mtu = options.mtu });
        o.fds[0] = t.fd;
        o.count = 1;
        o.caps = t.caps;
        o.name = t.name;
        o.index = t.index;
        o.native = .{ .bsd = t };
        return o;
    }
    if (wintun.supported) {
        const a = try wintun.Adapter.open(.{ .name = options.name, .mtu = options.mtu, .guid = options.guid });
        o.count = 1;
        o.caps = a.caps;
        o.name = a.shortName();
        o.index = a.index;
        o.native = .{ .wintun = a };
        return o;
    }
    return error.NotSupported;
}

test {
    _ = linux;
    _ = external;
}
