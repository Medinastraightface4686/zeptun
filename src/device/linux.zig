const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const device = @import("device.zig");
const sys = @import("../io/sys.zig");
const io = @import("../io/io.zig");
const gso = @import("../packet/gso.zig");
const pool = @import("../packet/pool.zig");
const log = @import("../log.zig");

const os_linux = std.os.linux;
const IOCTL = os_linux.IOCTL;

pub const if_tun = struct {
    pub const IFF_TUN: u16 = 0x0001;
    pub const IFF_TAP: u16 = 0x0002;
    pub const IFF_NAPI: u16 = 0x0010;
    pub const IFF_NAPI_FRAGS: u16 = 0x0020;
    pub const IFF_NO_CARRIER: u16 = 0x0040;
    pub const IFF_BACKPRESSURE: u16 = 0x0080;
    pub const IFF_NO_PI: u16 = 0x1000;
    pub const IFF_ONE_QUEUE: u16 = 0x2000;
    pub const IFF_VNET_HDR: u16 = 0x4000;
    pub const IFF_TUN_EXCL: u16 = 0x8000;
    pub const IFF_MULTI_QUEUE: u16 = 0x0100;
    pub const IFF_ATTACH_QUEUE: u16 = 0x0200;
    pub const IFF_DETACH_QUEUE: u16 = 0x0400;
    pub const IFF_PERSIST: u16 = 0x0800;
    pub const IFF_NOFILTER: u16 = 0x1000;

    pub const TUN_F_CSUM: u32 = 0x01;
    pub const TUN_F_TSO4: u32 = 0x02;
    pub const TUN_F_TSO6: u32 = 0x04;
    pub const TUN_F_TSO_ECN: u32 = 0x08;
    pub const TUN_F_UFO: u32 = 0x10;
    pub const TUN_F_USO4: u32 = 0x20;
    pub const TUN_F_USO6: u32 = 0x40;
    pub const TUN_F_UDP_TUNNEL_GSO: u32 = 0x80;

    pub const TUNSETIFF = IOCTL.IOW('T', 202, c_int);
    pub const TUNSETPERSIST = IOCTL.IOW('T', 203, c_int);
    pub const TUNGETFEATURES = IOCTL.IOR('T', 207, c_uint);
    pub const TUNSETOFFLOAD = IOCTL.IOW('T', 208, c_uint);
    pub const TUNGETIFF = IOCTL.IOR('T', 210, c_uint);
    pub const TUNSETSNDBUF = IOCTL.IOW('T', 212, c_int);
    pub const TUNGETVNETHDRSZ = IOCTL.IOR('T', 215, c_int);
    pub const TUNSETVNETHDRSZ = IOCTL.IOW('T', 216, c_int);
    pub const TUNSETQUEUE = IOCTL.IOW('T', 217, c_int);
    pub const TUNSETSTEERINGEBPF = IOCTL.IOR('T', 224, c_int);
    pub const TUNSETFILTEREBPF = IOCTL.IOR('T', 225, c_int);
};

pub const IfReq = extern struct {
    name: [16]u8 = @splat(0),
    flags: u16 = 0,
    pad: [22]u8 = @splat(0),
};

pub const max_queues = 256;

pub const OpenOptions = struct {
    name: []const u8 = "zeptun%d",
    queues: u16 = 1,
    vnet_hdr: bool = true,
    offload: bool = true,
    uso: bool = true,
    persist: bool = false,
    multi_queue: bool = true,
    mtu: u32 = 1500,
    sndbuf: ?i32 = null,
    napi: bool = false,
};

