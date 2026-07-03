const std = @import("std");

const mcp_host = @import("mcp_host/mod.zig");

const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: std.json.Value,
};

const TextContent = struct { type: []const u8 = "text", text: []const u8 };
const ToolResult = struct { content: []const TextContent };

const InitializeResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: struct {
        protocolVersion: []const u8 = "2024-11-05",
        capabilities: struct { tools: struct {} = .{} } = .{},
        serverInfo: struct { name: []const u8 = "Affective MCP Stdio", version: []const u8 = "0.1.0" } = .{},
    } = .{},
};

const ToolsResponse = struct { jsonrpc: []const u8 = "2.0", id: std.json.Value, result: struct { tools: []const Tool } };
const ToolResponse = struct { jsonrpc: []const u8 = "2.0", id: std.json.Value, result: ToolResult };
const ErrorResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    @"error": struct { code: i32, message: []const u8 },
};
const ShutdownResult = struct { ok: bool = true, shutdown: bool = true };

const Options = struct {
    brain_root: []const u8 = "data/affective-mcp-stdio/default",
    brain_id: []const u8 = "affective-mcp-stdio",
    manifest_path: []const u8 = "fixtures/embedded_api/manifest_macos.json",
    conversation_models: []const u8 = "openai:gpt-4.1-nano",
    conversation_reasoning_effort: []const u8 = "",
    image_generation_model: []const u8 = "",
    image_generation_output_dir: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    const options = try parseOptions(&args);

    var session = try openCodexSession(init.io, init.environ_map, options, .live);
    defer session.deinit();
    try session.setupHost();

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_file_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    while (try readMcpMessage(allocator, stdin_reader)) |request_bytes| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{}) catch {
            const response = try std.json.Stringify.valueAlloc(allocator, ErrorResponse{ .id = .null, .@"error" = .{ .code = -32700, .message = "parse error" } }, .{});
            try sendMcpMessage(init.io, response);
            continue;
        };
        defer parsed.deinit();
        var shutdown = false;
        if (try handleMcpRequest(allocator, &session, parsed.value, &shutdown)) |response| {
            try sendMcpMessage(init.io, response);
        }
        if (shutdown) break;
    }
}

fn openCodexSession(
    io: std.Io,
    env: *const std.process.Environ.Map,
    options: Options,
    host_mode: mcp_host.session.Options.HostMode,
) !mcp_host.session.Session {
    return try mcp_host.session.Session.openWithEnv(io, env, .{
        .brain_root = options.brain_root,
        .brain_id = options.brain_id,
        .manifest_path = options.manifest_path,
        .conversation_models = options.conversation_models,
        .conversation_reasoning_effort = options.conversation_reasoning_effort,
        .image_generation_model = options.image_generation_model,
        .image_generation_output_dir = options.image_generation_output_dir,
        .host_mode = host_mode,
    });
}

