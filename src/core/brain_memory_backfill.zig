const std = @import("std");
const brain_mod = @import("brain.zig");
const vector_index = @import("vector_index.zig");
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;
const schema = @import("ports.zig").schema;

pub const BackfillReport = struct {
    updated: usize,
    total: usize,
};

pub fn embedBackfillMemories(self: *Brain) !BackfillReport {
    const expected = self.deps.embedding_service.dimensions();
    var memories = try self.deps.store.loadMemoryRecords(self.allocator);
    var updated: usize = 0;
    var batch_texts = std.ArrayList([]const u8).empty;
    defer batch_texts.deinit(self.allocator);
    var batch_indices = std.ArrayList(usize).empty;
    defer batch_indices.deinit(self.allocator);

    for (memories, 0..) |memory, i| {
        if (memory.vector.len == expected) continue;
        try batch_texts.append(self.allocator, helpers.memoryInterpretation(memory));
        try batch_indices.append(self.allocator, i);
        if (batch_texts.items.len >= 32) {
            updated += try flushBackfillBatch(self, &memories, &batch_texts, &batch_indices);
        }
    }
    if (batch_texts.items.len > 0) {
        updated += try flushBackfillBatch(self, &memories, &batch_texts, &batch_indices);
    }
    return .{ .updated = updated, .total = memories.len };
}

fn flushBackfillBatch(
    self: *Brain,
    memories: *[]schema.MemoryRecord,
    batch_texts: *std.ArrayList([]const u8),
    batch_indices: *std.ArrayList(usize),
) !usize {
    const vectors = try self.deps.embedding_service.embedBatch(self.allocator, batch_texts.items);
    defer {
        for (vectors) |vector| self.allocator.free(vector);
        self.allocator.free(vectors);
    }
    if (vectors.len != batch_texts.items.len) return error.EmbeddingBatchSizeMismatch;
    var count: usize = 0;
    for (batch_indices.items, vectors) |memory_index, vector| {
        var memory = memories.*[memory_index];
        self.allocator.free(memory.vector);
        memory.vector = try self.allocator.dupe(f32, vector);
        try self.deps.store.saveMemoryRecord(memory);
        memories.*[memory_index] = memory;
        count += 1;
    }
    batch_texts.clearRetainingCapacity();
    batch_indices.clearRetainingCapacity();
    return count;
}
