const std = @import("std");
const build_options = @import("build_options");
const device = @import("device.zig");
const linux_dev = @import("linux.zig");
const io = @import("../io/io.zig");
const sys = @import("../io/sys.zig");
const pool = @import("../packet/pool.zig");
const gso = @import("../packet/gso.zig");
const parse = @import("../packet/parse.zig");
const stats = @import("../stats.zig");
const addr = @import("../addr.zig");
const route = @import("../route/linux.zig");

fn MockWorker(comptime L: type) type {
    return struct {
        const Self = @This();
        pub const Loop = L;

        loop: Loop,
        pool: pool.Pool,
        counters: *stats.Counters,
        q: linux_dev.Queue(Self),
        reflected: u32 = 0,

        pub fn onDevicePacket(w: *Self, b: *pool.Buffer, vh: gso.VirtioNetHdr) void {
            const data = b.bytes();
            const p = parse.parse(data) catch {
                w.pool.put(b);
                return;
            };
            if (p.l4 != .udp) {
                w.pool.put(b);
                return;
            }
            const al = p.ip.addrLen();
            var tmp: [16]u8 = undefined;
            @memcpy(tmp[0..al], data[p.ip.srcOff()..][0..al]);
            @memcpy(data[p.ip.srcOff()..][0..al], data[p.ip.dstOff()..][0..al]);
            @memcpy(data[p.ip.dstOff()..][0..al], tmp[0..al]);
            const sp = p.l4.udp.src_port;
            parse.setBe16(data, p.l4_off, p.l4.udp.dst_port);
            parse.setBe16(data, p.l4_off + 2, sp);
            if (!vh.needsCsum()) {
                gso.setFullChecksum(data, p.ip, parse.proto.udp, p.l4_off + 6);
            }
            w.reflected += 1;
            w.q.send(b, vh);
        }
    };
}

fn reflectOnce(comptime L: type, kind: io.BackendKind) !void {
    var t = linux_dev.Tun.open(.{ .name = "zept%d", .queues = 1, .mtu = 1500 }) catch |err| switch (err) {
        error.PermissionDenied, error.DeviceNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer t.close();
    const prefix = try addr.Prefix.parse("10.77.0.1/24");
    _ = route.configure(.{ .name = t.nameSlice(), .mtu = 1500, .addresses = &.{prefix} }) catch |err| switch (err) {
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    var counters: stats.Counters = .{};
    const W = MockWorker(L);
    var w: W = undefined;
    w.loop = try L.init(std.testing.allocator, .{ .entries = 128, .backend = kind });
    defer w.loop.deinit();
    w.pool = try pool.Pool.init(std.testing.allocator, .{ .count = 256, .buffer_size = t.caps.bufferSize() });
    defer w.pool.deinit();
    w.counters = &counters;
    w.reflected = 0;
    try w.q.init(std.testing.allocator, &w, .{ .fd = t.fds[0], .caps = t.caps, .rx_parallel = 4, .tx_slots = 32 });
    defer w.q.deinit(std.testing.allocator);
    try w.q.start();

    const s = try sys.socket(.v4, .udp);
    defer sys.close(s);
    var bind_sa = sys.Sockaddr.fromEndpoint(try addr.Endpoint.parse("10.77.0.1:0"));
    try std.testing.expect(sys.bind(s, &bind_sa) == 0);
    var local: sys.Sockaddr = .{};
    _ = sys.getsockname(s, &local);
    const dst = sys.Sockaddr.fromEndpoint(try addr.Endpoint.parse("10.77.0.2:4242"));
    const payload = "zeptun reflect test payload";
    try std.testing.expectEqual(@as(i32, payload.len), sys.sendto(s, payload, 0, &dst));
    var buf: [256]u8 = undefined;
    var from: sys.Sockaddr = .{};
    var got: i32 = -1;
    var spins: u32 = 0;
    while (got < 0 and spins < 200) : (spins += 1) {
        try w.loop.run(10 * std.time.ns_per_ms);
        w.q.flush();
        got = sys.recvfrom(s, &buf, 0, &from);
    }
    try std.testing.expectEqual(@as(i32, payload.len), got);
    try std.testing.expectEqualStrings(payload, buf[0..payload.len]);
    try std.testing.expect(from.toEndpoint().?.eql(try addr.Endpoint.parse("10.77.0.2:4242")));
    try std.testing.expect(w.reflected >= 1);
    w.q.stop();
    spins = 0;
    while (!w.q.idle() and spins < 100) : (spins += 1) try w.loop.run(5 * std.time.ns_per_ms);
    try std.testing.expect(w.q.idle());
}

test "tun queue reflects udp through io_uring" {
    if (io.IoUring == void or !@import("../io/io_uring.zig").probe()) return error.SkipZigTest;
    try reflectOnce(io.IoUring, .io_uring);
}

test "tun queue reflects udp through epoll" {
    if (io.Epoll == void) return error.SkipZigTest;
    try reflectOnce(io.Epoll, .epoll);
}
