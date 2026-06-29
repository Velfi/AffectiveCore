const std = @import("std");
const hash_vector = @import("hash_vector.zig");

pub const test_embedding_dimensions: usize = 512;

pub const EmbeddingService = struct {
    ctx: *anyopaque,
    dimensionsFn: *const fn (ctx: *anyopaque) usize,
    embedQueryFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8, tags: []const []const u8) anyerror![]f32,
    embedBatchFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, texts: []const []const u8) anyerror![][]f32,

    pub fn dimensions(self: EmbeddingService) usize {
        return self.dimensionsFn(self.ctx);
    }

    pub fn embedQuery(self: EmbeddingService, allocator: std.mem.Allocator, text: []const u8, tags: []const []const u8) ![]f32 {
        return self.embedQueryFn(self.ctx, allocator, text, tags);
    }

    pub fn embedBatch(self: EmbeddingService, allocator: std.mem.Allocator, texts: []const []const u8) ![][]f32 {
        return self.embedBatchFn(self.ctx, allocator, texts);
    }
};

pub const TestEmbeddingService = struct {
    pub fn service(self: *TestEmbeddingService) EmbeddingService {
        return .{
            .ctx = self,
            .dimensionsFn = dimensions,
            .embedQueryFn = embedQuery,
            .embedBatchFn = embedBatch,
        };
    }

    fn dimensions(_: *anyopaque) usize {
        return test_embedding_dimensions;
    }

    fn embedQuery(_: *anyopaque, allocator: std.mem.Allocator, text: []const u8, tags: []const []const u8) ![]f32 {
        return expandToTestDimensions(allocator, try hash_vector.embed(allocator, text, tags));
    }

    fn embedBatch(_: *anyopaque, allocator: std.mem.Allocator, texts: []const []const u8) ![][]f32 {
        var out = try allocator.alloc([]f32, texts.len);
        errdefer {
            for (out[0..texts.len]) |vector| allocator.free(vector);
            allocator.free(out);
        }
        for (texts, 0..) |text, i| {
            out[i] = try expandToTestDimensions(allocator, try hash_vector.embed(allocator, text, &.{}));
        }
        return out;
    }
};

fn expandToTestDimensions(allocator: std.mem.Allocator, compact: []f32) ![]f32 {
    defer allocator.free(compact);
    const vector = try allocator.alloc(f32, test_embedding_dimensions);
    @memset(vector, 0);
    const copy_len = @min(compact.len, vector.len);
    @memcpy(vector[0..copy_len], compact[0..copy_len]);
    var magnitude: f32 = 0;
    for (vector) |value| magnitude += value * value;
    if (magnitude > 0) {
        const scale = @sqrt(magnitude);
        for (vector) |*value| value.* /= scale;
    }
    return vector;
}
