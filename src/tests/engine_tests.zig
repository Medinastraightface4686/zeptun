const std = @import("std");
const build_options = @import("build_options");
const addr = @import("../addr.zig");
const config = @import("../config.zig");
const engine = @import("../engine.zig");
const sys = @import("../io/sys.zig");
const parse = @import("../packet/parse.zig");
const checksum = @import("../packet/checksum.zig");
const stats = @import("../stats.zig");
const external = @import("../device/external.zig");
const h = @import("helpers.zig");

fn externalConfig() config.Config {
    var cfg = config.Config.fromPreset(.mobile);
    cfg.device.kind = .external;
    cfg.stack.mode = .userspace;
    cfg.handler.kind = .direct;
    cfg.io.workers = 1;
    cfg.log_level = .warn;
    return cfg;
}

test "external device udp echo through direct handler" {
    if (!sys.is_linux) return error.SkipZigTest;
    var echo: h.UdpEcho = .{ .fd = -1, .port = 0 };
    try echo.start();
    defer echo.deinit();
    var collector: h.Collector = .{};
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    e.external.?.setOutput(h.Collector.output, &collector);
    try e.start();
    const client = try addr.Endpoint.parse("10.0.0.2:5555");
    const server: addr.Endpoint = .{ .addr = try addr.Address.parse("127.0.0.1"), .port = echo.port };
    var pkt_buf: [256]u8 = undefined;
    const payload = "hello zeptun udp";
    const pkt = h.buildUdp4(&pkt_buf, client, server, payload);
    const pk: external.Packet = .{ .data = pkt.ptr, .len = pkt.len };
    try std.testing.expectEqual(@as(usize, 1), e.external.?.injectBatch(&.{pk}));
    var out: [2048]u8 = undefined;
    const reply = collector.next(3000, &out) orelse return error.NoReply;
    const p = try parse.parse(reply);
    try std.testing.expect(p.l4 == .udp);
    try std.testing.expect(parse.l4ChecksumValid(reply, p));
    try std.testing.expect(checksum.verifyIpv4Header(reply[0..20]));
    try std.testing.expectEqual(echo.port, p.l4.udp.src_port);
    try std.testing.expectEqual(@as(u16, 5555), p.l4.udp.dst_port);
    try std.testing.expectEqualStrings(payload, reply[p.payload_off..][0..p.payload_len]);
    var snap: stats.Snapshot = .{};
    e.snapshot(&snap);
    try std.testing.expectEqual(@as(u64, 1), snap.udp_opened);
    e.stop();
}

test "stop requested before the engine runs is not lost" {
    if (!sys.is_linux) return error.SkipZigTest;
    const e = try engine.Engine.create(std.testing.allocator, externalConfig());
    defer e.destroy();
    e.stop();
    const started = sys.monotonicMs();
    try e.run();
    try std.testing.expect(sys.monotonicMs() - started < 5000);
    try std.testing.expect(!e.isRunning());
}

const PacketTcpClient = struct {
    e: *engine.Engine,
    collector: *h.Collector,
    client: addr.Endpoint,
    server: addr.Endpoint,
    snd_nxt: u32 = 1000,
    rcv_nxt: u32 = 0,
    peer_wscale: u8 = 0,
    peer_window: u32 = 0,
    received: std.ArrayList(u8) = .empty,
    got_fin: bool = false,
    acked: u32 = 0,

    fn send(self: *PacketTcpClient, seg: h.TcpSeg) !void {
        var buf: [2048]u8 = undefined;
        const pkt = h.buildTcp4(&buf, self.client, self.server, seg);
        const pk: external.Packet = .{ .data = pkt.ptr, .len = pkt.len };
        if (self.e.external.?.injectBatch(&.{pk}) != 1) return error.InjectFailed;
    }

    fn pump(self: *PacketTcpClient, timeout_ms: u64) !?parse.Tcp {
        var out: [2048]u8 = undefined;
        const raw = self.collector.next(timeout_ms, &out) orelse return null;
        const p = try parse.parse(raw);
        if (p.l4 != .tcp) return error.UnexpectedProtocol;
        if (!parse.l4ChecksumValid(raw, p)) return error.BadChecksum;
        const t = p.l4.tcp;
        if (t.flags.rst) return error.Reset;
        if (t.flags.ack) {
            self.acked = t.ack;
            self.peer_window = @as(u32, t.window) << @intCast(self.peer_wscale);
        }
        if (p.payload_len > 0) {
            if (t.seq == self.rcv_nxt) {
                try self.received.appendSlice(std.testing.allocator, raw[p.payload_off..][0..p.payload_len]);
                self.rcv_nxt +%= p.payload_len;
            }
            try self.send(.{ .seq = self.snd_nxt, .ack = self.rcv_nxt, .flags = 0x10 });
        }
        if (t.flags.fin and t.seq +% p.payload_len == self.rcv_nxt) {
            self.rcv_nxt +%= 1;
            self.got_fin = true;
            try self.send(.{ .seq = self.snd_nxt, .ack = self.rcv_nxt, .flags = 0x10 });
        }
        return t;
    }
};

