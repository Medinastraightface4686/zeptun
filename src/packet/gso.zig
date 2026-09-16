const std = @import("std");
const checksum = @import("checksum.zig");
const parse = @import("parse.zig");
const pool = @import("pool.zig");

pub const VirtioNetHdr = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,

    pub const size = 10;
    pub const f_needs_csum: u8 = 1;
    pub const f_data_valid: u8 = 2;
    pub const gso_none: u8 = 0;
    pub const gso_tcpv4: u8 = 1;
    pub const gso_udp: u8 = 3;
    pub const gso_tcpv6: u8 = 4;
    pub const gso_udp_l4: u8 = 5;
    pub const gso_ecn: u8 = 0x80;

    pub fn read(bytes: *const [size]u8) VirtioNetHdr {
        return .{
            .flags = bytes[0],
            .gso_type = bytes[1],
            .hdr_len = checksum.readNative16(bytes[2..4]),
            .gso_size = checksum.readNative16(bytes[4..6]),
            .csum_start = checksum.readNative16(bytes[6..8]),
            .csum_offset = checksum.readNative16(bytes[8..10]),
        };
    }

    pub fn write(h: VirtioNetHdr, bytes: *[size]u8) void {
        bytes[0] = h.flags;
        bytes[1] = h.gso_type;
        checksum.writeNative16(bytes[2..4], h.hdr_len);
        checksum.writeNative16(bytes[4..6], h.gso_size);
        checksum.writeNative16(bytes[6..8], h.csum_start);
        checksum.writeNative16(bytes[8..10], h.csum_offset);
    }

    pub inline fn gsoKind(h: VirtioNetHdr) u8 {
        return h.gso_type & ~gso_ecn;
    }

    pub inline fn isGso(h: VirtioNetHdr) bool {
        return h.gsoKind() != gso_none and h.gso_size != 0;
    }

    pub inline fn needsCsum(h: VirtioNetHdr) bool {
        return h.flags & f_needs_csum != 0;
    }

    pub fn tcp(v6: bool, ip_hlen: u16, tcp_hlen: u16, mss: u16, ecn: bool) VirtioNetHdr {
        return .{
            .flags = f_needs_csum,
            .gso_type = (if (v6) gso_tcpv6 else gso_tcpv4) | (if (ecn) gso_ecn else 0),
            .hdr_len = ip_hlen + tcp_hlen,
            .gso_size = mss,
            .csum_start = ip_hlen,
            .csum_offset = 16,
        };
    }

    pub fn tcpCsumOnly(ip_hlen: u16, tcp_hlen: u16) VirtioNetHdr {
        return .{
            .flags = f_needs_csum,
            .gso_type = gso_none,
            .hdr_len = ip_hlen + tcp_hlen,
            .csum_start = ip_hlen,
            .csum_offset = 16,
        };
    }

    pub fn udp(ip_hlen: u16, gso_size: u16) VirtioNetHdr {
        return .{
            .flags = f_needs_csum,
            .gso_type = if (gso_size != 0) gso_udp_l4 else gso_none,
            .hdr_len = ip_hlen + 8,
            .gso_size = gso_size,
            .csum_start = ip_hlen,
            .csum_offset = 6,
        };
    }
};

pub const Error = error{ Malformed, Unsupported, NoSpace };

pub fn completeChecksum(pkt: []u8, h: VirtioNetHdr) Error!void {
    if (!h.needsCsum()) return;
    const start: usize = h.csum_start;
    const field: usize = start + h.csum_offset;
    if (field + 2 > pkt.len or start > pkt.len) return error.Malformed;
    var c = checksum.finish(checksum.sum(pkt[start..], 0));
    if (c == 0) c = 0xffff;
    checksum.writeNative16(pkt[field..][0..2], c);
}

pub fn setPartialChecksum(pkt: []u8, ip: parse.Ip, l4_proto: u8, csum_field: usize) void {
    const l4_len: u32 = ip.total_len - ip.header_len;
    const acc = checksum.pseudo(ip.isV6(), ip.src(pkt), ip.dst(pkt), l4_proto, l4_len);
    checksum.writeNative16(pkt[csum_field..][0..2], checksum.fold(acc));
}

