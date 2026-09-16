const std = @import("std");
const io = @import("../io/io.zig");
const sys = @import("../io/sys.zig");
const handler_mod = @import("../handler/handler.zig");

const linux = std.os.linux;

const splice_move: u32 = 1;
const splice_nonblock: u32 = 2;
pub const pipe_size: usize = 1 << 20;
const pump_rounds = 16;
const small_read = 16 * 1024;

fn splice(fd_in: i32, fd_out: i32, len: usize) i32 {
    const rc = linux.syscall6(.splice, @as(usize, @bitCast(@as(isize, fd_in))), 0, @as(usize, @bitCast(@as(isize, fd_out))), 0, len, splice_move | splice_nonblock);
    return sys.linuxResult(rc);
}

pub fn Relay(comptime W: type) type {
    return struct {
        const Self = @This();
        const Loop = W.Loop;
        const Dial = handler_mod.Dial(W);

        pub const ReleaseFn = *const fn (w: *W, r: *Self) void;

        pub const Direction = enum { client_to_upstream, upstream_to_client };

        pub const Side = struct {
            fd: sys.fd_t = sys.invalid_fd,
            poll_in: Loop.Completion = .{},
            poll_out: Loop.Completion = .{},
        };

        active: bool = false,
        closing: bool = false,
        connected: bool = false,
        client: Side = .{},
        upstream: Side = .{},
        dial: Dial = .{},
        pipe_cu: [2]sys.fd_t = .{ sys.invalid_fd, sys.invalid_fd },
        pipe_uc: [2]sys.fd_t = .{ sys.invalid_fd, sys.invalid_fd },
        cu_pending: u32 = 0,
        uc_pending: u32 = 0,
        client_eof: bool = false,
        upstream_eof: bool = false,
        cu_shut: bool = false,
        uc_shut: bool = false,
        reset: bool = false,
        on_release: ?ReleaseFn = null,

        pub fn idle(r: *const Self) bool {
            return !(r.client.poll_in.isActive() or r.client.poll_out.isActive() or r.upstream.poll_in.isActive() or r.upstream.poll_out.isActive() or r.dial.busy() or r.dial.completionActive());
        }

        pub fn fromDial(d: *Dial) *Self {
            return @alignCast(@fieldParentPtr("dial", d));
        }

        pub fn dialDone(r: *Self, w: *W, d: *Dial, result: sys.Errno) void {
            if (result == .success) {
                r.upstream.fd = d.fd;
                d.fd = sys.invalid_fd;
            }
            if (r.closing) {
                r.tryRelease(w);
                return;
            }
            if (result != .success) {
                w.counters.inc(.tcp_connect_failed);
                r.close(w, true);
                return;
            }
            r.connected = true;
            const cu = sys.pipe() catch {
                r.close(w, true);
                return;
            };
            r.pipe_cu = cu;
            const uc = sys.pipe() catch {
                r.close(w, true);
                return;
            };
            r.pipe_uc = uc;
            _ = linux.fcntl(r.pipe_cu[1], linux.F.SETPIPE_SZ, pipe_size);
            _ = linux.fcntl(r.pipe_uc[1], linux.F.SETPIPE_SZ, pipe_size);
            const extra = d.leftover();
            if (extra.len > 0) {
                const n = sys.write(r.pipe_uc[1], extra);
                if (n != @as(i32, @intCast(extra.len))) {
                    r.close(w, true);
                    return;
                }
                r.uc_pending += @intCast(n);
                w.counters.add(.upstream_rx_bytes, @intCast(n));
            }
            r.pump(w, .client_to_upstream);
            if (r.active and !r.closing) r.pump(w, .upstream_to_client);
        }

        fn armPoll(r: *Self, w: *W, side: *Side, out: bool) void {
            const c = if (out) &side.poll_out else &side.poll_in;
            if (c.isActive()) return;
            c.* = .{
                .op = .{ .poll = .{ .fd = side.fd, .events = .{ .in = !out, .out = out } } },
                .userdata = r,
                .callback = if (out) onPollOut else onPollIn,
            };
            w.loop.submit(c);
        }

        fn onPollIn(ud: ?*anyopaque, loop: *Loop, c: *Loop.Completion, result: i32) io.Disposition {
            const r: *Self = @ptrCast(@alignCast(ud.?));
            const w: *W = @alignCast(@fieldParentPtr("loop", loop));
            if (r.closing) {
                r.tryRelease(w);
                return .disarm;
            }
            if (result < 0 and sys.toErrno(result) != .again) {
                r.close(w, true);
                return .disarm;
            }
            r.pump(w, if (c == &r.client.poll_in) .client_to_upstream else .upstream_to_client);
            return .disarm;
        }

        fn onPollOut(ud: ?*anyopaque, loop: *Loop, c: *Loop.Completion, result: i32) io.Disposition {
            const r: *Self = @ptrCast(@alignCast(ud.?));
            const w: *W = @alignCast(@fieldParentPtr("loop", loop));
            if (r.closing) {
                r.tryRelease(w);
                return .disarm;
            }
            if (result < 0 and sys.toErrno(result) != .again) {
                r.close(w, true);
                return .disarm;
            }
            r.pump(w, if (c == &r.upstream.poll_out) .client_to_upstream else .upstream_to_client);
            return .disarm;
        }

        fn pump(r: *Self, w: *W, dir: Direction) void {
            const src = if (dir == .client_to_upstream) &r.client else &r.upstream;
            const dst = if (dir == .client_to_upstream) &r.upstream else &r.client;
            const p = if (dir == .client_to_upstream) &r.pipe_cu else &r.pipe_uc;
            const pending = if (dir == .client_to_upstream) &r.cu_pending else &r.uc_pending;
            const eof = if (dir == .client_to_upstream) &r.client_eof else &r.upstream_eof;
            const shut = if (dir == .client_to_upstream) &r.cu_shut else &r.uc_shut;
            var bulk = false;
            var rounds: u32 = 0;
            while (rounds < pump_rounds) : (rounds += 1) {
                if (pending.* > 0) {
                    const n = splice(p[0], dst.fd, pending.*);
                    if (n > 0) {
                        pending.* -= @intCast(n);
                        if (dir == .client_to_upstream) w.counters.add(.upstream_tx_bytes, @intCast(n)) else w.counters.add(.upstream_rx_bytes, @intCast(n));
                        continue;
                    }
                    if (sys.toErrno(n) == .again) {
                        r.armPoll(w, dst, true);
                        return;
                    }
                    r.close(w, true);
                    return;
                }
                if (eof.*) {
                    if (!shut.*) {
                        shut.* = true;
                        _ = sys.shutdown(dst.fd, .write);
                    }
                    if (r.client_eof and r.upstream_eof and r.cu_pending == 0 and r.uc_pending == 0) r.close(w, false);
                    return;
                }
                if (!bulk) {
                    var buf: [small_read]u8 = undefined;
                    const got = sys.recv(src.fd, &buf, sys.msg_dontwait);
                    if (got > 0) {
                        const len: usize = @intCast(got);
                        const sent = sys.send(dst.fd, buf[0..len], sys.msg_dontwait);
                        const done: usize = if (sent > 0) @intCast(sent) else 0;
                        if (sent < 0 and sys.toErrno(sent) != .again) {
                            r.close(w, true);
                            return;
                        }
                        if (done > 0) {
                            if (dir == .client_to_upstream) w.counters.add(.upstream_tx_bytes, done) else w.counters.add(.upstream_rx_bytes, done);
                        }
                        if (done < len) {
                            const rest = buf[done..len];
                            const wrote = sys.write(p[1], rest);
                            if (wrote != @as(i32, @intCast(rest.len))) {
                                r.close(w, true);
                                return;
                            }
                            pending.* += @intCast(rest.len);
                            continue;
                        }
                        if (len < small_read) {
                            r.armPoll(w, src, false);
                            return;
                        }
                        bulk = true;
                        continue;
                    }
                    if (got == 0) {
                        eof.* = true;
                        continue;
                    }
                    if (sys.toErrno(got) == .again) {
                        r.armPoll(w, src, false);
                        return;
                    }
                    r.close(w, true);
                    return;
                }
                const n = splice(src.fd, p[1], pipe_size);
                if (n > 0) {
                    pending.* += @intCast(n);
                    continue;
                }
                if (n == 0) {
                    eof.* = true;
                    continue;
                }
                if (sys.toErrno(n) == .again) {
                    r.armPoll(w, src, false);
                    return;
                }
                r.close(w, true);
                return;
            }
            r.armPoll(w, src, false);
        }

        pub fn close(r: *Self, w: *W, reset: bool) void {
            if (r.closing or !r.active) return;
            r.closing = true;
            r.reset = reset;
            if (r.dial.busy()) w.handler.abortDial(w, &r.dial);
            for ([_]*Side{ &r.client, &r.upstream }) |side| {
                if (side.poll_in.isActive()) w.loop.cancel(&side.poll_in);
                if (side.poll_out.isActive()) w.loop.cancel(&side.poll_out);
            }
            r.tryRelease(w);
        }

        pub fn tryRelease(r: *Self, w: *W) void {
            if (!r.closing or !r.idle()) return;
            if (r.reset and r.client.fd != sys.invalid_fd) {
                const lg = extern struct { onoff: c_int, linger: c_int }{ .onoff = 1, .linger = 0 };
                _ = sys.setsockopt(r.client.fd, linux.SOL.SOCKET, linux.SO.LINGER, std.mem.asBytes(&lg));
            }
            for ([_]sys.fd_t{ r.client.fd, r.upstream.fd }) |fd| {
                if (fd != sys.invalid_fd) {
                    w.loop.unregister(fd);
                    sys.close(fd);
                }
            }
            for ([_]sys.fd_t{ r.pipe_cu[0], r.pipe_cu[1], r.pipe_uc[0], r.pipe_uc[1] }) |fd| sys.close(fd);
            const release = r.on_release;
            r.* = .{};
            w.counters.dec(.tcp_active);
            w.counters.inc(.tcp_closed);
            if (release) |f| f(w, r);
        }
    };
}
