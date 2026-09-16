const std = @import("std");
const parse = @import("../packet/parse.zig");
const checksum = @import("../packet/checksum.zig");
const table = @import("table.zig");
const timeouts = @import("timeouts.zig");

pub const State = enum(u8) { free, syn, established, fin_wait, closed };

pub const ListenerPorts = struct {
    bits: [2][2048]std.atomic.Value(u32) = @splat(@splat(.init(0))),

    pub fn add(p: *ListenerPorts, v6: bool, port: u16) void {
        _ = p.bits[@intFromBool(v6)][port >> 5].fetchOr(@as(u32, 1) << @intCast(port & 31), .acquire);
    }

    pub inline fn contains(p: *const ListenerPorts, v6: bool, port: u16) bool {
        return p.bits[@intFromBool(v6)][port >> 5].load(.acquire) & (@as(u32, 1) << @intCast(port & 31)) != 0;
    }
};

pub const Mapping = struct {
    key: parse.FlowKey,
    port: u16,
    state: State,
    fin_client: bool,
    fin_server: bool,
    accepted: bool,
    last_active: u64,
    timer: timeouts.Timer,
    user: u64,
};

pub const Options = struct {
    worker_id: u16,
    workers: u16,
    port_base: u16 = 20000,
    port_limit: u16 = 65000,
    max_mappings: u32,
};

pub const Nat = struct {
    allocator: std.mem.Allocator,
    forward: table.FlowTable(u32),
    mappings: []Mapping,
    free_stack: []u32,
    free_len: u32,
    fresh: u32,
    worker_id: u16,
    workers: u16,
    port_base: u16,
    slots: u32,
    active: u32,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Nat {
        std.debug.assert(options.workers > 0 and options.worker_id < options.workers);
        std.debug.assert(options.port_limit > options.port_base);
        const range: u32 = options.port_limit - options.port_base;
        const slots: u32 = @min(range / options.workers, options.max_mappings);
        if (slots == 0) return error.NoPorts;
        var forward = try table.FlowTable(u32).init(allocator, slots);
        errdefer forward.deinit(allocator);
        const mappings = try allocator.alloc(Mapping, slots);
        errdefer allocator.free(mappings);
        const free_stack = try allocator.alloc(u32, slots);
        return .{
            .allocator = allocator,
            .forward = forward,
            .mappings = mappings,
            .free_stack = free_stack,
            .free_len = 0,
            .fresh = 0,
            .worker_id = options.worker_id,
            .workers = options.workers,
            .port_base = options.port_base,
            .slots = slots,
            .active = 0,
        };
    }

    pub fn deinit(n: *Nat) void {
        n.forward.deinit(n.allocator);
        n.allocator.free(n.mappings);
        n.allocator.free(n.free_stack);
        n.* = undefined;
    }

    pub inline fn portForSlot(n: *const Nat, slot: u32) u16 {
        return @intCast(@as(u32, n.port_base) + slot * n.workers + n.worker_id);
    }

    pub inline fn slotForPort(n: *const Nat, port: u16) ?u32 {
        if (port < n.port_base) return null;
        const rel: u32 = port - n.port_base;
        if (rel % n.workers != n.worker_id) return null;
        const slot = rel / n.workers;
        if (slot >= n.fresh) return null;
        return slot;
    }

    pub fn ownerOfPort(port_base: u16, workers: u16, port: u16) ?u16 {
        if (port < port_base) return null;
        return @intCast((port - port_base) % workers);
    }

    pub fn lookup(n: *Nat, key: *const parse.FlowKey) ?*Mapping {
        const i = n.forward.find(key) orelse return null;
        return &n.mappings[n.forward.value(i).*];
    }

    pub fn byPort(n: *Nat, port: u16) ?*Mapping {
        const slot = n.slotForPort(port) orelse return null;
        const m = &n.mappings[slot];
        if (m.state == .free) return null;
        return m;
    }

    pub fn create(n: *Nat, key: parse.FlowKey, now: u64) error{ Exhausted, Exists }!*Mapping {
        const recycled = n.free_len > 0;
        const slot = if (recycled) n.free_stack[n.free_len - 1] else if (n.fresh < n.slots) n.fresh else return error.Exhausted;
        _ = n.forward.insert(key, slot) catch |err| return switch (err) {
            error.Full => error.Exhausted,
            error.Exists => error.Exists,
        };
        if (recycled) n.free_len -= 1 else n.fresh += 1;
        const m = &n.mappings[slot];
        m.* = .{
            .key = key,
            .port = n.portForSlot(slot),
            .state = .syn,
            .fin_client = false,
            .fin_server = false,
            .accepted = false,
            .last_active = now,
            .timer = .{},
            .user = 0,
        };
        n.active += 1;
        return m;
    }

    pub fn release(n: *Nat, m: *Mapping) void {
        std.debug.assert(m.state != .free);
        _ = n.forward.removeKey(&m.key);
        m.state = .free;
        const slot: u32 = @intCast((@intFromPtr(m) - @intFromPtr(n.mappings.ptr)) / @sizeOf(Mapping));
        n.free_stack[n.free_len] = slot;
        n.free_len += 1;
        n.active -= 1;
    }

    pub fn slotOf(n: *const Nat, m: *const Mapping) u32 {
        return @intCast((@intFromPtr(m) - @intFromPtr(n.mappings.ptr)) / @sizeOf(Mapping));
    }
};

