const std = @import("std");
const session_mod = @import("session.zig");
const requests = @import("requests.zig");

const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: std.json.Value,
};

pub fn run(init: std.process.Init, session: *session_mod.Session) !void {
    const allocator = init.arena.allocator();
    var stdin_buffer: [8192]u8 = undefined;
    var stdin_file_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    while (try readMessage(allocator, stdin_reader)) |request_bytes| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{}) catch {
            const response = try std.json.Stringify.valueAlloc(allocator, ErrorResponse{ .id = .null, .@"error" = .{ .code = -32700, .message = "parse error" } }, .{});
            try sendMessage(init.io, response);
            continue;
        };
        defer parsed.deinit();
        if (try handleRequest(allocator, session, parsed.value)) |response| {
            try sendMessage(init.io, response);
        }
    }
}

pub const RequestShape = union(enum) {
    initialize: std.json.Value,
    tools_list: std.json.Value,
    tools_call: struct { id: std.json.Value, name: []const u8, arguments: std.json.Value },
    notification,
    invalid: struct { id: std.json.Value, code: i32, message: []const u8 },
};

pub fn classifyRequest(request: std.json.Value) RequestShape {
    if (request != .object) return .{ .invalid = .{ .id = .null, .code = -32600, .message = "request must be an object" } };
    const object = request.object;
    const id = object.get("id") orelse std.json.Value.null;
    const method_value = object.get("method") orelse return .{ .invalid = .{ .id = id, .code = -32600, .message = "missing method" } };
    if (method_value != .string) return .{ .invalid = .{ .id = id, .code = -32600, .message = "method must be a string" } };
    const method = method_value.string;
    if (std.mem.eql(u8, method, "initialize")) return .{ .initialize = id };
    if (std.mem.eql(u8, method, "tools/list")) return .{ .tools_list = id };
    if (std.mem.eql(u8, method, "tools/call")) {
        const params_value = object.get("params") orelse return .{ .invalid = .{ .id = id, .code = -32602, .message = "missing params" } };
        if (params_value != .object) return .{ .invalid = .{ .id = id, .code = -32602, .message = "params must be an object" } };
        const params = params_value.object;
        const name_value = params.get("name") orelse return .{ .invalid = .{ .id = id, .code = -32602, .message = "missing tool name" } };
        if (name_value != .string) return .{ .invalid = .{ .id = id, .code = -32602, .message = "tool name must be a string" } };
        const args = params.get("arguments") orelse std.json.Value.null;
        return .{ .tools_call = .{ .id = id, .name = name_value.string, .arguments = args } };
    }
    if (object.get("id") == null) return .notification;
    return .{ .invalid = .{ .id = id, .code = -32601, .message = "unknown method" } };
}

fn handleRequest(allocator: std.mem.Allocator, session: *session_mod.Session, request: std.json.Value) !?[]u8 {
    switch (classifyRequest(request)) {
        .initialize => |id| return try std.json.Stringify.valueAlloc(allocator, InitializeResponse{ .id = id }, .{}),
        .tools_list => |id| return try std.json.Stringify.valueAlloc(allocator, ToolsResponse{ .id = id, .result = .{ .tools = try tools(allocator) } }, .{}),
        .tools_call => |call| {
            const result_json = dispatchTool(allocator, session, call.name, call.arguments) catch |err| {
                const message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
                return try std.json.Stringify.valueAlloc(allocator, ErrorResponse{ .id = call.id, .@"error" = .{ .code = -32000, .message = message } }, .{});
            };
            defer allocator.free(result_json);
            const content = [_]TextContent{.{ .text = result_json }};
            return try std.json.Stringify.valueAlloc(allocator, ToolResponse{ .id = call.id, .result = .{ .content = &content } }, .{});
        },
        .notification => return null,
        .invalid => |invalid| return try std.json.Stringify.valueAlloc(allocator, ErrorResponse{ .id = invalid.id, .@"error" = .{ .code = invalid.code, .message = invalid.message } }, .{}),
    }
}

