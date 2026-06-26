const std = @import("std");
const clock_port = @import("../../core/port_clock.zig");

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
