const std = @import("std");
const sys = @import("../io/sys.zig");
const log = @import("../log.zig");
const linux_route = @import("linux.zig");
const macos = @import("macos.zig");
const windows = @import("windows.zig");

pub const supported = sys.is_linux or macos.supported or windows.supported;

pub const debounce_ms: u64 = 750;

pub const Identity = struct {
    index4: u32 = 0,
    index6: u32 = 0,
    hash: u64 = 0,
};

pub fn identity(tun_index: u32) Identity {
    if (sys.is_linux) {
        const id = linux_route.networkIdentity(tun_index);
        return .{ .index4 = id.index4, .index6 = id.index6, .hash = id.hash };
    }
    if (macos.supported) {
        const id = macos.networkIdentity(tun_index);
        return .{ .index4 = id.index4, .index6 = id.index6, .hash = id.hash };
    }
    if (windows.supported) {
        const id = windows.networkIdentity(tun_index);
        return .{ .index4 = id.index4, .index6 = id.index6, .hash = id.hash };
    }
    return .{};
}

pub const Callback = *const fn (ctx: ?*anyopaque, id: Identity) void;

pub const Monitor = struct {
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = .init(false),
    fd: sys.fd_t = sys.invalid_fd,
    wake: [2]sys.fd_t = .{ sys.invalid_fd, sys.invalid_fd },
    notifications: if (windows.supported) windows.ChangeNotifications else void = if (windows.supported) .{} else {},
    tun_index: u32 = 0,
    last: Identity = .{},
    ctx: ?*anyopaque = null,
    callback: ?Callback = null,

    pub fn start(m: *Monitor, tun_index: u32, ctx: ?*anyopaque, callback: Callback) !void {
        if (!supported) return error.NotSupported;
        if (m.thread != null) return;
        m.stop_flag.store(false, .release);
        m.tun_index = tun_index;
        m.ctx = ctx;
        m.callback = callback;
        m.last = identity(tun_index);
        errdefer m.release();
        if (sys.is_linux) {
            m.fd = try linux_route.openMonitorSocket();
            const rc = sys.linuxResult(std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
            if (rc < 0) return error.SystemResources;
            m.wake = .{ rc, rc };
        } else if (macos.supported) {
            m.fd = try macos.openMonitorSocket();
            m.wake = try sys.pipe();
        } else if (windows.supported) {
            m.notifications = .{};
            try m.notifications.register();
        }
        m.thread = try std.Thread.spawn(.{ .stack_size = 256 << 10 }, run, .{m});
    }

    fn release(m: *Monitor) void {
        if (m.fd != sys.invalid_fd) {
            sys.close(m.fd);
            m.fd = sys.invalid_fd;
        }
        if (m.wake[0] != sys.invalid_fd) sys.close(m.wake[0]);
        if (m.wake[1] != m.wake[0] and m.wake[1] != sys.invalid_fd) sys.close(m.wake[1]);
        m.wake = .{ sys.invalid_fd, sys.invalid_fd };
        if (windows.supported) m.notifications.unregister();
    }

    pub fn stop(m: *Monitor) void {
        const t = m.thread orelse return;
        m.stop_flag.store(true, .release);
        if (windows.supported) {
            m.notifications.wake();
        } else if (m.wake[1] != sys.invalid_fd) {
            const one: u64 = 1;
            _ = sys.write(m.wake[1], if (sys.is_linux) std.mem.asBytes(&one) else "x");
        }
        t.join();
        m.thread = null;
        m.release();
    }

    fn waitEvent(m: *Monitor, timeout_ms: ?u32) bool {
        if (windows.supported) return m.notifications.wait(timeout_ms);
        if (m.fd == sys.invalid_fd) return false;
        const timeout: i32 = if (timeout_ms) |t| @intCast(t) else -1;
        if (sys.is_linux) {
            const linux = std.os.linux;
            var pfd = [2]linux.pollfd{ .{ .fd = m.fd, .events = linux.POLL.IN, .revents = 0 }, .{ .fd = m.wake[0], .events = linux.POLL.IN, .revents = 0 } };
            if (sys.linuxResult(linux.poll(&pfd, 2, timeout)) <= 0) return false;
            if (pfd[0].revents == 0) return false;
        } else {
            var pfd = [2]std.c.pollfd{ .{ .fd = m.fd, .events = std.c.POLL.IN, .revents = 0 }, .{ .fd = m.wake[0], .events = std.c.POLL.IN, .revents = 0 } };
            if (std.c.poll(&pfd, 2, timeout) <= 0) return false;
            if (pfd[0].revents == 0) return false;
        }
        var buf: [8192]u8 = undefined;
        var got = false;
        while (true) {
            const n = sys.recv(m.fd, &buf, sys.msg_dontwait);
            if (n <= 0) {
                if (n < 0 and sys.toErrno(n) == .nobufs) {
                    got = true;
                    continue;
                }
                break;
            }
            got = true;
        }
        return got;
    }

    fn run(m: *Monitor) void {
        var pending_since: u64 = 0;
        while (!m.stop_flag.load(.acquire)) {
            const timeout: ?u32 = if (pending_since == 0) null else @intCast(debounce_ms -| (sys.monotonicMs() - pending_since) + 1);
            if (m.waitEvent(timeout) and pending_since == 0) pending_since = sys.monotonicMs();
            if (pending_since == 0 or sys.monotonicMs() - pending_since < debounce_ms) continue;
            pending_since = 0;
            const id = identity(m.tun_index);
            if (id.hash == m.last.hash) continue;
            m.last = id;
            log.info("network: default interface changed to {d}/{d}", .{ id.index4, id.index6 });
            if (m.callback) |cb| cb(m.ctx, id);
        }
    }
};