pub const Rewrite = struct {
    src: []const u8,
    dst: []const u8,
    src_port: u16,
    dst_port: u16,
};

pub fn rewrite(data: []u8, pkt: parse.Packet, r: Rewrite, partial: bool) void {
    const ip = pkt.ip;
    const al = ip.addrLen();
    const so = ip.srcOff();
    const do_ = ip.dstOff();
    const l4 = pkt.l4_off;
    const csum_off: usize = switch (pkt.l4) {
        .tcp => l4 + 16,
        .udp => l4 + 6,
        else => 0,
    };
    const has_l4_csum = csum_off != 0 and !(pkt.l4 == .udp and pkt.l4.udp.checksum == 0);
    if (has_l4_csum) {
        var c = checksum.readNative16(data[csum_off..][0..2]);
        const old_addr = checksum.fold(checksum.sum(data[so..][0 .. 2 * al], 0));
        var new_acc = checksum.sum(r.src[0..al], 0);
        new_acc = checksum.sum(r.dst[0..al], new_acc);
        const new_addr = checksum.fold(new_acc);
        if (partial) {
            c = checksum.updatePartial16(c, old_addr, new_addr);
        } else {
            c = checksum.update16(c, old_addr, new_addr);
            var old_ports: [4]u8 = undefined;
            @memcpy(&old_ports, data[l4..][0..4]);
            var new_ports: [4]u8 = undefined;
            std.mem.writeInt(u16, new_ports[0..2], r.src_port, .big);
            std.mem.writeInt(u16, new_ports[2..4], r.dst_port, .big);
            c = checksum.update16(c, checksum.fold(checksum.sum(&old_ports, 0)), checksum.fold(checksum.sum(&new_ports, 0)));
            if (pkt.l4 == .udp and c == 0) c = 0xffff;
        }
        checksum.writeNative16(data[csum_off..][0..2], c);
    }
    if (ip.version == 4) {
        const hc = checksum.readNative16(data[10..12]);
        const old_addr = checksum.fold(checksum.sum(data[12..20], 0));
        var new_acc = checksum.sum(r.src[0..4], 0);
        new_acc = checksum.sum(r.dst[0..4], new_acc);
        checksum.writeNative16(data[10..12], checksum.update16(hc, old_addr, checksum.fold(new_acc)));
    }
    @memcpy(data[so..][0..al], r.src[0..al]);
    @memcpy(data[do_..][0..al], r.dst[0..al]);
    if (pkt.l4 == .tcp or pkt.l4 == .udp) {
        parse.setBe16(data, l4, r.src_port);
        parse.setBe16(data, l4 + 2, r.dst_port);
    }
}

