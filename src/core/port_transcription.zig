const std = @import("std");

pub const TranscriptionService = struct {
    ctx: *anyopaque,
    transcribeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!TranscriptionResult,

    pub fn transcribe(self: TranscriptionService, allocator: std.mem.Allocator, audio_path: []const u8) !TranscriptionResult {
        return self.transcribeFn(self.ctx, allocator, audio_path);
    }
};

pub const TranscriptionResult = struct {
    text: []const u8,
    provider: []const u8,
    model_path: []const u8,
    audio_path: []const u8,
    raw_provider_json_path: []const u8,
    summary_json: []const u8,
};

pub const TestTranscriptionService = struct {
    pub fn service(self: *TestTranscriptionService) TranscriptionService {
        return .{ .ctx = self, .transcribeFn = transcribe };
    }

    fn transcribe(_: *anyopaque, allocator: std.mem.Allocator, audio_path: []const u8) !TranscriptionResult {
        return .{
            .text = try allocator.dupe(u8, ""),
            .provider = try allocator.dupe(u8, "test"),
            .model_path = try allocator.dupe(u8, "test://model"),
            .audio_path = try allocator.dupe(u8, audio_path),
            .raw_provider_json_path = try allocator.dupe(u8, "test://transcription.json"),
            .summary_json = try allocator.dupe(u8, "{\"language\":null,\"segment_count\":0,\"segments\":[]}"),
        };
    }
};
