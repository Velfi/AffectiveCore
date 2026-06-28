const std = @import("std");

pub const Speaker = struct {
    ctx: *anyopaque,
    playFileFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!void,
    playFileBackgroundFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!void,

    pub fn playFile(self: Speaker, allocator: std.mem.Allocator, path: []const u8) !void {
        return self.playFileFn(self.ctx, allocator, path);
    }

    pub fn playFileBackground(self: Speaker, allocator: std.mem.Allocator, path: []const u8) !void {
        return self.playFileBackgroundFn(self.ctx, allocator, path);
    }
};

pub const TestSpeaker = struct {
    played_path: ?[]const u8 = null,

    pub fn speaker(self: *TestSpeaker) Speaker {
        return .{ .ctx = self, .playFileFn = play, .playFileBackgroundFn = playBackground };
    }

    fn play(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) !void {
        const self: *TestSpeaker = @ptrCast(@alignCast(ctx));
        self.played_path = try allocator.dupe(u8, path);
    }

    fn playBackground(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) !void {
        const self: *TestSpeaker = @ptrCast(@alignCast(ctx));
        self.played_path = try allocator.dupe(u8, path);
    }
};
