const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;
const ctx_mod = @import("context.zig");
const types = @import("types.zig");

const ScoredMatch = struct {
    match: types.RetrievalMatch,
    score: f32,
};

pub const MemoryRetrievalActor = struct {
    pub fn retrieve(
        context: *const ctx_mod.ActorContext,
        query: []const u8,
        status: ?schema.MemoryRecordStatus,
        limit: usize,
    ) ![]types.RetrievalMatch {
        if (limit == 0) return error.InvalidRetrievalLimit;
        const trimmed = std.mem.trim(u8, query, " \r\n\t");
        if (trimmed.len == 0) return error.EmptyRetrievalQuery;

        const memories = try context.store.loadMemoryRecords(context.allocator);
        var scored = std.ArrayList(ScoredMatch).empty;
        for (memories) |memory| {
            if (status) |required| {
                if (memory.status != required) continue;
            }
            const relevance = relevanceScore(memory, trimmed);
            if (relevance <= 0) continue;
            try scored.append(context.allocator, .{
                .match = .{
                    .memory_id = memory.memory_id,
                    .status = memory.status,
                    .confidence = memory.confidence,
                    .salience = memory.salience,
                    .text = memory.interpretation,
                },
                .score = relevance + memory.confidence * 0.3 + memory.salience * 0.3,
            });
        }
        std.mem.sort(@TypeOf(scored.items[0]), scored.items, {}, lessThanScore);
        const take = @min(limit, scored.items.len);
        var out = try context.allocator.alloc(types.RetrievalMatch, take);
        for (scored.items[0..take], 0..) |item, index| out[index] = item.match;
        return out;
    }

    pub fn formatContext(allocator: std.mem.Allocator, matches: []const types.RetrievalMatch) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(allocator, "memory_retrieval:\n");
        if (matches.len == 0) {
            try out.appendSlice(allocator, "- none\n");
            return out.toOwnedSlice(allocator);
        }
        for (matches) |item| {
            try out.writer(allocator).print(
                "- {s} status={s} confidence={d:.2} salience={d:.2} text={s}\n",
                .{ item.memory_id, @tagName(item.status), item.confidence, item.salience, item.text },
            );
        }
        return out.toOwnedSlice(allocator);
    }

    fn relevanceScore(memory: schema.MemoryRecord, query: []const u8) f32 {
        var score: f32 = 0;
        if (std.ascii.indexOfIgnoreCase(memory.text, query) != null) score += 0.8;
        if (std.ascii.indexOfIgnoreCase(memory.interpretation, query) != null) score += 0.8;
        for (memory.tags) |tag| {
            if (std.ascii.indexOfIgnoreCase(tag, query) != null) score += 0.4;
        }
        return score;
    }

    fn lessThanScore(_: void, lhs: ScoredMatch, rhs: ScoredMatch) bool {
        return lhs.score > rhs.score;
    }
};
