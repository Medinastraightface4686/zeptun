const std = @import("std");
const checksum = @import("../packet/checksum.zig");
const parse = @import("../packet/parse.zig");
const pool = @import("../packet/pool.zig");
const ip = @import("ip.zig");
const addr = @import("../addr.zig");

pub const echo_request_v4: u8 = 8;
pub const echo_reply_v4: u8 = 0;
pub const echo_request_v6: u8 = 128;
pub const echo_reply_v6: u8 = 129;
pub const unreachable_v4: u8 = 3;
pub const unreachable_v6: u8 = 1;
pub const time_exceeded_v4: u8 = 11;
pub const time_exceeded_v6: u8 = 3;

pub fn input(w: anytype, b: *pool.Buffer, pkt: parse.Packet) void {
    const data = b.bytes();
    const m = pkt.l4.icmp;
    const v6 = pkt.ip.isV6();
    const request: u8 = if (v6) echo_request_v6 else echo_request_v4;
    if (w.cfg.stack.icmp == .drop or m.kind != request or m.code != 0 or pkt.ip.isFragment()) {
        w.pool.put(b);
        return;
    }
    if (w.cfg.icmpForward()) {
        if (w.ping.input(w, b, pkt)) return;
    }
    if (!reflectEcho(data, pkt)) {
        w.pool.put(b);
        return;
    }
    w.counters.inc(.icmp_echo);
    w.transmit(b, .{});
}

pub fn reflectEcho(data: []u8, pkt: parse.Packet) bool {
    const v6 = pkt.ip.isV6();
    const al = pkt.ip.addrLen();
    const so = pkt.ip.srcOff();
    const do_ = pkt.ip.dstOff();
    var tmp: [16]u8 = undefined;
    @memcpy(tmp[0..al], data[so..][0..al]);
    @memcpy(data[so..][0..al], data[do_..][0..al]);
    @memcpy(data[do_..][0..al], tmp[0..al]);
    const l4 = pkt.l4_off;
    const old_word = checksum.readNative16(data[l4..][0..2]);
    data[l4] = if (v6) echo_reply_v6 else echo_reply_v4;
    const new_word = checksum.readNative16(data[l4..][0..2]);
    const hc = checksum.readNative16(data[l4 + 2 ..][0..2]);
    checksum.writeNative16(data[l4 + 2 ..][0..2], checksum.update16(hc, old_word, new_word));
    if (v6) {
        data[7] = ip.default_ttl;
    } else {
        data[8] = ip.default_ttl;
        checksum.ipv4Header(data[0..pkt.ip.header_len]);
    }
    return true;
}

pub fn expired(w: anytype, b: *pool.Buffer, pkt: parse.Packet) bool {
    if (pkt.ip.ttl > 1 or w.cfg.stack.icmp == .drop) return false;
    const data = b.bytes();
    if (pkt.l4 == .icmp and !isQuery(pkt.l4.icmp.kind, pkt.ip.isV6())) return true;
    if (pkt.ip.frag_offset != 0) return true;
    sendError(w, data, pkt, if (pkt.ip.isV6()) time_exceeded_v6 else time_exceeded_v4, 0);
    return true;
}

fn isQuery(kind: u8, v6: bool) bool {
    if (v6) return kind >= 128;
    return kind == echo_request_v4 or kind == echo_reply_v4 or kind >= 13;
}

pub fn sendUnreachable(w: anytype, orig: []const u8, pkt: parse.Packet, port: bool) void {
    const v6 = pkt.ip.isV6();
    const kind: u8 = if (v6) unreachable_v6 else unreachable_v4;
    const code: u8 = if (v6) (if (port) @as(u8, 4) else 3) else (if (port) @as(u8, 3) else 1);
    sendError(w, orig, pkt, kind, code);
}

pub fn sendPortUnreachable(w: anytype, client: addr.Endpoint, target: addr.Endpoint) void {
    const v6 = client.addr.family == .v6;
    const al: usize = if (v6) 16 else 4;
    const hl = ip.headerLen(v6);
    const total = hl + 8;
    var orig: [48]u8 = @splat(0);
    if (total > orig.len) return;
    _ = ip.writeHeader(orig[0..total], v6, client.addr.bytes[0..al], target.addr.bytes[0..al], parse.proto.udp, 8, 0);
    parse.setBe16(orig[0..total], hl, client.port);
    parse.setBe16(orig[0..total], hl + 2, target.port);
    parse.setBe16(orig[0..total], hl + 4, 8);
    const pkt = parse.parse(orig[0..total]) catch return;
    sendError(w, orig[0..total], pkt, if (v6) unreachable_v6 else unreachable_v4, if (v6) 4 else 3);
}

