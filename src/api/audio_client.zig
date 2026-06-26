const std = @import("std");
const transcription = @import("transcription_client.zig");
const audio_port = @import("../core/port_audio.zig");

pub const AudioKind = audio_port.AudioKind;
pub const AudioInspection = audio_port.AudioInspection;
pub const AudioInspectionService = audio_port.AudioInspectionService;
pub const TestAudioInspectionService = audio_port.TestAudioInspectionService;

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