pub fn setFullChecksum(pkt: []u8, ip: parse.Ip, l4_proto: u8, csum_field: usize) void {
    const l4_len: u32 = ip.total_len - ip.header_len;
    pkt[csum_field] = 0;
    pkt[csum_field + 1] = 0;
    const acc = checksum.pseudo(ip.isV6(), ip.src(pkt), ip.dst(pkt), l4_proto, l4_len);
    const c = checksum.sum(pkt[ip.header_len..ip.total_len], acc);
    const v = if (l4_proto == parse.proto.udp) checksum.finishUdp(c) else checksum.finish(c);
    checksum.writeNative16(pkt[csum_field..][0..2], v);
}

pub const Segmenter = struct {
    src: []const u8,
    ip: parse.Ip,
    l4_proto: u8,
    hdr_len: u32,
    mss: u32,
    offset: u32,
    index: u32,
    seq: u32,
    tcp_flags: u8,
    ip_id: u16,
    fill_csum: bool,

    pub fn init(pkt: []const u8, h: VirtioNetHdr, fill_csum: bool) Error!Segmenter {
        const p = parse.parse(pkt) catch return error.Malformed;
        const kind = h.gsoKind();
        var s: Segmenter = .{
            .src = pkt[0..p.ip.total_len],
            .ip = p.ip,
            .l4_proto = p.ip.next,
            .hdr_len = p.payload_off,
            .mss = h.gso_size,
            .offset = 0,
            .index = 0,
            .seq = 0,
            .tcp_flags = 0,
            .ip_id = if (p.ip.version == 4) parse.be16(pkt, 4) else 0,
            .fill_csum = fill_csum,
        };
        if (p.ip.isFragment()) return error.Unsupported;
        switch (p.l4) {
            .tcp => |t| {
                if (kind != VirtioNetHdr.gso_tcpv4 and kind != VirtioNetHdr.gso_tcpv6 and kind != VirtioNetHdr.gso_none) return error.Unsupported;
                s.seq = t.seq;
                s.tcp_flags = t.flags.bits();
            },
            .udp => {
                if (kind != VirtioNetHdr.gso_udp_l4 and kind != VirtioNetHdr.gso_none) return error.Unsupported;
            },
            else => return error.Unsupported,
        }
        if (s.mss == 0 or kind == VirtioNetHdr.gso_none) s.mss = @max(1, p.payload_len);
        return s;
    }

    pub inline fn payloadLen(s: *const Segmenter) u32 {
        return @intCast(s.src.len - s.hdr_len);
    }

    pub fn count(s: *const Segmenter) u32 {
        const pl = s.payloadLen();
        if (pl == 0) return 1;
        return (pl + s.mss - 1) / s.mss;
    }

    pub inline fn maxSegmentLen(s: *const Segmenter) u32 {
        return s.hdr_len + s.mss;
    }

    pub fn next(s: *Segmenter, out: []u8) Error!?[]u8 {
        const pl = s.payloadLen();
        if (s.offset >= pl and !(pl == 0 and s.index == 0)) return null;
        const chunk = @min(s.mss, pl - s.offset);
        const total = s.hdr_len + chunk;
        if (out.len < total) return error.NoSpace;
        @memcpy(out[0..s.hdr_len], s.src[0..s.hdr_len]);
        @memcpy(out[s.hdr_len..total], s.src[s.hdr_len + s.offset ..][0..chunk]);
        const last = s.offset + chunk >= pl;
        const first = s.index == 0;
        var seg_ip = s.ip;
        seg_ip.total_len = total;
        if (s.ip.version == 4) {
            parse.setBe16(out, 2, @intCast(total));
            parse.setBe16(out, 4, s.ip_id +% @as(u16, @truncate(s.index)));
            checksum.ipv4Header(out[0..s.ip.header_len]);
        } else {
            parse.setBe16(out, 4, @intCast(total - 40));
        }
        const l4 = s.ip.header_len;
        const csum_field: usize = switch (s.l4_proto) {
            parse.proto.tcp => blk: {
                parse.setBe32(out, l4 + 4, s.seq +% s.offset);
                var flags = s.tcp_flags;
                if (!first) flags &= ~@as(u8, 0x80);
                if (!last) flags &= ~@as(u8, 0x01 | 0x08);
                out[l4 + 13] = flags;
                break :blk l4 + 16;
            },
            else => blk: {
                parse.setBe16(out, l4 + 4, @intCast(total - l4));
                break :blk l4 + 6;
            },
        };
        if (s.fill_csum) {
            setFullChecksum(out[0..total], seg_ip, s.l4_proto, csum_field);
        } else {
            setPartialChecksum(out[0..total], seg_ip, s.l4_proto, csum_field);
        }
        s.offset += chunk;
        s.index += 1;
        if (pl == 0) s.offset = 1;
        return out[0..total];
    }
};

