const std = @import("std");

pub fn Slab(comptime T: type, comptime per_chunk: usize) type {
    comptime {
        std.debug.assert(@sizeOf(T) >= @sizeOf(usize));
        std.debug.assert(@alignOf(T) >= @alignOf(usize));
    }
    return struct {
        const Self = @This();

        const Node = struct { next: ?*Node };

        const Chunk = struct {
            next: ?*Chunk,
            items: [per_chunk]T,
        };

        free: ?*Node = null,
        chunks: ?*Chunk = null,
        fresh: usize = per_chunk,
        in_use: u32 = 0,

        pub fn take(s: *Self, allocator: std.mem.Allocator) ?*T {
            if (s.free) |node| {
                s.free = node.next;
                s.in_use += 1;
                return @ptrCast(@alignCast(node));
            }
            if (s.fresh == per_chunk) {
                const chunk = allocator.create(Chunk) catch return null;
                chunk.next = s.chunks;
                s.chunks = chunk;
                s.fresh = 0;
            }
            const item = &s.chunks.?.items[s.fresh];
            s.fresh += 1;
            s.in_use += 1;
            return item;
        }

        pub fn put(s: *Self, item: *T) void {
            const node: *Node = @ptrCast(@alignCast(item));
            node.next = s.free;
            s.free = node;
            s.in_use -= 1;
        }

        pub fn deinit(s: *Self, allocator: std.mem.Allocator) void {
            var it = s.chunks;
            while (it) |chunk| {
                it = chunk.next;
                allocator.destroy(chunk);
            }
            s.* = .{};
        }
    };
}

test "slab reuses freed items and grows by chunk" {
    const Item = struct { a: u64, b: [40]u8 };
    var s: Slab(Item, 4) = .{};
    defer s.deinit(std.testing.allocator);
    var items: [9]*Item = undefined;
    for (&items) |*p| p.* = s.take(std.testing.allocator).?;
    try std.testing.expectEqual(@as(u32, 9), s.in_use);
    s.put(items[3]);
    s.put(items[7]);
    try std.testing.expectEqual(items[7], s.take(std.testing.allocator).?);
    try std.testing.expectEqual(items[3], s.take(std.testing.allocator).?);
    try std.testing.expectEqual(@as(u32, 9), s.in_use);
    for (items) |p| s.put(p);
    try std.testing.expectEqual(@as(u32, 0), s.in_use);
}
