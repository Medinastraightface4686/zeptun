const std = @import("std");
const parse = @import("../packet/parse.zig");

pub const Index = u32;
pub const none: Index = std.math.maxInt(u32);

pub const FlowKeyContext = struct {
    pub inline fn hash(k: *const parse.FlowKey) u64 {
        return k.hash();
    }
    pub inline fn eql(a: *const parse.FlowKey, b: *const parse.FlowKey) bool {
        return parse.FlowKey.eql(a, b);
    }
};

pub fn IntContext(comptime K: type) type {
    return struct {
        pub inline fn hash(k: *const K) u64 {
            const x: u64 = @intCast(k.*);
            return parse.mix5(x, 0x9e37_79b9_7f4a_7c15, x >> 32, 0xbf58_476d_1ce4_e5b9, 0x94d0_49bb_1331_11eb);
        }
        pub inline fn eql(a: *const K, b: *const K) bool {
            return a.* == b.*;
        }
    };
}

const paged_threshold: usize = 64 << 10;

pub fn Table(comptime K: type, comptime V: type, comptime Ctx: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: K,
            value: V,
            tag: u32,
            prev: Index,
            next: Index,
            live: bool,
        };

        const Slot = packed struct(u64) {
            index: u32,
            tag: u32,
        };

        const empty_slot: Slot = .{ .index = 0, .tag = 0 };

        slots: []Slot,
        entries: []Entry,
        paged: bool,
        mask: u32,
        len: u32,
        free_head: Index,
        fresh: u32,
        lru_head: Index,
        lru_tail: Index,
        seq: std.atomic.Value(u32) = .init(0),

        pub fn init(allocator: std.mem.Allocator, max_entries: u32) !Self {
            std.debug.assert(max_entries > 0);
            const slot_count = std.math.ceilPowerOfTwo(u32, @max(8, max_entries * 2)) catch return error.OutOfMemory;
            const paged = @as(usize, slot_count) * @sizeOf(Slot) >= paged_threshold;
            const slots = if (paged) try zeroedPages(slot_count) else try allocator.alloc(Slot, slot_count);
            errdefer if (paged) freePages(slots) else allocator.free(slots);
            if (!paged) @memset(slots, empty_slot);
            const entries = try allocator.alloc(Entry, max_entries);
            return .{
                .slots = slots,
                .entries = entries,
                .paged = paged,
                .mask = slot_count - 1,
                .len = 0,
                .free_head = none,
                .fresh = 0,
                .lru_head = none,
                .lru_tail = none,
            };
        }

        fn zeroedPages(count: u32) error{OutOfMemory}![]Slot {
            const len = @as(usize, count) * @sizeOf(Slot);
            const raw = std.heap.page_allocator.rawAlloc(len, .of(Slot), @returnAddress()) orelse return error.OutOfMemory;
            const ptr: [*]Slot = @ptrCast(@alignCast(raw));
            return ptr[0..count];
        }

        fn freePages(slots: []Slot) void {
            std.heap.page_allocator.rawFree(std.mem.sliceAsBytes(slots), .of(Slot), @returnAddress());
        }

        pub fn deinit(t: *Self, allocator: std.mem.Allocator) void {
            if (t.paged) freePages(t.slots) else allocator.free(t.slots);
            allocator.free(t.entries);
            t.* = undefined;
        }

        pub inline fn capacity(t: *const Self) u32 {
            return @intCast(t.entries.len);
        }

        pub inline fn isFull(t: *const Self) bool {
            return t.len == t.entries.len;
        }

        inline fn tagOf(key: *const K) u32 {
            const h = Ctx.hash(key);
            return @as(u32, @truncate(h ^ (h >> 32))) | 1;
        }

        pub fn find(t: *const Self, key: *const K) ?Index {
            const tag = tagOf(key);
            var pos = tag & t.mask;
            while (true) : (pos = (pos + 1) & t.mask) {
                const s = t.slots[pos];
                if (s.tag == 0) return null;
                if (s.tag == tag and Ctx.eql(&t.entries[s.index].key, key)) return s.index;
            }
        }

        pub fn containsShared(t: *const Self, key: *const K) bool {
            const tag = tagOf(key);
            var spins: u32 = 0;
            while (spins < 1 << 14) : (spins += 1) {
                const before = t.seq.load(.acquire);
                if (before & 1 != 0) {
                    if (spins & 63 == 63) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
                    continue;
                }
                var found = false;
                var pos = tag & t.mask;
                var probes: u32 = 0;
                while (probes <= t.mask) : ({
                    probes += 1;
                    pos = (pos + 1) & t.mask;
                }) {
                    const s = t.slots[pos];
                    if (s.tag == 0) break;
                    if (s.tag == tag and s.index < t.entries.len and Ctx.eql(&t.entries[s.index].key, key)) {
                        found = true;
                        break;
                    }
                }
                if (t.seq.load(.acquire) == before) return found;
            }
            return false;
        }

        inline fn beginWrite(t: *Self) void {
            t.seq.store(t.seq.raw +% 1, .release);
        }

        inline fn endWrite(t: *Self) void {
            t.seq.store(t.seq.raw +% 1, .release);
        }

        pub fn get(t: *Self, key: *const K) ?*V {
            const i = t.find(key) orelse return null;
            return &t.entries[i].value;
        }

        pub inline fn entry(t: *Self, index: Index) *Entry {
            return &t.entries[index];
        }

        pub inline fn value(t: *Self, index: Index) *V {
            return &t.entries[index].value;
        }

        pub fn indexOfValue(t: *const Self, v: *const V) Index {
            const e: *const Entry = @alignCast(@fieldParentPtr("value", v));
            return @intCast((@intFromPtr(e) - @intFromPtr(t.entries.ptr)) / @sizeOf(Entry));
        }

        fn allocEntry(t: *Self) ?Index {
            if (t.free_head != none) {
                const i = t.free_head;
                t.free_head = t.entries[i].next;
                return i;
            }
            if (t.fresh < t.entries.len) {
                const i = t.fresh;
                t.fresh += 1;
                return i;
            }
            return null;
        }

        pub const InsertError = error{ Full, Exists };

        pub fn insert(t: *Self, key: K, v: V) InsertError!Index {
            const tag = tagOf(&key);
            var pos = tag & t.mask;
            while (true) : (pos = (pos + 1) & t.mask) {
                const s = t.slots[pos];
                if (s.tag == 0) break;
                if (s.tag == tag and Ctx.eql(&t.entries[s.index].key, &key)) return error.Exists;
            }
            const i = t.allocEntry() orelse return error.Full;
            t.beginWrite();
            t.entries[i] = .{ .key = key, .value = v, .tag = tag, .prev = none, .next = none, .live = true };
            t.slots[pos] = .{ .index = i, .tag = tag };
            t.endWrite();
            t.len += 1;
            t.linkFront(i);
            return i;
        }

        pub fn insertUndefined(t: *Self, key: K) InsertError!Index {
            return t.insert(key, undefined);
        }

        pub fn remove(t: *Self, index: Index) void {
            const e = &t.entries[index];
            std.debug.assert(e.live);
            var pos = e.tag & t.mask;
            while (t.slots[pos].index != index or t.slots[pos].tag == 0) : (pos = (pos + 1) & t.mask) {}
            t.beginWrite();
            defer t.endWrite();
            var hole = pos;
            var j = (pos + 1) & t.mask;
            while (t.slots[j].tag != 0) : (j = (j + 1) & t.mask) {
                const ideal = t.slots[j].tag & t.mask;
                const dist_j = (j -% ideal) & t.mask;
                const dist_hole = (j -% hole) & t.mask;
                if (dist_j >= dist_hole) {
                    t.slots[hole] = t.slots[j];
                    hole = j;
                }
            }
            t.slots[hole] = empty_slot;
            t.unlink(index);
            e.live = false;
            e.next = t.free_head;
            t.free_head = index;
            t.len -= 1;
        }

        pub fn removeKey(t: *Self, key: *const K) bool {
            const i = t.find(key) orelse return false;
            t.remove(i);
            return true;
        }

        fn linkFront(t: *Self, i: Index) void {
            const e = &t.entries[i];
            e.prev = none;
            e.next = t.lru_head;
            if (t.lru_head != none) t.entries[t.lru_head].prev = i else t.lru_tail = i;
            t.lru_head = i;
        }

        fn unlink(t: *Self, i: Index) void {
            const e = &t.entries[i];
            if (e.prev != none) t.entries[e.prev].next = e.next else t.lru_head = e.next;
            if (e.next != none) t.entries[e.next].prev = e.prev else t.lru_tail = e.prev;
            e.prev = none;
            e.next = none;
        }

        pub fn touch(t: *Self, i: Index) void {
            if (t.lru_head == i) return;
            t.unlink(i);
            t.linkFront(i);
        }

        pub inline fn oldest(t: *const Self) ?Index {
            return if (t.lru_tail == none) null else t.lru_tail;
        }

        pub inline fn newer(t: *const Self, i: Index) ?Index {
            const p = t.entries[i].prev;
            return if (p == none) null else p;
        }

        pub const Iterator = struct {
            table: *Self,
            pos: u32 = 0,

            pub fn next(it: *Iterator) ?Index {
                while (it.pos < it.table.fresh) {
                    const i = it.pos;
                    it.pos += 1;
                    if (it.table.entries[i].live) return i;
                }
                return null;
            }
        };

        pub fn iterator(t: *Self) Iterator {
            return .{ .table = t };
        }
    };
}

