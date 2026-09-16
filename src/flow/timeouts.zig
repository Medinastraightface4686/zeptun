const std = @import("std");

pub const Kind = enum(u8) {
    none = 0,
    tcp_rto,
    tcp_persist,
    tcp_life,
    udp_idle,
    frag_expire,
    nat_expire,
    system_conn,
    dial_timeout,
    stats,
    tcp_delack,
    pool_expire,
    icmp_idle,
};

pub const Timer = struct {
    deadline: u64 = 0,
    prev: ?*Timer = null,
    next: ?*Timer = null,
    level: u8 = 0,
    active: bool = false,
    kind: u8 = 0,
    slot: u16 = 0,

    pub inline fn isActive(t: *const Timer) bool {
        return t.active;
    }
};

const slot_bits = 10;
const slots = 1 << slot_bits;
const slot_mask: u64 = slots - 1;
const words = slots / 64;

const List = struct {
    head: ?*Timer = null,

    fn push(l: *List, t: *Timer) void {
        t.prev = null;
        t.next = l.head;
        if (l.head) |h| h.prev = t;
        l.head = t;
    }

    fn remove(l: *List, t: *Timer) void {
        if (t.prev) |p| p.next = t.next else l.head = t.next;
        if (t.next) |n| n.prev = t.prev;
        t.prev = null;
        t.next = null;
    }
};

pub const Wheel = struct {
    lists: [2][slots]List = @splat(@splat(.{})),
    bitmap: [2][words]u64 = @splat(@splat(0)),
    overflow: List = .{},
    now: u64,
    count: usize = 0,

    pub fn init(now_ms: u64) Wheel {
        return .{ .now = now_ms };
    }

    pub fn schedule(w: *Wheel, t: *Timer, deadline_ms: u64) void {
        if (t.active) w.cancel(t);
        t.deadline = deadline_ms;
        w.place(t);
        t.active = true;
        w.count += 1;
    }

    fn place(w: *Wheel, t: *Timer) void {
        var d = t.deadline;
        if (d <= w.now) d = w.now + 1;
        const delta = d - w.now;
        if (delta < slots) {
            w.link(t, 0, @intCast(d & slot_mask));
        } else if ((d >> slot_bits) - (w.now >> slot_bits) < slots) {
            w.link(t, 1, @intCast((d >> slot_bits) & slot_mask));
        } else {
            t.level = 2;
            w.overflow.push(t);
        }
    }

    fn placeFrom(w: *Wheel, t: *Timer, base: u64) void {
        const d = @max(t.deadline, base);
        if (d - base < slots) {
            w.link(t, 0, @intCast(d & slot_mask));
        } else if ((d >> slot_bits) - (base >> slot_bits) < slots) {
            w.link(t, 1, @intCast((d >> slot_bits) & slot_mask));
        } else {
            t.level = 2;
            w.overflow.push(t);
        }
    }

    inline fn link(w: *Wheel, t: *Timer, level: u8, slot: u16) void {
        t.level = level;
        t.slot = slot;
        w.lists[level][slot].push(t);
        w.bitmap[level][slot >> 6] |= @as(u64, 1) << @intCast(slot & 63);
    }

    pub fn cancel(w: *Wheel, t: *Timer) void {
        if (!t.active) return;
        switch (t.level) {
            0, 1 => {
                const l = &w.lists[t.level][t.slot];
                l.remove(t);
                if (l.head == null) w.bitmap[t.level][t.slot >> 6] &= ~(@as(u64, 1) << @intCast(t.slot & 63));
            },
            else => w.overflow.remove(t),
        }
        t.active = false;
        w.count -= 1;
    }

    fn takeSlot(w: *Wheel, level: u8, slot: u16) ?*Timer {
        const head = w.lists[level][slot].head;
        w.lists[level][slot].head = null;
        w.bitmap[level][slot >> 6] &= ~(@as(u64, 1) << @intCast(slot & 63));
        return head;
    }

    fn cascade(w: *Wheel, base: u64) void {
        var node = w.takeSlot(1, @intCast((base >> slot_bits) & slot_mask));
        while (node) |t| {
            node = t.next;
            w.placeFrom(t, base);
        }
        if ((base >> slot_bits) & slot_mask == 0) {
            var o = w.overflow.head;
            w.overflow.head = null;
            while (o) |t| {
                o = t.next;
                t.prev = null;
                t.next = null;
                w.placeFrom(t, base);
            }
        }
    }

    fn nextSetInLevel0(w: *const Wheel, from: u64, limit: u64) ?u64 {
        var tick = from;
        while (tick <= limit) {
            const slot: u16 = @intCast(tick & slot_mask);
            const word_index = slot >> 6;
            const bit: u6 = @intCast(slot & 63);
            const word = w.bitmap[0][word_index] >> bit;
            if (word != 0) {
                const cand = tick + @ctz(word);
                return if (cand <= limit) cand else null;
            }
            tick += 64 - @as(u64, bit);
        }
        return null;
    }

    pub fn advance(w: *Wheel, now_ms: u64, ctx: anytype, comptime onExpire: fn (@TypeOf(ctx), *Timer) void) void {
        while (w.now < now_ms) {
            const t = w.now + 1;
            if (t & slot_mask == 0) {
                w.cascade(t);
            }
            const boundary = (t | slot_mask);
            const limit = @min(boundary, now_ms);
            const fire_tick = w.nextSetInLevel0(t, limit) orelse {
                w.now = limit;
                continue;
            };
            w.now = fire_tick;
            var node = w.takeSlot(0, @intCast(fire_tick & slot_mask));
            while (node) |timer| {
                node = timer.next;
                timer.prev = null;
                timer.next = null;
                timer.active = false;
                w.count -= 1;
                onExpire(ctx, timer);
            }
        }
    }

    pub fn nextExpiry(w: *const Wheel) ?u64 {
        if (w.count == 0) return null;
        const boundary = w.now | slot_mask;
        if (w.nextSetInLevel0(w.now + 1, boundary)) |tick| return tick;
        const cur = w.now >> slot_bits;
        var k: u64 = 1;
        while (k < slots) {
            const slot: u16 = @intCast((cur + k) & slot_mask);
            const bit: u6 = @intCast(slot & 63);
            const word = w.bitmap[1][slot >> 6] >> bit;
            if (word != 0) {
                k += @ctz(word);
                if (k < slots) return (cur + k) << slot_bits;
                break;
            }
            k += 64 - @as(u64, bit);
        }
        if (w.overflow.head != null) return ((w.now >> (2 * slot_bits)) + 1) << (2 * slot_bits);
        return boundary + 1;
    }

    pub fn timeoutMs(w: *const Wheel, max_ms: u64) u64 {
        const next = w.nextExpiry() orelse return max_ms;
        if (next <= w.now) return 0;
        return @min(next - w.now, max_ms);
    }
};

