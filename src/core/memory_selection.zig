// Conversation memory selection is vector-only; there is no LLM rerank step.
const std = @import("std");
const brain_mod = @import("brain.zig");
const ports = @import("ports.zig");
const helpers = @import("brain_helpers.zig");
const vector_index = @import("vector_index.zig");
const context_composition = @import("context_composition.zig");
const context_tier = @import("context_tier.zig");
const selection_port = ports.memory_selection;

const Brain = brain_mod.Brain;
const schema = ports.schema;

pub const catalog_line_max_bytes: usize = 160;

pub const ResolvedEntry = struct {
    memory_id: []const u8,
    relevance: f32,
    reason: []const u8,
    interpretation: []const u8,
};

pub const ResolvedMemorySelection = struct {
    summary: []const u8,
    entries: []ResolvedEntry,
    candidate_count: usize,
};

fn relevanceFromScore(score: f32) f32 {
    if (score <= 0.0) return 0.0;
    if (score >= 1.0) return 1.0;
    return score;
}

pub fn selectConversationMemories(self: *Brain, user_utterance: []const u8) !ResolvedMemorySelection {
    const trimmed = std.mem.trim(u8, user_utterance, " \r\n\t");
    if (trimmed.len == 0) return error.EmptyMemorySelectionUtterance;

    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    if (memories.len == 0) {
        return .{
            .summary = try self.allocator.dupe(u8, "No stored memories yet."),
            .entries = &.{},
            .candidate_count = 0,
        };
    }

    const prefilter_limit = self.cfg.capacity.memory_prefilter_max;
    const max_selected_limit = context_tier.effectiveMemorySelectedMax(
        self.cfg.capacity.memory_selected_max,
        self.last_conversation_effort_tier,
    );
    const prefiltered = try vector_index.search(
        self.allocator,
        self.deps.embedding_service,
        memories,
        trimmed,
        &[_][]const u8{},
        prefilter_limit,
    );
    defer self.allocator.free(prefiltered);

    var candidates = std.ArrayList(selection_port.MemoryCandidate).empty;
    defer candidates.deinit(self.allocator);
    for (prefiltered) |result| {
        const memory = memories[result.memory_index];
        try candidates.append(self.allocator, .{
            .memory_id = memory.memory_id,
            .interpretation = try catalogLine(self.allocator, memory, self.cfg.capacity.memory_snippet_max_bytes),
            .tags = memory.tags,
            .salience = memory.salience,
            .score = memory.score,
            .scope = @tagName(memory.scope),
        });
    }
    try self.traceContextComposition(context_composition.auditMemorySelection(trimmed, candidates.items));

    var entries = std.ArrayList(ResolvedEntry).empty;
    errdefer {
        for (entries.items) |entry| {
            self.allocator.free(entry.memory_id);
            self.allocator.free(entry.reason);
            self.allocator.free(entry.interpretation);
        }
        entries.deinit(self.allocator);
    }

    applyRetrievalBoosts(self, trimmed, memories, prefiltered);
    const mmr_selected = try mmrSelect(
        self.allocator,
        self.deps.embedding_service,
        memories,
        prefiltered,
        max_selected_limit,
        0.7,
    );
    defer self.allocator.free(mmr_selected);

    for (mmr_selected) |result| {
        const memory = memories[result.memory_index];
        try touchSelectedMemory(self, memory);
        try entries.append(self.allocator, .{
            .memory_id = try self.allocator.dupe(u8, memory.memory_id),
            .relevance = relevanceFromScore(result.score),
            .reason = try self.allocator.dupe(u8, result.reason),
            .interpretation = try memorySnippet(
                self.allocator,
                memory,
                self.cfg.capacity.memory_snippet_max_bytes,
            ),
        });
    }
    try appendFactAndBeliefEntries(self, trimmed, &entries, max_selected_limit);

    const summary = if (entries.items.len == 0)
        try self.allocator.dupe(u8, "No vector-ranked memories matched this utterance.")
    else
        try std.fmt.allocPrint(self.allocator, "Top {d} vector-ranked memories for this utterance.", .{entries.items.len});

    return .{
        .summary = summary,
        .entries = try entries.toOwnedSlice(self.allocator),
        .candidate_count = prefiltered.len,
    };
}