pub const Kind = enum(u8) { tcp, udp };

pub const Item = struct {
    buf: *pool.Buffer,
    key: parse.FlowKey,
    kind: Kind,
    ip_hlen: u16,
    l4_hlen: u16,
    gso_size: u16,
    segs: u16,
    next_seq: u32,
    ack: u32,
    closed: bool,
};

pub const AddResult = enum { merged, inserted, full, rejected };

pub const max_udp_segments = 64;

pub fn Coalescer(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]Item = undefined,
        count: usize = 0,
        max_packet: u32 = pool.max_super_packet,
        enable_udp: bool = true,

        pub fn reset(c: *Self) void {
            c.count = 0;
        }

        fn ipCompatible(a: []const u8, b: []const u8, v6: bool) bool {
            if (v6) {
                return std.mem.readInt(u32, a[0..4], .big) == std.mem.readInt(u32, b[0..4], .big) and a[7] == b[7];
            }
            return a[1] == b[1] and a[8] == b[8] and (a[6] & 0x40) == (b[6] & 0x40);
        }

        pub fn add(c: *Self, p: *pool.Pool, buf: *pool.Buffer) AddResult {
            const data = buf.bytes();
            const pkt = parse.parse(data) catch return .rejected;
            if (pkt.ip.isFragment()) return .rejected;
            const v6 = pkt.ip.isV6();
            if (pkt.ip.header_len != (if (v6) @as(u16, 40) else @as(u16, 20))) return .rejected;
            if (pkt.ip.total_len != data.len) return .rejected;
            const kind: Kind = switch (pkt.l4) {
                .tcp => |t| blk: {
                    const f = t.flags.bits();
                    if (f & ~@as(u8, 0x10 | 0x08) != 0 or f & 0x10 == 0) return .rejected;
                    break :blk .tcp;
                },
                .udp => if (c.enable_udp) .udp else return .rejected,
                else => return .rejected,
            };
            const key = parse.FlowKey.fromPacket(data, pkt);
            const payload_len = pkt.payload_len;
            var i = c.count;
            while (i > 0) {
                i -= 1;
                const it = &c.items[i];
                if (!parse.FlowKey.eql(&it.key, &key)) continue;
                if (it.closed or it.kind != kind) break;
                const head = it.buf.bytes();
                if (!ipCompatible(head, data, v6)) break;
                if (payload_len == 0 or payload_len > it.gso_size) break;
                if (head.len + payload_len > c.max_packet or it.buf.tailroom() < payload_len) break;
                switch (kind) {
                    .tcp => {
                        const t = pkt.l4.tcp;
                        if (t.header_len != it.l4_hlen or t.ack != it.ack or t.seq != it.next_seq) break;
                        if (t.header_len > 20 and !std.mem.eql(u8, head[it.ip_hlen + 20 .. it.ip_hlen + it.l4_hlen], data[pkt.l4_off + 20 .. pkt.payload_off])) break;
                        @memcpy(it.buf.tail()[0..payload_len], data[pkt.payload_off..][0..payload_len]);
                        it.buf.len += payload_len;
                        const hb = it.buf.bytes();
                        hb[it.ip_hlen + 14] = data[pkt.l4_off + 14];
                        hb[it.ip_hlen + 15] = data[pkt.l4_off + 15];
                        if (t.flags.psh) {
                            hb[it.ip_hlen + 13] |= 0x08;
                            it.closed = true;
                        }
                        it.next_seq +%= payload_len;
                    },
                    .udp => {
                        if (it.segs >= max_udp_segments) break;
                        @memcpy(it.buf.tail()[0..payload_len], data[pkt.payload_off..][0..payload_len]);
                        it.buf.len += payload_len;
                    },
                }
                it.segs += 1;
                if (payload_len < it.gso_size) it.closed = true;
                p.put(buf);
                return .merged;
            }
            if (c.count == capacity) return .full;
            c.items[c.count] = .{
                .buf = buf,
                .key = key,
                .kind = kind,
                .ip_hlen = pkt.ip.header_len,
                .l4_hlen = @intCast(pkt.payload_off - pkt.l4_off),
                .gso_size = @intCast(@min(payload_len, 0xffff)),
                .segs = 1,
                .next_seq = if (kind == .tcp) pkt.l4.tcp.seq +% payload_len else 0,
                .ack = if (kind == .tcp) pkt.l4.tcp.ack else 0,
                .closed = payload_len == 0,
            };
            c.count += 1;
            return .inserted;
        }

        pub fn finalize(it: *Item) VirtioNetHdr {
            if (it.segs <= 1) return .{};
            const data = it.buf.bytes();
            const v6 = it.key.v6 != 0;
            const total: u32 = @intCast(data.len);
            if (v6) {
                parse.setBe16(data, 4, @intCast(total - 40));
            } else {
                parse.setBe16(data, 2, @intCast(total));
                checksum.ipv4Header(data[0..it.ip_hlen]);
            }
            const ip = parse.parseIp(data) catch unreachable;
            switch (it.kind) {
                .tcp => {
                    setPartialChecksum(data, ip, parse.proto.tcp, it.ip_hlen + 16);
                    return VirtioNetHdr.tcp(v6, it.ip_hlen, it.l4_hlen, it.gso_size, false);
                },
                .udp => {
                    parse.setBe16(data, it.ip_hlen + 4, @intCast(@min(total - it.ip_hlen, 0xffff)));
                    setPartialChecksum(data, ip, parse.proto.udp, it.ip_hlen + 6);
                    return VirtioNetHdr.udp(it.ip_hlen, it.gso_size);
                },
            }
        }
    };
}