pub fn FlowTable(comptime V: type) type {
    return Table(parse.FlowKey, V, FlowKeyContext);
}

test "insert find remove with backward shift" {
    const T = Table(u32, u32, IntContext(u32));
    var t = try T.init(std.testing.allocator, 1000);
    defer t.deinit(std.testing.allocator);
    var prng = std.Random.DefaultPrng.init(1);
    const r = prng.random();
    var keys: [1000]u32 = undefined;
    for (&keys, 0..) |*k, i| {
        k.* = r.int(u32) | 1;
        for (keys[0..i]) |prev| {
            if (prev == k.*) k.* +%= 2;
        }
        _ = try t.insert(k.*, @intCast(i));
    }
    try std.testing.expectError(error.Full, t.insert(0, 0));
    try std.testing.expectError(error.Exists, t.insert(keys[5], 0));
    for (keys, 0..) |k, i| try std.testing.expectEqual(@as(u32, @intCast(i)), t.get(&k).?.*);
    for (keys, 0..) |k, i| {
        if (i % 3 == 0) try std.testing.expect(t.removeKey(&k));
    }
    for (keys, 0..) |k, i| {
        if (i % 3 == 0) {
            try std.testing.expect(t.find(&k) == null);
        } else {
            try std.testing.expectEqual(@as(u32, @intCast(i)), t.get(&k).?.*);
        }
    }
    for (keys, 0..) |k, i| {
        if (i % 3 == 0) _ = try t.insert(k, 7);
    }
    try std.testing.expectEqual(@as(u32, 1000), t.len);
}

