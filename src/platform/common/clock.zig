const std = @import("std");
const clock_port = @import("../../core/port_clock.zig");

const c = @cImport({
    @cInclude("time.h");
});

pub const Clock = clock_port.Clock;

pub const LocalClock = struct {
    pub fn clock(self: *LocalClock) Clock {
        return .{ .ctx = self, .nowSecondsFn = localNowSeconds };
    }

    fn localNowSeconds(_: *anyopaque, io: std.Io) !i64 {
        return @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
    }
};

pub fn nowSeconds(io: std.Io) i64 {
    return @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
}

pub fn nowTimestamp(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{nowSeconds(io)});
}

pub fn localMinuteOfDayFromUnix(unix_seconds: i64) !u32 {
    var ts: c.time_t = @intCast(unix_seconds);
    var result: c.struct_tm = undefined;
    if (c.localtime_r(&ts, &result) == null) return error.LocalDateUnavailable;
    return @as(u32, @intCast(result.tm_hour)) * 60 + @as(u32, @intCast(result.tm_min));
}

pub fn localDayKeyFromUnix(allocator: std.mem.Allocator, unix_seconds: i64) ![]const u8 {
    var ts: c.time_t = @intCast(unix_seconds);
    var result: c.struct_tm = undefined;
    if (c.localtime_r(&ts, &result) == null) return error.LocalDateUnavailable;
    var buf: [16]u8 = undefined;
    const written = c.strftime(&buf, buf.len, "%Y-%m-%d", &result);
    if (written == 0) return error.LocalDateUnavailable;
    return allocator.dupe(u8, buf[0..written]);
}

test "local wall clock formats unix seconds" {
    // 2026-06-23 12:30:00 UTC; local fields depend on host TZ.
    const minute = try localMinuteOfDayFromUnix(1_781_222_400);
    _ = minute;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const day_key = try localDayKeyFromUnix(arena.allocator(), 1_781_222_400);
    try std.testing.expect(day_key.len == 10);
    try std.testing.expect(day_key[4] == '-');
    try std.testing.expect(day_key[7] == '-');
}
