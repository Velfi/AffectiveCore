const std = @import("std");
const posix = std.posix;

pub fn nowTimestamp(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{nowSeconds()});
}

pub fn nowSeconds() i64 {
    return wallClockUnixSeconds();
}

pub fn daysBetweenUnixish(last_seen_at: ?[]const u8, now_seconds: i64) i64 {
    const text = last_seen_at orelse return 9999;
    const previous = std.fmt.parseInt(i64, text, 10) catch return 9999;
    const delta = now_seconds - previous;
    if (delta <= 0) return 0;
    return @divFloor(delta, 86_400);
}

test "nowSeconds reads the wall clock" {
    const before = wallClockUnixSeconds();
    const actual = nowSeconds();
    const after = wallClockUnixSeconds();

    try std.testing.expect(actual >= before);
    try std.testing.expect(actual <= after);
}

test "nowTimestamp formats wall-clock seconds" {
    const before = wallClockUnixSeconds();
    const timestamp = try nowTimestamp(std.testing.allocator);
    defer std.testing.allocator.free(timestamp);
    const actual = try std.fmt.parseInt(i64, timestamp, 10);
    const after = wallClockUnixSeconds();

    try std.testing.expect(actual >= before);
    try std.testing.expect(actual <= after);
}

fn wallClockUnixSeconds() i64 {
    var timespec: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.REALTIME, &timespec))) {
        .SUCCESS => return @intCast(timespec.sec),
        else => |err| std.debug.panic("clock_gettime(CLOCK_REALTIME) failed: {s}", .{@tagName(err)}),
    }
}