test "external device tcp session through userspace terminator" {
    if (!sys.is_linux) return error.SkipZigTest;
    var echo: h.TcpEcho = .{ .fd = -1, .port = 0 };
    try echo.start();
    defer echo.deinit();
    var collector: h.Collector = .{};
    var cfg = externalConfig();
    cfg.stack.tcp_timestamps = false;
    const e = try engine.Engine.create(std.testing.allocator, cfg);
    defer e.destroy();
    e.external.?.setOutput(h.Collector.output, &collector);
    try e.start();
    var cl: PacketTcpClient = .{
        .e = e,
        .collector = &collector,
        .client = try addr.Endpoint.parse("10.0.0.2:40000"),
        .server = .{ .addr = try addr.Address.parse("127.0.0.1"), .port = echo.port },
    };
    defer cl.received.deinit(std.testing.allocator);
    const syn_opts = [_]u8{ 2, 4, 0x05, 0xb4, 4, 2, 1, 3, 3, 7 };
    try cl.send(.{ .seq = 999, .ack = 0, .flags = 0x02, .options = &syn_opts });
    var out: [2048]u8 = undefined;
    const synack_raw = collector.next(3000, &out) orelse return error.NoSynAck;
    const sp = try parse.parse(synack_raw);
    const sa = sp.l4.tcp;
    try std.testing.expect(sa.flags.syn and sa.flags.ack);
    try std.testing.expectEqual(@as(u32, 1000), sa.ack);
    const so = parse.parseTcpOptions(synack_raw[sp.l4_off + 20 .. sp.payload_off]);
    try std.testing.expect(so.mss > 0 and so.sack_permitted and so.has_wscale);
    cl.peer_wscale = so.wscale;
    cl.rcv_nxt = sa.seq +% 1;
    try cl.send(.{ .seq = cl.snd_nxt, .ack = cl.rcv_nxt, .flags = 0x10 });
    var prng = std.Random.DefaultPrng.init(99);
    var payload: [24000]u8 = undefined;
    prng.random().bytes(&payload);
    var sent: usize = 0;
    const deadline = sys.monotonicMs() + 10_000;
    while (cl.received.items.len < payload.len and sys.monotonicMs() < deadline) {
        const inflight = cl.snd_nxt -% cl.acked;
        if (sent < payload.len and (cl.acked == 0 or inflight < 8000)) {
            const n = @min(1200, payload.len - sent);
            try cl.send(.{ .seq = cl.snd_nxt, .ack = cl.rcv_nxt, .flags = 0x18, .payload = payload[sent..][0..n] });
            cl.snd_nxt +%= @intCast(n);
            sent += n;
        }
        _ = try cl.pump(if (sent < payload.len) 5 else 200);
    }
    try std.testing.expectEqual(payload.len, cl.received.items.len);
    try std.testing.expectEqualSlices(u8, &payload, cl.received.items);
    try cl.send(.{ .seq = cl.snd_nxt, .ack = cl.rcv_nxt, .flags = 0x11 });
    cl.snd_nxt +%= 1;
    const close_deadline = sys.monotonicMs() + 5000;
    while (!cl.got_fin and sys.monotonicMs() < close_deadline) _ = try cl.pump(50);
    try std.testing.expect(cl.got_fin);
    var snap: stats.Snapshot = .{};
    const release_deadline = sys.monotonicMs() + 3000;
    while (sys.monotonicMs() < release_deadline) {
        e.snapshot(&snap);
        if (snap.tcp_closed == 1) break;
        _ = try cl.pump(20);
    }
    try std.testing.expectEqual(@as(u64, 1), snap.tcp_opened);
    try std.testing.expectEqual(@as(u64, 1), snap.tcp_closed);
    try std.testing.expectEqual(@as(u64, 0), snap.tcp_active);
    try std.testing.expectEqual(@as(u64, payload.len), echo.bytes.load(.acquire));
}

