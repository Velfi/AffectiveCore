const std = @import("std");
const transcription = @import("transcription_client.zig");

pub const AudioKind = enum {
    speech,
    music,
    mixed,
    ambient,
    unknown,
};

pub const AudioInspection = struct {
    kind: AudioKind,
    transcription: ?transcription.TranscriptionResult = null,
};

pub const AudioInspectionService = struct {
    ctx: *anyopaque,
    inspectFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!AudioInspection,

    pub fn inspect(self: AudioInspectionService, allocator: std.mem.Allocator, audio_path: []const u8) !AudioInspection {
        return self.inspectFn(self.ctx, allocator, audio_path);
    }
};

pub const TranscriptionBackedAudioInspectionService = struct {
    transcription_service: transcription.TranscriptionService,

    pub fn init(transcription_service: transcription.TranscriptionService) TranscriptionBackedAudioInspectionService {
        return .{ .transcription_service = transcription_service };
    }

    pub fn service(self: *TranscriptionBackedAudioInspectionService) AudioInspectionService {
        return .{ .ctx = self, .inspectFn = inspect };
    }

    fn inspect(ctx: *anyopaque, allocator: std.mem.Allocator, audio_path: []const u8) !AudioInspection {
        const self: *TranscriptionBackedAudioInspectionService = @ptrCast(@alignCast(ctx));
        const result = try self.transcription_service.transcribe(allocator, audio_path);
        const transcript = std.mem.trim(u8, result.text, " \r\n\t");
        if (transcript.len == 0) {
            return .{ .kind = .unknown, .transcription = result };
        }
        return .{ .kind = .speech, .transcription = result };
    }
};

pub const TestAudioInspectionService = struct {
    kind: AudioKind = .speech,
    transcript: []const u8 = "test transcript",

    pub fn service(self: *TestAudioInspectionService) AudioInspectionService {
        return .{ .ctx = self, .inspectFn = inspect };
    }

    fn inspect(ctx: *anyopaque, allocator: std.mem.Allocator, audio_path: []const u8) !AudioInspection {
        const self: *TestAudioInspectionService = @ptrCast(@alignCast(ctx));
        const result: ?transcription.TranscriptionResult = switch (self.kind) {
            .speech, .mixed, .unknown => .{
                .text = try allocator.dupe(u8, self.transcript),
                .provider = try allocator.dupe(u8, "test"),
                .model_path = try allocator.dupe(u8, "test://audio-classifier"),
                .audio_path = try allocator.dupe(u8, audio_path),
                .raw_provider_json_path = try allocator.dupe(u8, "test://audio-classifier.json"),
                .summary_json = try allocator.dupe(u8, "{\"language\":null,\"segment_count\":1,\"segments\":[]}"),
            },
            .music, .ambient => null,
        };
        return .{ .kind = self.kind, .transcription = result };
    }
};

test "test audio inspection can represent unknown audio" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var classifier = TestAudioInspectionService{ .kind = .unknown, .transcript = "" };
    const inspection = try classifier.service().inspect(arena.allocator(), "data/test/audio.wav");
    try std.testing.expectEqual(AudioKind.unknown, inspection.kind);
}