fn buildTcp(buf: []u8, v6: bool, seq: u32, flags: u8, payload: []const u8) []u8 {
    const ip_hlen: usize = if (v6) 40 else 20;
    const total = ip_hlen + 20 + payload.len;
    @memset(buf[0..total], 0);
    if (v6) {
        buf[0] = 0x60;
        parse.setBe16(buf, 4, @intCast(total - 40));
        buf[6] = parse.proto.tcp;
        buf[7] = 64;
        buf[8] = 0xfd;
        buf[23] = 1;
        buf[24] = 0xfd;
        buf[39] = 2;
    } else {
        buf[0] = 0x45;
        parse.setBe16(buf, 2, @intCast(total));
        parse.setBe16(buf, 4, 7);
        buf[6] = 0x40;
        buf[8] = 64;
        buf[9] = parse.proto.tcp;
        @memcpy(buf[12..16], &[_]u8{ 10, 1, 2, 3 });
        @memcpy(buf[16..20], &[_]u8{ 10, 9, 8, 7 });
        checksum.ipv4Header(buf[0..20]);
    }
    const t = ip_hlen;
    parse.setBe16(buf, t, 5555);
    parse.setBe16(buf, t + 2, 80);
    parse.setBe32(buf, t + 4, seq);
    parse.setBe32(buf, t + 8, 99);
    buf[t + 12] = 0x50;
    buf[t + 13] = flags;
    parse.setBe16(buf, t + 14, 1000);
    @memcpy(buf[t + 20 ..][0..payload.len], payload);
    const ip = parse.parseIp(buf[0..total]) catch unreachable;
    setFullChecksum(buf[0..total], ip, parse.proto.tcp, t + 16);
    return buf[0..total];
}

