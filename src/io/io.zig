const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
pub const sys = @import("sys.zig");
pub const file = @import("file.zig");

pub const fd_t = sys.fd_t;

pub const MsgHdr = if (sys.is_linux) std.os.linux.msghdr else if (sys.is_windows) extern struct {
    name: ?*anyopaque = null,
    namelen: u32 = 0,
    iov: [*]sys.iovec = undefined,
    iovlen: usize = 0,
    control: ?*anyopaque = null,
    controllen: usize = 0,
    flags: u32 = 0,
} else std.c.msghdr;

pub const MsgHdrConst = if (sys.is_linux) std.os.linux.msghdr_const else if (sys.is_windows) extern struct {
    name: ?*const anyopaque = null,
    namelen: u32 = 0,
    iov: [*]const sys.iovec_const = undefined,
    iovlen: usize = 0,
    control: ?*const anyopaque = null,
    controllen: usize = 0,
    flags: u32 = 0,
} else std.c.msghdr_const;

pub const Events = packed struct(u32) {
    in: bool = false,
    out: bool = false,
    err: bool = false,
    hup: bool = false,
    _pad: u28 = 0,
};

pub const no_group: u16 = std.math.maxInt(u16);

pub const Operation = union(enum) {
    none: void,
    read: struct { fd: fd_t, buf: []u8, group: u16 = no_group, multishot: bool = false },
    write: struct { fd: fd_t, buf: []const u8 },
    writev: struct { fd: fd_t, iov: []const sys.iovec_const },
    recv: struct { fd: fd_t, buf: []u8, flags: u32 = 0, group: u16 = no_group },
    send: struct { fd: fd_t, buf: []const u8, flags: u32 = 0 },
    recvmsg: struct { fd: fd_t, msg: *MsgHdr, flags: u32 = 0 },
    sendmsg: struct { fd: fd_t, msg: *const MsgHdrConst, flags: u32 = 0 },
    accept: struct { fd: fd_t, peer: ?*sys.Sockaddr = null },
    connect: struct { fd: fd_t, addr: *const sys.Sockaddr },
    poll: struct { fd: fd_t, events: Events },
    close: struct { fd: fd_t },

    pub fn fd(op: Operation) fd_t {
        return switch (op) {
            .none => sys.invalid_fd,
            inline else => |v| v.fd,
        };
    }

    pub fn wantsRead(op: Operation) bool {
        return switch (op) {
            .read, .recv, .recvmsg, .accept => true,
            .poll => |p| p.events.in,
            else => false,
        };
    }
};

pub const Disposition = enum { disarm, rearm };

pub const State = enum(u8) { idle, queued, active, canceling };

pub const Options = struct {
    entries: u16 = 1024,
    sqpoll: bool = false,
    sqpoll_idle_ms: u32 = 50,
    sqpoll_cpu: ?u32 = null,
    max_events: u16 = 256,
    max_fds_hint: u32 = 1024,
    defer_enable: bool = false,
    backend: BackendKind = .io_uring,
};

pub const BackendKind = enum(u8) { io_uring, epoll, kqueue, iocp };

pub const Linux = if (sys.is_linux and (build_options.enable_io_uring or build_options.enable_epoll)) @import("linux_loop.zig").Loop else void;
pub const IoUring = if (build_options.enable_io_uring and sys.is_linux) Linux else void;
pub const Epoll = if (build_options.enable_epoll and sys.is_linux) Linux else void;
pub const Kqueue = if (sys.is_darwin or sys.is_bsd) @import("kqueue.zig").Loop else void;
pub const Iocp = if (sys.is_windows) @import("iocp.zig").Loop else void;

pub fn available(kind: BackendKind) bool {
    return switch (kind) {
        .io_uring => IoUring != void and @import("io_uring.zig").probe(),
        .epoll => Epoll != void,
        .kqueue => Kqueue != void,
        .iocp => Iocp != void,
    };
}

pub fn defaultBackend() BackendKind {
    if (IoUring != void and available(.io_uring)) return .io_uring;
    if (Epoll != void) return .epoll;
    if (Kqueue != void) return .kqueue;
    return .iocp;
}