test "port encoding per worker" {
    var a = try Nat.init(std.testing.allocator, .{ .worker_id = 1, .workers = 3, .max_mappings = 100 });
    defer a.deinit();
    var k: parse.FlowKey = .{ .proto = 6, .src_port = 1234, .dst_port = 443 };
    k.src[0] = 10;
    const m = try a.create(k, 5);
    try std.testing.expectEqual(@as(u16, 1), Nat.ownerOfPort(20000, 3, m.port).?);
    try std.testing.expect(a.byPort(m.port) == m);
    try std.testing.expect(a.lookup(&k) == m);
    try std.testing.expectError(error.Exists, a.create(k, 6));
    a.release(m);
    try std.testing.expect(a.lookup(&k) == null);
    try std.testing.expect(a.byPort(m.port) == null);
    try std.testing.expectEqual(@as(u32, 0), a.active);
}

fn buildTcpPacket(buf: []u8, payload_len: usize) []u8 {
    const total = 40 + payload_len;
    @memset(buf[0..total], 0x5a);
    buf[0] = 0x45;
    buf[1] = 0;
    parse.setBe16(buf, 2, @intCast(total));
    parse.setBe16(buf, 4, 1);
    buf[6] = 0x40;
    buf[7] = 0;
    buf[8] = 64;
    buf[9] = 6;
    @memcpy(buf[12..16], &[_]u8{ 172, 19, 0, 1 });
    @memcpy(buf[16..20], &[_]u8{ 1, 1, 1, 1 });
    checksum.ipv4Header(buf[0..20]);
    parse.setBe16(buf, 20, 40000);
    parse.setBe16(buf, 22, 443);
    buf[32] = 0x50;
    buf[33] = 0x18;
    const ip = parse.parseIp(buf[0..total]) catch unreachable;
    @import("../packet/gso.zig").setFullChecksum(buf[0..total], ip, 6, 36);
    return buf[0..total];
}

test "nat rewrite keeps checksums valid" {
    var buf: [1600]u8 = undefined;
    const data = buildTcpPacket(&buf, 1000);
    const p = try parse.parse(data);
    try std.testing.expect(parse.l4ChecksumValid(data, p));
    rewrite(data, p, .{
        .src = &[_]u8{ 172, 19, 0, 2 },
        .dst = &[_]u8{ 172, 19, 0, 1 },
        .src_port = 20001,
        .dst_port = 7000,
    }, false);
    const p2 = try parse.parse(data);
    try std.testing.expect(checksum.verifyIpv4Header(data[0..20]));
    try std.testing.expect(parse.l4ChecksumValid(data, p2));
    try std.testing.expectEqual(@as(u16, 7000), p2.l4.tcp.dst_port);
}

test "nat rewrite on partial checksum packets" {
    var buf: [1600]u8 = undefined;
    const data = buildTcpPacket(&buf, 1000);
    const gso = @import("../packet/gso.zig");
    var p = try parse.parse(data);
    gso.setPartialChecksum(data, p.ip, 6, 36);
    rewrite(data, p, .{
        .src = &[_]u8{ 9, 9, 9, 9 },
        .dst = &[_]u8{ 8, 8, 4, 4 },
        .src_port = 1,
        .dst_port = 2,
    }, true);
    p = try parse.parse(data);
    try gso.completeChecksum(data, gso.VirtioNetHdr.tcpCsumOnly(20, 20));
    try std.testing.expect(parse.l4ChecksumValid(data, p));
    try std.testing.expect(checksum.verifyIpv4Header(data[0..20]));
}
