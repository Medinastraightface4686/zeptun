const std = @import("std");
const device = @import("device.zig");
const sys = @import("../io/sys.zig");
const gso = @import("../packet/gso.zig");
const pool = @import("../packet/pool.zig");
const log = @import("../log.zig");
const iphlp = @import("../route/windows.zig");

const win = sys.windows;
const kernel32 = win.kernel32;

pub const supported = sys.is_windows;

pub const OpenOptions = struct {
    name: []const u8,
    mtu: u32,
};

pub const ring_capacity: u32 = 0x80_0000;
pub const max_packet: usize = 0xffff;
pub const max_name = 128;
pub const max_poll = 1024;

const library_name = std.unicode.utf8ToUtf16LeStringLiteral("wintun.dll");
const tunnel_type = std.unicode.utf8ToUtf16LeStringLiteral("Zeptun");

const AdapterHandle = *opaque {};
const SessionHandle = *opaque {};

pub const Api = struct {
    library: win.HMODULE,
    create_adapter: *const fn (name: [*:0]const u16, tunnel_type: [*:0]const u16, requested_guid: ?*const win.GUID) callconv(.winapi) ?AdapterHandle,
    open_adapter: *const fn (name: [*:0]const u16) callconv(.winapi) ?AdapterHandle,
    close_adapter: *const fn (adapter: ?AdapterHandle) callconv(.winapi) void,
    get_adapter_luid: *const fn (adapter: AdapterHandle, luid: *iphlp.NET_LUID) callconv(.winapi) void,
    get_running_driver_version: *const fn () callconv(.winapi) u32,
    start_session: *const fn (adapter: AdapterHandle, capacity: u32) callconv(.winapi) ?SessionHandle,
    end_session: *const fn (session: SessionHandle) callconv(.winapi) void,
    get_read_wait_event: *const fn (session: SessionHandle) callconv(.winapi) ?win.HANDLE,
    receive_packet: *const fn (session: SessionHandle, size: *u32) callconv(.winapi) ?[*]u8,
    release_receive_packet: *const fn (session: SessionHandle, packet: [*]const u8) callconv(.winapi) void,
    allocate_send_packet: *const fn (session: SessionHandle, size: u32) callconv(.winapi) ?[*]u8,
    send_packet: *const fn (session: SessionHandle, packet: [*]const u8) callconv(.winapi) void,

    const exports = [_]struct { field: []const u8, symbol: [:0]const u8 }{
        .{ .field = "create_adapter", .symbol = "WintunCreateAdapter" },
        .{ .field = "open_adapter", .symbol = "WintunOpenAdapter" },
        .{ .field = "close_adapter", .symbol = "WintunCloseAdapter" },
        .{ .field = "get_adapter_luid", .symbol = "WintunGetAdapterLUID" },
        .{ .field = "get_running_driver_version", .symbol = "WintunGetRunningDriverVersion" },
        .{ .field = "start_session", .symbol = "WintunStartSession" },
        .{ .field = "end_session", .symbol = "WintunEndSession" },
        .{ .field = "get_read_wait_event", .symbol = "WintunGetReadWaitEvent" },
        .{ .field = "receive_packet", .symbol = "WintunReceivePacket" },
        .{ .field = "release_receive_packet", .symbol = "WintunReleaseReceivePacket" },
        .{ .field = "allocate_send_packet", .symbol = "WintunAllocateSendPacket" },
        .{ .field = "send_packet", .symbol = "WintunSendPacket" },
    };

    pub fn load() !Api {
        const library = kernel32.LoadLibraryExW(library_name, null, win.LOAD_LIBRARY_SEARCH_APPLICATION_DIR | win.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
            log.err("wintun: cannot load wintun.dll (error {d})", .{win.lastError()});
            return error.DeviceNotFound;
        };
        errdefer _ = kernel32.FreeLibrary(library);
        var api: Api = undefined;
        api.library = library;
        inline for (exports) |e| {
            const proc = kernel32.GetProcAddress(library, e.symbol) orelse {
                log.err("wintun: wintun.dll does not export {s}", .{e.symbol});
                return error.NotSupported;
            };
            @field(api, e.field) = @ptrCast(@alignCast(proc));
        }
        return api;
    }

    pub fn unload(api: *const Api) void {
        _ = kernel32.FreeLibrary(api.library);
    }
};

fn deviceError(code: u32) anyerror {
    return switch (code) {
        win.ERROR_ACCESS_DENIED => error.PermissionDenied,
        win.ERROR_FILE_NOT_FOUND, win.ERROR_MOD_NOT_FOUND, win.ERROR_NOT_FOUND => error.DeviceNotFound,
        win.ERROR_ALREADY_EXISTS => error.DeviceBusy,
        win.ERROR_NOT_ENOUGH_MEMORY, win.ERROR_OUTOFMEMORY => error.SystemResources,
        win.ERROR_INVALID_PARAMETER => error.InvalidArgument,
        else => error.DeviceError,
    };
}

