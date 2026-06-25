const std = @import("std");
const files = @import("../platform/common/files.zig");
const process = @import("../platform/common/process.zig");

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

    fn synthesize(_: *anyopaque, allocator: std.mem.Allocator, text: []const u8) !AudioFile {
        std.debug.print("SPEECH TEST: {s}\n", .{text});
        return .{ .path = try allocator.dupe(u8, "test://speech") };
    }
};

pub const SpeakNSpellSpeechService = struct {
    io: std.Io,
    output_dir: []const u8 = "data/audio/output",
    voice: []const u8 = "Fred",

    pub fn init(io: std.Io, voice: []const u8) SpeakNSpellSpeechService {
        return .{ .io = io, .voice = voice };
    }

    pub fn service(self: *SpeakNSpellSpeechService) SpeechService {
        return .{ .ctx = self, .synthesizeFn = synthesize };
    }

    fn synthesize(ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8) !AudioFile {
        const self: *SpeakNSpellSpeechService = @ptrCast(@alignCast(ctx));
        const stamp = std.Io.Clock.real.now(self.io).toMilliseconds();
        const raw_path = try std.fmt.allocPrint(allocator, "{s}/speak_{d}.aiff", .{ self.output_dir, stamp });
        try files.ensureParentDir(self.io, raw_path);

        try process.runCommand(allocator, self.io, &.{ "say", "-v", self.voice, "-o", raw_path, text });
        return .{ .path = raw_path };
    }
};
