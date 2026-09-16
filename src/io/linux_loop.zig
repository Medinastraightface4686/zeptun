const std = @import("std");
const build_options = @import("build_options");
const linux = std.os.linux;
const io = @import("io.zig");
const sys = @import("sys.zig");
const uring = @import("io_uring.zig");
const epoll = @import("epoll.zig");

pub const has_uring = build_options.enable_io_uring;
pub const has_epoll = build_options.enable_epoll;

pub const Loop = struct {
    pub const Callback = *const fn (userdata: ?*anyopaque, loop: *Loop, c: *Completion, result: i32) io.Disposition;

    pub const Completion = struct {
        pub const Where = enum(u8) { none, readers, writers, ready };

        op: io.Operation = .none,
        userdata: ?*anyopaque = null,
        callback: Callback = noopCallback,
        state: io.State = .idle,
        where: Where = .none,
        connecting: bool = false,
        addrlen: u32 = 0,
        cqe_flags: u32 = 0,
        result: i32 = 0,
        next: ?*Completion = null,
        prev: ?*Completion = null,

        pub inline fn bufferId(c: *const Completion) ?u16 {
            if (c.cqe_flags & linux.IORING_CQE_F_BUFFER == 0) return null;
            return @intCast(c.cqe_flags >> linux.IORING_CQE_BUFFER_SHIFT);
        }

        pub inline fn more(c: *const Completion) bool {
            return c.cqe_flags & linux.IORING_CQE_F_MORE != 0;
        }

        pub inline fn isActive(c: *const Completion) bool {
            return c.state != .idle;
        }
    };

    pub const BufferRing = uring.BufferRing;

    kind: io.BackendKind,
    uring: if (has_uring) uring.Impl(Loop) else void,
    epoll: if (has_epoll) epoll.Impl(Loop) else void,

    inline fn isUring(loop: *const Loop) bool {
        if (!has_epoll) return true;
        if (!has_uring) return false;
        return loop.kind == .io_uring;
    }

    pub fn init(allocator: std.mem.Allocator, options: io.Options) !Loop {
        if (has_uring and (!has_epoll or options.backend != .epoll)) {
            return .{ .kind = .io_uring, .uring = try uring.Impl(Loop).init(allocator, options), .epoll = undefined };
        }
        return .{ .kind = .epoll, .uring = undefined, .epoll = try epoll.Impl(Loop).init(allocator, options) };
    }

    pub fn deinit(loop: *Loop) void {
        if (loop.isUring()) loop.uring.deinit() else loop.epoll.deinit();
    }

    pub fn enable(loop: *Loop) !void {
        if (loop.isUring()) try loop.uring.enable();
    }

    pub inline fn completionBased(loop: *const Loop) bool {
        return loop.isUring();
    }

    pub inline fn now(loop: *const Loop) u64 {
        return if (loop.isUring()) loop.uring.now() else loop.epoll.now();
    }

    pub inline fn nowNs(loop: *const Loop) u64 {
        return if (loop.isUring()) loop.uring.nowNs() else loop.epoll.nowNs();
    }

    pub fn updateTime(loop: *Loop) void {
        if (loop.isUring()) loop.uring.updateTime() else loop.epoll.updateTime();
    }

    pub inline fn pending(loop: *const Loop) u32 {
        return if (loop.isUring()) loop.uring.pending() else loop.epoll.pending();
    }

    pub fn setupBufferRing(loop: *Loop, entries: u16, group: u16) !BufferRing {
        if (!has_uring or !loop.isUring()) return error.NotSupported;
        return loop.uring.setupBufferRing(entries, group);
    }

    pub fn freeBufferRing(loop: *Loop, br: *BufferRing) void {
        if (has_uring and loop.isUring()) loop.uring.freeBufferRing(br);
    }

    pub fn registerFixed(loop: *Loop, fds: []const sys.fd_t) !void {
        if (!has_uring or !loop.isUring()) return error.NotSupported;
        return loop.uring.registerFixed(fds);
    }

    pub inline fn register(loop: *Loop, fd: sys.fd_t) !void {
        if (loop.isUring()) return loop.uring.register(fd);
        return loop.epoll.register(fd);
    }

    pub inline fn unregister(loop: *Loop, fd: sys.fd_t) void {
        if (loop.isUring()) loop.uring.unregister(fd) else loop.epoll.unregister(fd);
    }

    pub fn wakeup(loop: *Loop) void {
        if (loop.isUring()) loop.uring.wakeup() else loop.epoll.wakeup();
    }

    pub inline fn submit(loop: *Loop, c: *Completion) void {
        if (loop.isUring()) loop.uring.submit(c) else loop.epoll.submit(c);
    }

    pub inline fn cancel(loop: *Loop, c: *Completion) void {
        if (loop.isUring()) loop.uring.cancel(c) else loop.epoll.cancel(c);
    }

    pub fn cancelFd(loop: *Loop, fd: sys.fd_t) void {
        if (loop.isUring()) loop.uring.cancelFd(fd) else loop.epoll.cancelFd(fd);
    }

    pub fn run(loop: *Loop, timeout_ns: u64) !void {
        if (loop.isUring()) return loop.uring.run(timeout_ns);
        return loop.epoll.run(timeout_ns);
    }
};

