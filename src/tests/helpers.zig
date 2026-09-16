const std = @import("std");
const builtin = @import("builtin");
const addr = @import("../addr.zig");
const sys = @import("../io/sys.zig");
const checksum = @import("../packet/checksum.zig");
const parse = @import("../packet/parse.zig");
const gso = @import("../packet/gso.zig");
const ip = @import("../stack/ip.zig");
const external = @import("../device/external.zig");
const queue = @import("../queue.zig");

const linux = std.os.linux;

pub fn debugSink(_: ?*anyopaque, level: @import("../log.zig").Level, message: []const u8) void {
    std.debug.print("[{t}] {s}\n", .{ level, message });
}

pub fn blockingSocket(family: addr.Family, udp: bool) !i32 {
    const af: u32 = if (family == .v4) linux.AF.INET else linux.AF.INET6;
    const kind: u32 = if (udp) linux.SOCK.DGRAM else linux.SOCK.STREAM;
    const r = sys.linuxResult(linux.socket(af, kind | linux.SOCK.CLOEXEC, 0));
    if (r < 0) return error.SocketFailed;
    return r;
}

pub fn setRecvTimeout(fd: i32, ms: u32) void {
    const tv: linux.timeval = .{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
}

pub const UdpEcho = struct {
    fd: i32,
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *UdpEcho) !void {
        self.fd = try blockingSocket(.v4, true);
        var sa = sys.Sockaddr.fromEndpoint(try addr.Endpoint.parse("127.0.0.1:0"));
        if (sys.bind(self.fd, &sa) < 0) return error.BindFailed;
        _ = sys.getsockname(self.fd, &sa);
        self.port = sa.toEndpoint().?.port;
        setRecvTimeout(self.fd, 50);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *UdpEcho) void {
        var buf: [65536]u8 = undefined;
        while (!self.stop.load(.acquire)) {
            var from: sys.Sockaddr = .{};
            const n = sys.recvfrom(self.fd, &buf, 0, &from);
            if (n <= 0) continue;
            _ = sys.sendto(self.fd, buf[0..@intCast(n)], 0, &from);
        }
    }

    pub fn deinit(self: *UdpEcho) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        sys.close(self.fd);
    }
};

