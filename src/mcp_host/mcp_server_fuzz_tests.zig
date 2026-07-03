const std = @import("std");
const mcp_server = @import("mcp_server.zig");
const json_fuzz = @import("../harness/json_fuzz.zig");

const classifyRequest = mcp_server.classifyRequest;

fn classify(allocator: std.mem.Allocator, request_json: []const u8) !mcp_server.RequestShape {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, request_json, .{});
    return classifyRequest(parsed.value);
}

test "mcp request classification rejects malformed request shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_corpus = [_]struct { request: []const u8, code: i32 }{
        .{ .request = "null", .code = -32600 },
        .{ .request = "[]", .code = -32600 },
        .{ .request = "42", .code = -32600 },
        .{ .request = "\"initialize\"", .code = -32600 },
        .{ .request = "{}", .code = -32600 },
        .{ .request = "{\"id\":1}", .code = -32600 },
        .{ .request = "{\"method\":42,\"id\":1}", .code = -32600 },
        .{ .request = "{\"method\":null}", .code = -32600 },
        .{ .request = "{\"method\":\"tools/call\",\"id\":1}", .code = -32602 },
        .{ .request = "{\"method\":\"tools/call\",\"id\":1,\"params\":[]}", .code = -32602 },
        .{ .request = "{\"method\":\"tools/call\",\"id\":1,\"params\":{}}", .code = -32602 },
        .{ .request = "{\"method\":\"tools/call\",\"id\":1,\"params\":{\"name\":17}}", .code = -32602 },
        .{ .request = "{\"method\":\"no_such_method\",\"id\":1}", .code = -32601 },
    };
    for (invalid_corpus) |case| {
        const shape = try classify(allocator, case.request);
        try std.testing.expect(shape == .invalid);
        try std.testing.expectEqual(case.code, shape.invalid.code);
    }
}

test "mcp request classification accepts well-formed requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(try classify(allocator, "{\"method\":\"initialize\",\"id\":1}") == .initialize);
    try std.testing.expect(try classify(allocator, "{\"method\":\"tools/list\",\"id\":\"a\"}") == .tools_list);
    try std.testing.expect(try classify(allocator, "{\"method\":\"notifications/initialized\"}") == .notification);

    const call = try classify(allocator, "{\"method\":\"tools/call\",\"id\":1,\"params\":{\"name\":\"user_text\",\"arguments\":{\"text\":\"hi\"}}}");
    try std.testing.expect(call == .tools_call);
    try std.testing.expectEqualStrings("user_text", call.tools_call.name);
}

test "mcp request classification survives fuzzed json requests" {
    var prng = std.Random.DefaultPrng.init(0x6d63705f667a);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 2048) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var out = std.ArrayList(u8).empty;
        try json_fuzz.appendRandomValue(allocator, &out, random, 3);
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, out.items, .{}) catch continue;
        const shape = classifyRequest(parsed.value);
        // Any classification is acceptable; the property is that no input panics
        // and invalid shapes always carry a JSON-RPC error code.
        if (shape == .invalid) try std.testing.expect(shape.invalid.code < 0);
    }
}
