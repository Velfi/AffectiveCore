const std = @import("std");

const files = @import("platform/common/files.zig");
const live_host = @import("mcp_host/live_host.zig");
const admin_tools = @import("mcp_host/admin_tools.zig");
const protocol = @import("session/protocol.zig");
const requests = @import("mcp_host/requests.zig");

const net = std.Io.net;
const posix = std.posix;

extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;

const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: std.json.Value,
};

const TextContent = struct { type: []const u8 = "text", text: []const u8 };
const ToolResult = struct { content: []const TextContent };
const ShutdownResult = struct { ok: bool = true, shutdown: bool = true };

const InitializeResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    result: struct {
        protocolVersion: []const u8 = "2024-11-05",
        capabilities: struct { tools: struct {} = .{} } = .{},
        serverInfo: struct { name: []const u8 = "Affective MCP", version: []const u8 = "0.1.0" } = .{},
    } = .{},
};

const ToolsResponse = struct { jsonrpc: []const u8 = "2.0", id: std.json.Value, result: struct { tools: []const Tool } };
const ToolResponse = struct { jsonrpc: []const u8 = "2.0", id: std.json.Value, result: ToolResult };
const ErrorResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: std.json.Value,
    @"error": struct { code: i32, message: []const u8 },
};

const Options = struct {
    port: u16 = 0,
    brain_root: []const u8 = "data/affective-mcp/default",
    brain_id: []const u8 = "affective-mcp",
    manifest_path: []const u8 = "fixtures/embedded_api/manifest_macos.json",
    conversation_models: []const u8 = "openai:gpt-4.1-nano",
    conversation_reasoning_effort: []const u8 = "",
    image_generation_model: []const u8 = "",
};

const BspClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    stream: net.Stream,
    host: live_host.LiveHost,
    next_request_id: usize = 1,

    fn init(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, stream: net.Stream, models: []const u8) BspClient {
        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .stream = stream,
            .host = live_host.LiveHost.init(io, env, models),
        };
    }

    fn deinit(self: *BspClient) void {
        self.host.deinit();
        self.stream.close(self.io);
    }

    fn createSession(self: *BspClient, reader: *std.Io.Reader, options: Options) !void {
        const manifest = try files.readFileAllocPath(self.io, options.manifest_path, self.allocator, .limited(1024 * 1024));
        const memory_path = try std.fs.path.join(self.allocator, &.{ options.brain_root, "memory/people.sqlite" });
        const graph_path = try std.fs.path.join(self.allocator, &.{ options.brain_root, "memory/relationships.sqlite" });
        const schedule_path = try std.fs.path.join(self.allocator, &.{ options.brain_root, "maintenance.md" });
        const maintenance_state_path = try std.fs.path.join(self.allocator, &.{ options.brain_root, "maintenance_state.json" });
        const face_embeddings_dir = try std.fs.path.join(self.allocator, &.{ options.brain_root, "memory/face_embeddings" });
        const image_output_dir = try std.fs.path.join(self.allocator, &.{ options.brain_root, "generated/images" });

        try ensureBrainLayout(self.io, options.brain_root);

        const request_id = "affective-mcp-session-create";
        try self.sendValue(.{
            .type = "session.create",
            .request_id = request_id,
            .config = protocol.SessionConfig{
                .brain_id = options.brain_id,
                .brain_root = options.brain_root,
                .conversation_models = options.conversation_models,
                .conversation_reasoning_effort = options.conversation_reasoning_effort,
                .image_generation_model = options.image_generation_model,
                .image_generation_output_dir = image_output_dir,
                .memory_path = memory_path,
                .graph_path = graph_path,
                .schedule_path = schedule_path,
                .maintenance_state_path = maintenance_state_path,
                .face_embeddings_dir = face_embeddings_dir,
                .host_manifest_json = manifest,
            },
        });
        try self.waitFor(request_id, "session.ready", reader);
        _ = try self.dispatch(reader, try requests.connect("affective-mcp-connect"));
        _ = try self.dispatch(reader, try hostAttachRequest("affective-mcp-attach", "affective-mcp"));
    }

    fn dispatch(self: *BspClient, reader: *std.Io.Reader, request_json: []const u8) ![]u8 {
        const request_id = try self.nextRequestId("dispatch");
        try self.sendValue(.{
            .type = "dispatch",
            .request_id = request_id,
            .request_json = request_json,
        });
        return try self.waitForPayload(request_id, "dispatch.result", reader);
    }

    fn drain(self: *BspClient, reader: *std.Io.Reader) ![]u8 {
        const request_id = try self.nextRequestId("drain");
        try self.sendValue(.{ .type = "drain", .request_id = request_id });
        return try self.waitForPayload(request_id, "drain.result", reader);
    }

    fn conversationText(self: *BspClient, reader: *std.Io.Reader, request_id: []const u8, text: []const u8) ![]u8 {
        try self.sendValue(.{
            .type = "conversation.text",
            .request_id = request_id,
            .text = text,
        });
        return try self.waitForPayload(request_id, "conversation.result", reader);
    }

    fn shutdown(self: *BspClient, reader: *std.Io.Reader) !void {
        const request_id = try self.nextRequestId("shutdown");
        try self.sendValue(.{ .type = "session.destroy", .request_id = request_id });
        try self.waitFor(request_id, "session.destroyed", reader);
    }

    fn nextRequestId(self: *BspClient, prefix: []const u8) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "affective-mcp-{s}-{d}", .{ prefix, self.next_request_id });
        self.next_request_id += 1;
        return id;
    }

    fn waitFor(self: *BspClient, request_id: []const u8, expected_type: []const u8, reader: *std.Io.Reader) !void {
        while (true) {
            var parsed = try self.readBspValue(reader);
            defer parsed.deinit();
            const object = try expectObject(parsed.value);
            const message_type = try requireStringValue(object.get("type"), "type");
            if (std.mem.eql(u8, message_type, "host.http.begin")) {
                try self.completeHostHttp(object);
                continue;
            }
            if (std.mem.eql(u8, message_type, "events.push")) continue;
            const id = object.get("request_id") orelse std.json.Value.null;
            if (!valueStringEql(id, request_id)) continue;
            if (std.mem.eql(u8, message_type, "dispatch.error")) return error.BspDispatchError;
            if (!std.mem.eql(u8, message_type, expected_type)) return error.UnexpectedBspResponse;
            return;
        }
    }

    fn waitForPayload(self: *BspClient, request_id: []const u8, expected_type: []const u8, reader: *std.Io.Reader) ![]u8 {
        while (true) {
            var parsed = try self.readBspValue(reader);
            defer parsed.deinit();
            const object = try expectObject(parsed.value);
            const message_type = try requireStringValue(object.get("type"), "type");
            if (std.mem.eql(u8, message_type, "host.http.begin")) {
                try self.completeHostHttp(object);
                continue;
            }
            if (std.mem.eql(u8, message_type, "events.push")) continue;
            const id = object.get("request_id") orelse std.json.Value.null;
            if (!valueStringEql(id, request_id)) continue;
            if (std.mem.eql(u8, message_type, "dispatch.error")) return error.BspDispatchError;
            if (!std.mem.eql(u8, message_type, expected_type)) return error.UnexpectedBspResponse;
            if (object.get("payload_json")) |payload| return try requireStringDupe(self.allocator, payload, "payload_json");
            if (object.get("envelope")) |envelope| return try std.json.Stringify.valueAlloc(self.allocator, envelope, .{ .whitespace = .indent_2 });
            return error.MissingBspPayload;
        }
    }

    fn completeHostHttp(self: *BspClient, object: std.json.ObjectMap) !void {
        const request_id = try requireStringValue(object.get("request_id"), "request_id");
        const url = try requireStringValue(object.get("url"), "url");
        const body_b64 = try requireStringValue(object.get("body_b64"), "body_b64");
        const body = try protocol.decodeBase64(self.allocator, body_b64);
        const result = self.host.completeRequest(url, body);
        if (result.error_msg.len > 0) {
            try self.sendValue(.{
                .type = "host.http.complete",
                .request_id = request_id,
                .status = "failed",
                .@"error" = result.error_msg,
            });
            return;
        }
        const response_b64 = try protocol.encodeBase64(self.allocator, result.response);
        try self.sendValue(.{
            .type = "host.http.complete",
            .request_id = request_id,
            .status = "complete",
            .data_b64 = response_b64,
        });
    }

    fn readBspValue(self: *BspClient, reader: *std.Io.Reader) !std.json.Parsed(std.json.Value) {
        const line = (try reader.takeDelimiter('\n')) orelse return error.BspConnectionClosed;
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        return try std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{});
    }

    fn sendValue(self: *BspClient, value: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, value, .{ .whitespace = .minified });
        var write_buffer: [64 * 1024]u8 = undefined;
        var writer_state = self.stream.writer(self.io, &write_buffer);
        const writer = &writer_state.interface;
        try writer.writeAll(json);
        try writer.writeByte('\n');
        try writer.flush();
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    const options = try parseOptions(allocator, &args, init.environ_map);

    var io_threaded = std.Io.Threaded.init_single_threaded;
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const stream = try connectLoopback(options.port);
    var bsp = BspClient.init(allocator, io, init.environ_map, stream, options.conversation_models);
    defer bsp.deinit();

    var bsp_read_buffer: [64 * 1024]u8 = undefined;
    var bsp_reader_state = bsp.stream.reader(io, &bsp_read_buffer);
    try bsp.createSession(&bsp_reader_state.interface, options);

    var stdin_buffer: [8192]u8 = undefined;
    var stdin_file_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    while (try readMcpMessage(allocator, stdin_reader)) |request_bytes| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, request_bytes, .{}) catch {
            const response = try std.json.Stringify.valueAlloc(allocator, ErrorResponse{ .id = .null, .@"error" = .{ .code = -32700, .message = "parse error" } }, .{});
            try sendMcpMessage(io, response);
            continue;
        };
        defer parsed.deinit();
        var shutdown = false;
        if (try handleMcpRequest(allocator, &bsp, &bsp_reader_state.interface, options, parsed.value, &shutdown)) |response| {
            try sendMcpMessage(io, response);
        }
        if (shutdown) break;
    }
}