fn dispatchTool(allocator: std.mem.Allocator, session: *session_mod.Session, name: []const u8, args: std.json.Value) ![]u8 {
    const request_id = getString(args, "request_id") orelse "mcp-tool";
    if (std.mem.eql(u8, name, "connect")) {
        const json = try requests.connect(request_id);
        defer std.heap.page_allocator.free(json);
        const response = try session.dispatch(json);
        return try allocator.dupe(u8, response);
    }
    if (std.mem.eql(u8, name, "host_attach")) {
        const host_id = getString(args, "host_id") orelse "mcp-host";
        const json = try requests.hostAttach(request_id, host_id);
        defer std.heap.page_allocator.free(json);
        const response = try session.dispatch(json);
        return try allocator.dupe(u8, response);
    }
    if (std.mem.eql(u8, name, "user_text")) {
        const text = getString(args, "text") orelse return error.MissingText;
        const json = try requests.userText(request_id, text);
        defer std.heap.page_allocator.free(json);
        const response = try session.dispatch(json);
        return try allocator.dupe(u8, response);
    }
    if (std.mem.eql(u8, name, "short_touch")) {
        const json = try requests.shortTouch(request_id);
        defer std.heap.page_allocator.free(json);
        const response = try session.dispatch(json);
        return try allocator.dupe(u8, response);
    }
    if (std.mem.eql(u8, name, "sense_observation")) {
        const image_path = getString(args, "image_path") orelse return error.MissingImagePath;
        const json = try requests.senseObservationCamera(request_id, image_path);
        defer std.heap.page_allocator.free(json);
        const response = try session.dispatch(json);
        return try allocator.dupe(u8, response);
    }
    if (std.mem.eql(u8, name, "read_models_snapshot")) {
        const json = try requests.readModelsSnapshot(request_id);
        defer std.heap.page_allocator.free(json);
        const response = try session.dispatch(json);
        return try allocator.dupe(u8, response);
    }
    if (std.mem.eql(u8, name, "drain")) {
        const response = try session.drain();
        return try allocator.dupe(u8, response);
    }
    return error.UnknownOperation;
}

fn tools(allocator: std.mem.Allocator) ![]const Tool {
    const specs = [_]struct { name: []const u8, description: []const u8, schema_json: []const u8 }{
        .{ .name = "connect", .description = "Embedded connect event.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
        .{ .name = "host_attach", .description = "Attach mock host binding.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"},\"host_id\":{\"type\":\"string\"}}}" },
        .{ .name = "user_text", .description = "Deliver typed user text.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"request_id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "short_touch", .description = "Deliver short touch activation.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
        .{ .name = "sense_observation", .description = "Resume with a camera observation.", .schema_json = "{\"type\":\"object\",\"required\":[\"image_path\"],\"properties\":{\"request_id\":{\"type\":\"string\"},\"image_path\":{\"type\":\"string\"}}}" },
        .{ .name = "read_models_snapshot", .description = "Read compact brain models.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
        .{ .name = "drain", .description = "Drain queued host/brain events.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
    };
    const out = try allocator.alloc(Tool, specs.len);
    for (specs, 0..) |spec, i| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, spec.schema_json, .{});
        out[i] = .{ .name = spec.name, .description = spec.description, .inputSchema = parsed };
    }
    return out;
}

fn getString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

const TextContent = struct { type: []const u8 = "text", text: []const u8 };
const ToolResult = struct { content: []const TextContent };
const InitializeResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: struct {
        protocolVersion: []const u8 = "2024-11-05",
        capabilities: struct { tools: struct {} = .{} } = .{},
        serverInfo: struct { name: []const u8 = "mcp-host", version: []const u8 = "0.1.0" } = .{},
    } = .{},
};
const ToolsResponse = struct { jsonrpc: []const u8 = "2.0", id: std.json.Value, result: struct { tools: []const Tool } };
const ToolResponse = struct { jsonrpc: []const u8 = "2.0", id: std.json.Value, result: ToolResult };
const ErrorResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    @"error": struct { code: i32, message: []const u8 },
};

fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var content_length: usize = 0;
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse return null;
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) {
            const value = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
    }
    if (content_length == 0) return null;
    const body = try allocator.alloc(u8, content_length);
    try reader.readSliceAll(body);
    return body;
}

fn sendMessage(io: std.Io, body: []const u8) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const writer = &stdout_file_writer.interface;
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try writer.flush();
}
