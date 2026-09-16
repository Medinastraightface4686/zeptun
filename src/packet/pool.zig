const std = @import("std");

pub const Buffer = struct {
    ptr: [*]u8,
    cap: u32,
    off: u32,
    len: u32,
    refs: u16,
    flags: u16,
    index: u32,
    next: ?*Buffer,
    pool: *Pool,
    meta: u64,

    pub inline fn bytes(b: *const Buffer) []u8 {
        return b.ptr[b.off..][0..b.len];
    }

    pub inline fn storage(b: *const Buffer) []u8 {
        return b.ptr[0..b.cap];
    }

    pub inline fn headroom(b: *const Buffer) u32 {
        return b.off;
    }

    pub inline fn tailroom(b: *const Buffer) u32 {
        return b.cap - b.off - b.len;
    }

    pub inline fn tail(b: *const Buffer) []u8 {
        return b.ptr[b.off + b.len .. b.cap];
    }

    pub inline fn prepend(b: *Buffer, n: u32) []u8 {
        std.debug.assert(n <= b.off);
        b.off -= n;
        b.len += n;
        return b.ptr[b.off..][0..n];
    }

    pub inline fn trimFront(b: *Buffer, n: u32) void {
        std.debug.assert(n <= b.len);
        b.off += n;
        b.len -= n;
    }

    pub inline fn reset(b: *Buffer, head: u32) void {
        b.off = head;
        b.len = 0;
    }

    pub inline fn setRange(b: *Buffer, off: u32, len: u32) void {
        std.debug.assert(off + len <= b.cap);
        b.off = off;
        b.len = len;
    }

    pub inline fn ref(b: *Buffer) void {
        b.refs += 1;
    }
};

pub const Options = struct {
    count: u32,
    buffer_size: u32,
    headroom: u32 = default_headroom,
};

pub const default_headroom: u32 = 128;
pub const max_super_packet: u32 = 65535;
pub const flag_control: u16 = 0x8000;
pub const hop_mask: u16 = 0x000f;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    memory: []align(std.heap.page_size_min) u8,
    buffers: []Buffer,
    free: ?*Buffer,
    initialized: u32,
    in_use: u32,
    peak: u32,
    exhausted: u64,
    buffer_size: u32,
    headroom: u32,
    remote: std.atomic.Value(?*Buffer),

    pub fn init(allocator: std.mem.Allocator, options: Options) !Pool {
        std.debug.assert(options.buffer_size > options.headroom);
        const total = @as(usize, options.count) * options.buffer_size;
        const memory = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), total);
        errdefer allocator.free(memory);
        const buffers = try allocator.alloc(Buffer, options.count);
        return .{
            .allocator = allocator,
            .memory = memory,
            .buffers = buffers,
            .free = null,
            .initialized = 0,
            .in_use = 0,
            .peak = 0,
            .exhausted = 0,
            .buffer_size = options.buffer_size,
            .headroom = options.headroom,
            .remote = .init(null),
        };
    }

    pub fn deinit(p: *Pool) void {
        p.allocator.free(p.buffers);
        p.allocator.free(p.memory);
        p.* = undefined;
    }

    pub inline fn capacity(p: *const Pool) u32 {
        return @intCast(p.buffers.len);
    }

    pub inline fn available(p: *const Pool) u32 {
        return p.capacity() - p.in_use;
    }

    pub fn get(p: *Pool) ?*Buffer {
        const b = p.free orelse blk: {
            if (p.initialized < p.buffers.len) {
                const i = p.initialized;
                p.initialized += 1;
                const nb = &p.buffers[i];
                nb.* = .{
                    .ptr = p.memory.ptr + @as(usize, i) * p.buffer_size,
                    .cap = p.buffer_size,
                    .off = p.headroom,
                    .len = 0,
                    .refs = 0,
                    .flags = 0,
                    .index = i,
                    .next = null,
                    .pool = p,
                    .meta = 0,
                };
                break :blk nb;
            }
            if (p.drainRemote() == 0) {
                p.exhausted += 1;
                return null;
            }
            break :blk p.free.?;
        };
        if (b == p.free) p.free = b.next;
        b.next = null;
        b.refs = 1;
        b.flags = 0;
        b.meta = 0;
        b.off = p.headroom;
        b.len = 0;
        p.in_use += 1;
        if (p.in_use > p.peak) p.peak = p.in_use;
        return b;
    }

    inline fn freeLocal(p: *Pool, b: *Buffer) void {
        b.refs = 0;
        b.next = p.free;
        p.free = b;
        p.in_use -= 1;
    }

    pub fn put(p: *Pool, b: *Buffer) void {
        std.debug.assert(b.refs > 0);
        b.refs -= 1;
        if (b.refs != 0) return;
        if (b.pool == p) {
            p.freeLocal(b);
        } else {
            b.pool.putRemote(b);
        }
    }

    pub fn putRemote(p: *Pool, b: *Buffer) void {
        b.refs = 0;
        var head = p.remote.load(.acquire);
        while (true) {
            b.next = head;
            head = p.remote.cmpxchgWeak(head, b, .acquire, .acquire) orelse return;
        }
    }

    pub fn drainRemote(p: *Pool) u32 {
        var list = p.remote.swap(null, .acquire);
        var n: u32 = 0;
        while (list) |b| {
            list = b.next;
            b.next = p.free;
            p.free = b;
            n += 1;
        }
        p.in_use -= n;
        return n;
    }

    pub inline fn owns(p: *const Pool, b: *const Buffer) bool {
        return b.pool == p;
    }

    pub fn residentBytes(p: *const Pool) usize {
        return @as(usize, p.initialized) * p.buffer_size;
    }
};