pub fn appendMemorySelectionToMemory(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    selection: ResolvedMemorySelection,
    context_bytes_max: usize,
) !void {
    const section_start = out.items.len;
    try out.appendSlice(allocator, "relevant_memories:\n");
    try out.appendSlice(allocator, selection.summary);
    if (!std.mem.endsWith(u8, selection.summary, "\n")) try out.append(allocator, '\n');
    if (selection.entries.len > 0) {
        try out.appendSlice(allocator, "selected_memory_ids:");
        for (selection.entries) |entry| {
            try out.print(allocator, " {s}", .{entry.memory_id});
        }
        try out.append(allocator, '\n');
    }
    for (selection.entries) |entry| {
        if (out.items.len - section_start >= context_bytes_max) break;
        try out.print(allocator, "- {s} relevance={d:.2} reason={s}\n  {s}\n", .{
            entry.memory_id,
            entry.relevance,
            entry.reason,
            entry.interpretation,
        });
    }
}

pub fn appendMemorySelectionObservation(allocator: std.mem.Allocator, out: *std.ArrayList(u8), selection: ResolvedMemorySelection) !void {
    try out.appendSlice(allocator, "memory_selection:\n");
    try out.print(allocator, "- candidate_count: {d}\n- selected_count: {d}\n", .{ selection.candidate_count, selection.entries.len });
    try out.appendSlice(allocator, "- summary: ");
    try out.appendSlice(allocator, selection.summary);
    if (!std.mem.endsWith(u8, selection.summary, "\n")) try out.append(allocator, '\n');
    if (selection.entries.len == 0) {
        try out.appendSlice(allocator, "- none\n");
        return;
    }
    try out.appendSlice(allocator, "- selected_memory_ids:");
    for (selection.entries) |entry| {
        try out.print(allocator, " {s} relevance={d:.2}", .{ entry.memory_id, entry.relevance });
    }
    try out.append(allocator, '\n');
}

pub fn memorySnippet(allocator: std.mem.Allocator, memory: schema.MemoryRecord, max_bytes: usize) ![]const u8 {
    if (memory.context_snippet.len > 0) return snippetFromText(allocator, memory.context_snippet, max_bytes);
    return snippetFromText(allocator, helpers.memoryInterpretation(memory), max_bytes);
}

fn snippetFromText(allocator: std.mem.Allocator, raw: []const u8, max_bytes: usize) ![]const u8 {
    const first_line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    const first_line = raw[0..first_line_end];
    if (first_line.len <= max_bytes) return allocator.dupe(u8, first_line);
    return std.fmt.allocPrint(allocator, "{s}...", .{first_line[0..max_bytes]});
}

fn catalogLine(allocator: std.mem.Allocator, memory: schema.MemoryRecord, max_bytes: usize) ![]const u8 {
    return memorySnippet(allocator, memory, max_bytes);
}

const MmrResult = struct {
    memory_index: usize,
    score: f32,
    reason: []const u8,
};

fn applyRetrievalBoosts(_: *Brain, query: []const u8, memories: []const schema.MemoryRecord, results: []vector_index.SearchResult) void {
    _ = query;
    _ = memories;
    _ = results;
}

