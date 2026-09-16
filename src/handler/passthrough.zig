const std = @import("std");
const external = @import("../device/external.zig");
const gso = @import("../packet/gso.zig");
const pool = @import("../packet/pool.zig");

pub const max_batch = 128;

pub fn Passthrough(comptime W: type) type {
    return struct {
        const Self = @This();

        shared: *external.Shared,
        accept_gso: bool,
        batch: [max_batch]*pool.Buffer = undefined,
        desc: [max_batch]external.Packet = undefined,
        count: usize = 0,

        pub fn init(shared: *external.Shared, accept_gso: bool) Self {
            return .{ .shared = shared, .accept_gso = accept_gso };
        }

        fn push(p: *Self, w: *W, b: *pool.Buffer) void {
            if (p.count == max_batch) p.flush(w);
            p.batch[p.count] = b;
            p.count += 1;
        }

        pub fn onPacket(p: *Self, w: *W, b: *pool.Buffer, vh: gso.VirtioNetHdr) void {
            if (vh.isGso() and !p.accept_gso) {
                defer w.pool.put(b);
                var seg = gso.Segmenter.init(b.bytes(), vh, true) catch {
                    w.counters.inc(.rx_dropped);
                    return;
                };
                while (true) {
                    const nb = w.pool.get() orelse {
                        w.counters.inc(.pool_exhausted);
                        return;
                    };
                    const out = seg.next(nb.tail()) catch {
                        w.pool.put(nb);
                        return;
                    } orelse {
                        w.pool.put(nb);
                        return;
                    };
                    nb.len = @intCast(out.len);
                    w.counters.inc(.gso_segments);
                    p.push(w, nb);
                }
            }
            if (vh.needsCsum() and !p.accept_gso) gso.completeChecksum(b.bytes(), vh) catch {};
            p.push(w, b);
        }

        pub fn flush(p: *Self, w: *W) void {
            if (p.count == 0) return;
            for (p.batch[0..p.count], 0..) |b, i| p.desc[i] = .{ .data = b.bytes().ptr, .len = b.len };
            if (p.shared.output) |f| f(p.shared.output_ctx, &p.desc, p.count);
            for (p.batch[0..p.count]) |b| w.pool.put(b);
            p.count = 0;
        }

        pub fn poll(p: *Self, w: *W) void {
            var n: usize = 0;
            while (n < 1024) : (n += 1) {
                const b = p.shared.inbound.pop() orelse break;
                W.injectToDevice(w, b);
            }
        }
    };
}