test "large tables start with empty paged slots" {
    const T = Table(u32, u32, IntContext(u32));
    var t = try T.init(std.testing.allocator, 1 << 14);
    defer t.deinit(std.testing.allocator);
    try std.testing.expect(t.paged);
    for (t.slots) |sl| try std.testing.expectEqual(@as(u32, 0), sl.tag);
    const k: u32 = 77;
    try std.testing.expect(t.find(&k) == null);
    _ = try t.insert(k, 5);
    try std.testing.expectEqual(@as(u32, 5), t.get(&k).?.*);
}

test "shared lookups stay exact while the owner mutates" {
    const T = Table(u32, u32, IntContext(u32));
    var t = try T.init(std.heap.page_allocator, 1 << 12);
    defer t.deinit(std.heap.page_allocator);
    var k: u32 = 0;
    while (k < 512) : (k += 1) _ = try t.insert(k * 2, k);
    const Ctx = struct {
        fn writer(tab: *T, stop: *std.atomic.Value(bool)) void {
            var prng = std.Random.DefaultPrng.init(3);
            while (!stop.load(.acquire)) {
                const key = (prng.random().int(u32) % 3000) * 2 + 1;
                if (tab.find(&key)) |i| tab.remove(i) else _ = tab.insert(key, 1) catch {};
                var pause: u32 = 0;
                while (pause < 64) : (pause += 1) std.atomic.spinLoopHint();
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    const th = try std.Thread.spawn(.{}, Ctx.writer, .{ &t, &stop });
    var rounds: u32 = 0;
    var misses: u32 = 0;
    while (rounds < 200) : (rounds += 1) {
        var i: u32 = 0;
        while (i < 512) : (i += 1) {
            const key = i * 2;
            if (!t.containsShared(&key)) misses += 1;
            const absent = i * 2 + 100_001;
            try std.testing.expect(!t.containsShared(&absent));
        }
    }
    stop.store(true, .release);
    th.join();
    try std.testing.expectEqual(@as(u32, 0), misses);
}

test "lru order" {
    const T = Table(u32, u8, IntContext(u32));
    var t = try T.init(std.testing.allocator, 4);
    defer t.deinit(std.testing.allocator);
    const a = try t.insert(1, 1);
    const b = try t.insert(2, 2);
    const c = try t.insert(3, 3);
    try std.testing.expectEqual(a, t.oldest().?);
    t.touch(a);
    try std.testing.expectEqual(b, t.oldest().?);
    t.remove(b);
    try std.testing.expectEqual(c, t.oldest().?);
    try std.testing.expectEqual(t.indexOfValue(t.value(c)), c);
    var it = t.iterator();
    var n: u32 = 0;
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(u32, 2), n);
}

test "flow table with flow keys" {
    var t = try FlowTable(u64).init(std.testing.allocator, 64);
    defer t.deinit(std.testing.allocator);
    var k: parse.FlowKey = .{ .proto = 6, .src_port = 1, .dst_port = 2 };
    k.src[0] = 10;
    const i = try t.insert(k, 99);
    try std.testing.expectEqual(i, t.find(&k).?);
    const rk = k.reversed();
    try std.testing.expect(t.find(&rk) == null);
}

fn fuzzTable(_: void, smith: *std.testing.Smith) anyerror!void {
    const T = Table(u16, u16, IntContext(u16));
    var t = try T.init(std.testing.allocator, 64);
    defer t.deinit(std.testing.allocator);
    var present: [65536]bool = @splat(false);
    var count: u32 = 0;
    var steps: u32 = 0;
    while (!smith.eos() and steps < 2000) : (steps += 1) {
        const key = smith.valueRangeAtMost(u16, 0, 200);
        if (smith.value(bool)) {
            if (t.insert(key, key)) |_| {
                try std.testing.expect(!present[key]);
                present[key] = true;
                count += 1;
            } else |err| switch (err) {
                error.Exists => try std.testing.expect(present[key]),
                error.Full => try std.testing.expectEqual(@as(u32, 64), count),
            }
        } else {
            const removed = t.removeKey(&key);
            try std.testing.expectEqual(present[key], removed);
            if (removed) {
                present[key] = false;
                count -= 1;
            }
        }
        try std.testing.expectEqual(count, t.len);
    }
    for (0..201) |k| {
        const kk: u16 = @intCast(k);
        try std.testing.expectEqual(present[k], t.find(&kk) != null);
    }
}

test "fuzz table" {
    try std.testing.fuzz({}, fuzzTable, .{});
}