fn parseOptions(allocator: std.mem.Allocator, args: *std.process.Args.Iterator, env: *const std.process.Environ.Map) !Options {
    _ = args.next();
    var options = Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            options.port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingPortArgument, 10);
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            options.port = try std.fmt.parseInt(u16, arg["--port=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--brain-root")) {
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
        } else if (std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else {
            std.debug.print("Unknown Affective MCP flag: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    if (options.port == 0) {
        const env_port = env.get("AFFECTIVE_BSP_PORT") orelse return error.MissingBspPort;
        options.port = try std.fmt.parseInt(u16, env_port, 10);
    }
    _ = allocator;
    return options;
}

fn handleMcpRequest(allocator: std.mem.Allocator, bsp: *BspClient, bsp_reader: *std.Io.Reader, options: Options, request: std.json.Value, shutdown: *bool) !?[]u8 {
    if (request != .object) return try mcpError(allocator, .null, -32600, "request must be an object");
    const object = request.object;
    const id = object.get("id") orelse std.json.Value.null;
    const method = try requireStringValue(object.get("method"), "method");
    if (std.mem.eql(u8, method, "initialize")) return try std.json.Stringify.valueAlloc(allocator, InitializeResponse{ .id = id }, .{});
    if (std.mem.eql(u8, method, "tools/list")) return try std.json.Stringify.valueAlloc(allocator, ToolsResponse{ .id = id, .result = .{ .tools = try tools(allocator) } }, .{});
    if (std.mem.eql(u8, method, "tools/call")) {
        const params_value = object.get("params") orelse return try mcpError(allocator, id, -32602, "missing params");
        const params = try expectObject(params_value);
        const name = try requireStringValue(params.get("name"), "name");
        const args = params.get("arguments") orelse std.json.Value.null;
        const result_json = dispatchTool(allocator, bsp, bsp_reader, options, name, args, shutdown) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
            return try mcpError(allocator, id, -32000, message);
        };
        const content = [_]TextContent{.{ .text = result_json }};
        return try std.json.Stringify.valueAlloc(allocator, ToolResponse{ .id = id, .result = .{ .content = &content } }, .{});
    }
    if (object.get("id") == null) return null;
    return try mcpError(allocator, id, -32601, "unknown method");
}

