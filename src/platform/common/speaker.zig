const std = @import("std");

pub const Speaker = struct {
    ctx: *anyopaque,
    playFileFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!void,

    pub fn playFile(self: Speaker, allocator: std.mem.Allocator, path: []const u8) !void {
        return self.playFileFn(self.ctx, allocator, path);
    }
};

pub const TestSpeaker = struct {
    pub fn speaker(self: *TestSpeaker) Speaker {
        return .{ .ctx = self, .playFileFn = play };
    }

    fn play(_: *anyopaque, _: std.mem.Allocator, path: []const u8) !void {
        std.debug.print("SPEAKER TEST: {s}\n", .{path});
    }
};