fn sendError(w: anytype, orig: []const u8, pkt: parse.Packet, kind: u8, code: u8) void {
    const b = w.pool.get() orelse return;
    const v6 = pkt.ip.isV6();
    const ip_hlen: u32 = ip.headerLen(v6);
    const max_body: usize = if (v6) 1280 - 48 else 576 - 28;
    const body_len: u32 = @intCast(@min(@min(orig.len, pkt.ip.total_len), max_body));
    const total = ip_hlen + 8 + body_len;
    if (b.tailroom() < total) {
        w.pool.put(b);
        return;
    }
    const out = b.tail()[0..total];
    const icmp_len: u32 = 8 + body_len;
    _ = ip.writeHeader(out, v6, pkt.ip.dst(orig), pkt.ip.src(orig), if (v6) parse.proto.icmpv6 else parse.proto.icmp, icmp_len, 0);
    const m = out[ip_hlen..];
    m[0] = kind;
    m[1] = code;
    @memset(m[2..8], 0);
    @memcpy(m[8..][0..body_len], orig[0..body_len]);
    var acc: u64 = 0;
    if (v6) acc = checksum.pseudoV6(out[8..24], out[24..40], parse.proto.icmpv6, icmp_len);
    checksum.writeNative16(m[2..4], checksum.finish(checksum.sum(m[0..icmp_len], acc)));
    b.len = total;
    w.transmit(b, .{});
}

test "echo reflection keeps checksum valid" {
    var buf: [64]u8 = @splat(0);
    const payload = "pingdata";
    const total: u32 = 20 + 8 + payload.len;
    ip.writeIpv4(&buf, &[_]u8{ 10, 0, 0, 1 }, &[_]u8{ 1, 1, 1, 1 }, parse.proto.icmp, 8 + payload.len, 64, 0, 3);
    buf[20] = echo_request_v4;
    parse.setBe16(&buf, 24, 0x1234);
    @memcpy(buf[28..][0..payload.len], payload);
    checksum.writeNative16(buf[22..24], checksum.compute(buf[20..total]));
    const pkt = try parse.parse(buf[0..total]);
    try std.testing.expect(reflectEcho(buf[0..total], pkt));
    try std.testing.expectEqual(echo_reply_v4, buf[20]);
    try std.testing.expectEqual(@as(u16, 0xffff), checksum.fold(checksum.sum(buf[20..total], 0)));
    try std.testing.expect(checksum.verifyIpv4Header(buf[0..20]));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 1, 1 }, buf[12..16]);
}

const config = @import("../config.zig");
const stats = @import("../stats.zig");

const TestWorker = struct {
    cfg: config.Config = .{},
    pool: pool.Pool,
    counters: stats.Counters = .{},
    out: ?*pool.Buffer = null,

    fn transmit(w: *@This(), b: *pool.Buffer, _: anytype) void {
        w.out = b;
    }
};

test "expired ttl answers with time exceeded" {
    var w = TestWorker{ .pool = try pool.Pool.init(std.testing.allocator, .{ .count = 4, .buffer_size = 512 }) };
    defer w.pool.deinit();
    const probe = w.pool.get().?;
    defer w.pool.put(probe);
    const payload = "udpprobe";
    const total: u32 = 20 + 8 + payload.len;
    const data = probe.tail()[0..total];
    ip.writeIpv4(data, &[_]u8{ 10, 0, 0, 2 }, &[_]u8{ 8, 8, 8, 8 }, parse.proto.udp, 8 + payload.len, 1, 0, 7);
    parse.setBe16(data, 20, 40000);
    parse.setBe16(data, 22, 33434);
    parse.setBe16(data, 24, @intCast(8 + payload.len));
    @memcpy(data[28..][0..payload.len], payload);
    probe.len = total;
    const pkt = try parse.parse(probe.bytes());
    try std.testing.expect(expired(&w, probe, pkt));
    const reply = w.out.?;
    defer w.pool.put(reply);
    const rb = reply.bytes();
    const rp = try parse.parse(rb);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 8, 8, 8 }, rb[12..16]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 2 }, rb[16..20]);
    try std.testing.expectEqual(time_exceeded_v4, rb[20]);
    try std.testing.expectEqual(@as(u8, 0), rb[21]);
    try std.testing.expectEqualSlices(u8, data[0..total], rb[28..][0..total]);
    try std.testing.expectEqual(@as(u16, 0xffff), checksum.fold(checksum.sum(rb[20..rp.ip.total_len], 0)));
    try std.testing.expect(checksum.verifyIpv4Header(rb[0..20]));
}

test "expired ttl stays silent for icmp errors" {
    var w = TestWorker{ .pool = try pool.Pool.init(std.testing.allocator, .{ .count = 4, .buffer_size = 512 }) };
    defer w.pool.deinit();
    const probe = w.pool.get().?;
    defer w.pool.put(probe);
    const total: u32 = 20 + 8;
    const data = probe.tail()[0..total];
    ip.writeIpv4(data, &[_]u8{ 10, 0, 0, 2 }, &[_]u8{ 8, 8, 8, 8 }, parse.proto.icmp, 8, 1, 0, 7);
    data[20] = unreachable_v4;
    probe.len = total;
    const pkt = try parse.parse(probe.bytes());
    try std.testing.expect(expired(&w, probe, pkt));
    try std.testing.expect(w.out == null);
}
