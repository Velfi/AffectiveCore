const std = @import("std");

pub const dimensions: usize = 64;

pub fn embed(allocator: std.mem.Allocator, text: []const u8, tags: []const []const u8) ![]f32 {
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

pub fn cosine(a: []const f32, b: []const f32) f32 {
    const count = @min(a.len, b.len);
    var dot: f32 = 0.0;
    var i: usize = 0;
    while (i < count) : (i += 1) dot += a[i] * b[i];
    return dot;
}