pub const Adapter = struct {
    caps: device.Capabilities = .{},
    index: u32 = 0,
    luid: iphlp.NET_LUID = .{ .Value = 0 },
    name: [16]u8 = @splat(0),
    api: Api,
    handle: AdapterHandle,
    session: SessionHandle,
    read_event: win.HANDLE,

    pub fn open(options: OpenOptions) !*Adapter {
        if (!supported) return error.NotSupported;
        if (options.name.len == 0 or options.name.len >= max_name) return error.InvalidArgument;
        var wide: [max_name:0]u16 = @splat(0);
        const wide_len = std.unicode.utf8ToUtf16Le(&wide, options.name) catch return error.InvalidArgument;
        wide[wide_len] = 0;
        const api = try Api.load();
        errdefer api.unload();
        const handle = api.open_adapter(&wide) orelse api.create_adapter(&wide, tunnel_type, null) orelse {
            const code = win.lastError();
            log.err("wintun: cannot open or create adapter {s} (error {d})", .{ options.name, code });
            return deviceError(code);
        };
        errdefer api.close_adapter(handle);
        var luid: iphlp.NET_LUID = .{ .Value = 0 };
        api.get_adapter_luid(handle, &luid);
        const index = try iphlp.luidToIndex(luid);
        const session = api.start_session(handle, ring_capacity) orelse {
            const code = win.lastError();
            log.err("wintun: cannot start session on {s} (error {d})", .{ options.name, code });
            return deviceError(code);
        };
        errdefer api.end_session(session);
        const read_event = api.get_read_wait_event(session) orelse return error.DeviceError;
        const a = try std.heap.page_allocator.create(Adapter);
        a.* = .{
            .caps = .{ .mtu = options.mtu, .queues = 1 },
            .index = index,
            .luid = luid,
            .api = api,
            .handle = handle,
            .session = session,
            .read_event = read_event,
        };
        var n: usize = 0;
        for (options.name) |ch| {
            if (n == a.name.len - 1) break;
            if (ch >= 0x80) continue;
            a.name[n] = ch;
            n += 1;
        }
        const version = api.get_running_driver_version();
        log.info("wintun: adapter {s} index {d} driver {d}.{d}", .{ options.name, index, version >> 16, version & 0xffff });
        return a;
    }

    pub fn close(a: *Adapter) void {
        a.api.end_session(a.session);
        a.api.close_adapter(a.handle);
        a.api.unload();
        std.heap.page_allocator.destroy(a);
    }

    pub fn shortName(a: *const Adapter) [16]u8 {
        return a.name;
    }
};