const Recorder = struct {
    fired: std.ArrayList(u64) = .empty,
    now: *const u64,

    fn onExpire(self: *Recorder, t: *Timer) void {
        self.fired.append(std.testing.allocator, t.deadline) catch unreachable;
        std.testing.expect(t.deadline <= self.now.*) catch unreachable;
    }
};

test "timers fire in order and never early" {
    var w = Wheel.init(1000);
    var timers: [300]Timer = @splat(.{});
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    for (&timers) |*t| {
        const delay = switch (r.uintLessThan(u8, 3)) {
            0 => r.uintLessThan(u64, 1000),
            1 => r.uintLessThan(u64, 1_000_000),
            else => r.uintLessThan(u64, 5_000_000),
        };
        w.schedule(t, 1000 + delay + 1);
    }
    for (timers[0..50]) |*t| w.cancel(t);
    try std.testing.expectEqual(@as(usize, 250), w.count);
    var now: u64 = 1000;
    var rec: Recorder = .{ .now = &now };
    defer rec.fired.deinit(std.testing.allocator);
    while (w.count > 0) {
        const next = w.nextExpiry().?;
        try std.testing.expect(next > w.now);
        now = next + r.uintLessThan(u64, 3);
        w.advance(now, &rec, Recorder.onExpire);
    }
    try std.testing.expectEqual(@as(usize, 250), rec.fired.items.len);
    for (timers[50..]) |t| try std.testing.expect(!t.active);
}

test "reschedule and cancel inside wheel" {
    var w = Wheel.init(0);
    var a: Timer = .{};
    var b: Timer = .{};
    w.schedule(&a, 10);
    w.schedule(&b, 5000);
    w.schedule(&a, 3000);
    try std.testing.expectEqual(@as(usize, 2), w.count);
    const Ctx = struct {
        n: u32 = 0,
        fn onExpire(self: *@This(), t: *Timer) void {
            _ = t;
            self.n += 1;
        }
    };
    var ctx: Ctx = .{};
    w.advance(2999, &ctx, Ctx.onExpire);
    try std.testing.expectEqual(@as(u32, 0), ctx.n);
    w.advance(3000, &ctx, Ctx.onExpire);
    try std.testing.expectEqual(@as(u32, 1), ctx.n);
    w.cancel(&b);
    w.advance(10000, &ctx, Ctx.onExpire);
    try std.testing.expectEqual(@as(u32, 1), ctx.n);
    try std.testing.expect(w.nextExpiry() == null);
}
