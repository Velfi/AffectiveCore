const std = @import("std");
const files = @import("../platform/common/files.zig");
const process = @import("../platform/common/process.zig");
const speech_port = @import("../core/port_speech.zig");

pub const AudioFile = speech_port.AudioFile;
pub const SpeechService = speech_port.SpeechService;
pub const TestSpeechService = speech_port.TestSpeechService;

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
