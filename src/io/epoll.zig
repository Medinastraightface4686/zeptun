const std = @import("std");
const linux = std.os.linux;
const io = @import("io.zig");
const sys = @import("sys.zig");

const wake_token: u64 = std.math.maxInt(u64);

pub fn Impl(comptime Outer: type) type {
    return struct {
        const Loop = @This();
        const Completion = Outer.Completion;

        inline fn outer(loop: *Loop) *Outer {
            return @alignCast(@fieldParentPtr("epoll", loop));
        }

        const List = struct {
            head: ?*Completion = null,
            tail: ?*Completion = null,

            fn push(l: *List, c: *Completion) void {
                c.next = null;
                c.prev = l.tail;
                if (l.tail) |t| t.next = c else l.head = c;
                l.tail = c;
            }

            fn remove(l: *List, c: *Completion) void {
                if (c.prev) |p| p.next = c.next else l.head = c.next;
                if (c.next) |n| n.prev = c.prev else l.tail = c.prev;
                c.next = null;
                c.prev = null;
            }

            fn pop(l: *List) ?*Completion {
                const c = l.head orelse return null;
                l.remove(c);
                return c;
            }
        };

        const FdState = struct {
            readers: List = .{},
            writers: List = .{},
            registered: bool = false,
        };

        allocator: std.mem.Allocator,
        epfd: i32,
        wake_fd: i32,
        fds: []FdState,
        ready: List = .{},
        active: u32 = 0,
        now_ns: u64,
        events: []linux.epoll_event,

        pub fn init(allocator: std.mem.Allocator, options: io.Options) !Loop {
            const ep_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
            if (linux.errno(ep_rc) != .SUCCESS) return error.SystemResources;
            const epfd: i32 = @intCast(ep_rc);
            errdefer _ = linux.close(epfd);
            const efd_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(efd_rc) != .SUCCESS) return error.SystemResources;
            const wake_fd: i32 = @intCast(efd_rc);
            errdefer _ = linux.close(wake_fd);
            var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = wake_token } };
            if (linux.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, wake_fd, &ev)) != .SUCCESS) return error.SystemResources;
            const fds = try allocator.alloc(FdState, @max(options.max_fds_hint, 64));
            errdefer allocator.free(fds);
            @memset(fds, .{});
            const events = try allocator.alloc(linux.epoll_event, @max(options.max_events, 16));
            return .{
                .allocator = allocator,
                .epfd = epfd,
                .wake_fd = wake_fd,
                .fds = fds,
                .now_ns = sys.monotonicNs(),
                .events = events,
            };
        }

        pub fn deinit(loop: *Loop) void {
            _ = linux.close(loop.epfd);
            _ = linux.close(loop.wake_fd);
            loop.allocator.free(loop.fds);
            loop.allocator.free(loop.events);
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
            const one: u64 = 1;
            _ = linux.write(loop.wake_fd, std.mem.asBytes(&one), 8);
        }

        fn state(loop: *Loop, fd: i32) *FdState {
            const idx: usize = @intCast(fd);
            if (idx >= loop.fds.len) {
                var new_len = loop.fds.len * 2;
                while (new_len <= idx) new_len *= 2;
                const grown = loop.allocator.realloc(loop.fds, new_len) catch @panic("epoll fd table allocation failed");
                @memset(grown[loop.fds.len..], .{});
                loop.fds = grown;
            }
            return &loop.fds[idx];
        }

        pub fn register(loop: *Loop, fd: sys.fd_t) !void {
            const st = loop.state(fd);
            if (st.registered) return;
            var ev: linux.epoll_event = .{
                .events = linux.EPOLL.IN | linux.EPOLL.OUT | linux.EPOLL.RDHUP | linux.EPOLL.ET,
                .data = .{ .u64 = @intCast(fd) },
            };
            switch (linux.errno(linux.epoll_ctl(loop.epfd, linux.EPOLL.CTL_ADD, fd, &ev))) {
                .SUCCESS, .EXIST => st.registered = true,
                .PERM => return error.NotSupported,
                else => return error.SystemResources,
            }
        }

        pub fn unregister(loop: *Loop, fd: sys.fd_t) void {
            if (fd < 0) return;
            const idx: usize = @intCast(fd);
            if (idx >= loop.fds.len) return;
            const st = &loop.fds[idx];
            loop.failAll(&st.readers);
            loop.failAll(&st.writers);
            if (st.registered) {
                _ = linux.epoll_ctl(loop.epfd, linux.EPOLL.CTL_DEL, fd, null);
                st.registered = false;
            }
        }

        fn failAll(loop: *Loop, list: *List) void {
            while (list.pop()) |c| {
                c.result = sys.Errno.canceled.result();
                c.where = .ready;
                loop.ready.push(c);
            }
        }

        pub fn submit(loop: *Loop, c: *Completion) void {
            std.debug.assert(c.state == .idle);
            c.state = .active;
            c.connecting = false;
            loop.active += 1;
            switch (c.op) {
                .none => {
                    c.result = 0;
                    c.where = .ready;
                    loop.ready.push(c);
                },
                .close => |op| {
                    loop.unregister(op.fd);
                    _ = linux.close(op.fd);
                    c.result = 0;
                    c.where = .ready;
                    loop.ready.push(c);
                },
                else => {
                    const r = attempt(c);
                    if (r == sys.Errno.again.result()) {
                        loop.wait(c);
                    } else {
                        c.result = r;
                        c.where = .ready;
                        loop.ready.push(c);
                    }
                },
            }
        }

        fn wait(loop: *Loop, c: *Completion) void {
            const fd = c.op.fd();
            loop.register(fd) catch {
                c.result = sys.Errno.badf.result();
                c.where = .ready;
                loop.ready.push(c);
                return;
            };
            const st = loop.state(fd);
            if (c.op.wantsRead()) {
                c.where = .readers;
                st.readers.push(c);
            } else {
                c.where = .writers;
                st.writers.push(c);
            }
        }

        fn attempt(c: *Completion) i32 {
            return switch (c.op) {
                .none, .close => 0,
                .read => |op| sys.read(op.fd, op.buf),
                .write => |op| sys.write(op.fd, op.buf),
                .writev => |op| sys.writev(op.fd, op.iov),
                .recv => |op| sys.recv(op.fd, op.buf, op.flags | linux.MSG.DONTWAIT),
                .send => |op| sys.send(op.fd, op.buf, op.flags | linux.MSG.DONTWAIT),
                .recvmsg => |op| sys.linuxResult(linux.recvmsg(op.fd, op.msg, op.flags | linux.MSG.DONTWAIT)),
                .sendmsg => |op| sys.linuxResult(linux.sendmsg(op.fd, op.msg, op.flags | linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL)),
                .accept => |op| sys.accept(op.fd, op.peer),
                .connect => |op| blk: {
                    if (!c.connecting) {
                        c.connecting = true;
                        const r = sys.connect(op.fd, op.addr);
                        if (sys.toErrno(r) == .inprogress or sys.toErrno(r) == .already) break :blk sys.Errno.again.result();
                        break :blk r;
                    }
                    const e = sys.socketError(op.fd);
                    if (e != .success) break :blk e.result();
                    var peer: sys.Sockaddr = .{};
                    const pr = sys.getpeername(op.fd, &peer);
                    if (sys.toErrno(pr) == .notconn) break :blk sys.Errno.again.result();
                    break :blk 0;
                },
                .poll => |op| blk: {
                    var mask: i16 = 0;
                    if (op.events.in) mask |= linux.POLL.IN | 0x2000;
                    if (op.events.out) mask |= linux.POLL.OUT;
                    var pfd = [1]linux.pollfd{.{ .fd = op.fd, .events = mask, .revents = 0 }};
                    const r = sys.linuxResult(linux.poll(&pfd, 1, 0));
                    if (r < 0) break :blk r;
                    if (r == 0) break :blk sys.Errno.again.result();
                    const rev: u32 = @bitCast(@as(i32, pfd[0].revents));
                    const ev: io.Events = .{
                        .in = rev & (linux.POLL.IN | 0x2000) != 0,
                        .out = rev & linux.POLL.OUT != 0,
                        .err = rev & linux.POLL.ERR != 0,
                        .hup = rev & linux.POLL.HUP != 0,
                    };
                    break :blk @bitCast(@as(u32, @bitCast(ev)));
                },
            };
        }

        pub fn cancel(loop: *Loop, c: *Completion) void {
            if (c.state != .active) return;
            switch (c.where) {
                .readers, .writers => {
                    const st = loop.state(c.op.fd());
                    if (c.where == .readers) st.readers.remove(c) else st.writers.remove(c);
                    c.result = sys.Errno.canceled.result();
                    c.where = .ready;
                    loop.ready.push(c);
                },
                else => {},
            }
        }

        pub fn cancelFd(loop: *Loop, fd: sys.fd_t) void {
            if (fd < 0) return;
            const idx: usize = @intCast(fd);
            if (idx >= loop.fds.len) return;
            loop.failAll(&loop.fds[idx].readers);
            loop.failAll(&loop.fds[idx].writers);
        }

        fn retry(loop: *Loop, list: *List) void {
            while (list.head) |c| {
                const r = attempt(c);
                if (r == sys.Errno.again.result()) break;
                list.remove(c);
                c.result = r;
                c.where = .ready;
                loop.ready.push(c);
            }
        }

        pub fn run(loop: *Loop, timeout_ns: u64) !void {
            const timeout_ms: i32 = if (loop.ready.head != null or timeout_ns == 0)
                0
            else if (timeout_ns == std.math.maxInt(u64))
                -1
            else
                @intCast(@min((timeout_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms, std.math.maxInt(i32)));
            const rc = linux.epoll_wait(loop.epfd, loop.events.ptr, @intCast(loop.events.len), timeout_ms);
            const n: usize = switch (linux.errno(rc)) {
                .SUCCESS => rc,
                .INTR => 0,
                else => |e| return sys.errnoError(sys.mapErrno(e)),
            };
            loop.now_ns = sys.monotonicNs();
            for (loop.events[0..n]) |ev| {
                if (ev.data.u64 == wake_token) {
                    var v: u64 = 0;
                    _ = linux.read(loop.wake_fd, std.mem.asBytes(&v), 8);
                    continue;
                }
                const fd: usize = @intCast(ev.data.u64);
                if (fd >= loop.fds.len) continue;
                const st = &loop.fds[fd];
                const bad = ev.events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0;
                if (bad or ev.events & (linux.EPOLL.IN | linux.EPOLL.RDHUP) != 0) loop.retry(&st.readers);
                if (bad or ev.events & linux.EPOLL.OUT != 0) loop.retry(&st.writers);
            }
            var batch = loop.ready;
            loop.ready = .{};
            while (batch.pop()) |c| {
                c.where = .none;
                c.state = .idle;
                loop.active -= 1;
                if (c.callback(c.userdata, loop.outer(), c, c.result) == .rearm and c.state == .idle) loop.submit(c);
            }
        }
    };
}