fn dispatchTool(allocator: std.mem.Allocator, bsp: *BspClient, bsp_reader: *std.Io.Reader, options: Options, name: []const u8, args: std.json.Value, shutdown: *bool) ![]u8 {
    const request_id = getString(args, "request_id") orelse "affective-mcp-tool";
    if (std.mem.eql(u8, name, "connect")) return try bsp.dispatch(bsp_reader, try requests.connect(request_id));
    if (std.mem.eql(u8, name, "host_attach")) return try bsp.dispatch(bsp_reader, try hostAttachRequest(request_id, getString(args, "host_id") orelse "affective-mcp"));
    if (std.mem.eql(u8, name, "user_text")) return try bsp.dispatch(bsp_reader, try requests.userText(request_id, getString(args, "text") orelse return error.MissingText));
    if (std.mem.eql(u8, name, "short_touch")) return try bsp.dispatch(bsp_reader, try requests.shortTouch(request_id));
    if (std.mem.eql(u8, name, "sense_observation")) return try bsp.dispatch(bsp_reader, try requests.senseObservationCamera(request_id, getString(args, "image_path") orelse return error.MissingImagePath));
    if (std.mem.eql(u8, name, "read_models_snapshot")) return try bsp.dispatch(bsp_reader, try requests.readModelsSnapshot(request_id));
    if (std.mem.eql(u8, name, "memory_inspect_safe")) {
        const snapshot = try bsp.dispatch(bsp_reader, try requests.readModelsSnapshot(request_id));
        return try admin_tools.memoryInspectSafe(allocator, snapshot, args);
    }
    if (std.mem.eql(u8, name, "session_metadata_get")) return try admin_tools.metadataGet(allocator, bsp.io, options.brain_root);
    if (std.mem.eql(u8, name, "session_metadata_set")) return try admin_tools.metadataSet(allocator, bsp.io, options.brain_root, args);
    if (std.mem.eql(u8, name, "export_brain")) return try bsp.dispatch(bsp_reader, try requests.exportBrain(request_id, getString(args, "brain_file_path") orelse getString(args, "output_path") orelse return error.MissingBrainFilePath));
    if (std.mem.eql(u8, name, "conversation_text")) return try bsp.conversationText(bsp_reader, request_id, getString(args, "text") orelse return error.MissingText);
    if (std.mem.eql(u8, name, "brain_step")) return try bsp.dispatch(bsp_reader, try requests.brainStep(request_id));
    if (std.mem.eql(u8, name, "request_dream_time")) return try bsp.dispatch(bsp_reader, try requests.requestDreamTime(request_id, getString(args, "text") orelse ""));
    if (std.mem.eql(u8, name, "drain")) return try bsp.drain(bsp_reader);
    if (std.mem.eql(u8, name, "shutdown")) {
        try bsp.shutdown(bsp_reader);
        shutdown.* = true;
        return try std.json.Stringify.valueAlloc(allocator, ShutdownResult{}, .{ .whitespace = .indent_2 });
    }
    return error.UnknownOperation;
}