fn noopCallback(_: ?*anyopaque, _: *Loop, _: *Loop.Completion, _: i32) io.Disposition {
    return .disarm;
}

fn backends() []const io.BackendKind {
    if (has_uring and has_epoll) return &.{ .io_uring, .epoll };
    if (has_uring) return &.{.io_uring};
    return &.{.epoll};
}

fn usable(kind: io.BackendKind) bool {
    return kind != .io_uring or uring.probe();
}

test "linux loop read write socketpair and wakeup" {
    for (backends()) |kind| {
        if (!usable(kind)) continue;
        var loop = try Loop.init(std.testing.allocator, .{ .entries = 64, .backend = kind });
        defer loop.deinit();
        try std.testing.expectEqual(kind, loop.kind);
        var fds: [2]i32 = undefined;
        try std.testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0, &fds)) == .SUCCESS);
        defer _ = linux.close(fds[0]);
        defer _ = linux.close(fds[1]);
        const Ctx = struct {
            got: usize = 0,
            writes: usize = 0,
            buf: [64]u8 = undefined,
            fn onRead(ud: ?*anyopaque, _: *Loop, c: *Loop.Completion, result: i32) io.Disposition {
                const self: *@This() = @ptrCast(@alignCast(ud.?));
                if (result > 0) self.got += @intCast(result);
                _ = c;
                return if (self.got < 10) .rearm else .disarm;
            }
            fn onWrite(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, result: i32) io.Disposition {
                const self: *@This() = @ptrCast(@alignCast(ud.?));
                if (result > 0) self.writes += 1;
                return .disarm;
            }
        };
        var ctx: Ctx = .{};
        var rc: Loop.Completion = .{ .op = .{ .recv = .{ .fd = fds[0], .buf = &ctx.buf } }, .userdata = &ctx, .callback = Ctx.onRead };
        loop.submit(&rc);
        var w1: Loop.Completion = .{ .op = .{ .send = .{ .fd = fds[1], .buf = "hello" } }, .userdata = &ctx, .callback = Ctx.onWrite };
        var w2: Loop.Completion = .{ .op = .{ .send = .{ .fd = fds[1], .buf = "world" } }, .userdata = &ctx, .callback = Ctx.onWrite };
        loop.submit(&w1);
        loop.submit(&w2);
        var spins: u32 = 0;
        while (ctx.got < 10 and spins < 100) : (spins += 1) try loop.run(100 * std.time.ns_per_ms);
        try std.testing.expectEqual(@as(usize, 10), ctx.got);
        try std.testing.expectEqual(@as(usize, 2), ctx.writes);
        const Waker = struct {
            fn run(l: *Loop) void {
                sys.sleepMs(20);
                l.wakeup();
            }
        };
        const t = try std.Thread.spawn(.{}, Waker.run, .{&loop});
        const start = sys.monotonicNs();
        try loop.run(5 * std.time.ns_per_s);
        t.join();
        try std.testing.expect(sys.monotonicNs() - start < 2 * std.time.ns_per_s);
    }
}