pub const Tun = struct {
    fds: [max_queues]i32 = @splat(-1),
    queue_count: u16 = 0,
    name: [16]u8 = @splat(0),
    caps: device.Capabilities = .{},
    offload_flags: u32 = 0,
    features: u32 = 0,
    flags: u16 = 0,

    pub fn open(options: OpenOptions) !Tun {
        if (!sys.is_linux) return error.NotSupported;
        if (options.name.len >= 16) return error.InvalidArgument;
        const want_queues = std.math.clamp(options.queues, 1, max_queues);
        var t: Tun = .{};
        errdefer t.close();
        const first = try openControl();
        t.fds[0] = first;
        t.queue_count = 1;
        var features: c_uint = 0;
        if (sys.ioctl(first, if_tun.TUNGETFEATURES, @intFromPtr(&features)) == 0) t.features = features;
        var flags: u16 = if_tun.IFF_TUN | if_tun.IFF_NO_PI;
        const vnet = options.vnet_hdr and build_options.enable_gso and (t.features == 0 or t.features & if_tun.IFF_VNET_HDR != 0);
        if (vnet) flags |= if_tun.IFF_VNET_HDR;
        const mq = options.multi_queue and (t.features == 0 or t.features & if_tun.IFF_MULTI_QUEUE != 0);
        if (mq) flags |= if_tun.IFF_MULTI_QUEUE;
        if (options.napi and (t.features == 0 or t.features & if_tun.IFF_NAPI != 0)) flags |= if_tun.IFF_NAPI;
        if (t.features & if_tun.IFF_BACKPRESSURE != 0) flags |= if_tun.IFF_BACKPRESSURE;
        var req: IfReq = .{ .flags = flags };
        @memcpy(req.name[0..options.name.len], options.name);
        const r = sys.ioctl(first, if_tun.TUNSETIFF, @intFromPtr(&req));
        if (r < 0) return sys.errnoError(sys.toErrno(r));
        t.flags = flags;
        t.name = req.name;
        t.caps.mtu = options.mtu;
        if (vnet) {
            var hdr_len: c_int = gso.VirtioNetHdr.size;
            if (sys.ioctl(first, if_tun.TUNSETVNETHDRSZ, @intFromPtr(&hdr_len)) < 0) return error.DeviceError;
            t.caps.vnet_hdr = true;
            if (options.offload) t.negotiateOffloads(options.uso);
        }
        if (options.persist) _ = sys.ioctl(first, if_tun.TUNSETPERSIST, 1);
        if (options.sndbuf) |sb| {
            var v: c_int = sb;
            _ = sys.ioctl(first, if_tun.TUNSETSNDBUF, @intFromPtr(&v));
        }
        const queues: u16 = if (mq) want_queues else 1;
        while (t.queue_count < queues) {
            const fd = try openControl();
            var qreq: IfReq = .{ .flags = flags, .name = t.name };
            const qr = sys.ioctl(fd, if_tun.TUNSETIFF, @intFromPtr(&qreq));
            if (qr < 0) {
                sys.close(fd);
                if (t.queue_count == 0) return sys.errnoError(sys.toErrno(qr));
                log.warn("tun: attached {d} of {d} queues: {t}", .{ t.queue_count, queues, sys.toErrno(qr) });
                break;
            }
            t.fds[t.queue_count] = fd;
            t.queue_count += 1;
        }
        t.caps.queues = t.queue_count;
        t.caps.jumbo_tx = true;
        return t;
    }

    fn openControl() !i32 {
        const paths = [_][*:0]const u8{ "/dev/net/tun", "/dev/tun" };
        var last: i32 = 0;
        for (paths) |path| {
            const r = sys.linuxResult(os_linux.open(path, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true }, 0));
            if (r >= 0) return r;
            last = r;
            if (sys.toErrno(r) != .noent) break;
        }
        return sys.errnoError(sys.toErrno(last));
    }

    fn negotiateOffloads(t: *Tun, allow_uso: bool) void {
        const F = if_tun;
        const attempts = [_]u32{
            F.TUN_F_CSUM | F.TUN_F_TSO4 | F.TUN_F_TSO6 | F.TUN_F_TSO_ECN | F.TUN_F_USO4 | F.TUN_F_USO6,
            F.TUN_F_CSUM | F.TUN_F_TSO4 | F.TUN_F_TSO6 | F.TUN_F_TSO_ECN,
            F.TUN_F_CSUM | F.TUN_F_TSO4 | F.TUN_F_TSO6,
            F.TUN_F_CSUM,
        };
        for (attempts) |want| {
            if (!allow_uso and want & F.TUN_F_USO4 != 0) continue;
            if (sys.ioctl(t.fds[0], F.TUNSETOFFLOAD, want) == 0) {
                t.offload_flags = want;
                t.caps.csum_offload = want & F.TUN_F_CSUM != 0;
                t.caps.tso = want & F.TUN_F_TSO4 != 0;
                t.caps.uso = want & F.TUN_F_USO4 != 0;
                return;
            }
        }
    }

    pub fn setSteeringBpf(t: *Tun, prog_fd: i32) !void {
        var fd = prog_fd;
        const r = sys.ioctl(t.fds[0], if_tun.TUNSETSTEERINGEBPF, @intFromPtr(&fd));
        if (r < 0) return sys.errnoError(sys.toErrno(r));
    }

    pub fn setQueueEnabled(t: *Tun, index: u16, enabled: bool) !void {
        if (index >= t.queue_count) return error.InvalidArgument;
        return setQueueAttached(t.fds[index], enabled);
    }

    pub fn setQueueAttached(fd: i32, attached: bool) !void {
        var req: IfReq = .{ .flags = if (attached) if_tun.IFF_ATTACH_QUEUE else if_tun.IFF_DETACH_QUEUE };
        const r = sys.ioctl(fd, if_tun.TUNSETQUEUE, @intFromPtr(&req));
        if (r < 0) return sys.errnoError(sys.toErrno(r));
    }

    pub fn addQueue(t: *Tun) !i32 {
        if (t.queue_count >= max_queues or t.flags & if_tun.IFF_MULTI_QUEUE == 0) return error.NotSupported;
        const fd = try openControl();
        var req: IfReq = .{ .flags = t.flags, .name = t.name };
        const r = sys.ioctl(fd, if_tun.TUNSETIFF, @intFromPtr(&req));
        if (r < 0) {
            sys.close(fd);
            return sys.errnoError(sys.toErrno(r));
        }
        t.fds[t.queue_count] = fd;
        t.queue_count += 1;
        return fd;
    }

    pub inline fn multiQueue(t: *const Tun) bool {
        return t.flags & if_tun.IFF_MULTI_QUEUE != 0;
    }

    pub fn nameSlice(t: *const Tun) []const u8 {
        return std.mem.sliceTo(&t.name, 0);
    }

    pub fn close(t: *Tun) void {
        var i: u16 = 0;
        while (i < t.queue_count) : (i += 1) {
            sys.close(t.fds[i]);
            t.fds[i] = -1;
        }
        t.queue_count = 0;
    }
};