fn mmrSelect(
    allocator: std.mem.Allocator,
    service: ports.embedding.EmbeddingService,
    memories: []const schema.MemoryRecord,
    prefiltered: []const vector_index.SearchResult,
    limit: usize,
    lambda: f32,
) ![]MmrResult {
    if (prefiltered.len == 0 or limit == 0) return &[_]MmrResult{};
    var selected = std.ArrayList(MmrResult).empty;
    errdefer {
        for (selected.items) |item| allocator.free(item.reason);
        selected.deinit(allocator);
    }
    var picked = std.AutoHashMap(usize, void).init(allocator);
    defer picked.deinit();
    const take_limit = @min(limit, prefiltered.len);
    while (selected.items.len < take_limit) {
        var best_index: ?usize = null;
        var best_score: f32 = -1.0;
        var best_reason: []const u8 = undefined;
        for (prefiltered) |candidate| {
            if (picked.contains(candidate.memory_index)) continue;
            var diversity_penalty: f32 = 0.0;
            for (selected.items) |chosen| {
                const a = try memoryVector(allocator, service, memories[candidate.memory_index]);
                defer if (memories[candidate.memory_index].vector.len != service.dimensions()) allocator.free(a);
                const b = try memoryVector(allocator, service, memories[chosen.memory_index]);
                defer if (memories[chosen.memory_index].vector.len != service.dimensions()) allocator.free(b);
                diversity_penalty = @max(diversity_penalty, vector_index.cosine(a, b));
            }
            const mmr_score = lambda * candidate.score - (1.0 - lambda) * diversity_penalty;
            if (mmr_score > best_score) {
                best_score = mmr_score;
                best_index = candidate.memory_index;
                best_reason = try std.fmt.allocPrint(allocator, "mmr score {d:.2} vector {d:.2}", .{ mmr_score, candidate.score });
            }
        }
        const index = best_index orelse break;
        try picked.put(index, {});
        try selected.append(allocator, .{
            .memory_index = index,
            .score = best_score,
            .reason = best_reason,
        });
    }
    return selected.toOwnedSlice(allocator);
}

fn memoryVector(allocator: std.mem.Allocator, service: ports.embedding.EmbeddingService, memory: schema.MemoryRecord) ![]f32 {
    if (memory.vector.len == service.dimensions()) return memory.vector;
    return vector_index.embedMemory(allocator, service, memory);
}

fn appendFactAndBeliefEntries(self: *Brain, query: []const u8, entries: *std.ArrayList(ResolvedEntry), max_total: usize) !void {
    if (entries.items.len >= max_total) return;
    const facts = try self.deps.store.loadFactRecords(self.allocator);
    for (facts) |fact| {
        if (entries.items.len >= max_total) return;
        if (!substringMatch(fact.key, query) and !substringMatch(fact.value, query)) continue;
        try entries.append(self.allocator, .{
            .memory_id = try std.fmt.allocPrint(self.allocator, "fact:{s}", .{fact.fact_id}),
            .relevance = 0.75,
            .reason = try self.allocator.dupe(u8, "fact key/value match"),
            .interpretation = try std.fmt.allocPrint(self.allocator, "fact: {s} -> {s}", .{ fact.key, fact.value }),
        });
    }
    const beliefs = try self.deps.store.loadBeliefs(self.allocator);
    for (beliefs) |belief| {
        if (entries.items.len >= max_total) return;
        if (!substringMatch(belief.key, query) and !substringMatch(belief.proposition, query)) continue;
        try entries.append(self.allocator, .{
            .memory_id = try std.fmt.allocPrint(self.allocator, "belief:{s}", .{belief.belief_id}),
            .relevance = belief.confidence,
            .reason = try self.allocator.dupe(u8, "belief key match"),
            .interpretation = try std.fmt.allocPrint(self.allocator, "belief: {s} -> {s}", .{ belief.key, belief.proposition }),
        });
    }
}

fn substringMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len < 3 or haystack.len == 0) return false;
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn touchSelectedMemory(self: *Brain, memory: schema.MemoryRecord) !void {
    var updated = memory;
    const expected = self.deps.embedding_service.dimensions();
    if (updated.vector.len != expected) {
        updated.vector = try vector_index.embedMemory(self.allocator, self.deps.embedding_service, updated);
    }
    updated.access_count += 1;
    updated.score += 1;
    updated.last_accessed_at = try self.timestampNow();
    try self.deps.store.saveMemoryRecord(updated);
}

test "appendMemorySelectionObservation formats ids only" {
    var entries = [_]ResolvedEntry{
        .{
            .memory_id = "mem_a",
            .relevance = 0.9,
            .reason = "vector score 0.91",
            .interpretation = "self-defined want: Continue existing.",
        },
    };
    const selection = ResolvedMemorySelection{
        .summary = "Top 1 vector-ranked memories for this utterance.",
        .candidate_count = 4,
        .entries = entries[0..],
    };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try appendMemorySelectionObservation(std.testing.allocator, &out, selection);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "memory_selection:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "mem_a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Continue existing") == null);
}
