const std = @import("std");
const io = @import("io.zig");
const sys = @import("sys.zig");
const addr = @import("../addr.zig");
const win = @import("windows.zig");

const kernel32 = win.kernel32;
const ws2_32 = win.ws2_32;

const wake_key: usize = std.math.maxInt(usize);
const socket_key: usize = 0;
const max_bufs = 64;
const max_transfer: usize = std.math.maxInt(i32);
const accept_addr_len: u32 = 64;

const ConnectEx = *const fn (s: win.SOCKET, name: *const anyopaque, namelen: c_int, send_buf: ?*const anyopaque, send_len: u32, sent: ?*u32, overlapped: *win.OVERLAPPED) callconv(.winapi) win.BOOL;
const AcceptEx = *const fn (listener: win.SOCKET, accepted: win.SOCKET, output: *anyopaque, receive_len: u32, local_len: u32, remote_len: u32, received: ?*u32, overlapped: *win.OVERLAPPED) callconv(.winapi) win.BOOL;

const wsaid_connectex: win.GUID = .{ .Data1 = 0x25a2_07b9, .Data2 = 0xddf3, .Data3 = 0x4660, .Data4 = .{ 0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e } };
const wsaid_acceptex: win.GUID = .{ .Data1 = 0xb536_7df1, .Data2 = 0xcbac, .Data3 = 0x11cf, .Data4 = .{ 0x95, 0xca, 0x00, 0x80, 0x5f, 0x48, 0xa1, 0x92 } };

var zero_byte: [1]u8 = .{0};