pub const QueueOptions = struct {
    fd: sys.fd_t,
    caps: device.Capabilities,
    rx_parallel: u32 = 16,
    tx_slots: u32 = 512,
    coalesce: bool = true,
    owns_fd: bool = false,
    ring: bool = true,
};

const rx_burst = 64;

pub fn Queue(comptime W: type) type {
    return struct {
        const Self = @This();
        const Loop = W.Loop;
        const Slots = device.SlotPool(Loop);
        const Slot = device.TxSlot(Loop);
        const has_rings = @hasDecl(Loop, "BufferRing");
        const ring_group: u16 = 0;

        pub const RxSlot = struct {
            c: Loop.Completion = .{},
            buf: ?*pool.Buffer = null,
            queue: *Self = undefined,
        };

        worker: *W,
        fd: sys.fd_t,
        caps: device.Capabilities,
        vnet_len: u32,
        has_vnet: bool,
        rx: []RxSlot,
        rx_starved: u32 = 0,
        tx: Slots,
        coal: gso.Coalescer(64) = .{},
        coalesce_enabled: bool,
        completion: bool,
        running: bool = false,
        owns_fd: bool,
        ring: if (has_rings) ?Loop.BufferRing else void = if (has_rings) null else {},
        ring_c: Loop.Completion = .{},
        ring_bufs: []?*pool.Buffer = &.{},
        free_bids: []u16 = &.{},
        free_bid_count: usize = 0,
        ring_starved: bool = false,
        ring_disabled: bool = false,

        pub fn init(q: *Self, allocator: std.mem.Allocator, w: *W, options: QueueOptions) !void {
            const completion = w.loop.completionBased();
            const rx = try allocator.alloc(RxSlot, @max(1, if (completion) options.rx_parallel else 1));
            errdefer allocator.free(rx);
            for (rx) |*s| s.* = .{ .queue = q };
            const entries: usize = if (has_rings and completion and options.ring) std.math.ceilPowerOfTwo(usize, std.math.clamp(@as(usize, options.rx_parallel) * 2, 16, 1024)) catch 16 else 0;
            const ring_bufs = try allocator.alloc(?*pool.Buffer, entries);
            errdefer allocator.free(ring_bufs);
            @memset(ring_bufs, null);
            const free_bids = try allocator.alloc(u16, entries);
            errdefer allocator.free(free_bids);
            for (free_bids, 0..) |*bid, i| bid.* = @intCast(free_bids.len - 1 - i);
            q.* = .{
                .worker = w,
                .fd = options.fd,
                .caps = options.caps,
                .vnet_len = if (options.caps.vnet_hdr) gso.VirtioNetHdr.size else if (options.caps.af_prefix) 4 else 0,
                .has_vnet = options.caps.vnet_hdr,
                .rx = rx,
                .tx = try Slots.init(allocator, options.tx_slots),
                .coalesce_enabled = options.coalesce and options.caps.gsoWrite(),
                .completion = completion,
                .owns_fd = options.owns_fd,
                .ring_bufs = ring_bufs,
                .free_bids = free_bids,
                .free_bid_count = entries,
            };
            q.coal.max_packet = pool.max_super_packet;
            q.coal.enable_udp = options.caps.uso;
        }

        pub fn deinit(q: *Self, allocator: std.mem.Allocator) void {
            for (q.rx) |*s| {
                if (s.buf) |b| q.worker.pool.put(b);
                s.buf = null;
            }
            for (q.ring_bufs) |*slot| {
                if (slot.*) |b| q.worker.pool.put(b);
                slot.* = null;
            }
            allocator.free(q.ring_bufs);
            allocator.free(q.free_bids);
            allocator.free(q.rx);
            q.tx.deinit(allocator);
            if (q.owns_fd) sys.close(q.fd);
        }

        pub fn start(q: *Self) !void {
            q.running = true;
            try q.worker.loop.register(q.fd);
            if (has_rings and q.startRing()) return;
            for (q.rx) |*s| {
                if (!q.arm(s)) q.rx_starved += 1;
            }
        }

        pub fn stop(q: *Self) void {
            q.running = false;
            for (q.rx) |*s| {
                if (s.c.isActive()) q.worker.loop.cancel(&s.c);
            }
            if (q.ring_c.isActive()) q.worker.loop.cancel(&q.ring_c);
            q.flush();
        }

        pub fn idle(q: *const Self) bool {
            for (q.rx) |*s| {
                if (s.c.isActive()) return false;
            }
            if (q.ring_c.isActive()) return false;
            return q.tx.in_flight == 0;
        }

        pub fn finish(q: *Self) void {
            if (has_rings and !q.ring_c.isActive()) {
                if (q.ring) |*br| q.worker.loop.freeBufferRing(br);
                q.ring = null;
            }
        }

        fn startRing(q: *Self) bool {
            if (q.ring_bufs.len == 0 or q.ring_disabled) return false;
            q.ring = q.worker.loop.setupBufferRing(@intCast(q.ring_bufs.len), ring_group) catch return false;
            q.provideRing();
            q.submitRing();
            return true;
        }

        fn provideRing(q: *Self) void {
            const br = if (q.ring) |*r| r else return;
            while (q.free_bid_count > 0) {
                const b = q.worker.pool.getReserved() orelse break;
                q.free_bid_count -= 1;
                const bid = q.free_bids[q.free_bid_count];
                q.ring_bufs[bid] = b;
                br.add(b.ptr[b.headroom() - q.vnet_len .. b.cap], bid);
            }
            br.commit();
        }

        fn submitRing(q: *Self) void {
            q.ring_c = .{
                .op = .{ .read = .{ .fd = q.fd, .buf = &.{}, .group = ring_group, .multishot = true } },
                .userdata = q,
                .callback = onRingRead,
            };
            q.worker.loop.submit(&q.ring_c);
        }

        fn abandonRing(q: *Self) void {
            for (q.ring_bufs, 0..) |*slot, i| {
                if (slot.*) |b| {
                    q.worker.pool.put(b);
                    slot.* = null;
                    q.free_bids[q.free_bid_count] = @intCast(i);
                    q.free_bid_count += 1;
                }
            }
            if (q.ring) |*br| q.worker.loop.freeBufferRing(br);
            q.ring = null;
            q.ring_disabled = true;
            for (q.rx) |*s| {
                if (!s.c.isActive() and !q.arm(s)) q.rx_starved += 1;
            }
        }

        fn onRingRead(ud: ?*anyopaque, loop: *Loop, c: *Loop.Completion, result: i32) io.Disposition {
            _ = loop;
            const q: *Self = @ptrCast(@alignCast(ud.?));
            const w = q.worker;
            if (c.bufferId()) |bid| {
                if (q.ring_bufs[bid]) |b| {
                    q.ring_bufs[bid] = null;
                    q.free_bids[q.free_bid_count] = bid;
                    q.free_bid_count += 1;
                    if (result > 0 and q.running) {
                        q.deliver(b, @intCast(result));
                    } else {
                        w.pool.put(b);
                    }
                    if (q.running) q.provideRing();
                }
            }
            if (c.more() or !q.running) return .disarm;
            if (result >= 0) return .rearm;
            switch (sys.toErrno(result)) {
                .canceled, .badf => return .disarm,
                .nobufs => {
                    q.provideRing();
                    if (q.free_bid_count == q.ring_bufs.len) {
                        q.ring_starved = true;
                        w.counters.inc(.pool_exhausted);
                        return .disarm;
                    }
                    return .rearm;
                },
                .inval, .opnotsupp => {
                    q.abandonRing();
                    return .disarm;
                },
                .again, .intr => return .rearm,
                else => {
                    w.counters.inc(.rx_dropped);
                    return .rearm;
                },
            }
        }

        fn deliver(q: *Self, b: *pool.Buffer, n: u32) void {
            const w = q.worker;
            if (n <= q.vnet_len) {
                w.counters.inc(.rx_dropped);
                w.pool.put(b);
                return;
            }
            var vh: gso.VirtioNetHdr = .{};
            if (q.has_vnet) {
                vh = gso.VirtioNetHdr.read(b.ptr[b.headroom() - q.vnet_len ..][0..gso.VirtioNetHdr.size]);
            }
            b.len = n - q.vnet_len;
            w.counters.inc(.rx_packets);
            w.counters.add(.rx_bytes, b.len);
            if (vh.isGso()) w.counters.inc(.gso_rx_packets);
            W.onDevicePacket(w, b, vh);
        }

        fn drainReadable(q: *Self) void {
            const w = q.worker;
            var budget: u32 = rx_burst;
            while (budget > 0 and q.running) : (budget -= 1) {
                const nb = w.pool.getReserved() orelse return;
                const r = sys.read(q.fd, nb.ptr[nb.headroom() - q.vnet_len .. nb.cap]);
                if (r <= 0) {
                    w.pool.put(nb);
                    if (r < 0 and sys.toErrno(r) == .intr) continue;
                    return;
                }
                q.deliver(nb, @intCast(r));
            }
        }

        fn arm(q: *Self, s: *RxSlot) bool {
            const b = s.buf orelse (q.worker.pool.getReserved() orelse return false);
            s.buf = b;
            const start_off = b.headroom() - q.vnet_len;
            s.c = .{
                .op = .{ .read = .{ .fd = q.fd, .buf = b.ptr[start_off..b.cap] } },
                .userdata = s,
                .callback = onRead,
            };
            q.worker.loop.submit(&s.c);
            return true;
        }

        pub fn starved(q: *const Self) bool {
            return q.ring_starved or q.rx_starved != 0;
        }

        pub fn refill(q: *Self) void {
            if (has_rings and q.ring_starved and !q.ring_disabled and q.running and !q.ring_c.isActive()) {
                q.provideRing();
                if (q.free_bid_count < q.ring_bufs.len) {
                    q.ring_starved = false;
                    q.submitRing();
                }
                return;
            }
            if (q.rx_starved == 0 or !q.running) return;
            for (q.rx) |*s| {
                if (s.c.isActive()) continue;
                if (!q.arm(s)) return;
                q.rx_starved -= 1;
                if (q.rx_starved == 0) return;
            }
        }

        fn onRead(ud: ?*anyopaque, loop: *Loop, c: *Loop.Completion, result: i32) io.Disposition {
            _ = loop;
            const s: *RxSlot = @ptrCast(@alignCast(ud.?));
            const q = s.queue;
            const w = q.worker;
            if (result <= 0) {
                const e = sys.toErrno(result);
                if (!q.running or e == .canceled or e == .badf) {
                    if (s.buf) |b| w.pool.put(b);
                    s.buf = null;
                    return .disarm;
                }
                if (result < 0 and e != .again and e != .intr) w.counters.inc(.rx_dropped);
                return .rearm;
            }
            const n: u32 = @intCast(result);
            const b = s.buf.?;
            if (n <= q.vnet_len) {
                w.counters.inc(.rx_dropped);
                return .rearm;
            }
            var vh: gso.VirtioNetHdr = .{};
            if (q.has_vnet) {
                vh = gso.VirtioNetHdr.read(b.ptr[b.headroom() - q.vnet_len ..][0..gso.VirtioNetHdr.size]);
            }
            b.len = n - q.vnet_len;
            s.buf = null;
            w.counters.inc(.rx_packets);
            w.counters.add(.rx_bytes, b.len);
            if (vh.isGso()) w.counters.inc(.gso_rx_packets);
            W.onDevicePacket(w, b, vh);
            if (!q.completion) q.drainReadable();
            const nb = w.pool.getReserved() orelse {
                q.rx_starved += 1;
                w.counters.inc(.pool_exhausted);
                return .disarm;
            };
            s.buf = nb;
            c.op.read.buf = nb.ptr[nb.headroom() - q.vnet_len .. nb.cap];
            return .rearm;
        }

        fn finishSlot(q: *Self, slot: *Slot, result: i32) void {
            const w = q.worker;
            if (result < 0) {
                w.counters.inc(.tx_dropped);
            } else {
                w.counters.inc(.tx_packets);
                w.counters.add(.tx_bytes, slot.total -| q.vnet_len);
            }
            var i: u8 = 0;
            while (i < slot.nrefs) : (i += 1) w.pool.put(slot.refs[i]);
            q.tx.put(slot);
        }

        const SlotCtx = struct {
            fn callback(ud: ?*anyopaque, loop: *Loop, c: *Loop.Completion, result: i32) io.Disposition {
                _ = loop;
                const slot: *Slot = @alignCast(@fieldParentPtr("c", c));
                const q: *Self = @ptrCast(@alignCast(ud.?));
                q.finishSlot(slot, result);
                return .disarm;
            }
        };

        fn dispatchSlot(q: *Self, slot: *Slot) void {
            if (q.completion) {
                slot.c = .{
                    .op = .{ .writev = .{ .fd = q.fd, .iov = slot.iov[0..slot.niov] } },
                    .userdata = q,
                    .callback = SlotCtx.callback,
                };
                q.worker.loop.submit(&slot.c);
            } else {
                const r = sys.writev(q.fd, slot.iov[0..slot.niov]);
                q.finishSlot(slot, r);
            }
        }

        fn writeAfPrefix(dst: *[4]u8, first_byte: u8) void {
            const family: u32 = if (first_byte >> 4 == 6) sys.AF_INET6 else sys.AF_INET;
            std.mem.writeInt(u32, dst, family, .big);
        }

        pub fn send(q: *Self, b: *pool.Buffer, vh: gso.VirtioNetHdr) void {
            const w = q.worker;
            if (q.vnet_len != 0) {
                if (b.headroom() < q.vnet_len or b.len == 0) {
                    w.counters.inc(.tx_dropped);
                    w.pool.put(b);
                    return;
                }
                if (q.has_vnet) {
                    vh.write(b.prepend(q.vnet_len)[0..gso.VirtioNetHdr.size]);
                } else {
                    var vh_full = vh;
                    if (vh_full.isGso() or vh_full.needsCsum()) {
                        if (vh_full.isGso()) {
                            q.sendSegmented(b, vh_full);
                            return;
                        }
                        gso.completeChecksum(b.bytes(), vh_full) catch {};
                        vh_full = .{};
                    }
                    const first = b.bytes()[0];
                    writeAfPrefix(b.prepend(4)[0..4], first);
                }
            } else if (vh.isGso()) {
                q.sendSegmented(b, vh);
                return;
            } else if (vh.needsCsum()) {
                gso.completeChecksum(b.bytes(), vh) catch {};
            }
            if (vh.isGso()) w.counters.inc(.gso_tx_packets);
            const slot = q.tx.get() orelse {
                const r = sys.write(q.fd, b.bytes());
                if (r < 0) w.counters.inc(.tx_dropped) else {
                    w.counters.inc(.tx_packets);
                    w.counters.add(.tx_bytes, b.len - q.vnet_len);
                }
                w.pool.put(b);
                return;
            };
            const bytes = b.bytes();
            slot.iov[0] = .{ .base = bytes.ptr, .len = bytes.len };
            slot.niov = 1;
            slot.refs[0] = b;
            slot.nrefs = 1;
            slot.total = @intCast(bytes.len);
            q.dispatchSlot(slot);
        }

        pub fn sendParts(q: *Self, header: []const u8, vh: gso.VirtioNetHdr, parts: []const device.PayloadRef) void {
            const w = q.worker;
            std.debug.assert(header.len + q.vnet_len <= device.header_capacity);
            std.debug.assert(parts.len < device.max_iov);
            if (vh.isGso()) w.counters.inc(.gso_tx_packets);
            const slot = q.tx.get() orelse {
                var hdr_buf: [device.header_capacity]u8 = undefined;
                var iov: [device.max_iov]sys.iovec_const = undefined;
                const hl = q.fillHeader(&hdr_buf, header, vh);
                iov[0] = .{ .base = &hdr_buf, .len = hl };
                var total: usize = hl;
                for (parts, 1..) |p, i| {
                    iov[i] = .{ .base = p.buf.ptr + p.off, .len = p.len };
                    total += p.len;
                }
                const r = sys.writev(q.fd, iov[0 .. parts.len + 1]);
                if (r < 0) w.counters.inc(.tx_dropped) else {
                    w.counters.inc(.tx_packets);
                    w.counters.add(.tx_bytes, total - q.vnet_len);
                }
                return;
            };
            const hl = q.fillHeader(&slot.hdr, header, vh);
            slot.iov[0] = .{ .base = &slot.hdr, .len = hl };
            slot.total = @intCast(hl);
            for (parts, 1..) |p, i| {
                slot.iov[i] = .{ .base = p.buf.ptr + p.off, .len = p.len };
                slot.total += p.len;
                p.buf.ref();
                slot.refs[i - 1] = p.buf;
            }
            slot.niov = @intCast(parts.len + 1);
            slot.nrefs = @intCast(parts.len);
            q.dispatchSlot(slot);
        }

        inline fn fillHeader(q: *Self, dst: *[device.header_capacity]u8, header: []const u8, vh: gso.VirtioNetHdr) usize {
            var off: usize = 0;
            if (q.has_vnet) {
                vh.write(dst[0..gso.VirtioNetHdr.size]);
                off = q.vnet_len;
            } else if (q.vnet_len != 0) {
                writeAfPrefix(dst[0..4], header[0]);
                off = 4;
            }
            @memcpy(dst[off..][0..header.len], header);
            return off + header.len;
        }

        fn sendSegmented(q: *Self, b: *pool.Buffer, vh: gso.VirtioNetHdr) void {
            const w = q.worker;
            defer w.pool.put(b);
            var seg = gso.Segmenter.init(b.bytes(), vh, true) catch {
                w.counters.inc(.tx_dropped);
                return;
            };
            while (true) {
                const nb = w.pool.get() orelse {
                    w.counters.inc(.tx_dropped);
                    return;
                };
                const out = seg.next(nb.tail()) catch {
                    w.pool.put(nb);
                    w.counters.inc(.tx_dropped);
                    return;
                } orelse {
                    w.pool.put(nb);
                    return;
                };
                nb.len = @intCast(out.len);
                w.counters.inc(.gso_segments);
                q.send(nb, .{});
            }
        }

        pub fn sendCoalesced(q: *Self, b: *pool.Buffer) void {
            if (!q.coalesce_enabled) return q.send(b, .{});
            const w = q.worker;
            while (true) {
                switch (q.coal.add(&w.pool, b)) {
                    .merged => {
                        w.counters.inc(.gro_merged);
                        return;
                    },
                    .inserted => return,
                    .full => q.flush(),
                    .rejected => {
                        q.flush();
                        return q.send(b, .{});
                    },
                }
            }
        }

        pub fn flush(q: *Self) void {
            if (q.coal.count == 0) return;
            for (q.coal.items[0..q.coal.count]) |*it| {
                const vh = gso.Coalescer(64).finalize(it);
                q.send(it.buf, vh);
            }
            q.coal.reset();
        }
    };
}

test "tun open inside namespace when permitted" {
    if (!sys.is_linux) return error.SkipZigTest;
    var t = Tun.open(.{ .name = "zeptest%d", .queues = 2 }) catch |err| switch (err) {
        error.PermissionDenied, error.DeviceNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer t.close();
    try std.testing.expect(t.queue_count >= 1);
    try std.testing.expect(std.mem.startsWith(u8, t.nameSlice(), "zeptest"));
}
