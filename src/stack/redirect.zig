const std = @import("std");
const addr = @import("../addr.zig");
const io = @import("../io/io.zig");
const sys = @import("../io/sys.zig");
const handler_mod = @import("../handler/handler.zig");
const relay_mod = @import("relay.zig");
const log = @import("../log.zig");

const linux = std.os.linux;

pub fn openListener(family: addr.Family, port: u16) !sys.fd_t {
    const fd = try sys.socket(family, .tcp);
    errdefer sys.close(fd);
    _ = sys.setsockoptInt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
    _ = sys.setsockoptInt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, 1);
    if (family == .v6) _ = sys.setsockoptInt(fd, linux.IPPROTO.IPV6, linux.IPV6.V6ONLY, 1);
    const any: addr.Address = if (family == .v4) addr.Address.v4(@splat(0)) else addr.Address.v6(@splat(0));
    var sa = sys.Sockaddr.fromEndpoint(.{ .addr = any, .port = port });
    const r = sys.bind(fd, &sa);
    if (r < 0) return sys.errnoError(sys.toErrno(r));
    if (sys.listen(fd, 4096) < 0) return error.SystemResources;
    return fd;
}

pub fn boundPort(fd: sys.fd_t) ?u16 {
    var sa: sys.Sockaddr = .{};
    if (sys.getsockname(fd, &sa) < 0) return null;
    return (sa.toEndpoint() orelse return null).port;
}

pub fn Redirect(comptime W: type) type {
    return struct {
        const Self = @This();
        const Loop = W.Loop;
        const Dial = handler_mod.Dial(W);
        pub const Relay = relay_mod.Relay(W);

        const Listener = struct {
            fd: sys.fd_t = sys.invalid_fd,
            family: addr.Family = .v4,
            c: Loop.Completion = .{},
            peer: sys.Sockaddr = .{},
        };

        listeners: [2]Listener = .{ .{}, .{ .family = .v6 } },
        relays: []Relay,
        free: []u32,
        free_len: u32 = 0,
        fresh: u32 = 0,
        port: u16,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: u32, fd4: sys.fd_t, fd6: sys.fd_t, port: u16) !Self {
            const relays = try allocator.alloc(Relay, capacity);
            errdefer allocator.free(relays);
            const free = try allocator.alloc(u32, capacity);
            var s: Self = .{ .relays = relays, .free = free, .port = port, .allocator = allocator };
            s.listeners[0].fd = fd4;
            s.listeners[1].fd = fd6;
            return s;
        }

        pub fn deinit(rd: *Self) void {
            rd.allocator.free(rd.relays);
            rd.allocator.free(rd.free);
        }

        pub fn start(rd: *Self, w: *W) !void {
            for (&rd.listeners) |*l| {
                if (l.fd == sys.invalid_fd) continue;
                try w.loop.register(l.fd);
                l.c = .{ .op = .{ .accept = .{ .fd = l.fd, .peer = &l.peer } }, .userdata = l, .callback = onAccept };
                w.loop.submit(&l.c);
            }
        }

        fn take(rd: *Self) ?*Relay {
            if (rd.free_len > 0) {
                rd.free_len -= 1;
                return &rd.relays[rd.free[rd.free_len]];
            }
            if (rd.fresh < rd.relays.len) {
                rd.fresh += 1;
                return &rd.relays[rd.fresh - 1];
            }
            return null;
        }

        fn onRelayReleased(w: *W, r: *Relay) void {
            const rd = &w.redirect.?;
            const slot: u32 = @intCast((@intFromPtr(r) - @intFromPtr(rd.relays.ptr)) / @sizeOf(Relay));
            rd.free[rd.free_len] = slot;
            rd.free_len += 1;
        }

        fn onAccept(ud: ?*anyopaque, loop: *Loop, c: *Loop.Completion, result: i32) io.Disposition {
            _ = c;
            const l: *Listener = @ptrCast(@alignCast(ud.?));
            const w: *W = @alignCast(@fieldParentPtr("loop", loop));
            const rd = &w.redirect.?;
            if (result < 0) {
                return switch (sys.toErrno(result)) {
                    .canceled, .badf, .inval => .disarm,
                    else => .rearm,
                };
            }
            const fd: sys.fd_t = result;
            const target = sys.originalDestination(fd, l.family) orelse {
                sys.close(fd);
                return .rearm;
            };
            var local: sys.Sockaddr = .{};
            if (sys.getsockname(fd, &local) == 0) {
                if (local.toEndpoint()) |ep| {
                    if (ep.eql(target)) {
                        sys.close(fd);
                        return .rearm;
                    }
                }
            }
            const r = rd.take() orelse {
                w.counters.inc(.tcp_connect_failed);
                sys.close(fd);
                return .rearm;
            };
            r.* = .{ .active = true, .on_release = onRelayReleased };
            r.client.fd = fd;
            w.loop.register(fd) catch {};
            handler_mod.direct.tuneTcp(fd);
            w.counters.inc(.tcp_opened);
            w.counters.inc(.tcp_active);
            w.handler.dialTcp(w, &r.dial, target, .redirect);
            return .rearm;
        }

        pub fn onDialDone(rd: *Self, w: *W, d: *Dial, result: sys.Errno) void {
            _ = rd;
            Relay.fromDial(d).dialDone(w, d, result);
        }

        pub fn stop(rd: *Self, w: *W) void {
            for (&rd.listeners) |*l| {
                if (l.c.isActive()) w.loop.cancel(&l.c);
            }
            for (rd.relays[0..rd.fresh]) |*r| {
                if (r.active and !r.closing) r.close(w, true);
            }
        }

        pub fn idle(rd: *const Self) bool {
            for (&rd.listeners) |*l| {
                if (l.c.isActive()) return false;
            }
            for (rd.relays[0..rd.fresh]) |*r| {
                if (r.active) return false;
            }
            return true;
        }

        pub fn finalizeUnregistered(rd: *Self) void {
            for (&rd.listeners) |*l| {
                if (l.fd != sys.invalid_fd) {
                    sys.close(l.fd);
                    l.fd = sys.invalid_fd;
                }
            }
        }

        pub fn finalize(rd: *Self, w: *W) void {
            for (&rd.listeners) |*l| {
                if (l.fd != sys.invalid_fd) {
                    w.loop.unregister(l.fd);
                    sys.close(l.fd);
                    l.fd = sys.invalid_fd;
                }
            }
        }
    };
}