pub const Loop = struct {
    pub const completion_based = true;
    pub const kind: io.BackendKind = .iocp;

    pub inline fn completionBased(_: *const Loop) bool {
        return completion_based;
    }

    pub const Callback = *const fn (userdata: ?*anyopaque, loop: *Loop, c: *Completion, result: i32) io.Disposition;

    pub const Completion = struct {
        op: io.Operation = .none,
        userdata: ?*anyopaque = null,
        callback: Callback = noopCallback,
        state: io.State = .idle,
        where: Where = .none,
        result: i32 = 0,
        flags: u32 = 0,
        namelen: c_int = 0,
        accepted: sys.fd_t = sys.invalid_fd,
        overlapped: win.OVERLAPPED = .{},
        wsabuf: win.WSABUF = .{},
        next: ?*Completion = null,

        pub inline fn isActive(c: *const Completion) bool {
            return c.state != .idle;
        }
    };

    const Where = enum(u8) { none, kernel, ready };

    const List = struct {
        head: ?*Completion = null,
        tail: ?*Completion = null,

        fn push(l: *List, c: *Completion) void {
            c.next = null;
            if (l.tail) |t| t.next = c else l.head = c;
            l.tail = c;
        }

        fn pop(l: *List) ?*Completion {
            const c = l.head orelse return null;
            l.head = c.next;
            if (l.head == null) l.tail = null;
            c.next = null;
            return c;
        }
    };

    allocator: std.mem.Allocator,
    port: win.HANDLE,
    entries: []win.OVERLAPPED_ENTRY,
    registered: std.AutoHashMapUnmanaged(sys.fd_t, void) = .empty,
    ready: List = .{},
    active: u32 = 0,
    now_ns: u64,
    wake_pending: std.atomic.Value(bool) = .init(false),
    connect_ex: [2]?ConnectEx = @splat(null),
    accept_ex: [2]?AcceptEx = @splat(null),
    accept_scratch: [2 * accept_addr_len]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, options: io.Options) !Loop {
        try win.startup();
        const port = kernel32.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, null, 0, 1) orelse return error.SystemResources;
        errdefer _ = kernel32.CloseHandle(port);
        const entries = try allocator.alloc(win.OVERLAPPED_ENTRY, @max(options.max_events, 16));
        return .{
            .allocator = allocator,
            .port = port,
            .entries = entries,
            .now_ns = sys.monotonicNs(),
        };
    }

    pub fn deinit(loop: *Loop) void {
        _ = kernel32.CloseHandle(loop.port);
        loop.registered.deinit(loop.allocator);
        loop.allocator.free(loop.entries);
        loop.* = undefined;
    }

    pub fn enable(loop: *Loop) !void {
        _ = loop;
    }

    pub inline fn now(loop: *const Loop) u64 {
        return loop.now_ns / std.time.ns_per_ms;
    }

    pub inline fn nowNs(loop: *const Loop) u64 {
        return loop.now_ns;
    }

    pub fn updateTime(loop: *Loop) void {
        loop.now_ns = sys.monotonicNs();
    }

    pub inline fn pending(loop: *const Loop) u32 {
        return loop.active;
    }

    pub fn wakeup(loop: *Loop) void {
        if (loop.wake_pending.swap(true, .acquire)) return;
        if (kernel32.PostQueuedCompletionStatus(loop.port, 0, wake_key, null) == 0) loop.wake_pending.store(false, .release);
    }

    pub fn register(loop: *Loop, fd: sys.fd_t) !void {
        if (fd == sys.invalid_fd) return error.InvalidArgument;
        if (loop.registered.contains(fd)) return;
        try loop.registered.ensureUnusedCapacity(loop.allocator, 1);
        const handle: win.HANDLE = @ptrFromInt(fd);
        if (kernel32.CreateIoCompletionPort(handle, loop.port, socket_key, 0) == null) {
            switch (win.lastError()) {
                win.ERROR_INVALID_PARAMETER => {},
                win.ERROR_INVALID_HANDLE => return error.InvalidArgument,
                else => return error.SystemResources,
            }
        } else {
            _ = kernel32.SetFileCompletionNotificationModes(handle, win.FILE_SKIP_SET_EVENT_ON_HANDLE);
        }
        loop.registered.putAssumeCapacity(fd, {});
    }

    pub fn unregister(loop: *Loop, fd: sys.fd_t) void {
        if (fd == sys.invalid_fd) return;
        if (loop.registered.remove(fd)) _ = kernel32.CancelIoEx(@ptrFromInt(fd), null);
    }

    pub fn submit(loop: *Loop, c: *Completion) void {
        std.debug.assert(c.state == .idle);
        c.state = .active;
        loop.active += 1;
        if (loop.start(c)) |result| {
            c.result = result;
            c.where = .ready;
            loop.ready.push(c);
        } else {
            c.where = .kernel;
        }
    }

    fn start(loop: *Loop, c: *Completion) ?i32 {
        switch (c.op) {
            .none => return 0,
            .close => |op| {
                loop.unregister(op.fd);
                sys.close(op.fd);
                return 0;
            },
            else => {},
        }
        const fd = c.op.fd();
        loop.register(fd) catch return sys.Errno.badf.result();
        c.overlapped = .{};
        return switch (c.op) {
            .none, .close => unreachable,
            .read => |op| startRecv(c, fd, op.buf, 0),
            .recv => |op| startRecv(c, fd, op.buf, op.flags),
            .write => |op| startSend(c, fd, op.buf, 0),
            .send => |op| startSend(c, fd, op.buf, op.flags),
            .writev => |op| startSendv(c, fd, op.iov, 0, null, 0),
            .sendmsg => |op| startSendv(c, fd, op.msg.iov[0..op.msg.iovlen], op.flags, op.msg.name, op.msg.namelen),
            .recvmsg => |op| startRecvFrom(c, fd, op.msg, op.flags),
            .accept => |op| loop.startAccept(c, fd, op.peer),
            .connect => |op| loop.startConnect(c, fd, op.addr),
            .poll => |op| startPoll(c, fd, op.events),
        };
    }

    fn startRecv(c: *Completion, fd: sys.fd_t, buf: []u8, flags: u32) ?i32 {
        c.wsabuf = .{ .len = @intCast(@min(buf.len, max_transfer)), .buf = buf.ptr };
        c.flags = flags;
        return pendingResult(ws2_32.WSARecv(fd, @ptrCast(&c.wsabuf), 1, null, &c.flags, &c.overlapped, null));
    }

    fn startSend(c: *Completion, fd: sys.fd_t, buf: []const u8, flags: u32) ?i32 {
        c.wsabuf = .{ .len = @intCast(@min(buf.len, max_transfer)), .buf = @constCast(buf.ptr) };
        return pendingResult(ws2_32.WSASend(fd, @ptrCast(&c.wsabuf), 1, null, flags, &c.overlapped, null));
    }

    fn startSendv(c: *Completion, fd: sys.fd_t, iov: []const sys.iovec_const, flags: u32, name: ?*const anyopaque, namelen: u32) ?i32 {
        var bufs: [max_bufs]win.WSABUF = undefined;
        var n: usize = 0;
        var total: usize = 0;
        for (iov) |v| {
            if (n == bufs.len or total == max_transfer) break;
            const len = @min(v.len, max_transfer - total);
            bufs[n] = .{ .len = @intCast(len), .buf = @constCast(v.base) };
            total += len;
            n += 1;
        }
        if (n == 0) {
            bufs[0] = .{ .len = 0, .buf = &zero_byte };
            n = 1;
        }
        const rc = if (name) |to|
            ws2_32.WSASendTo(fd, &bufs, @intCast(n), null, flags, to, @intCast(namelen), &c.overlapped, null)
        else
            ws2_32.WSASend(fd, &bufs, @intCast(n), null, flags, &c.overlapped, null);
        return pendingResult(rc);
    }

    fn startRecvFrom(c: *Completion, fd: sys.fd_t, msg: *io.MsgHdr, flags: u32) ?i32 {
        c.wsabuf = if (msg.iovlen > 0) .{ .len = @intCast(@min(msg.iov[0].len, max_transfer)), .buf = msg.iov[0].base } else .{ .len = 0, .buf = &zero_byte };
        c.flags = flags;
        c.namelen = @intCast(@min(msg.namelen, std.math.maxInt(c_int)));
        const from_len: ?*c_int = if (msg.name != null) &c.namelen else null;
        return pendingResult(ws2_32.WSARecvFrom(fd, @ptrCast(&c.wsabuf), 1, null, &c.flags, msg.name, from_len, &c.overlapped, null));
    }

    fn startConnect(loop: *Loop, c: *Completion, fd: sys.fd_t, sa: *const sys.Sockaddr) ?i32 {
        const v6 = sa.family() == sys.AF_INET6;
        const connect_ex = loop.connectEx(fd, v6) orelse return sys.Errno.opnotsupp.result();
        const any: addr.Endpoint = .{ .addr = if (v6) addr.Address.v6(@splat(0)) else addr.Address.v4(@splat(0)) };
        const local = sys.Sockaddr.fromEndpoint(any);
        if (ws2_32.bind(fd, local.ptr(), @intCast(local.len)) == win.SOCKET_ERROR) {
            const code = win.lastWsaError();
            if (code != win.WSAEINVAL) return win.mapWsaError(@bitCast(code)).result();
        }
        return pendingBool(connect_ex(fd, sa.ptr(), @intCast(sa.len), null, 0, null, &c.overlapped));
    }

    fn startAccept(loop: *Loop, c: *Completion, fd: sys.fd_t, peer: ?*sys.Sockaddr) ?i32 {
        var local: sys.Sockaddr = .{};
        const r = win.getsockname(fd, &local);
        if (r < 0) return r;
        const v6 = local.family() == sys.AF_INET6;
        const accept_ex = loop.acceptEx(fd, v6) orelse return sys.Errno.opnotsupp.result();
        const s = win.socket(if (v6) .v6 else .v4, .tcp) catch return sys.Errno.mfile.result();
        const output: *anyopaque = if (peer) |p| p.mutPtr() else @ptrCast(&loop.accept_scratch);
        c.accepted = s;
        const result = pendingBool(accept_ex(fd, s, output, 0, accept_addr_len, accept_addr_len, null, &c.overlapped));
        if (result != null) {
            sys.close(s);
            c.accepted = sys.invalid_fd;
        }
        return result;
    }

    fn startPoll(c: *Completion, fd: sys.fd_t, events: io.Events) ?i32 {
        if (events.out or !events.in) return eventsResult(.{ .out = events.out });
        const dgram = win.getsockoptInt(fd, win.SOL_SOCKET, win.SO_TYPE) == win.SOCK_DGRAM;
        c.wsabuf = .{ .len = 0, .buf = &zero_byte };
        c.flags = if (dgram) win.MSG_PEEK else 0;
        return pendingResult(ws2_32.WSARecv(fd, @ptrCast(&c.wsabuf), 1, null, &c.flags, &c.overlapped, null));
    }

    fn connectEx(loop: *Loop, fd: sys.fd_t, v6: bool) ?ConnectEx {
        const slot = &loop.connect_ex[@intFromBool(v6)];
        if (slot.* == null) {
            const f = extensionFunction(fd, &wsaid_connectex) orelse return null;
            slot.* = @ptrCast(@alignCast(f));
        }
        return slot.*;
    }

    fn acceptEx(loop: *Loop, fd: sys.fd_t, v6: bool) ?AcceptEx {
        const slot = &loop.accept_ex[@intFromBool(v6)];
        if (slot.* == null) {
            const f = extensionFunction(fd, &wsaid_acceptex) orelse return null;
            slot.* = @ptrCast(@alignCast(f));
        }
        return slot.*;
    }

    fn extensionFunction(fd: sys.fd_t, guid: *const win.GUID) ?*anyopaque {
        var f: ?*anyopaque = null;
        var returned: u32 = 0;
        if (ws2_32.WSAIoctl(fd, win.SIO_GET_EXTENSION_FUNCTION_POINTER, guid, @sizeOf(win.GUID), @ptrCast(&f), @sizeOf(usize), &returned, null, null) == win.SOCKET_ERROR) return null;
        return f;
    }

    fn pendingResult(rc: c_int) ?i32 {
        if (rc != win.SOCKET_ERROR) return null;
        const code = win.lastWsaError();
        if (code == win.WSA_IO_PENDING) return null;
        return win.mapWsaError(@bitCast(code)).result();
    }

    fn pendingBool(ok: win.BOOL) ?i32 {
        if (ok != 0) return null;
        const code = win.lastWsaError();
        if (code == win.WSA_IO_PENDING) return null;
        return win.mapWsaError(@bitCast(code)).result();
    }

    fn eventsResult(ev: io.Events) i32 {
        return @bitCast(@as(u32, @bitCast(ev)));
    }

    fn finish(c: *Completion, bytes: u32) i32 {
        const status: u32 = @truncate(c.overlapped.Internal);
        const ok = status & 0x8000_0000 == 0;
        const count: i32 = @intCast(@min(bytes, max_transfer));
        switch (c.op) {
            .connect => |op| {
                if (!ok) return win.mapNtStatus(status).result();
                _ = ws2_32.setsockopt(op.fd, win.SOL_SOCKET, win.SO_UPDATE_CONNECT_CONTEXT, null, 0);
                return 0;
            },
            .accept => |op| return finishAccept(c, op.fd, op.peer, ok, status),
            .recvmsg => |op| {
                if (!ok) return win.mapNtStatus(status).result();
                op.msg.namelen = @intCast(@max(c.namelen, 0));
                op.msg.controllen = 0;
                op.msg.flags = 0;
                return count;
            },
            .poll => |op| {
                if (ok or status == win.STATUS_BUFFER_OVERFLOW) return eventsResult(.{ .in = op.events.in });
                const e = win.mapNtStatus(status);
                if (e == .canceled) return e.result();
                return eventsResult(.{ .in = op.events.in, .err = true, .hup = e == .connreset or e == .connaborted });
            },
            else => return if (ok) count else win.mapNtStatus(status).result(),
        }
    }

    fn finishAccept(c: *Completion, listener: sys.fd_t, peer: ?*sys.Sockaddr, ok: bool, status: u32) i32 {
        const s = c.accepted;
        c.accepted = sys.invalid_fd;
        if (s == sys.invalid_fd) return sys.Errno.badf.result();
        if (!ok) {
            sys.close(s);
            return win.mapNtStatus(status).result();
        }
        const r = win.setsockopt(s, win.SOL_SOCKET, win.SO_UPDATE_ACCEPT_CONTEXT, std.mem.asBytes(&listener));
        if (r < 0 or s > std.math.maxInt(i32)) {
            sys.close(s);
            return if (r < 0) r else sys.Errno.mfile.result();
        }
        if (peer) |p| {
            if (win.getpeername(s, p) < 0) p.len = 0;
        }
        return @intCast(s);
    }

    pub fn cancel(loop: *Loop, c: *Completion) void {
        _ = loop;
        if (c.state != .active or c.where != .kernel) return;
        const fd = c.op.fd();
        if (fd == sys.invalid_fd) return;
        c.state = .canceling;
        _ = kernel32.CancelIoEx(@ptrFromInt(fd), &c.overlapped);
    }

    pub fn cancelFd(loop: *Loop, fd: sys.fd_t) void {
        _ = loop;
        if (fd == sys.invalid_fd) return;
        _ = kernel32.CancelIoEx(@ptrFromInt(fd), null);
    }

    pub fn run(loop: *Loop, timeout_ns: u64) !void {
        const timeout_ms: u32 = if (loop.ready.head != null or timeout_ns == 0)
            0
        else if (timeout_ns == std.math.maxInt(u64))
            win.INFINITE
        else
            @intCast(@min((timeout_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, win.INFINITE - 1));
        var removed: u32 = 0;
        if (kernel32.GetQueuedCompletionStatusEx(loop.port, loop.entries.ptr, @intCast(loop.entries.len), &removed, timeout_ms, 0) == 0) {
            if (win.lastError() != win.WAIT_TIMEOUT) return error.Unexpected;
            removed = 0;
        }
        loop.now_ns = sys.monotonicNs();
        for (loop.entries[0..removed]) |entry| {
            const ov = entry.lpOverlapped orelse {
                if (entry.lpCompletionKey == wake_key) loop.wake_pending.store(false, .release);
                continue;
            };
            const c: *Completion = @alignCast(@fieldParentPtr("overlapped", ov));
            c.result = finish(c, entry.dwNumberOfBytesTransferred);
            c.where = .ready;
            loop.ready.push(c);
        }
        var batch = loop.ready;
        loop.ready = .{};
        while (batch.pop()) |c| {
            c.where = .none;
            c.state = .idle;
            loop.active -= 1;
            if (c.callback(c.userdata, loop, c, c.result) == .rearm and c.state == .idle) loop.submit(c);
        }
    }
};