fn tools(allocator: std.mem.Allocator) ![]const Tool {
    const specs = [_]struct { name: []const u8, description: []const u8, schema_json: []const u8 }{
        .{ .name = "connect", .description = "Open a direct connection event with the brain.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
        .{ .name = "host_attach", .description = "Attach Affective MCP as the active host.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"},\"host_id\":{\"type\":\"string\"}}}" },
        .{ .name = "user_text", .description = "Send text directly into the brain as user input.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"request_id\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "short_touch", .description = "Send a short touch activation to the brain.", .schema_json = "{\"type\":\"object\",\"properties\":{\"request_id\":{\"type\":\"string\"}}}" },
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
        .{ .name = "shutdown", .description = "Cleanly shut down this TCP-backed MCP session after returning.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
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

fn hostAttachRequest(request_id: []const u8, host_id: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(std.heap.page_allocator, "{{\"api_version\":1,\"request_id\":{s},\"event\":{{\"type\":\"host_update\",\"kind\":\"host_attach\",\"host_id\":{s},\"platform\":\"affective_mcp\",\"app_version\":\"0.1.0\",\"capability_ids\":[\"text_input\",\"short_touch\",\"camera_capture\",\"identity_recognition\",\"event_drain\",\"dream_time_request\"]}}}}", .{
        try std.json.Stringify.valueAlloc(std.heap.page_allocator, request_id, .{}),
        try std.json.Stringify.valueAlloc(std.heap.page_allocator, host_id, .{}),
    });
}

fn connectLoopback(port: u16) !net.Stream {
    const raw_fd = socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    switch (posix.errno(raw_fd)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    const fd: posix.fd_t = @intCast(raw_fd);
    errdefer _ = posix.system.close(fd);
    var address = posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    switch (posix.errno(posix.system.connect(fd, @ptrCast(&address), @sizeOf(posix.sockaddr.in)))) {
        .SUCCESS => {},
        .CONNREFUSED => return error.ConnectionRefused,
        .TIMEDOUT => return error.ConnectionTimedOut,
        else => |err| return posix.unexpectedErrno(err),
    }
    const stream_address = try net.IpAddress.parseIp4("127.0.0.1", port);
    return .{ .socket = .{ .handle = fd, .address = stream_address } };
}

fn ensureBrainLayout(io: std.Io, brain_root: []const u8) !void {
    try files.ensureDir(io, brain_root);
    const memory_dir = try std.fs.path.join(std.heap.page_allocator, &.{ brain_root, "memory" });
    defer std.heap.page_allocator.free(memory_dir);
    try files.ensureDir(io, memory_dir);
    const embeddings_dir = try std.fs.path.join(std.heap.page_allocator, &.{ brain_root, "memory/face_embeddings" });
    defer std.heap.page_allocator.free(embeddings_dir);
    try files.ensureDir(io, embeddings_dir);
    const images_dir = try std.fs.path.join(std.heap.page_allocator, &.{ brain_root, "generated/images" });
    defer std.heap.page_allocator.free(images_dir);
    try files.ensureDir(io, images_dir);
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

fn requireStringValue(value: ?std.json.Value, _: []const u8) ![]const u8 {
    const actual = value orelse return error.MissingJsonField;
    if (actual != .string) return error.ExpectedString;
    return actual.string;
}

fn requireStringDupe(allocator: std.mem.Allocator, value: std.json.Value, field: []const u8) ![]u8 {
    return try allocator.dupe(u8, try requireStringValue(value, field));
}

fn valueStringEql(value: std.json.Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
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

test "tools/list includes TCP MCP tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const listed = try tools(arena.allocator());
    const expected = [_][]const u8{ "connect", "host_attach", "user_text", "short_touch", "sense_observation", "read_models_snapshot", "memory_inspect_safe", "session_metadata_get", "session_metadata_set", "export_brain", "conversation_text", "brain_step", "request_dream_time", "drain", "shutdown" };
    for (expected) |name| {
        var found = false;
        for (listed) |tool| {
            if (std.mem.eql(u8, tool.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
}
