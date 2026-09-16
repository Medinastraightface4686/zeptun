const std = @import("std");

const cache_line = std.atomic.cache_line;

pub fn Spsc(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: []T,
        mask: usize,
        head: std.atomic.Value(usize) align(cache_line) = .init(0),
        tail: std.atomic.Value(usize) align(cache_line) = .init(0),

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const cap = try std.math.ceilPowerOfTwo(usize, @max(capacity, 2));
            return .{ .buffer = try allocator.alloc(T, cap), .mask = cap - 1 };
        }

        pub fn deinit(q: *Self, allocator: std.mem.Allocator) void {
            allocator.free(q.buffer);
        }

        pub fn push(q: *Self, value: T) bool {
            const t = q.tail.load(.unordered);
            const h = q.head.load(.acquire);
            if (t -% h == q.buffer.len) return false;
            q.buffer[t & q.mask] = value;
            q.tail.store(t +% 1, .release);
            return true;
        }

        pub fn pop(q: *Self) ?T {
            const h = q.head.load(.unordered);
            const t = q.tail.load(.acquire);
            if (h == t) return null;
            const v = q.buffer[h & q.mask];
            q.head.store(h +% 1, .release);
            return v;
        }

        pub fn len(q: *const Self) usize {
            return q.tail.load(.acquire) -% q.head.load(.acquire);
        }
    };
}

pub fn Mpsc(comptime T: type) type {
    return struct {
        const Self = @This();

        const Cell = struct {
            sequence: std.atomic.Value(usize),
            value: T,
        };

        cells: []Cell,
        mask: usize,
        enqueue_pos: std.atomic.Value(usize) align(cache_line) = .init(0),
        dequeue_pos: std.atomic.Value(usize) align(cache_line) = .init(0),

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const cap = try std.math.ceilPowerOfTwo(usize, @max(capacity, 2));
            const cells = try allocator.alloc(Cell, cap);
            for (cells, 0..) |*c, i| c.sequence = .init(i);
            return .{ .cells = cells, .mask = cap - 1 };
        }

        pub fn deinit(q: *Self, allocator: std.mem.Allocator) void {
            allocator.free(q.cells);
        }

        pub fn push(q: *Self, value: T) bool {
            var pos = q.enqueue_pos.load(.acquire);
            while (true) {
                const cell = &q.cells[pos & q.mask];
                const seq = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq)) -% @as(isize, @bitCast(pos));
                if (diff == 0) {
                    if (q.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .acquire, .acquire)) |actual| {
                        pos = actual;
                        continue;
                    }
                    cell.value = value;
                    cell.sequence.store(pos +% 1, .release);
                    return true;
                } else if (diff < 0) {
                    return false;
                } else {
                    pos = q.enqueue_pos.load(.acquire);
                }
            }
        }

        pub fn pop(q: *Self) ?T {
            const pos = q.dequeue_pos.load(.unordered);
            const cell = &q.cells[pos & q.mask];
            const seq = cell.sequence.load(.acquire);
            const diff = @as(isize, @bitCast(seq)) -% @as(isize, @bitCast(pos +% 1));
            if (diff != 0) return null;
            q.dequeue_pos.store(pos +% 1, .release);
            const v = cell.value;
            cell.sequence.store(pos +% q.mask +% 1, .release);
            return v;
        }
    };
}

pub fn Intrusive(comptime T: type) type {
    return struct {
        const Self = @This();

        head: std.atomic.Value(?*T) align(cache_line) = .init(null),

        pub fn push(q: *Self, node: *T) void {
            var head = q.head.load(.acquire);
            while (true) {
                node.next = head;
                head = q.head.cmpxchgWeak(head, node, .acquire, .acquire) orelse return;
            }
        }

        pub fn takeAll(q: *Self) ?*T {
            var list = q.head.swap(null, .acquire);
            var fifo: ?*T = null;
            while (list) |n| {
                list = n.next;
                n.next = fifo;
                fifo = n;
            }
            return fifo;
        }

        pub inline fn isEmpty(q: *const Self) bool {
            return q.head.load(.acquire) == null;
        }
    };
}

pub const SpinLock = struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(l: *SpinLock) void {
        while (true) {
            if (l.state.cmpxchgWeak(0, 1, .acquire, .acquire) == null) return;
            var spins: u32 = 0;
            while (l.state.load(.acquire) != 0) {
                std.atomic.spinLoopHint();
                spins += 1;
                if (spins > 64) {
                    std.Thread.yield() catch {};
                    spins = 0;
                }
            }
        }
    }

    pub fn unlock(l: *SpinLock) void {
        l.state.store(0, .release);
    }
};

test "spsc wraps" {
    var q = try Spsc(u32).init(std.testing.allocator, 4);
    defer q.deinit(std.testing.allocator);
    for (0..3) |round| {
        for (0..4) |i| try std.testing.expect(q.push(@intCast(i + round)));
        try std.testing.expect(!q.push(99));
        for (0..4) |i| try std.testing.expectEqual(@as(u32, @intCast(i + round)), q.pop().?);
        try std.testing.expect(q.pop() == null);
    }
}

test "mpsc many producers" {
    var q = try Mpsc(u64).init(std.testing.allocator, 1 << 12);
    defer q.deinit(std.testing.allocator);
    const per = 1000;
    const Prod = struct {
        fn run(queue: *Mpsc(u64), base: u64) void {
            var i: u64 = 0;
            while (i < per) {
                if (queue.push(base + i)) i += 1 else std.Thread.yield() catch {};
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Prod.run, .{ &q, @as(u64, i) * 1_000_000 });
    var seen: usize = 0;
    var sum: u64 = 0;
    while (seen < 4 * per) {
        if (q.pop()) |v| {
            seen += 1;
            sum += v;
        } else std.Thread.yield() catch {};
    }
    for (threads) |t| t.join();
    var expect: u64 = 0;
    for (0..4) |i| expect += @as(u64, i) * 1_000_000 * per + (per * (per - 1)) / 2;
    try std.testing.expectEqual(expect, sum);
}

test "intrusive queue keeps producer order" {
    const Node = struct { next: ?*@This() = null, producer: u32 = 0, seq: u32 = 0 };
    var q: Intrusive(Node) = .{};
    const per = 2000;
    var nodes: [4][per]Node = undefined;
    const Prod = struct {
        fn run(queue: *Intrusive(Node), list: *[per]Node, id: u32) void {
            for (list, 0..) |*n, i| {
                n.* = .{ .producer = id, .seq = @intCast(i) };
                queue.push(n);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Prod.run, .{ &q, &nodes[i], @as(u32, @intCast(i)) });
    var next_seq: [4]u32 = @splat(0);
    var seen: usize = 0;
    while (seen < 4 * per) {
        var list = q.takeAll();
        if (list == null) std.Thread.yield() catch {};
        while (list) |n| {
            list = n.next;
            try std.testing.expectEqual(next_seq[n.producer], n.seq);
            next_seq[n.producer] += 1;
            seen += 1;
        }
    }
    for (threads) |t| t.join();
    try std.testing.expect(q.isEmpty());
}