fn parseOptions(args: *std.process.Args.Iterator) !Options {
    _ = args.next();
    var options = Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--brain-root")) {
            options.brain_root = args.next() orelse return error.MissingBrainRootArgument;
        } else if (std.mem.eql(u8, arg, "--brain-id")) {
            options.brain_id = args.next() orelse return error.MissingBrainIdArgument;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            options.manifest_path = args.next() orelse return error.MissingManifestArgument;
        } else if (std.mem.eql(u8, arg, "--models")) {
            options.conversation_models = args.next() orelse return error.MissingModelsArgument;
        } else if (std.mem.eql(u8, arg, "--reasoning-effort")) {
            options.conversation_reasoning_effort = args.next() orelse return error.MissingReasoningEffortArgument;
        } else if (std.mem.eql(u8, arg, "--image-model")) {
            options.image_generation_model = args.next() orelse return error.MissingImageModelArgument;
        } else if (std.mem.eql(u8, arg, "--image-output-dir")) {
            options.image_generation_output_dir = args.next() orelse return error.MissingImageOutputDirArgument;
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else {
            std.debug.print("Unknown affective-mcp-stdio flag: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return options;
}

fn handleMcpRequest(allocator: std.mem.Allocator, session: *mcp_host.session.Session, request: std.json.Value, shutdown: *bool) !?[]u8 {
    if (request != .object) return try mcpError(allocator, .null, -32600, "request must be an object");
    const object = request.object;
    const id = object.get("id") orelse std.json.Value.null;
    const method = try requireStringValue(object.get("method"));
    if (std.mem.eql(u8, method, "initialize")) return try std.json.Stringify.valueAlloc(allocator, InitializeResponse{ .id = id }, .{});
    if (std.mem.eql(u8, method, "tools/list")) return try std.json.Stringify.valueAlloc(allocator, ToolsResponse{ .id = id, .result = .{ .tools = try tools(allocator) } }, .{});
    if (std.mem.eql(u8, method, "tools/call")) {
        const params_value = object.get("params") orelse return try mcpError(allocator, id, -32602, "missing params");
        const params = try expectObject(params_value);
        const name = try requireStringValue(params.get("name"));
        const args = params.get("arguments") orelse std.json.Value.null;
        const result_json = dispatchTool(allocator, session, name, args, shutdown) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            return try mcpError(allocator, id, -32000, message);
        };
        defer allocator.free(result_json);
        const content = [_]TextContent{.{ .text = result_json }};
        return try std.json.Stringify.valueAlloc(allocator, ToolResponse{ .id = id, .result = .{ .content = &content } }, .{});
    }
    if (object.get("id") == null) return null;
    return try mcpError(allocator, id, -32601, "unknown method");
}

fn dispatchTool(allocator: std.mem.Allocator, session: *mcp_host.session.Session, name: []const u8, args: std.json.Value, shutdown: *bool) ![]u8 {
    const request_id = getString(args, "request_id") orelse "affective-mcp-stdio-tool";
    const response = blk: {
        if (std.mem.eql(u8, name, "connect")) {
            const json = try mcp_host.requests.connect(request_id);
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "host_attach")) {
            const json = try mcp_host.requests.hostAttach(request_id, getString(args, "host_id") orelse "affective-mcp-stdio");
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "user_text")) {
            const json = try mcp_host.requests.userText(request_id, getString(args, "text") orelse return error.MissingText);
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "short_touch")) {
            const json = try mcp_host.requests.shortTouch(request_id);
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "sense_observation")) {
            const json = try mcp_host.requests.senseObservationCamera(request_id, getString(args, "image_path") orelse return error.MissingImagePath);
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "read_models_snapshot")) {
            const json = try mcp_host.requests.readModelsSnapshot(request_id);
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "memory_inspect_safe")) {
            const json = try mcp_host.requests.readModelsSnapshot(request_id);
            defer std.heap.page_allocator.free(json);
            const snapshot = try session.dispatch(json);
            break :blk try mcp_host.admin_tools.memoryInspectSafe(session.arena.allocator(), snapshot, args);
        }
        if (std.mem.eql(u8, name, "session_metadata_get")) {
            break :blk try mcp_host.admin_tools.metadataGet(session.arena.allocator(), session.io, session.brain_root);
        }
        if (std.mem.eql(u8, name, "session_metadata_set")) {
            break :blk try mcp_host.admin_tools.metadataSet(session.arena.allocator(), session.io, session.brain_root, args);
        }
        if (std.mem.eql(u8, name, "export_brain")) {
            const json = try mcp_host.requests.exportBrain(request_id, getString(args, "brain_file_path") orelse getString(args, "output_path") orelse return error.MissingBrainFilePath);
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "conversation_text")) {
            break :blk try session.conversationText(getString(args, "text") orelse return error.MissingText, request_id);
        }
        if (std.mem.eql(u8, name, "brain_step")) {
            const json = try mcp_host.requests.brainStep(request_id);
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "request_dream_time")) {
            const json = try mcp_host.requests.requestDreamTime(request_id, getString(args, "text") orelse "");
            defer std.heap.page_allocator.free(json);
            break :blk try session.dispatch(json);
        }
        if (std.mem.eql(u8, name, "drain")) break :blk try session.drain();
        if (std.mem.eql(u8, name, "shutdown")) {
            shutdown.* = true;
            break :blk try std.json.Stringify.valueAlloc(session.arena.allocator(), ShutdownResult{}, .{ .whitespace = .indent_2 });
        }
        return error.UnknownOperation;
    };
    return try allocator.dupe(u8, response);
}

