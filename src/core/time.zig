const std = @import("std");

pub fn timestampFromSeconds(allocator: std.mem.Allocator, seconds: i64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{seconds});
}

pub fn daysBetweenUnixish(last_seen_at: ?[]const u8, now_seconds: i64) i64 {
    const text = last_seen_at orelse return 9999;
    const previous = std.fmt.parseInt(i64, text, 10) catch return 9999;
    const delta = now_seconds - previous;
    if (delta <= 0) return 0;
    return @divFloor(delta, 86_400);
}

test "timestampFromSeconds formats unixish seconds" {
    const timestamp = try timestampFromSeconds(std.testing.allocator, 1_781_222_400);
    defer std.testing.allocator.free(timestamp);

    try std.testing.expectEqualStrings("1781222400", timestamp);
}