pub const Queue = struct {
    head: ?*Buffer = null,
    tail: ?*Buffer = null,
    count: u32 = 0,

    pub fn push(q: *Queue, b: *Buffer) void {
        b.next = null;
        if (q.tail) |t| t.next = b else q.head = b;
        q.tail = b;
        q.count += 1;
    }

    pub fn pushFront(q: *Queue, b: *Buffer) void {
        b.next = q.head;
        q.head = b;
        if (q.tail == null) q.tail = b;
        q.count += 1;
    }

    pub fn pop(q: *Queue) ?*Buffer {
        const b = q.head orelse return null;
        q.head = b.next;
        if (q.head == null) q.tail = null;
        b.next = null;
        q.count -= 1;
        return b;
    }

    pub inline fn peek(q: *const Queue) ?*Buffer {
        return q.head;
    }

    pub inline fn isEmpty(q: *const Queue) bool {
        return q.head == null;
    }

    pub fn releaseAll(q: *Queue, p: *Pool) void {
        while (q.pop()) |b| p.put(b);
    }
};

test "pool get put and lazy init" {
    var p = try Pool.init(std.testing.allocator, .{ .count = 4, .buffer_size = 256 });
    defer p.deinit();
    try std.testing.expectEqual(@as(u32, 0), p.initialized);
    const a = p.get().?;
    const b = p.get().?;
    try std.testing.expectEqual(@as(u32, 2), p.initialized);
    try std.testing.expectEqual(@as(u32, 128), a.headroom());
    try std.testing.expectEqual(@as(u32, 128), a.tailroom());
    a.len = 10;
    _ = a.prepend(20);
    try std.testing.expectEqual(@as(u32, 30), a.len);
    a.ref();
    p.put(a);
    try std.testing.expectEqual(@as(u32, 2), p.in_use);
    p.put(a);
    p.put(b);
    try std.testing.expectEqual(@as(u32, 0), p.in_use);
    var got: [4]*Buffer = undefined;
    for (&got) |*g| g.* = p.get().?;
    try std.testing.expect(p.get() == null);
    try std.testing.expectEqual(@as(u64, 1), p.exhausted);
    for (got) |g| p.put(g);
    try std.testing.expectEqual(@as(u32, 4), p.initialized);
}

test "remote free across pools and threads" {
    var owner = try Pool.init(std.testing.allocator, .{ .count = 1024, .buffer_size = 256 });
    defer owner.deinit();
    var other = try Pool.init(std.testing.allocator, .{ .count = 1, .buffer_size = 256 });
    defer other.deinit();
    var taken: [1024]*Buffer = undefined;
    for (&taken) |*t| t.* = owner.get().?;
    const Worker = struct {
        fn run(list: []*Buffer, pool: *Pool) void {
            for (list) |bb| pool.put(bb);
        }
    };
    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ taken[0..512], &other });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ taken[512..], &other });
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(u32, 1024), owner.in_use);
    try std.testing.expectEqual(@as(u32, 1024), owner.drainRemote());
    try std.testing.expectEqual(@as(u32, 0), owner.in_use);
    try std.testing.expect(owner.get() != null);
}

test "queue fifo" {
    var p = try Pool.init(std.testing.allocator, .{ .count = 3, .buffer_size = 200, .headroom = 16 });
    defer p.deinit();
    var q: Queue = .{};
    const a = p.get().?;
    const b = p.get().?;
    q.push(a);
    q.push(b);
    try std.testing.expect(q.pop().? == a);
    q.pushFront(a);
    try std.testing.expectEqual(@as(u32, 2), q.count);
    q.releaseAll(&p);
    try std.testing.expectEqual(@as(u32, 0), p.in_use);
}