pub fn Queue(comptime W: type) type {
    return struct {
        const Self = @This();

        worker: *W,
        adapter: *Adapter,
        stop_event: ?win.HANDLE = null,
        thread: ?std.Thread = null,
        running: bool = false,
        failed: bool = false,

        pub fn init(q: *Self, w: *W, adapter: *Adapter) !void {
            q.* = .{ .worker = w, .adapter = adapter };
        }

        pub fn deinit(q: *Self) void {
            q.stop();
        }

        pub fn start(q: *Self) !void {
            if (q.thread != null) return;
            const stop_event = kernel32.CreateEventW(null, 1, 0, null) orelse return error.SystemResources;
            errdefer _ = kernel32.CloseHandle(stop_event);
            q.thread = try std.Thread.spawn(.{ .stack_size = 64 << 10 }, waitLoop, .{ &q.worker.loop, q.adapter.read_event, stop_event });
            q.stop_event = stop_event;
            q.running = true;
            q.failed = false;
            q.worker.loop.wakeup();
        }

        pub fn stop(q: *Self) void {
            q.running = false;
            if (q.thread) |t| {
                if (q.stop_event) |ev| _ = kernel32.SetEvent(ev);
                t.join();
                q.thread = null;
            }
            if (q.stop_event) |ev| _ = kernel32.CloseHandle(ev);
            q.stop_event = null;
        }

        pub fn idle(q: *const Self) bool {
            return q.thread == null;
        }

        fn waitLoop(loop: *W.Loop, read_event: win.HANDLE, stop_event: win.HANDLE) void {
            const handles = [2]win.HANDLE{ stop_event, read_event };
            while (kernel32.WaitForMultipleObjects(handles.len, &handles, 0, win.INFINITE) == win.WAIT_OBJECT_0 + 1) {
                loop.wakeup();
            }
        }

        pub fn poll(q: *Self) usize {
            if (!q.running or q.failed) return 0;
            const w = q.worker;
            const a = q.adapter;
            var n: usize = 0;
            while (n < max_poll) : (n += 1) {
                var size: u32 = 0;
                const data = a.api.receive_packet(a.session, &size) orelse {
                    const code = win.lastError();
                    if (code != win.ERROR_NO_MORE_ITEMS) q.fail(code);
                    return n;
                };
                const b = q.copyIn(data[0..size]);
                a.api.release_receive_packet(a.session, data);
                if (b) |buf| W.onDevicePacket(w, buf, .{});
            }
            w.loop.wakeup();
            return n;
        }

        fn copyIn(q: *Self, packet: []const u8) ?*pool.Buffer {
            const w = q.worker;
            const b = w.pool.get() orelse {
                w.counters.inc(.pool_exhausted);
                w.counters.inc(.rx_dropped);
                return null;
            };
            if (packet.len == 0 or packet.len > b.tailroom()) {
                w.pool.put(b);
                w.counters.inc(.rx_dropped);
                return null;
            }
            @memcpy(b.tail()[0..packet.len], packet);
            b.len = @intCast(packet.len);
            w.counters.inc(.rx_packets);
            w.counters.add(.rx_bytes, b.len);
            return b;
        }

        fn fail(q: *Self, code: u32) void {
            if (q.failed) return;
            q.failed = true;
            log.err("wintun: receive failed on {s} (error {d}), stopping", .{ std.mem.sliceTo(&q.adapter.name, 0), code });
            q.worker.engine.requestStop();
        }

        pub fn refill(q: *Self) void {
            _ = q;
        }

        fn allocate(q: *Self, len: usize) ?[*]u8 {
            const w = q.worker;
            if (len == 0 or len > max_packet) {
                w.counters.inc(.tx_dropped);
                return null;
            }
            const a = q.adapter;
            return a.api.allocate_send_packet(a.session, @intCast(len)) orelse {
                w.counters.inc(.tx_dropped);
                return null;
            };
        }

        fn commit(q: *Self, packet: [*]u8, len: usize) void {
            const a = q.adapter;
            a.api.send_packet(a.session, packet);
            q.worker.counters.inc(.tx_packets);
            q.worker.counters.add(.tx_bytes, len);
        }

        pub fn send(q: *Self, b: *pool.Buffer, vh: gso.VirtioNetHdr) void {
            const w = q.worker;
            defer w.pool.put(b);
            const bytes = b.bytes();
            if (vh.isGso()) return q.sendSegments(bytes, vh);
            if (vh.needsCsum()) gso.completeChecksum(bytes, vh) catch {};
            const dst = q.allocate(bytes.len) orelse return;
            @memcpy(dst[0..bytes.len], bytes);
            q.commit(dst, bytes.len);
        }

        fn sendSegments(q: *Self, packet: []const u8, vh: gso.VirtioNetHdr) void {
            const w = q.worker;
            var seg = gso.Segmenter.init(packet, vh, true) catch {
                w.counters.inc(.tx_dropped);
                return;
            };
            while (true) {
                const payload = seg.payloadLen();
                if (seg.offset >= payload and !(payload == 0 and seg.index == 0)) return;
                const len: usize = seg.hdr_len + @min(seg.mss, payload - seg.offset);
                const dst = q.allocate(len) orelse return;
                const out = seg.next(dst[0..len]) catch null;
                if (out == null) {
                    @memset(dst[0..len], 0);
                    q.adapter.api.send_packet(q.adapter.session, dst);
                    w.counters.inc(.tx_dropped);
                    return;
                }
                q.commit(dst, len);
                w.counters.inc(.gso_segments);
            }
        }

        pub fn sendParts(q: *Self, header: []const u8, vh: gso.VirtioNetHdr, parts: []const device.PayloadRef) void {
            const w = q.worker;
            var total: usize = header.len;
            for (parts) |p| total += p.len;
            if (vh.isGso()) {
                const b = w.pool.get() orelse {
                    w.counters.inc(.tx_dropped);
                    return;
                };
                if (b.tailroom() < total) {
                    w.pool.put(b);
                    w.counters.inc(.tx_dropped);
                    return;
                }
                copyParts(b.tail()[0..total], header, parts);
                b.len = @intCast(total);
                return q.send(b, vh);
            }
            const dst = q.allocate(total) orelse return;
            copyParts(dst[0..total], header, parts);
            if (vh.needsCsum()) gso.completeChecksum(dst[0..total], vh) catch {};
            q.commit(dst, total);
        }

        fn copyParts(dst: []u8, header: []const u8, parts: []const device.PayloadRef) void {
            @memcpy(dst[0..header.len], header);
            var off = header.len;
            for (parts) |p| {
                @memcpy(dst[off..][0..p.len], p.buf.ptr[p.off..][0..p.len]);
                off += p.len;
            }
        }

        pub fn sendCoalesced(q: *Self, b: *pool.Buffer) void {
            q.send(b, .{});
        }

        pub fn flush(q: *Self) void {
            _ = q;
        }
    };
}
