const std = @import("std");
const brain_mod = @import("brain.zig");
const ports = @import("ports.zig");
const helpers = @import("brain_helpers.zig");
const vector_index = @import("vector_index.zig");
const context_composition = @import("context_composition.zig");
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
    const max_selected_limit = self.cfg.capacity.memory_selected_max;
    const prefiltered = try vector_index.search(self.allocator, memories, trimmed, &[_][]const u8{}, prefilter_limit);
    defer self.allocator.free(prefiltered);

    var candidates = std.ArrayList(selection_port.MemoryCandidate).empty;
    defer candidates.deinit(self.allocator);
    for (prefiltered) |result| {
        const memory = memories[result.memory_index];
        try candidates.append(self.allocator, .{
            .memory_id = memory.memory_id,
            .interpretation = try catalogLine(self.allocator, memory),
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

    const take = @min(prefiltered.len, max_selected_limit);
    for (prefiltered[0..take]) |result| {
        const memory = memories[result.memory_index];
        try touchSelectedMemory(self, memory);
        try entries.append(self.allocator, .{
            .memory_id = try self.allocator.dupe(u8, memory.memory_id),
            .relevance = relevanceFromScore(result.score),
            .reason = try std.fmt.allocPrint(self.allocator, "vector score {d:.2}", .{result.score}),
            .interpretation = try self.allocator.dupe(u8, helpers.memoryInterpretation(memory)),
        });
    }

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

pub fn appendMemorySelectionToMemory(allocator: std.mem.Allocator, out: *std.ArrayList(u8), selection: ResolvedMemorySelection) !void {
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
    for (selection.entries) |entry| {
        try out.print(allocator, "- {s} relevance={d:.2} reason={s}\n  {s}\n", .{
            entry.memory_id,
            entry.relevance,
            entry.reason,
            entry.interpretation,
        });
    }
}

fn catalogLine(allocator: std.mem.Allocator, memory: schema.MemoryRecord) ![]const u8 {
    const raw = helpers.memoryInterpretation(memory);
    const first_line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    const first_line = raw[0..first_line_end];
    if (first_line.len <= catalog_line_max_bytes) return allocator.dupe(u8, first_line);
    return std.fmt.allocPrint(allocator, "{s}...", .{first_line[0..catalog_line_max_bytes]});
}

fn touchSelectedMemory(self: *Brain, memory: schema.MemoryRecord) !void {
    var updated = memory;
    if (updated.vector.len != vector_index.dimensions) {
        updated.vector = try vector_index.embedMemory(self.allocator, updated);
    }
    updated.access_count += 1;
    updated.score += 1;
    updated.last_accessed_at = try self.timestampNow();
    try self.deps.store.saveMemoryRecord(updated);
}

test "appendMemorySelectionObservation formats selected entries" {
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
}
