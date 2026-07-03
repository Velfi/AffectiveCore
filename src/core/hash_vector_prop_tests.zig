const std = @import("std");
const hash_vector = @import("hash_vector.zig");

fn magnitude(vector: []const f32) f32 {
    var total: f32 = 0.0;
    for (vector) |value| total += value * value;
    return @sqrt(total);
}

fn randomText(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    const len = random.intRangeLessThan(usize, 0, 256);
    const text = try allocator.alloc(u8, len);
    switch (random.intRangeLessThan(u8, 0, 3)) {
        0 => random.bytes(text),
        1 => for (text) |*byte| {
            byte.* = random.intRangeAtMost(u8, 'a', 'z');
        },
        else => for (text) |*byte| {
            byte.* = if (random.boolean()) random.intRangeAtMost(u8, 'a', 'z') else ' ';
        },
    }
    return text;
}

test "hash vector embeddings are always finite unit-or-zero vectors" {
    var prng = std.Random.DefaultPrng.init(0x686173685f766563);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 2048) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const text = try randomText(allocator, random);
        var tags_buf: [3][]const u8 = undefined;
        const tag_count = random.intRangeLessThan(usize, 0, tags_buf.len + 1);
        for (tags_buf[0..tag_count]) |*tag| tag.* = try randomText(allocator, random);

        const vector = try hash_vector.embed(allocator, text, tags_buf[0..tag_count]);
        try std.testing.expectEqual(hash_vector.dimensions, vector.len);
        for (vector) |value| try std.testing.expect(std.math.isFinite(value));

        const size = magnitude(vector);
        try std.testing.expect(size == 0.0 or @abs(size - 1.0) < 1e-3);

        // Cosine of a vector with itself is its squared magnitude: 0 or ~1,
        // and identical inputs must embed identically.
        const again = try hash_vector.embed(allocator, text, tags_buf[0..tag_count]);
        try std.testing.expectEqualSlices(f32, vector, again);
        const self_similarity = hash_vector.cosine(vector, vector);
        try std.testing.expect(self_similarity == 0.0 or @abs(self_similarity - 1.0) < 1e-3);
    }
}

test "hash vector cosine is symmetric, bounded, and length-safe" {
    var prng = std.Random.DefaultPrng.init(0x636f73696e65);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 2048) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const a = try hash_vector.embed(allocator, try randomText(allocator, random), &.{});
        const b = try hash_vector.embed(allocator, try randomText(allocator, random), &.{});

        const ab = hash_vector.cosine(a, b);
        try std.testing.expect(std.math.isFinite(ab));
        try std.testing.expect(@abs(ab) <= 1.0 + 1e-4);
        try std.testing.expectEqual(ab, hash_vector.cosine(b, a));

        // Mismatched and empty operands must not read out of bounds.
        const half = hash_vector.cosine(a[0 .. a.len / 2], b);
        try std.testing.expect(std.math.isFinite(half));
        try std.testing.expectEqual(@as(f32, 0.0), hash_vector.cosine(a, &.{}));
        try std.testing.expectEqual(@as(f32, 0.0), hash_vector.cosine(&.{}, &.{}));
    }
}
