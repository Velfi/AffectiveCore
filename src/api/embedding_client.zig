const std = @import("std");
const http_transport = @import("http_transport.zig");
const embedding_port = @import("../core/port_embedding.zig");

pub const host_embed_compute_url = "affective-host://embed/compute";

pub const HostEmbeddingClient = struct {
    http: http_transport.Client,

    pub fn service(self: *HostEmbeddingClient) embedding_port.EmbeddingService {
        return .{
            .ctx = self,
            .dimensionsFn = dimensions,
            .embedQueryFn = embedQuery,
            .embedBatchFn = embedBatch,
        };
    }

    fn dimensions(ctx: *anyopaque) usize {
        _ = ctx;
        return 512;
    }

    fn embedQuery(ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8, tags: []const []const u8) ![]f32 {
        var tagged = std.ArrayList(u8).empty;
        defer tagged.deinit(allocator);
        try tagged.appendSlice(allocator, text);
        for (tags) |tag| {
            try tagged.append(allocator, ' ');
            try tagged.appendSlice(allocator, tag);
        }
        const batch = try embedBatch(ctx, allocator, &[_][]const u8{tagged.items});
        defer {
            for (batch) |vector| allocator.free(vector);
            allocator.free(batch);
        }
        if (batch.len == 0) return error.EmptyEmbeddingBatch;
        return try allocator.dupe(f32, batch[0]);
    }

    fn embedBatch(ctx: *anyopaque, allocator: std.mem.Allocator, texts: []const []const u8) ![][]f32 {
        const self: *HostEmbeddingClient = @ptrCast(@alignCast(ctx));
        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);
        try body.append(allocator, '{');
        try body.appendSlice(allocator, "\"texts\":[");
        for (texts, 0..) |text, i| {
            if (i > 0) try body.append(allocator, ',');
            try appendJsonString(allocator, &body, text);
        }
        try body.appendSlice(allocator, "]}");
        const response = try postJson(allocator, self.http, host_embed_compute_url, body.items);
        defer allocator.free(response);
        return try parseEmbeddingResponse(allocator, response);
    }
};

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |byte| {
        switch (byte) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, byte),
        }
    }
    try out.append(allocator, '"');
}

const WireResponse = struct {
    dimensions: usize,
    vectors: []const []const f64,
};

fn parseEmbeddingResponse(allocator: std.mem.Allocator, body: []const u8) ![][]f32 {
    const parsed = try std.json.parseFromSlice(WireResponse, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.vectors.len == 0) return error.EmptyEmbeddingBatch;
    var out = try allocator.alloc([]f32, parsed.value.vectors.len);
    errdefer {
        for (out) |vector| allocator.free(vector);
        allocator.free(out);
    }
    for (parsed.value.vectors, 0..) |wire, i| {
        out[i] = try allocator.alloc(f32, wire.len);
        for (wire, 0..) |value, j| out[i][j] = @floatCast(value);
    }
    return out;
}

fn postJson(allocator: std.mem.Allocator, http: http_transport.Client, url: []const u8, body: []const u8) ![]u8 {
    return http.postJson(allocator, .{ .url = url, .body = body });
}
