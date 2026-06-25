const std = @import("std");

pub const HeardSpeechSource = enum {
    typed_text,
    speech_transcription,
};

pub const HeardSpeech = struct {
    text: []const u8,
    source: HeardSpeechSource,
    provider: ?[]const u8 = null,
    model_path: ?[]const u8 = null,
    audio_path: ?[]const u8 = null,
    raw_provider_json_path: ?[]const u8 = null,
    summary_json: ?[]const u8 = null,

    pub fn typed(allocator: std.mem.Allocator, text: []const u8) !HeardSpeech {
        return .{
            .text = try allocator.dupe(u8, text),
            .source = .typed_text,
        };
    }
};

pub const UserInput = struct {
    ctx: *anyopaque,
    askFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!HeardSpeech,
    isActiveFn: ?*const fn (*anyopaque, std.mem.Allocator) anyerror!bool = null,

    pub fn ask(self: UserInput, allocator: std.mem.Allocator, prompt: []const u8) !HeardSpeech {
        return self.askFn(self.ctx, allocator, prompt);
    }

    pub fn isActive(self: UserInput, allocator: std.mem.Allocator) !bool {
        const activeFn = self.isActiveFn orelse return false;
        return activeFn(self.ctx, allocator);
    }
};