pub const TcpEcho = struct {
    fd: i32,
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    bytes: std.atomic.Value(u64) = .init(0),
    host: []const u8 = "127.0.0.1:0",
    discard: bool = false,

    pub fn start(self: *TcpEcho) !void {
        const ep = try addr.Endpoint.parse(self.host);
        self.fd = try blockingSocket(ep.addr.family, false);
        _ = sys.setsockoptInt(self.fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
        var sa = sys.Sockaddr.fromEndpoint(ep);
        if (sys.bind(self.fd, &sa) < 0) return error.BindFailed;
        if (sys.listen(self.fd, 64) < 0) return error.ListenFailed;
        _ = sys.getsockname(self.fd, &sa);
        self.port = sa.toEndpoint().?.port;
        setRecvTimeout(self.fd, 50);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn run(self: *TcpEcho) void {
        while (!self.stop.load(.acquire)) {
            const r = sys.linuxResult(linux.accept4(self.fd, null, null, linux.SOCK.CLOEXEC));
            if (r < 0) continue;
            const t = std.Thread.spawn(.{}, serve, .{ self, r }) catch {
                sys.close(r);
                continue;
            };
            t.detach();
        }
    }

    fn serve(self: *TcpEcho, fd: i32) void {
        defer sys.close(fd);
        setRecvTimeout(fd, 5000);
        var buf: [65536]u8 = undefined;
        while (true) {
            const n = sys.linuxResult(linux.read(fd, &buf, buf.len));
            if (n <= 0) return;
            _ = self.bytes.fetchAdd(@intCast(n), .monotonic);
            if (self.discard) continue;
            var off: usize = 0;
            while (off < n) {
                const wr = sys.linuxResult(linux.write(fd, buf[off..].ptr, @as(usize, @intCast(n)) - off));
                if (wr <= 0) return;
                off += @intCast(wr);
            }
        }
    }

    pub fn deinit(self: *TcpEcho) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        sys.close(self.fd);
    }
};

pub const Collector = struct {
    lock: queue.SpinLock = .{},
    packets: [256][2048]u8 = undefined,
    lens: [256]usize = undefined,
    count: usize = 0,
    read_index: usize = 0,

    pub fn output(ctx: ?*anyopaque, packets: [*]const external.Packet, n: usize) callconv(.c) void {
        const self: *Collector = @ptrCast(@alignCast(ctx.?));
        self.lock.lock();
        defer self.lock.unlock();
        for (packets[0..n]) |p| {
            if (self.count == self.packets.len) return;
            const l = @min(p.len, 2048);
            @memcpy(self.packets[self.count][0..l], p.data[0..l]);
            self.lens[self.count] = l;
            self.count += 1;
        }
    }

    pub fn next(self: *Collector, timeout_ms: u64, out: []u8) ?[]u8 {
        const deadline = sys.monotonicMs() + timeout_ms;
        while (sys.monotonicMs() < deadline) {
            self.lock.lock();
            if (self.read_index < self.count) {
                const i = self.read_index;
                self.read_index += 1;
                const l = self.lens[i];
                @memcpy(out[0..l], self.packets[i][0..l]);
                self.lock.unlock();
                return out[0..l];
            }
            self.lock.unlock();
            sys.sleepMs(1);
        }
        return null;
    }
};

pub fn buildUdp4(buf: []u8, src: addr.Endpoint, dst: addr.Endpoint, payload: []const u8) []u8 {
    const total = 28 + payload.len;
    ip.writeIpv4(buf, src.addr.slice(), dst.addr.slice(), parse.proto.udp, @intCast(8 + payload.len), 64, 0, 1);
    parse.setBe16(buf, 20, src.port);
    parse.setBe16(buf, 22, dst.port);
    parse.setBe16(buf, 24, @intCast(8 + payload.len));
    buf[26] = 0;
    buf[27] = 0;
    @memcpy(buf[28..][0..payload.len], payload);
    const p = parse.parseIp(buf[0..total]) catch unreachable;
    gso.setFullChecksum(buf[0..total], p, parse.proto.udp, 26);
    return buf[0..total];
}

pub const TcpSeg = struct {
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16 = 65535,
    options: []const u8 = &.{},
    payload: []const u8 = &.{},
};

pub fn buildTcp4(buf: []u8, src: addr.Endpoint, dst: addr.Endpoint, s: TcpSeg) []u8 {
    const opt_len = (s.options.len + 3) / 4 * 4;
    const tcp_len = 20 + opt_len + s.payload.len;
    const total = 20 + tcp_len;
    ip.writeIpv4(buf, src.addr.slice(), dst.addr.slice(), parse.proto.tcp, @intCast(tcp_len), 64, 0, 7);
    const t = buf[20..];
    parse.setBe16(t, 0, src.port);
    parse.setBe16(t, 2, dst.port);
    parse.setBe32(t, 4, s.seq);
    parse.setBe32(t, 8, s.ack);
    t[12] = @intCast((20 + opt_len) << 2);
    t[13] = s.flags;
    parse.setBe16(t, 14, s.window);
    t[16] = 0;
    t[17] = 0;
    t[18] = 0;
    t[19] = 0;
    @memset(t[20..][0..opt_len], 1);
    @memcpy(t[20..][0..s.options.len], s.options);
    @memcpy(t[20 + opt_len ..][0..s.payload.len], s.payload);
    const p = parse.parseIp(buf[0..total]) catch unreachable;
    gso.setFullChecksum(buf[0..total], p, parse.proto.tcp, 36);
    return buf[0..total];
}

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    calls: std.atomic.Value(u64) = .init(0),

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn count(self: *const CountingAllocator) u64 {
        return self.calls.load(.acquire);
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        _ = self.calls.fetchAdd(1, .monotonic);
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};
