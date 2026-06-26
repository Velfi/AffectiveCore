const std = @import("std");

pub const AudioFile = struct {
    path: []const u8,
};

pub const SpeechService = struct {
    ctx: *anyopaque,
    synthesizeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!AudioFile,

    pub fn synthesize(self: SpeechService, allocator: std.mem.Allocator, text: []const u8) !AudioFile {
        return self.synthesizeFn(self.ctx, allocator, text);
    }
};

pub const TestSpeechService = struct {
    pub fn service(self: *TestSpeechService) SpeechService {
        return .{ .ctx = self, .synthesizeFn = synthesize };
    }

    fn synthesize(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) !AudioFile {
        return .{ .path = try allocator.dupe(u8, "test://speech") };
    }
};
