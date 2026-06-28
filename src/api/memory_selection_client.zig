const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat = @import("chat_client.zig");
const selection_port = @import("../core/port_memory_selection.zig");
const llm_routing = @import("../core/llm_routing.zig");
const context_composition = @import("../core/context_composition.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");

pub const MemoryCandidate = selection_port.MemoryCandidate;
pub const SelectedMemory = selection_port.SelectedMemory;
pub const MemorySelectionResult = selection_port.MemorySelectionResult;
pub const MemorySelectionService = selection_port.MemorySelectionService;

pub const RandomProviderMemorySelectionService = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?chat.ReasoningEffort,
    ) RandomProviderMemorySelectionService {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn service(self: *RandomProviderMemorySelectionService) MemorySelectionService {
        return .{ .ctx = self, .selectFn = select };
    }

    fn select(ctx: *anyopaque, allocator: std.mem.Allocator, user_utterance: []const u8, candidates: []const MemoryCandidate) !MemorySelectionResult {
        const self: *RandomProviderMemorySelectionService = @ptrCast(@alignCast(ctx));
        if (candidates.len == 0) {
            return .{
                .summary = try allocator.dupe(u8, "No candidate memories were available for this turn."),
                .selected = &.{},
            };
        }
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "memory_selection",
            .system_prompt = systemPrompt(),
            .user_prompt = try buildUserPrompt(allocator, user_utterance, candidates),
            .temperature = 0.0,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = memorySelectionJsonSchema(),
            .response_validator = validateMemorySelectionResult,
            .bad_response_logger = reportMemorySelectionParseError,
        });
        return parseMemorySelectionResult(allocator, content);
    }
};

fn systemPrompt() []const u8 {
    return
    \\You select memories for this conversation turn.
    \\Choose the memories most relevant to what just reached you and summarize them for your ongoing context.
    \\Return strict JSON only with keys selected and summary.
    \\selected must contain 0 to 5 items from the provided candidate list only.
    \\Each selected item needs memory_id, relevance (0.0-1.0), and reason (short phrase grounded in what reached you and the memory text).
    \\summary must be one compact paragraph (<=200 words) synthesizing only the selected memories for this turn.
    \\Prefer fewer, highly relevant memories over broad coverage.
    \\Return {"selected":[],"summary":"..."} when nothing is relevant.
    \\Do not wrap JSON in Markdown or code fences.
    ;
}

fn buildUserPrompt(allocator: std.mem.Allocator, user_utterance: []const u8, candidates: []const MemoryCandidate) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "what_reached_you:\n");
    try out.appendSlice(allocator, user_utterance);
    try out.appendSlice(allocator, "\n\ncandidate_memories:\n");
    for (candidates) |candidate| {
        try out.print(
            allocator,
            "- memory_id: {s}\n  scope: {s}\n  salience: {d:.3}\n  score: {d}\n  interpretation: {s}\n",
            .{ candidate.memory_id, candidate.scope, candidate.salience, candidate.score, candidate.interpretation },
        );
        try out.appendSlice(allocator, "  tags:");
        if (candidate.tags.len == 0) {
            try out.appendSlice(allocator, " none");
        } else {
            for (candidate.tags) |tag| {
                try out.print(allocator, " {s}", .{tag});
            }
        }
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

pub fn parseMemorySelectionResult(allocator: std.mem.Allocator, body: []const u8) !MemorySelectionResult {
    const WireSelected = struct {
        memory_id: []const u8,
        relevance: f32,
        reason: []const u8,
    };
    const Wire = struct {
        selected: []const WireSelected,
        summary: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const summary = std.mem.trim(u8, parsed.value.summary, " \r\n\t");
    if (summary.len == 0) return error.EmptyMemorySelectionSummary;
    var out = std.ArrayList(SelectedMemory).empty;
    for (parsed.value.selected) |item| {
        const memory_id = std.mem.trim(u8, item.memory_id, " \r\n\t");
        const reason = std.mem.trim(u8, item.reason, " \r\n\t");
        if (memory_id.len == 0) return error.EmptyMemorySelectionMemoryId;
        if (reason.len == 0) return error.EmptyMemorySelectionReason;
        if (item.relevance < 0.0 or item.relevance > 1.0) return error.InvalidMemorySelectionRelevance;
        try out.append(allocator, .{
            .memory_id = try allocator.dupe(u8, memory_id),
            .relevance = item.relevance,
            .reason = try allocator.dupe(u8, reason),
        });
    }
    return .{
        .summary = try allocator.dupe(u8, summary),
        .selected = try out.toOwnedSlice(allocator),
    };
}

fn validateMemorySelectionResult(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseMemorySelectionResult(allocator, content);
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const candidates = [_]MemoryCandidate{
        .{
            .memory_id = "mem_tea_pref",
            .scope = "preference",
            .salience = 0.72,
            .score = 84,
            .interpretation = "User prefers tea over coffee.",
            .tags = &.{"preference", "beverage"},
        },
        .{
            .memory_id = "mem_cat_name",
            .scope = "relationship",
            .salience = 0.55,
            .score = 61,
            .interpretation = "User's cat is named Mochi.",
            .tags = &.{"pet"},
        },
        .{
            .memory_id = "mem_quiet_mornings",
            .scope = "preference",
            .salience = 0.40,
            .score = 44,
            .interpretation = "User likes quiet mornings.",
            .tags = &.{"routine"},
        },
    };
    const user_prompt = try buildUserPrompt(allocator, "Do you remember what I like to drink?", candidates[0..]);
    const scenario = try llm_tester_scenario.Scenario.init(
        allocator,
        "memory_selection_beverage",
        "Select relevant memories for a beverage question",
        "Tests selecting memories relevant to a beverage question while deprioritizing unrelated candidates with lower topical scores.",
        "memory_selection",
        systemPrompt(),
        user_prompt,
        .json_object,
        memorySelectionJsonSchema(),
        512,
        0,
    );
    const out = try allocator.alloc(llm_tester_scenario.Scenario, 1);
    out[0] = scenario;
    return out;
}

fn memorySelectionJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"selected":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"memory_id":{"type":"string"},"relevance":{"type":"number"},"reason":{"type":"string"}},"required":["memory_id","relevance","reason"]}},"summary":{"type":"string"}},"required":["selected","summary"]}
    ;
}

fn reportMemorySelectionParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nMEMORY SELECTION PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with selected array and summary string\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

test "parse memory selection result requires strict valid envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseMemorySelectionResult(arena.allocator(),
        \\{"selected":[{"memory_id":"mem_a","relevance":0.91,"reason":"active want matches utterance"}],"summary":"The user is continuing an existing recognition thread."}
    );
    try std.testing.expectEqual(@as(usize, 1), result.selected.len);
    try std.testing.expectEqualStrings("mem_a", result.selected[0].memory_id);
    try std.testing.expectError(error.UnknownField, parseMemorySelectionResult(arena.allocator(),
        \\{"selected":[],"summary":"ok","extra":true}
    ));
    try std.testing.expectError(error.EmptyMemorySelectionSummary, parseMemorySelectionResult(arena.allocator(),
        \\{"selected":[],"summary":""}
    ));
}