fn tools(allocator: std.mem.Allocator) ![]const Tool {
    const specs = [_]struct { name: []const u8, description: []const u8, schema_json: []const u8 }{
        .{ .name = "connect", .description = "Open a direct connection event with the embedded brain.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
        .{ .name = "host_attach", .description = "Attach Affective MCP Stdio as the active host.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"},\"host_id\":{\"type\":\"string\"}}}" },
        .{ .name = "user_text", .description = "Send text into the brain as speech stimulus.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"request_id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "short_touch", .description = "Send a short touch stimulus to the brain.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
        .{ .name = "sense_observation", .description = "Send a camera image observation to the brain.", .schema_json = "{\"type\":\"object\",\"required\":[\"image_path\"],\"properties\":{\"request_id\":{\"type\":\"string\"},\"image_path\":{\"type\":\"string\"}}}" },
        .{ .name = "read_models_snapshot", .description = "Read the brain's compact model snapshot.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
        .{ .name = "memory_inspect_safe", .description = "Read privacy-aware memory/session counts without raw memory text.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"},\"include_text\":{\"type\":\"boolean\"}}}" },
        .{ .name = "session_metadata_get", .description = "Read lightweight host session metadata such as active identity.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "session_metadata_set", .description = "Persist lightweight host session metadata such as active identity.", .schema_json = "{\"type\":\"object\",\"properties\":{\"active_identity\":{\"type\":\"string\"},\"continuity_thread\":{\"type\":\"string\"},\"notes\":{\"type\":\"string\"}}}" },
        .{ .name = "export_brain", .description = "Export Brain-owned state to a portable .brain archive without host secrets.", .schema_json = "{\"type\":\"object\",\"required\":[\"brain_file_path\"],\"properties\":{\"request_id\":{\"type\":\"string\"},\"brain_file_path\":{\"type\":\"string\"},\"output_path\":{\"type\":\"string\"}}}" },
        .{ .name = "conversation_text", .description = "Run a synchronous conversation turn and return the brain's spoken response.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"request_id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "brain_step", .description = "Run one embedded autonomy brain step.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
        .{ .name = "request_dream_time", .description = "Ask the brain to enter dream-time processing.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "drain", .description = "Drain queued brain and host events.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "shutdown", .description = "Cleanly shut down this stdio MCP session after returning.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
    };
    const out = try allocator.alloc(Tool, specs.len);
    for (specs, 0..) |spec, i| {
        out[i] = .{
            .name = spec.name,
            .description = spec.description,
            .inputSchema = try std.json.parseFromSliceLeaky(std.json.Value, allocator, spec.schema_json, .{}),
        };
    }
    return out;
}

fn readMcpMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var content_length: usize = 0;
    while (true) {
        const line = (try reader.takeDelimiter('\n')) orelse return null;
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "Content-Length:")) {
            content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, trimmed["Content-Length:".len..], " \t"), 10);
        }
    }
    if (content_length == 0) return null;
    const body = try allocator.alloc(u8, content_length);
    try reader.readSliceAll(body);
    return body;
}

fn sendMcpMessage(io: std.Io, body: []const u8) !void {
    var stdout_buffer: [8192]u8 = undefined;
    var stdout_file_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const writer = &stdout_file_writer.interface;
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    try writer.flush();
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.ExpectedObject;
    return value.object;
}

fn requireStringValue(value: ?std.json.Value) ![]const u8 {
    const actual = value orelse return error.MissingJsonField;
    if (actual != .string) return error.ExpectedString;
    return actual.string;
}

fn getString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn mcpError(allocator: std.mem.Allocator, id: std.json.Value, code: i32, message: []const u8) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, ErrorResponse{ .id = id, .@"error" = .{ .code = code, .message = message } }, .{});
}

test "tools/list includes Codex stdio tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const listed = try tools(allocator);
    const expected = [_][]const u8{ "connect", "host_attach", "user_text", "short_touch", "sense_observation", "read_models_snapshot", "memory_inspect_safe", "session_metadata_get", "session_metadata_set", "export_brain", "conversation_text", "brain_step", "request_dream_time", "drain", "shutdown" };
    for (expected) |name| {
        var found = false;
        for (listed) |tool| {
            if (std.mem.eql(u8, tool.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "read_models_snapshot returns ok true from embedded brain" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var session = try openCodexSession(std.testing.io, &env, .{
        .brain_root = "data/test/affective_mcp_stdio_read_models",
    }, .mock);
    defer session.deinit();
    try session.setupHost();

    var shutdown = false;
    const response = try dispatchTool(std.testing.allocator, &session, "read_models_snapshot", .null, &shutdown);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"event_type\": \"brain_read\"") != null);
}

test "user_text returns accepted stimulus_ingest" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var session = try openCodexSession(std.testing.io, &env, .{
        .brain_root = "data/test/affective_mcp_stdio_user_text",
    }, .mock);
    defer session.deinit();
    try session.setupHost();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"text\":\"hello from codex\"}", .{});
    defer parsed.deinit();
    var shutdown = false;
    const response = try dispatchTool(std.testing.allocator, &session, "user_text", parsed.value, &shutdown);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"event_type\": \"stimulus_ingest\"") != null);
}

test "conversation_text returns spoken response" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var session = try mcp_host.session.Session.openWithEnv(std.testing.io, &env, .{
        .brain_root = "data/test/affective_mcp_stdio_conversation_text",
        .fresh = true,
        .scenario = "touch_speak",
        .host_mode = .mock,
    });
    defer session.deinit();
    try session.setupHost();

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"text\":\"hello\"}", .{});
    defer parsed.deinit();
    var shutdown = false;
    const response = try dispatchTool(std.testing.allocator, &session, "conversation_text", parsed.value, &shutdown);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"spoken_text\": \"Hi there.\"") != null);
}

test "shutdown tool requests loop termination" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var session = try openCodexSession(std.testing.io, &env, .{
        .brain_root = "data/test/affective_mcp_stdio_shutdown",
    }, .mock);
    defer session.deinit();

    var shutdown = false;
    const response = try dispatchTool(std.testing.allocator, &session, "shutdown", .null, &shutdown);
    defer std.testing.allocator.free(response);
    try std.testing.expect(shutdown);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"shutdown\": true") != null);
}

test "stdio options reject TCP port flags" {
    try std.testing.expect(!@hasDecl(@This(), "connectLoopback"));
}
