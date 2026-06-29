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

pub const local_datetime_format = "ISO-8601 local";
pub const local_friendly_datetime_format = "local long date and time";

pub fn localFriendlyDateTimeFromUnix(allocator: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    var ts: c.time_t = @intCast(unix_seconds);
    var result: c.struct_tm = undefined;
    if (c.localtime_r(&ts, &result) == null) return error.LocalDateUnavailable;

    var buf: [64]u8 = undefined;
    const written = c.strftime(&buf, buf.len, "%B %d, %Y at %l:%M %p", &result);
    if (written == 0) return error.LocalDateUnavailable;
    return normalizeSpaces(allocator, buf[0..written]);
}

fn normalizeSpaces(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var prior_space = false;
    for (text) |byte| {
        if (byte == ' ') {
            if (prior_space) continue;
            prior_space = true;
        } else {
            prior_space = false;
        }
        try out.append(allocator, byte);
    }
    return out.toOwnedSlice(allocator);
}

pub fn localIso8601FromUnix(allocator: std.mem.Allocator, unix_seconds: i64) ![]u8 {
    var ts: c.time_t = @intCast(unix_seconds);
    var result: c.struct_tm = undefined;
    if (c.localtime_r(&ts, &result) == null) return error.LocalDateUnavailable;

    var datetime_buf: [32]u8 = undefined;
    const datetime_written = c.strftime(&datetime_buf, datetime_buf.len, "%Y-%m-%dT%H:%M:%S", &result);
    if (datetime_written == 0) return error.LocalDateUnavailable;

    var offset_buf: [8]u8 = undefined;
    const offset_written = c.strftime(&offset_buf, offset_buf.len, "%z", &result);
    if (offset_written != 5) return error.LocalDateUnavailable;

    return std.fmt.allocPrint(allocator, "{s}{s}{s}:{s}", .{
        datetime_buf[0..datetime_written],
        offset_buf[0..1],
        offset_buf[1..3],
        offset_buf[3..5],
    });
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

    const iso = try localIso8601FromUnix(arena.allocator(), 1_781_222_400);
    try std.testing.expect(iso.len >= 25);
    try std.testing.expect(iso[4] == '-');
    try std.testing.expect(iso[7] == '-');
    try std.testing.expect(iso[10] == 'T');
    try std.testing.expect(iso[13] == ':');
    try std.testing.expect(iso[16] == ':');
    const tz_sign = iso[iso.len - 6];
    try std.testing.expect(tz_sign == '+' or tz_sign == '-');
    try std.testing.expect(iso[iso.len - 3] == ':');

    const friendly = try localFriendlyDateTimeFromUnix(arena.allocator(), 1_781_222_400);
    try std.testing.expect(friendly.len > 10);
    try std.testing.expect(std.mem.indexOf(u8, friendly, " at ") != null);
    try std.testing.expect(std.mem.indexOf(u8, friendly, "  ") == null);
}