test "linux loop cancel pending recv" {
    for (backends()) |kind| {
        if (!usable(kind)) continue;
        var loop = try Loop.init(std.testing.allocator, .{ .entries = 16, .backend = kind });
        defer loop.deinit();
        var fds: [2]i32 = undefined;
        _ = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK, 0, &fds);
        defer _ = linux.close(fds[0]);
        defer _ = linux.close(fds[1]);
        const Ctx = struct {
            result: ?i32 = null,
            buf: [8]u8 = undefined,
            fn onRead(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, result: i32) io.Disposition {
                const self: *@This() = @ptrCast(@alignCast(ud.?));
                self.result = result;
                return .disarm;
            }
        };
        var ctx: Ctx = .{};
        var rc: Loop.Completion = .{ .op = .{ .recv = .{ .fd = fds[0], .buf = &ctx.buf } }, .userdata = &ctx, .callback = Ctx.onRead };
        loop.submit(&rc);
        try loop.run(0);
        loop.cancel(&rc);
        var spins: u32 = 0;
        while (ctx.result == null and spins < 50) : (spins += 1) try loop.run(10 * std.time.ns_per_ms);
        try std.testing.expectEqual(sys.Errno.canceled, sys.toErrno(ctx.result.?));
        if (kind == .io_uring) try std.testing.expectEqual(@as(u32, 1), loop.pending());
        if (kind == .epoll) try std.testing.expectEqual(@as(u32, 0), loop.pending());
    }
}

test "linux loop recv send connect accept" {
    const addr = @import("../addr.zig");
    for (backends()) |kind| {
        if (!usable(kind)) continue;
        var loop = try Loop.init(std.testing.allocator, .{ .backend = kind });
        defer loop.deinit();
        const lfd = try sys.socket(.v4, .tcp);
        defer sys.close(lfd);
        var sa = sys.Sockaddr.fromEndpoint(try addr.Endpoint.parse("127.0.0.1:0"));
        try std.testing.expect(sys.bind(lfd, &sa) == 0);
        try std.testing.expect(sys.listen(lfd, 8) == 0);
        try std.testing.expect(sys.getsockname(lfd, &sa) == 0);
        const cfd = try sys.socket(.v4, .tcp);
        defer sys.close(cfd);
        try loop.register(lfd);
        try loop.register(cfd);
        const Ctx = struct {
            accepted: i32 = -1,
            connected: ?i32 = null,
            received: usize = 0,
            buf: [32]u8 = undefined,
            fn onAccept(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, r: i32) io.Disposition {
                const self: *@This() = @ptrCast(@alignCast(ud.?));
                self.accepted = r;
                return .disarm;
            }
            fn onConnect(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, r: i32) io.Disposition {
                const self: *@This() = @ptrCast(@alignCast(ud.?));
                self.connected = r;
                return .disarm;
            }
            fn onRecv(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, r: i32) io.Disposition {
                const self: *@This() = @ptrCast(@alignCast(ud.?));
                if (r > 0) self.received += @intCast(r);
                return if (r > 0 and self.received < 11) .rearm else .disarm;
            }
        };
        var ctx: Ctx = .{};
        var ac: Loop.Completion = .{ .op = .{ .accept = .{ .fd = lfd } }, .userdata = &ctx, .callback = Ctx.onAccept };
        var cc: Loop.Completion = .{ .op = .{ .connect = .{ .fd = cfd, .addr = &sa } }, .userdata = &ctx, .callback = Ctx.onConnect };
        loop.submit(&ac);
        loop.submit(&cc);
        var spins: u32 = 0;
        while ((ctx.accepted < 0 or ctx.connected == null) and spins < 100) : (spins += 1) try loop.run(50 * std.time.ns_per_ms);
        try std.testing.expect(ctx.accepted >= 0);
        try std.testing.expectEqual(@as(i32, 0), ctx.connected.?);
        defer sys.close(ctx.accepted);
        try loop.register(ctx.accepted);
        var rc: Loop.Completion = .{ .op = .{ .recv = .{ .fd = ctx.accepted, .buf = &ctx.buf } }, .userdata = &ctx, .callback = Ctx.onRecv };
        loop.submit(&rc);
        try loop.run(0);
        try std.testing.expect(sys.send(cfd, "hello ", 0) == 6);
        try std.testing.expect(sys.send(cfd, "world", 0) == 5);
        spins = 0;
        while (ctx.received < 11 and spins < 100) : (spins += 1) try loop.run(50 * std.time.ns_per_ms);
        try std.testing.expectEqual(@as(usize, 11), ctx.received);
        loop.unregister(ctx.accepted);
        loop.unregister(cfd);
        loop.unregister(lfd);
    }
}
