const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat = @import("chat_client.zig");

pub const WantCandidate = struct {
    memory_id: []const u8,
    text: []const u8,
    interpretation: []const u8,
    salience: f32,
    score: i32,
};

pub const WantAchievementMatch = struct {
    memory_id: []const u8,
    confidence: f32,
    evidence: []const u8,
};

pub const WantAchievementResult = struct {
    matches: []const WantAchievementMatch,
};

pub const WantAchievementDetector = struct {
    ctx: *anyopaque,
    detectFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const WantCandidate) anyerror!WantAchievementResult,

    pub fn detect(self: WantAchievementDetector, allocator: std.mem.Allocator, event_text: []const u8, wants: []const WantCandidate) !WantAchievementResult {
        return self.detectFn(self.ctx, allocator, event_text, wants);
    }
};

pub const RandomProviderWantAchievementDetector = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, models_spec: []const u8, reasoning_effort: ?chat.ReasoningEffort) RandomProviderWantAchievementDetector {
        return .{
            .provider_client = ai.RandomProviderClient.init(io, http, env, models_spec),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn detector(self: *RandomProviderWantAchievementDetector) WantAchievementDetector {
        return .{ .ctx = self, .detectFn = detect };
    }

    fn detect(ctx: *anyopaque, allocator: std.mem.Allocator, event_text: []const u8, wants: []const WantCandidate) !WantAchievementResult {
        const self: *RandomProviderWantAchievementDetector = @ptrCast(@alignCast(ctx));
        if (wants.len == 0) return .{ .matches = &.{} };
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "want_achievement",
            .system_prompt = systemPrompt(),
            .user_prompt = try buildUserPrompt(allocator, event_text, wants),
            .temperature = 0.0,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = wantAchievementJsonSchema(),
            .response_validator = validateWantAchievementResult,
            .bad_response_logger = reportWantAchievementParseError,
        });
        return parseWantAchievementResult(allocator, content);
    }
};

pub const ScriptedWantAchievementDetector = struct {
    matches: []const WantAchievementMatch = &.{},
    fail: ?anyerror = null,
    calls: usize = 0,
    last_event_text: []const u8 = "",
    last_want_count: usize = 0,

    pub fn detector(self: *ScriptedWantAchievementDetector) WantAchievementDetector {
        return .{ .ctx = self, .detectFn = detect };
    }

    fn detect(ctx: *anyopaque, allocator: std.mem.Allocator, event_text: []const u8, wants: []const WantCandidate) !WantAchievementResult {
        _ = allocator;
        const self: *ScriptedWantAchievementDetector = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_event_text = event_text;
        self.last_want_count = wants.len;
        if (self.fail) |err| return err;
        return .{ .matches = self.matches };
    }
};

fn systemPrompt() []const u8 {
    return
    \\You judge whether an event clearly achieved one of the brain's ongoing wants.
    \\Only return a match when the event provides direct evidence that a want was achieved or materially fulfilled.
    \\Do not infer achievement from vague positivity, planning, or unrelated success.
    \\Return exactly JSON with key matches.
    \\matches must be an array of objects with memory_id, confidence, and evidence.
    \\confidence is 0.0 to 1.0. evidence is a short quote or paraphrase from the event.
    \\Return {"matches":[]} when nothing was achieved.
    \\Do not wrap JSON in Markdown or code fences.
    ;
}

fn buildUserPrompt(allocator: std.mem.Allocator, event_text: []const u8, wants: []const WantCandidate) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "event:\n");
    try out.appendSlice(allocator, event_text);
    try out.appendSlice(allocator, "\n\nactive_wants:\n");
    for (wants) |want| {
        try out.print(
            allocator,
            "- memory_id: {s}\n  text: {s}\n  interpretation: {s}\n  salience: {d:.3}\n  score: {d}\n",
            .{ want.memory_id, want.text, want.interpretation, want.salience, want.score },
        );
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseWantAchievementResult(allocator: std.mem.Allocator, body: []const u8) !WantAchievementResult {
    const WireMatch = struct {
        memory_id: []const u8,
        confidence: f32,
        evidence: []const u8,
    };
    const Wire = struct {
        matches: []const WireMatch,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    var out = std.ArrayList(WantAchievementMatch).empty;
    for (parsed.value.matches) |match| {
        const id = std.mem.trim(u8, match.memory_id, " \r\n\t");
        const evidence = std.mem.trim(u8, match.evidence, " \r\n\t");
        if (id.len == 0) return error.EmptyWantAchievementMemoryId;
        if (evidence.len == 0) return error.EmptyWantAchievementEvidence;
        if (match.confidence < 0.0 or match.confidence > 1.0) return error.InvalidWantAchievementConfidence;
        try out.append(allocator, .{
            .memory_id = try allocator.dupe(u8, id),
            .confidence = match.confidence,
            .evidence = try allocator.dupe(u8, evidence),
        });
    }
    return .{ .matches = try out.toOwnedSlice(allocator) };
}

fn validateWantAchievementResult(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseWantAchievementResult(allocator, content);
}

fn wantAchievementJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"matches":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"memory_id":{"type":"string"},"confidence":{"type":"number"},"evidence":{"type":"string"}},"required":["memory_id","confidence","evidence"]}}},"required":["matches"]}
    ;
}

fn reportWantAchievementParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nWANT ACHIEVEMENT PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with matches array\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

test "parse want achievement result requires strict valid matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseWantAchievementResult(arena.allocator(),
        \\{"matches":[{"memory_id":"want_garden","confidence":0.82,"evidence":"the garden map was completed"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqualStrings("want_garden", result.matches[0].memory_id);
    try std.testing.expectError(error.UnknownField, parseWantAchievementResult(arena.allocator(),
        \\{"matches":[],"extra":true}
    ));
    try std.testing.expectError(error.InvalidWantAchievementConfidence, parseWantAchievementResult(arena.allocator(),
        \\{"matches":[{"memory_id":"want_garden","confidence":1.5,"evidence":"done"}]}
    ));
}

test "want achievement schema requires strict matches envelope" {
    const schema = wantAchievementJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"matches\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"memory_id\",\"confidence\",\"evidence\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"additionalProperties\":false") != null);
}