fn noopCallback(_: ?*anyopaque, _: *Loop, _: *Loop.Completion, _: i32) io.Disposition {
    return .disarm;
}

test "iocp accept connect send recv" {
    if (!sys.is_windows) return error.SkipZigTest;
    var loop = try Loop.init(std.testing.allocator, .{});
    defer loop.deinit();
    const lfd = try sys.socket(.v4, .tcp);
    defer sys.close(lfd);
    var sa = sys.Sockaddr.fromEndpoint(try addr.Endpoint.parse("127.0.0.1:0"));
    try std.testing.expect(sys.bind(lfd, &sa) == 0);
    try std.testing.expect(sys.listen(lfd, 8) == 0);
    try std.testing.expect(sys.getsockname(lfd, &sa) == 0);
    const cfd = try sys.socket(.v4, .tcp);
    defer sys.close(cfd);
    const Ctx = struct {
        accepted: i32 = -1,
        connected: ?i32 = null,
        sent: usize = 0,
        received: usize = 0,
        peer: sys.Sockaddr = .{},
        buf: [32]u8 = undefined,
        fn onAccept(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, r: i32) io.Disposition {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.accepted = r;
            return .disarm;
        }
        fn onConnect(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, r: i32) io.Disposition {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.connected = r;
            return .disarm;
        }
        fn onSend(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, r: i32) io.Disposition {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            if (r > 0) self.sent += @intCast(r);
            return .disarm;
        }
        fn onRecv(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, r: i32) io.Disposition {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            if (r > 0) self.received += @intCast(r);
            return if (r > 0 and self.received < 11) .rearm else .disarm;
        }
    };
    var ctx: Ctx = .{};
    var ac: Loop.Completion = .{ .op = .{ .accept = .{ .fd = lfd, .peer = &ctx.peer } }, .userdata = &ctx, .callback = Ctx.onAccept };
    var cc: Loop.Completion = .{ .op = .{ .connect = .{ .fd = cfd, .addr = &sa } }, .userdata = &ctx, .callback = Ctx.onConnect };
    loop.submit(&ac);
    loop.submit(&cc);
    var spins: u32 = 0;
    while ((ctx.accepted < 0 or ctx.connected == null) and spins < 100) : (spins += 1) try loop.run(50 * std.time.ns_per_ms);
    try std.testing.expect(ctx.accepted >= 0);
    try std.testing.expectEqual(@as(i32, 0), ctx.connected.?);
    try std.testing.expect(ctx.peer.toEndpoint() != null);
    const afd: sys.fd_t = @intCast(ctx.accepted);
    defer sys.close(afd);
    var rc: Loop.Completion = .{ .op = .{ .recv = .{ .fd = afd, .buf = &ctx.buf } }, .userdata = &ctx, .callback = Ctx.onRecv };
    loop.submit(&rc);
    const iov = [2]sys.iovec_const{ .{ .base = "hello ", .len = 6 }, .{ .base = "world", .len = 5 } };
    var wc: Loop.Completion = .{ .op = .{ .writev = .{ .fd = cfd, .iov = &iov } }, .userdata = &ctx, .callback = Ctx.onSend };
    loop.submit(&wc);
    spins = 0;
    while ((ctx.received < 11 or wc.isActive()) and spins < 100) : (spins += 1) try loop.run(50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 11), ctx.sent);
    try std.testing.expectEqual(@as(usize, 11), ctx.received);
    try std.testing.expectEqual(@as(u32, 0), loop.pending());
}

