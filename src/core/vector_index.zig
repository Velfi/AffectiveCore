const std = @import("std");
const schema = @import("../storage/schema.zig");

pub const dimensions: usize = 64;

pub const SearchResult = struct {
    memory_index: usize,
    score: f32,
    similarity: f32,
};

pub fn embedMemory(allocator: std.mem.Allocator, memory: schema.MemoryRecord) ![]f32 {
    return embed(allocator, memoryInterpretation(memory), memory.tags);
}

pub fn embedQuery(allocator: std.mem.Allocator, query: []const u8, tags: []const []const u8) ![]f32 {
    return embed(allocator, query, tags);
}

pub fn search(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    query: []const u8,
    tags: []const []const u8,
    limit: usize,
) ![]SearchResult {
    var results = std.ArrayList(SearchResult).empty;
    defer results.deinit(allocator);
    const query_vector = try embedQuery(allocator, query, tags);
    defer allocator.free(query_vector);
    const has_query = std.mem.trim(u8, query, " \r\n\t").len > 0;

    for (memories, 0..) |memory, i| {
        if (!hasRequiredTags(memory, tags)) continue;
        const vector = if (memory.vector.len == dimensions) memory.vector else try embedMemory(allocator, memory);
        defer if (memory.vector.len != dimensions) allocator.free(vector);
        const similarity = if (has_query) cosine(query_vector, vector) else @as(f32, 0.0);
        const lexical = if (has_query and lexicalMatch(memory, query)) @as(f32, 0.28) else @as(f32, 0.0);
        const tag_boost = tagOverlapBoost(memory, tags);
        const durability = @min(@as(f32, 0.12), @as(f32, @floatFromInt(@max(memory.score, 0))) * 0.012);
        const salience = memory.salience * 0.08;
        const recency = if (memory.scope == .long_term) @as(f32, 0.04) else @as(f32, 0.0);
        const score = if (has_query) similarity + lexical + tag_boost + durability + salience + recency else tag_boost + durability + salience + recency;
        if (!has_query and tags.len == 0) continue;
        if (has_query and similarity < 0.08 and lexical == 0.0 and tag_boost == 0.0) continue;
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

fn embed(allocator: std.mem.Allocator, text: []const u8, tags: []const []const u8) ![]f32 {
    const vector = try allocator.alloc(f32, dimensions);
    @memset(vector, 0.0);
    addText(vector, text, 1.0);
    for (tags) |tag| addText(vector, tag, 1.35);
    normalize(vector);
    return vector;
}

fn addText(vector: []f32, text: []const u8, weight: f32) void {
    var token_buf: [64]u8 = undefined;
    var token_len: usize = 0;
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (token_len < token_buf.len) {
                token_buf[token_len] = std.ascii.toLower(byte);
                token_len += 1;
            }
        } else {
            addToken(vector, token_buf[0..token_len], weight);
            token_len = 0;
        }
    }
    addToken(vector, token_buf[0..token_len], weight);
}

fn addToken(vector: []f32, token: []const u8, weight: f32) void {
    const trimmed = stem(token);
    if (trimmed.len < 2 or isStopWord(trimmed)) return;
    vector[hashToken(trimmed) % dimensions] += weight;
    if (trimmed.len >= 5) {
        var i: usize = 0;
        while (i + 3 <= trimmed.len) : (i += 1) {
            vector[hashToken(trimmed[i .. i + 3]) % dimensions] += weight * 0.25;
        }
    }
}

fn stem(token: []const u8) []const u8 {
    if (token.len > 5 and std.mem.endsWith(u8, token, "ing")) return token[0 .. token.len - 3];
    if (token.len > 4 and std.mem.endsWith(u8, token, "ed")) return token[0 .. token.len - 2];
    if (token.len > 4 and std.mem.endsWith(u8, token, "es")) return token[0 .. token.len - 2];
    if (token.len > 3 and std.mem.endsWith(u8, token, "s")) return token[0 .. token.len - 1];
    return token;
}

fn normalize(vector: []f32) void {
    var magnitude: f32 = 0.0;
    for (vector) |value| magnitude += value * value;
    if (magnitude == 0.0) return;
    const scale = @sqrt(magnitude);
    for (vector) |*value| value.* /= scale;
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

fn hashToken(token: []const u8) usize {
    var hash: u64 = 14695981039346656037;
    for (token) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return @as(usize, @truncate(hash));
}

fn isStopWord(token: []const u8) bool {
    const words = [_][]const u8{ "the", "and", "for", "you", "your", "are", "was", "were", "with", "that", "this", "from", "have", "has", "had", "but", "not", "can", "will", "would", "should", "about", "into", "onto", "over", "under", "she", "him", "her", "his", "they", "them", "our", "out" };
    for (words) |word| if (std.mem.eql(u8, token, word)) return true;
    return false;
}

test "vector search ranks semantically adjacent words above unrelated memories" {
    const allocator = std.testing.allocator;
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
    const results = try search(allocator, &memories, "morning plant care", &[_][]const u8{}, 3);
    defer allocator.free(results);
    try std.testing.expect(results.len > 0);
    try std.testing.expectEqual(@as(usize, 0), results[0].memory_index);
}

test "embeddings are deterministic and normalized" {
    const allocator = std.testing.allocator;
    const first = try embedQuery(allocator, "Plants need morning water!", &[_][]const u8{"plants"});
    defer allocator.free(first);
    const second = try embedQuery(allocator, "Plants need morning water!", &[_][]const u8{"plants"});
    defer allocator.free(second);

    var magnitude: f32 = 0.0;
    for (first, second) |a, b| {
        try std.testing.expectEqual(a, b);
        magnitude += a * a;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), magnitude, 0.0001);
}

test "empty and stopword-only text produces a zero vector" {
    const allocator = std.testing.allocator;
    const vector = try embedQuery(allocator, "the and for you", &[_][]const u8{});
    defer allocator.free(vector);
    for (vector) |value| try std.testing.expectEqual(@as(f32, 0.0), value);
}

test "search requires explicit tags even when query text is close" {
    const allocator = std.testing.allocator;
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
    const results = try search(allocator, &memories, "plants morning", &[_][]const u8{"work"}, 8);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(usize, 1), results[0].memory_index);
}

test "tag-only search returns tagged memories ordered by boosts and limit" {
    const allocator = std.testing.allocator;
    const memories = [_]schema.MemoryRecord{
        .{
            .memory_id = "memory_low_score",
            .scope = .short_term,
            .text = "Low score plant note",
            .tags = @constCast(&[_][]const u8{"plants"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = 1,
            .salience = 0.3,
        },
        .{
            .memory_id = "memory_high_score",
            .scope = .long_term,
            .text = "High score plant note",
            .tags = @constCast(&[_][]const u8{"plants"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 4,
            .score = 9,
            .salience = 0.9,
        },
        .{
            .memory_id = "memory_unrelated",
            .scope = .long_term,
            .text = "Music note",
            .tags = @constCast(&[_][]const u8{"music"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
        },
    };
    const results = try search(allocator, &memories, "", &[_][]const u8{"plants"}, 1);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(usize, 1), results[0].memory_index);
    try std.testing.expectEqual(@as(f32, 0.0), results[0].similarity);
}

test "search with no query and no tags returns no memories" {
    const allocator = std.testing.allocator;
    const memories = [_]schema.MemoryRecord{
        .{
            .memory_id = "memory_any",
            .scope = .long_term,
            .text = "Anything",
            .tags = @constCast(&[_][]const u8{"note"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
        },
    };
    const results = try search(allocator, &memories, "   ", &[_][]const u8{}, 8);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}