test "userspace tcp accepts acks at the right window edge" {
    if (!sys.is_linux) return error.SkipZigTest;
    var echo: h.TcpEcho = .{ .fd = -1, .port = 0 };
    try echo.start();
    defer echo.deinit();
    var collector: h.Collector = .{};
    var cfg = externalConfig();
    cfg.stack.tcp_timestamps = false;
    const e = try engine.Engine.create(std.testing.allocator, cfg);
    defer e.destroy();
    e.external.?.setOutput(h.Collector.output, &collector);
    try e.start();
    var cl: PacketTcpClient = .{
        .e = e,
        .collector = &collector,
        .client = try addr.Endpoint.parse("10.0.0.2:40001"),
        .server = .{ .addr = try addr.Address.parse("127.0.0.1"), .port = echo.port },
    };
    defer cl.received.deinit(std.testing.allocator);
    const syn_opts = [_]u8{ 2, 4, 0x05, 0xb4, 4, 2, 1, 3, 3, 7 };
    try cl.send(.{ .seq = 999, .ack = 0, .flags = 0x02, .options = &syn_opts });
    var out: [2048]u8 = undefined;
    const synack_raw = collector.next(3000, &out) orelse return error.NoSynAck;
    const sp = try parse.parse(synack_raw);
    const sa = sp.l4.tcp;
    try std.testing.expect(sa.flags.syn and sa.flags.ack);
    const so = parse.parseTcpOptions(synack_raw[sp.l4_off + 20 .. sp.payload_off]);
    cl.peer_wscale = so.wscale;
    cl.rcv_nxt = sa.seq +% 1;
    try cl.send(.{ .seq = cl.snd_nxt, .ack = cl.rcv_nxt, .flags = 0x10 });
    const hello = "window edge";
    try cl.send(.{ .seq = cl.snd_nxt, .ack = cl.rcv_nxt, .flags = 0x18, .payload = hello });
    cl.snd_nxt +%= hello.len;
    var edge: u32 = 0;
    const deadline = sys.monotonicMs() + 5000;
    while (cl.received.items.len < hello.len and sys.monotonicMs() < deadline) {
        const raw = collector.next(50, &out) orelse continue;
        const p = try parse.parse(raw);
        if (p.l4 != .tcp) continue;
        const t = p.l4.tcp;
        if (t.flags.ack and t.ack == cl.snd_nxt) edge = t.ack +% (@as(u32, t.window) << @intCast(cl.peer_wscale));
        if (p.payload_len > 0 and t.seq == cl.rcv_nxt) {
            try cl.received.appendSlice(std.testing.allocator, raw[p.payload_off..][0..p.payload_len]);
            cl.rcv_nxt +%= p.payload_len;
        }
    }
    try std.testing.expectEqualStrings(hello, cl.received.items);
    try std.testing.expect(edge != 0 and edge != cl.snd_nxt);
    try cl.send(.{ .seq = edge, .ack = cl.rcv_nxt, .flags = 0x10 });
    var retransmitted = false;
    const quiet_deadline = sys.monotonicMs() + 900;
    while (sys.monotonicMs() < quiet_deadline) {
        const raw = collector.next(50, &out) orelse continue;
        const p = try parse.parse(raw);
        if (p.l4 == .tcp and p.payload_len > 0) retransmitted = true;
    }
    var snap: stats.Snapshot = .{};
    e.snapshot(&snap);
    try std.testing.expect(!retransmitted);
    try std.testing.expectEqual(@as(u64, 0), snap.tcp_retransmits);
}

test "steady state tcp traffic performs no heap allocation" {
    if (!sys.is_linux) return error.SkipZigTest;
    var echo: h.TcpEcho = .{ .fd = -1, .port = 0 };
    try echo.start();
    defer echo.deinit();
    var collector: h.Collector = .{};
    var counting: h.CountingAllocator = .{ .child = std.testing.allocator };
    var cfg = externalConfig();
    cfg.stack.tcp_timestamps = false;
    const e = try engine.Engine.create(counting.allocator(), cfg);
    defer e.destroy();
    e.external.?.setOutput(h.Collector.output, &collector);
    try e.start();
    var cl: PacketTcpClient = .{
        .e = e,
        .collector = &collector,
        .client = try addr.Endpoint.parse("10.0.0.2:40002"),
        .server = .{ .addr = try addr.Address.parse("127.0.0.1"), .port = echo.port },
    };
    defer cl.received.deinit(std.testing.allocator);
    const syn_opts = [_]u8{ 2, 4, 0x05, 0xb4, 4, 2, 1, 3, 3, 7 };
    try cl.send(.{ .seq = 999, .ack = 0, .flags = 0x02, .options = &syn_opts });
    var out: [2048]u8 = undefined;
    const synack_raw = collector.next(3000, &out) orelse return error.NoSynAck;
    const sp = try parse.parse(synack_raw);
    const so = parse.parseTcpOptions(synack_raw[sp.l4_off + 20 .. sp.payload_off]);
    cl.peer_wscale = so.wscale;
    cl.rcv_nxt = sp.l4.tcp.seq +% 1;
    try cl.send(.{ .seq = cl.snd_nxt, .ack = cl.rcv_nxt, .flags = 0x10 });
    var payload: [48000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 31);
    var sent: usize = 0;
    var baseline: ?u64 = null;
    const deadline = sys.monotonicMs() + 15_000;
    while (cl.received.items.len < payload.len and sys.monotonicMs() < deadline) {
        if (baseline == null and cl.received.items.len >= 6000) baseline = counting.count();
        const inflight = cl.snd_nxt -% cl.acked;
        if (sent < payload.len and (cl.acked == 0 or inflight < 8000)) {
            const n = @min(1200, payload.len - sent);
            try cl.send(.{ .seq = cl.snd_nxt, .ack = cl.rcv_nxt, .flags = 0x18, .payload = payload[sent..][0..n] });
            cl.snd_nxt +%= @intCast(n);
            sent += n;
        }
        _ = try cl.pump(if (sent < payload.len) 5 else 200);
    }
    try std.testing.expectEqualSlices(u8, &payload, cl.received.items);
    try std.testing.expect(baseline != null);
    try std.testing.expectEqual(baseline.?, counting.count());
}