test "iocp cancel pending recv and wakeup" {
    if (!sys.is_windows) return error.SkipZigTest;
    var loop = try Loop.init(std.testing.allocator, .{});
    defer loop.deinit();
    const fd = try sys.socket(.v4, .udp);
    defer sys.close(fd);
    var sa = sys.Sockaddr.fromEndpoint(try addr.Endpoint.parse("127.0.0.1:0"));
    try std.testing.expect(sys.bind(fd, &sa) == 0);
    const Ctx = struct {
        result: ?i32 = null,
        buf: [8]u8 = undefined,
        fn onRead(ud: ?*anyopaque, _: *Loop, _: *Loop.Completion, r: i32) io.Disposition {
            const self: *@This() = @ptrCast(@alignCast(ud.?));
            self.result = r;
            return .disarm;
        }
    };
    var ctx: Ctx = .{};
    var c: Loop.Completion = .{ .op = .{ .recv = .{ .fd = fd, .buf = &ctx.buf } }, .userdata = &ctx, .callback = Ctx.onRead };
    loop.submit(&c);
    try std.testing.expectEqual(@as(u32, 1), loop.pending());
    loop.cancel(&c);
    var spins: u32 = 0;
    while (ctx.result == null and spins < 50) : (spins += 1) try loop.run(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(sys.Errno.canceled, sys.toErrno(ctx.result.?));
    try std.testing.expectEqual(@as(u32, 0), loop.pending());
    const Waker = struct {
        fn run(l: *Loop) void {
            sys.sleepMs(20);
            l.wakeup();
        }
    };
    const t = try std.Thread.spawn(.{}, Waker.run, .{&loop});
    const start_ns = sys.monotonicNs();
    try loop.run(5 * std.time.ns_per_s);
    t.join();
    try std.testing.expect(sys.monotonicNs() - start_ns < 2 * std.time.ns_per_s);
}
