const std = @import("std");
const process = @import("../platform/common/process.zig");

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

pub const WhisperCliTranscriptionService = struct {
    io: std.Io,
    command: []const u8 = "tools/whisper.cpp-v1.9.1-bin/whisper-cli",
    model_path: []const u8 = "models/ggml-base.en.bin",

    pub fn init(io: std.Io) WhisperCliTranscriptionService {
        return .{ .io = io };
    }

    pub fn initWith(io: std.Io, command: []const u8, model_path: []const u8) WhisperCliTranscriptionService {
        return .{ .io = io, .command = command, .model_path = model_path };
    }

    pub fn service(self: *WhisperCliTranscriptionService) TranscriptionService {
        return .{ .ctx = self, .transcribeFn = transcribe };
    }

    fn transcribe(ctx: *anyopaque, allocator: std.mem.Allocator, audio_path: []const u8) !TranscriptionResult {
        const self: *WhisperCliTranscriptionService = @ptrCast(@alignCast(ctx));
        const output_stem = try std.fmt.allocPrint(allocator, "{s}.transcription", .{audio_path});
        const output_json_path = try std.fmt.allocPrint(allocator, "{s}.json", .{output_stem});
        const out = try process.runCaptureLarge(allocator, self.io, &.{
            self.command,
            "-m",
            self.model_path,
            "-f",
            audio_path,
            "-nt",
            "-oj",
            "-ojf",
            "-of",
            output_stem,
        });
        const raw_provider_json = try readFileAllocPath(self.io, output_json_path, allocator, .limited(32 * 1024 * 1024));
        const summary_json = try summarizeWhisperJson(allocator, raw_provider_json);
        return .{
            .text = try allocator.dupe(u8, std.mem.trim(u8, out, " \r\n\t")),
            .provider = try allocator.dupe(u8, "whisper.cpp/whisper-cli"),
            .model_path = try allocator.dupe(u8, self.model_path),
            .audio_path = try allocator.dupe(u8, audio_path),
            .raw_provider_json_path = output_json_path,
            .summary_json = summary_json,
        };
    }
};

fn summarizeWhisperJson(allocator: std.mem.Allocator, raw_provider_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_provider_json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const language = if (root.get("result")) |result|
        if (result.object.get("language")) |value| value.string else null
    else
        null;
    const transcription = root.get("transcription") orelse return error.MissingWhisperTranscription;

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "{\"language\":");
    if (language) |lang| {
        try out.appendSlice(allocator, try std.json.Stringify.valueAlloc(allocator, lang, .{}));
    } else {
        try out.appendSlice(allocator, "null");
    }
    try appendFmt(allocator, &out, ",\"segment_count\":{d},\"segments\":[", .{transcription.array.items.len});

    for (transcription.array.items, 0..) |segment, segment_index| {
        if (segment_index > 0) try out.appendSlice(allocator, ",");
        try appendWhisperSegmentSummary(allocator, &out, segment);
    }

    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn appendWhisperSegmentSummary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), segment: std.json.Value) !void {
    const object = segment.object;
    const text = if (object.get("text")) |value| value.string else return error.MissingWhisperSegmentText;
    const offsets = object.get("offsets") orelse return error.MissingWhisperSegmentOffsets;
    const tokens = object.get("tokens") orelse return error.MissingWhisperSegmentTokens;

    var probability_sum: f64 = 0;
    var probability_min: f64 = 1;
    var probability_count: usize = 0;
    for (tokens.array.items) |token| {
        const p = whisperProbability(token) orelse continue;
        probability_sum += p;
        probability_min = @min(probability_min, p);
        probability_count += 1;
    }
    const average_probability = if (probability_count == 0) 0 else probability_sum / @as(f64, @floatFromInt(probability_count));
    if (probability_count == 0) probability_min = 0;

    try appendFmt(allocator, out, "{{\"from_ms\":{d},\"to_ms\":{d},\"text\":", .{
        jsonInteger(offsets.object.get("from") orelse return error.MissingWhisperSegmentOffset),
        jsonInteger(offsets.object.get("to") orelse return error.MissingWhisperSegmentOffset),
    });
    try out.appendSlice(allocator, try std.json.Stringify.valueAlloc(allocator, text, .{}));
    try appendFmt(allocator, out, ",\"token_count\":{d},\"avg_token_p\":{d:.3},\"min_token_p\":{d:.3},\"low_confidence_tokens\":[", .{
        tokens.array.items.len,
        average_probability,
        probability_min,
    });

    var low_count: usize = 0;
    for (tokens.array.items) |token| {
        const p = whisperProbability(token) orelse continue;
        if (p >= 0.5) continue;
        if (low_count == 8) break;
        if (low_count > 0) try out.appendSlice(allocator, ",");
        const token_object = token.object;
        const token_text = if (token_object.get("text")) |value| value.string else return error.MissingWhisperTokenText;
        try out.appendSlice(allocator, "{\"text\":");
        try out.appendSlice(allocator, try std.json.Stringify.valueAlloc(allocator, token_text, .{}));
        try appendFmt(allocator, out, ",\"p\":{d:.3}}}", .{p});
        low_count += 1;
    }

    try out.appendSlice(allocator, "]}");
}

fn whisperProbability(token: std.json.Value) ?f64 {
    const value = token.object.get("p") orelse return null;
    return jsonFloat(value);
}

fn jsonFloat(value: std.json.Value) f64 {
    return switch (value) {
        .float => |v| v,
        .integer => |v| @floatFromInt(v),
        else => 0,
    };
}

fn jsonInteger(value: std.json.Value) i64 {
    return switch (value) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        else => 0,
    };
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, fmt, args));
}

fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
    }
    const dirname = std.fs.path.dirname(path) orelse return error.MissingParentDirectory;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, basename, allocator, limit);
}