test "segment tcp super packet and verify each segment" {
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    var payload: [20000]u8 = undefined;
    r.bytes(&payload);
    var super_buf: [20100]u8 = undefined;
    for ([_]bool{ false, true }) |v6| {
        const pkt = buildTcp(&super_buf, v6, 0xfffffff0, 0x18 | 0x01 | 0x80, &payload);
        const ip_hlen: u16 = if (v6) 40 else 20;
        const h = VirtioNetHdr.tcp(v6, ip_hlen, 20, 1400, false);
        var seg = try Segmenter.init(pkt, h, true);
        try std.testing.expectEqual(@as(u32, 15), seg.count());
        var out: [1500]u8 = undefined;
        var reassembled: [20000]u8 = undefined;
        var got: usize = 0;
        var n: u32 = 0;
        while (try seg.next(&out)) |s| : (n += 1) {
            const p = try parse.parse(s);
            try std.testing.expect(parse.l4ChecksumValid(s, p));
            if (!v6) try std.testing.expect(checksum.verifyIpv4Header(s[0..20]));
            const t = p.l4.tcp;
            try std.testing.expectEqual(@as(u32, 0xfffffff0) +% @as(u32, @intCast(got)), t.seq);
            try std.testing.expectEqual(n == 0, t.flags.cwr);
            try std.testing.expectEqual(n == 14, t.flags.fin);
            @memcpy(reassembled[got..][0..p.payload_len], s[p.payload_off..][0..p.payload_len]);
            got += p.payload_len;
        }
        try std.testing.expectEqual(@as(usize, 20000), got);
        try std.testing.expectEqualSlices(u8, &payload, &reassembled);
    }
}

test "complete partial checksum" {
    var buf: [200]u8 = undefined;
    const pkt = buildTcp(&buf, false, 1, 0x10, "partial checksum data!");
    const good = checksum.readNative16(pkt[36..38]);
    const ip = try parse.parseIp(pkt);
    setPartialChecksum(pkt, ip, parse.proto.tcp, 36);
    try completeChecksum(pkt, VirtioNetHdr.tcpCsumOnly(20, 20));
    try std.testing.expectEqual(good, checksum.readNative16(pkt[36..38]));
}

test "coalesce tcp segments back into super packet" {
    var p = try pool.Pool.init(std.testing.allocator, .{ .count = 64, .buffer_size = 70000 });
    defer p.deinit();
    var prng = std.Random.DefaultPrng.init(9);
    const r = prng.random();
    var payload: [9000]u8 = undefined;
    r.bytes(&payload);
    var tmp: [10000]u8 = undefined;
    const super = buildTcp(&tmp, false, 5000, 0x10, &payload);
    var seg = try Segmenter.init(super, VirtioNetHdr.tcp(false, 20, 20, 1000, false), true);
    var c: Coalescer(8) = .{};
    var out: [1100]u8 = undefined;
    while (try seg.next(&out)) |s| {
        const b = p.get().?;
        @memcpy(b.tail()[0..s.len], s);
        b.len = @intCast(s.len);
        const res = c.add(&p, b);
        try std.testing.expect(res == .merged or res == .inserted);
    }
    try std.testing.expectEqual(@as(usize, 1), c.count);
    const it = &c.items[0];
    try std.testing.expectEqual(@as(u16, 9), it.segs);
    const h = Coalescer(8).finalize(it);
    try std.testing.expectEqual(VirtioNetHdr.gso_tcpv4, h.gso_type);
    try std.testing.expectEqual(@as(u16, 1000), h.gso_size);
    const merged = it.buf.bytes();
    const mp = try parse.parse(merged);
    try std.testing.expectEqual(@as(u32, 9000), mp.payload_len);
    try std.testing.expectEqualSlices(u8, &payload, merged[mp.payload_off..][0..mp.payload_len]);
    var resplit = try Segmenter.init(merged, h, true);
    try std.testing.expectEqual(@as(u32, 9), resplit.count());
    p.put(it.buf);
    try std.testing.expectEqual(@as(u32, 0), p.in_use);
}

fn fuzzSegment(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const n = smith.slice(&buf);
    const mss = smith.valueRangeAtMost(u16, 1, 2000);
    const kind = smith.valueRangeAtMost(u8, 0, 5);
    const h: VirtioNetHdr = .{ .flags = 1, .gso_type = kind, .gso_size = mss };
    var s = Segmenter.init(buf[0..n], h, smith.value(bool)) catch return;
    var out: [8192]u8 = undefined;
    var guard: u32 = 0;
    while (try s.next(&out)) |seg| {
        _ = seg;
        guard += 1;
        if (guard > 5000) return error.TooManySegments;
    }
}

test "fuzz segmenter" {
    try std.testing.fuzz({}, fuzzSegment, .{});
}
