const std = @import("std");
const ports = @import("ports.zig");
const embedding_mod = ports.embedding;
const schema = ports.schema;

pub const semantic_similarity_floor: f32 = 0.30;
pub const hash_similarity_floor: f32 = 0.08;

pub const SearchResult = struct {
    memory_index: usize,
    score: f32,
    similarity: f32,
};

pub fn similarityFloor(service: embedding_mod.EmbeddingService) f32 {
    if (service.dimensions() <= 64) return hash_similarity_floor;
    return semantic_similarity_floor;
}

pub fn embedMemory(allocator: std.mem.Allocator, service: embedding_mod.EmbeddingService, memory: schema.MemoryRecord) ![]f32 {
    return service.embedQuery(allocator, memoryInterpretation(memory), memory.tags);
}

pub fn embedQuery(allocator: std.mem.Allocator, service: embedding_mod.EmbeddingService, query: []const u8, tags: []const []const u8) ![]f32 {
    return service.embedQuery(allocator, query, tags);
}

pub const EphemeralVectorCache = struct {
    vectors: std.AutoHashMap(usize, []f32),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EphemeralVectorCache {
        return .{
            .vectors = std.AutoHashMap(usize, []f32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EphemeralVectorCache) void {
        var it = self.vectors.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.vectors.deinit();
    }

    pub fn fillMissing(
        self: *EphemeralVectorCache,
        service: embedding_mod.EmbeddingService,
        memories: []const schema.MemoryRecord,
        indices: []const usize,
    ) !void {
        const expected_dimensions = service.dimensions();
        var missing_indices = std.ArrayList(usize).empty;
        defer missing_indices.deinit(self.allocator);
        var missing_texts = std.ArrayList([]const u8).empty;
        defer {
            for (missing_texts.items) |text| self.allocator.free(text);
            missing_texts.deinit(self.allocator);
        }

        for (indices) |index| {
            const memory = memories[index];
            if (memory.vector.len == expected_dimensions) continue;
            if (self.vectors.contains(index)) continue;
            try missing_indices.append(self.allocator, index);
            try missing_texts.append(self.allocator, try memoryEmbeddingText(self.allocator, memory));
        }
        if (missing_texts.items.len == 0) return;

        const batch = try service.embedBatch(self.allocator, missing_texts.items);
        defer {
            for (batch) |values| self.allocator.free(values);
            self.allocator.free(batch);
        }
        if (batch.len != missing_indices.items.len) return error.EmptyEmbeddingBatch;

        for (missing_indices.items, batch) |index, values| {
            try self.vectors.put(index, try self.allocator.dupe(f32, values));
        }
    }

    pub fn vector(
        self: *const EphemeralVectorCache,
        service: embedding_mod.EmbeddingService,
        memories: []const schema.MemoryRecord,
        index: usize,
    ) ![]const f32 {
        const memory = memories[index];
        if (memory.vector.len == service.dimensions()) return memory.vector;
        return self.vectors.get(index) orelse error.MissingEphemeralVector;
    }
};

pub fn search(
    allocator: std.mem.Allocator,
    service: embedding_mod.EmbeddingService,
    memories: []const schema.MemoryRecord,
    query: []const u8,
    tags: []const []const u8,
    limit: usize,
) ![]SearchResult {
    const floor = similarityFloor(service);
    var results = std.ArrayList(SearchResult).empty;
    defer results.deinit(allocator);
    const query_vector = try embedQuery(allocator, service, query, tags);
    defer allocator.free(query_vector);
    const has_query = std.mem.trim(u8, query, " \r\n\t").len > 0;

    var candidate_indices = std.ArrayList(usize).empty;
    defer candidate_indices.deinit(allocator);
    for (memories, 0..) |memory, i| {
        if (!hasRequiredTags(memory, tags)) continue;
        try candidate_indices.append(allocator, i);
    }

    var vector_cache = EphemeralVectorCache.init(allocator);
    defer vector_cache.deinit();
    try vector_cache.fillMissing(service, memories, candidate_indices.items);

    for (candidate_indices.items) |i| {
        const memory = memories[i];
        const vector = try vector_cache.vector(service, memories, i);
        const similarity = if (has_query) cosine(query_vector, vector) else @as(f32, 0.0);
        const lexical = if (has_query and lexicalMatch(memory, query)) @as(f32, 0.28) else @as(f32, 0.0);
        const tag_boost = tagOverlapBoost(memory, tags);
        const durability = @min(@as(f32, 0.12), @as(f32, @floatFromInt(@max(memory.score, 0))) * 0.012);
        const salience = memory.salience * 0.08;
        const recency = if (memory.scope == .long_term) @as(f32, 0.04) else @as(f32, 0.0);
        const score = if (has_query) similarity + lexical + tag_boost + durability + salience + recency else tag_boost + durability + salience + recency;
        if (!has_query and tags.len == 0) continue;
        if (has_query and similarity < floor and lexical == 0.0 and tag_boost == 0.0) continue;
        try results.append(allocator, .{ .memory_index = i, .score = score, .similarity = similarity });
    }

    std.mem.sort(SearchResult, results.items, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const count = @min(limit, results.items.len);
    return try allocator.dupe(SearchResult, results.items[0..count]);
}

pub fn cosine(a: []const f32, b: []const f32) f32 {
    const count = @min(a.len, b.len);
    var dot: f32 = 0.0;
    var i: usize = 0;
    while (i < count) : (i += 1) dot += a[i] * b[i];
    return dot;
}

fn hasRequiredTags(memory: schema.MemoryRecord, tags: []const []const u8) bool {
    for (tags) |tag| {
        var found = false;
        for (memory.tags) |memory_tag| {
            if (std.ascii.eqlIgnoreCase(memory_tag, tag)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn tagOverlapBoost(memory: schema.MemoryRecord, tags: []const []const u8) f32 {
    var boost: f32 = 0.0;
    for (tags) |tag| {
        for (memory.tags) |memory_tag| {
            if (std.ascii.eqlIgnoreCase(memory_tag, tag)) {
                boost += 0.18;
                break;
            }
        }
    }
    return boost;
}

fn lexicalMatch(memory: schema.MemoryRecord, query: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(memory.text, query) != null or std.ascii.indexOfIgnoreCase(memoryInterpretation(memory), query) != null;
}

fn memoryInterpretation(memory: schema.MemoryRecord) []const u8 {
    if (memory.interpretation.len > 0) return memory.interpretation;
    return memory.text;
}

fn memoryEmbeddingText(allocator: std.mem.Allocator, memory: schema.MemoryRecord) ![]const u8 {
    const interpretation = memoryInterpretation(memory);
    if (memory.tags.len == 0) return allocator.dupe(u8, interpretation);
    var tagged = std.ArrayList(u8).empty;
    defer tagged.deinit(allocator);
    try tagged.appendSlice(allocator, interpretation);
    for (memory.tags) |tag| {
        try tagged.append(allocator, ' ');
        try tagged.appendSlice(allocator, tag);
    }
    return tagged.toOwnedSlice(allocator);
}

test "vector search ranks semantically adjacent words above unrelated memories" {
    const allocator = std.testing.allocator;
    var test_service = embedding_mod.TestEmbeddingService{};
    const service = test_service.service();
    const memories = [_]schema.MemoryRecord{
        .{
            .memory_id = "memory_plants",
            .scope = .long_term,
            .text = "Plants need morning checks and water",
            .interpretation = "Plants need morning checks and water",
            .tags = @constCast(&[_][]const u8{"plants"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = 4,
            .salience = 0.7,
        },
        .{
            .memory_id = "memory_music",
            .scope = .long_term,
            .text = "Zelda likes quiet piano music",
            .interpretation = "Zelda likes quiet piano music",
            .tags = @constCast(&[_][]const u8{"music"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = 4,
            .salience = 0.7,
        },
    };
    const results = try search(allocator, service, &memories, "morning plant care", &[_][]const u8{}, 3);
    defer allocator.free(results);
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqual(@as(usize, 0), results[0].memory_index);
}

test "search requires explicit tags even when query text is close" {
    const allocator = std.testing.allocator;
    var test_service = embedding_mod.TestEmbeddingService{};
    const service = test_service.service();
    const memories = [_]schema.MemoryRecord{
        .{
            .memory_id = "memory_plants_home",
            .scope = .long_term,
            .text = "Plants need morning checks at home",
            .interpretation = "Plants need morning checks at home",
            .tags = @constCast(&[_][]const u8{"home"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
        },
        .{
            .memory_id = "memory_plants_work",
            .scope = .long_term,
            .text = "Plants need morning checks at work",
            .interpretation = "Plants need morning checks at work",
            .tags = @constCast(&[_][]const u8{"work"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
        },
    };
    const results = try search(allocator, service, &memories, "plants morning", &[_][]const u8{"work"}, 8);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(usize, 1), results[0].memory_index);
}
