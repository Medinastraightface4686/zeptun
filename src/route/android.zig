const std = @import("std");
const config = @import("../config.zig");
const sys = @import("../io/sys.zig");
const log = @import("../log.zig");

pub const per_user_range: u32 = 100_000;
pub const packages_path = "/data/system/packages.list";
pub const users_path = "/data/user";

pub fn appIdOf(list: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const pkg = fields.next() orelse continue;
        if (!std.mem.eql(u8, pkg, name)) continue;
        const uid_text = fields.next() orelse return null;
        const uid = std.fmt.parseInt(u32, uid_text, 10) catch return null;
        return uid % per_user_range;
    }
    return null;
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    if (!sys.is_linux) return null;
    const linux = std.os.linux;
    const fd = sys.linuxResult(linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    if (fd < 0) return null;
    defer sys.close(fd);
    var total: usize = 0;
    while (total < buf.len) {
        const n = sys.linuxResult(linux.read(fd, buf[total..].ptr, buf.len - total));
        if (n <= 0) break;
        total += @intCast(n);
    }
    return buf[0..total];
}

fn listUsers(out: []u32) usize {
    if (!sys.is_linux) return 0;
    const linux = std.os.linux;
    const fd = sys.linuxResult(linux.open(users_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0));
    if (fd < 0) return 0;
    defer sys.close(fd);
    var count: usize = 0;
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = sys.linuxResult(linux.getdents64(fd, &buf, buf.len));
        if (n <= 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const reclen = std.mem.readInt(u16, buf[off + 16 ..][0..2], @import("builtin").cpu.arch.endian());
            if (reclen == 0) break;
            const name = std.mem.sliceTo(buf[off + 19 .. off + reclen], 0);
            if (std.fmt.parseInt(u32, name, 10)) |user| {
                if (count < out.len) {
                    out[count] = user;
                    count += 1;
                }
            } else |_| {}
            off += reclen;
        }
    }
    return count;
}

pub fn userExclusions(users: []const u32, out: []config.UidRange) []config.UidRange {
    var allowed: [config.max_uid_ranges]config.UidRange = undefined;
    const n = @min(users.len, allowed.len);
    for (users[0..n], 0..) |u, i| allowed[i] = .{ .start = u * per_user_range, .end = (u + 1) * per_user_range - 1 };
    return config.excludedUids(allowed[0..n], &.{}, out);
}

pub fn resolve(cfg: *const config.Config, include: *config.UidList, exclude: *config.UidList) void {
    const r = &cfg.route;
    if (r.include_packages.isEmpty() and r.exclude_packages.isEmpty() and r.android_users.len == 0) return;
    var users_buf: [32]u32 = undefined;
    var user_count: usize = 0;
    for (r.android_users.slice()) |range| {
        if (user_count < users_buf.len) {
            users_buf[user_count] = range.start;
            user_count += 1;
        }
    }
    if (user_count > 0) {
        var ex_buf: [2 * config.max_uid_ranges + 2]config.UidRange = undefined;
        for (userExclusions(users_buf[0..user_count], &ex_buf)) |range| exclude.append(range) catch {
            log.warn("android: too many uid ranges, user list truncated", .{});
            break;
        };
    } else {
        user_count = listUsers(&users_buf);
        if (user_count == 0) {
            users_buf[0] = 0;
            user_count = 1;
        }
    }
    if (r.include_packages.isEmpty() and r.exclude_packages.isEmpty()) return;
    const storage = std.heap.page_allocator.alloc(u8, 8 << 20) catch return;
    defer std.heap.page_allocator.free(storage);
    const list = readFile(packages_path, storage) orelse {
        log.warn("android: cannot read {s}, package rules ignored", .{packages_path});
        return;
    };
    const lists = [_]struct { names: *const config.PackageList, out: *config.UidList }{
        .{ .names = &r.include_packages, .out = include },
        .{ .names = &r.exclude_packages, .out = exclude },
    };
    for (lists) |entry| {
        var it = entry.names.iterator();
        while (it.next()) |name| {
            const app = appIdOf(list, name) orelse {
                log.warn("android: package {s} is not installed", .{name});
                continue;
            };
            for (users_buf[0..user_count]) |u| {
                const uid = u * per_user_range + app;
                entry.out.append(.{ .start = uid, .end = uid }) catch {
                    log.warn("android: too many uid ranges, package {s} truncated", .{name});
                    break;
                };
            }
        }
    }
}

test "android package list parsing and user ranges" {
    const list =
        \\com.android.chrome 10123 0 /data/user/0/com.android.chrome default:privapp:targetSdkVersion=34 3002,3003
        \\org.telegram.messenger 10245 0 /data/user/0/org.telegram.messenger default:targetSdkVersion=34 3003
    ;
    try std.testing.expectEqual(@as(?u32, 10245), appIdOf(list, "org.telegram.messenger"));
    try std.testing.expectEqual(@as(?u32, 10123), appIdOf(list, "com.android.chrome"));
    try std.testing.expect(appIdOf(list, "com.missing") == null);
    var out: [2 * config.max_uid_ranges + 2]config.UidRange = undefined;
    const ex = userExclusions(&.{10}, &out);
    try std.testing.expectEqual(@as(usize, 2), ex.len);
    try std.testing.expectEqual(config.UidRange{ .start = 0, .end = 999_999 }, ex[0]);
    try std.testing.expectEqual(@as(u32, 1_100_000), ex[1].start);
}
