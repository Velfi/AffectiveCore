const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat = @import("chat_client.zig");
const extraction_port = @import("../core/port_memory_extraction.zig");
const llm_routing = @import("../core/llm_routing.zig");
const context_composition = @import("../core/context_composition.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");

pub const CandidateKind = extraction_port.CandidateKind;
pub const ExtractionCandidate = extraction_port.ExtractionCandidate;
pub const MemoryExtractionService = extraction_port.MemoryExtractionService;

pub const RandomProviderMemoryExtractionService = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?chat.ReasoningEffort,
    ) RandomProviderMemoryExtractionService {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn service(self: *RandomProviderMemoryExtractionService) MemoryExtractionService {
        return .{ .ctx = self, .extractFn = extract };
    }

    fn extract(ctx: *anyopaque, allocator: std.mem.Allocator, episode_text: []const u8) ![]ExtractionCandidate {
        const self: *RandomProviderMemoryExtractionService = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, episode_text, " \r\n\t");
        if (trimmed.len == 0) return error.EmptyEpisodeSummaryForExtraction;
        context_composition.traceReportToDebug(0, context_composition.auditMemoryExtraction(trimmed));
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "memory_extraction",
            .system_prompt = extractionSystemPrompt(),
            .user_prompt = try extractionUserPrompt(allocator, trimmed),
            .temperature = 0.0,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = extractionJsonSchema(),
            .response_validator = validateExtractionCandidates,
            .bad_response_logger = reportExtractionParseError,
        });
        return parseExtractionCandidates(allocator, content);
    }
};

fn extractionSystemPrompt() []const u8 {
    return
    \\Extract durable memory hypotheses from a completed episode summary.
    \\Return strict JSON only with key candidates.
    \\Each candidate must include key, proposition, evidence, kind, confidence, salience, tags, source_references.
    \\kind must be one of belief, preference, relationship.
    \\confidence and salience must be numbers in [0.0, 1.0].
    \\source_references must quote or point to exact source phrases from the episode summary.
    \\Do not invent facts not grounded in the provided episode summary.
    \\Return {"candidates":[]} when no durable memory hypothesis is justified.
    \\Do not wrap JSON in Markdown or code fences.
    ;
}

fn extractionUserPrompt(allocator: std.mem.Allocator, episode_text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "episode_summary:\n{s}\n\nextract durable belief/preference/relationship hypotheses.",
        .{episode_text},
    );
}

const ExtractionCandidateWire = struct {
    key: []const u8,
    proposition: []const u8,
    evidence: []const u8,
    kind: []const u8,
    confidence: f32,
    salience: f32,
    tags: []const []const u8,
    source_references: []const []const u8,
};

const ExtractionWire = struct {
    candidates: []const ExtractionCandidateWire,
};

pub fn parseExtractionCandidates(allocator: std.mem.Allocator, body: []const u8) ![]ExtractionCandidate {
    const parsed = try std.json.parseFromSlice(ExtractionWire, allocator, body, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    var out = std.ArrayList(ExtractionCandidate).empty;
    for (parsed.value.candidates) |item| {
        const key = std.mem.trim(u8, item.key, " \r\n\t");
        const proposition = std.mem.trim(u8, item.proposition, " \r\n\t");
        const evidence = std.mem.trim(u8, item.evidence, " \r\n\t");
        if (key.len == 0) return error.EmptyMemoryExtractionKey;
        if (proposition.len == 0) return error.EmptyMemoryExtractionProposition;
        if (evidence.len == 0) return error.EmptyMemoryExtractionEvidence;
        if (item.confidence < 0.0 or item.confidence > 1.0) return error.InvalidMemoryExtractionConfidence;
        if (item.salience < 0.0 or item.salience > 1.0) return error.InvalidMemoryExtractionSalience;
        const kind = std.meta.stringToEnum(CandidateKind, item.kind) orelse return error.InvalidMemoryExtractionKind;
        const tags = try cloneTrimmedSlice(allocator, item.tags, error.EmptyMemoryExtractionTag);
        const source_references = try cloneTrimmedSlice(allocator, item.source_references, error.EmptyMemoryExtractionSourceReference);
        try out.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .proposition = try allocator.dupe(u8, proposition),
            .evidence = try allocator.dupe(u8, evidence),
            .kind = kind,
            .confidence = item.confidence,
            .salience = item.salience,
            .tags = tags,
            .source_references = source_references,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn cloneTrimmedSlice(
    allocator: std.mem.Allocator,
    values: []const []const u8,
    comptime empty_error: anyerror,
) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        const trimmed = std.mem.trim(u8, value, " \r\n\t");
        if (trimmed.len == 0) return empty_error;
        out[index] = try allocator.dupe(u8, trimmed);
    }
    return out;
}

fn validateExtractionCandidates(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseExtractionCandidates(allocator, content);
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const episode =
        \\User said they prefer tea over coffee and mentioned they usually drink it in the afternoon.
        \\They also said their cat's name is Mochi.
    ;
    const user_prompt = try extractionUserPrompt(allocator, episode);
    const scenario = try llm_tester_scenario.Scenario.init(
        allocator,
        "memory_extraction_tea_preference",
        "Extract durable memories from a completed episode",
        "Validates extraction of durable preferences and relationship facts from a completed episode without inventing details absent from the transcript.",
        "memory_extraction",
        extractionSystemPrompt(),
        user_prompt,
        .json_object,
        extractionJsonSchema(),
        512,
        0,
    );
    const out = try allocator.alloc(llm_tester_scenario.Scenario, 1);
    out[0] = scenario;
    return out;
}

fn extractionJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"candidates":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"key":{"type":"string"},"proposition":{"type":"string"},"evidence":{"type":"string"},"kind":{"type":"string","enum":["belief","preference","relationship"]},"confidence":{"type":"number"},"salience":{"type":"number"},"tags":{"type":"array","items":{"type":"string"}},"source_references":{"type":"array","items":{"type":"string"}}},"required":["key","proposition","evidence","kind","confidence","salience","tags","source_references"]}}},"required":["candidates"]}
    ;
}

fn reportExtractionParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nMEMORY EXTRACTION PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with candidates[] containing key/proposition/evidence/kind/confidence/salience/tags/source_references\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

test "parse extraction candidates enforces strict schema and bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const candidates = try parseExtractionCandidates(allocator,
        \\{"candidates":[{"key":"user.preference.tea","proposition":"User prefers tea over coffee.","evidence":"user said they prefer tea over coffee","kind":"preference","confidence":0.81,"salience":0.67,"tags":["episode","preference"],"source_references":["prefer tea over coffee"]}]}
    );
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    try std.testing.expectEqual(CandidateKind.preference, candidates[0].kind);
    try std.testing.expectEqualStrings("prefer tea over coffee", candidates[0].source_references[0]);
    try std.testing.expectError(error.UnknownField, parseExtractionCandidates(allocator,
        \\{"candidates":[],"extra":true}
    ));
    try std.testing.expectError(error.InvalidMemoryExtractionConfidence, parseExtractionCandidates(allocator,
        \\{"candidates":[{"key":"k","proposition":"p","evidence":"e","kind":"belief","confidence":1.2,"salience":0.4,"tags":["a"],"source_references":["b"]}]}
    ));
}

test "memory extraction schema requires strict candidate envelope" {
    const schema = extractionJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"candidates\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"key\",\"proposition\",\"evidence\",\"kind\",\"confidence\",\"salience\",\"tags\",\"source_references\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"additionalProperties\":false") != null);
}
