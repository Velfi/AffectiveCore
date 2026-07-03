const std = @import("std");

pub const MessageType = enum {
    session_create,
    session_destroy,
    session_ready,
    dispatch,
    dispatch_result,
    conversation_text,
    conversation_result,
    dispatch_error,
    drain,
    drain_try,
    drain_result,
    raw_ref_lookup,
    brain_export,
    brain_import,
    host_http_begin,
    host_http_complete,
    events_push,

    pub fn parse(value: []const u8) !MessageType {
        inline for (@typeInfo(MessageType).@"enum".fields) |field| {
            const tag: MessageType = @enumFromInt(field.value);
            if (std.mem.eql(u8, wireType(tag), value)) return tag;
        }
        return error.UnknownBspMessageType;
    }
};

pub fn wireType(message_type: MessageType) []const u8 {
    return switch (message_type) {
        .session_create => "session.create",
        .session_destroy => "session.destroy",
        .session_ready => "session.ready",
        .dispatch => "dispatch",
        .dispatch_result => "dispatch.result",
        .conversation_text => "conversation.text",
        .conversation_result => "conversation.result",
        .dispatch_error => "dispatch.error",
        .drain => "drain",
        .drain_try => "drain.try",
        .drain_result => "drain.result",
        .raw_ref_lookup => "raw_ref.lookup",
        .brain_export => "brain.export",
        .brain_import => "brain.import",
        .host_http_begin => "host.http.begin",
        .host_http_complete => "host.http.complete",
        .events_push => "events.push",
    };
}

pub const HostHttpCompletionStatus = enum {
    complete,
    failed,

    pub fn parse(value: []const u8) !HostHttpCompletionStatus {
        if (std.mem.eql(u8, value, "complete")) return .complete;
        if (std.mem.eql(u8, value, "failed")) return .failed;
        return error.InvalidHostHttpCompletionStatus;
    }

    pub fn wire(self: HostHttpCompletionStatus) []const u8 {
        return switch (self) {
            .complete => "complete",
            .failed => "failed",
        };
    }
};

pub const SessionConfig = struct {
    brain_id: []const u8 = "",
    brain_root: []const u8 = "",
    conversation_models: []const u8 = "",
    conversation_reasoning_effort: []const u8 = "",
    image_generation_model: []const u8 = "",
    image_generation_output_dir: []const u8 = "",
    memory_path: []const u8,
    graph_path: []const u8,
    schedule_path: []const u8,
    maintenance_state_path: []const u8,
    face_embeddings_dir: []const u8 = "",
    host_manifest_json: []const u8 = "",
};

pub const Message = union(MessageType) {
    session_create: SessionCreate,
    session_destroy: SessionDestroy,
    session_ready: SessionReady,
    dispatch: Dispatch,
    dispatch_result: JsonEnvelope,
    conversation_text: ConversationText,
    conversation_result: JsonEnvelope,
    dispatch_error: ErrorEnvelope,
    drain: Drain,
    drain_try: Drain,
    drain_result: JsonEnvelope,
    raw_ref_lookup: RawRefLookup,
    brain_export: BrainExport,
    brain_import: BrainImport,
    host_http_begin: HostHttpBegin,
    host_http_complete: HostHttpComplete,
    events_push: JsonEnvelope,

    pub fn messageType(self: Message) MessageType {
        return switch (self) {
            .session_create => .session_create,
            .session_destroy => .session_destroy,
            .session_ready => .session_ready,
            .dispatch => .dispatch,
            .dispatch_result => .dispatch_result,
            .conversation_text => .conversation_text,
            .conversation_result => .conversation_result,
            .dispatch_error => .dispatch_error,
            .drain => .drain,
            .drain_try => .drain_try,
            .drain_result => .drain_result,
            .raw_ref_lookup => .raw_ref_lookup,
            .brain_export => .brain_export,
            .brain_import => .brain_import,
            .host_http_begin => .host_http_begin,
            .host_http_complete => .host_http_complete,
            .events_push => .events_push,
        };
    }

    pub fn jsonStringify(self: Message, jw: anytype) !void {
        return writeMessageJson(self, jw);
    }
};

pub const SessionCreate = struct {
    request_id: []const u8,
    config: SessionConfig,
};

pub const SessionDestroy = struct {
    request_id: ?[]const u8 = null,
};

pub const SessionReady = struct {
    request_id: []const u8,
    session_id: []const u8,
    port: u16,
};

pub const Dispatch = struct {
    request_id: []const u8,
    request_json: []const u8,
};

pub const ConversationText = struct {
    request_id: []const u8,
    text: []const u8,
};

pub const Drain = struct {
    request_id: []const u8,
};

pub const RawRefLookup = struct {
    request_id: []const u8,
    raw_ref: []const u8,
};

pub const BrainExport = struct {
    request_id: []const u8,
};

pub const BrainImport = struct {
    request_id: []const u8,
    archive_b64: []const u8,
};

pub const HostHttpBegin = struct {
    request_id: []const u8,
    url: []const u8,
    headers_json: []const u8,
    body_b64: []const u8,
    timeout_ms: u64,
    max_response_bytes: usize,
};

pub const HostHttpComplete = struct {
    request_id: []const u8,
    status: HostHttpCompletionStatus,
    data_b64: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
};

pub const JsonEnvelope = struct {
    request_id: []const u8,
    payload_json: []const u8,
};

pub const ErrorEnvelope = struct {
    request_id: ?[]const u8 = null,
    code: []const u8,
    message: []const u8,
};

const Wire = struct {
    type: []const u8,
    request_id: ?[]const u8 = null,
    config: ?SessionConfig = null,
    session_id: ?[]const u8 = null,
    port: ?u16 = null,
    request_json: ?[]const u8 = null,
    text: ?[]const u8 = null,
    raw_ref: ?[]const u8 = null,
    archive_b64: ?[]const u8 = null,
    url: ?[]const u8 = null,
    headers_json: ?[]const u8 = null,
    body_b64: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    max_response_bytes: ?usize = null,
    status: ?[]const u8 = null,
    data_b64: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    payload_json: ?[]const u8 = null,
    host_manifest_json: ?[]const u8 = null,
};

pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(Message) {
    if (std.mem.indexOfScalar(u8, line, '\n') != null) return error.InvalidBspFrame;
    const parsed = try std.json.parseFromSlice(Wire, allocator, line, .{ .ignore_unknown_fields = false });
    errdefer parsed.deinit();
    const message = try fromWire(parsed.value);
    return .{
        .arena = parsed.arena,
        .value = message,
    };
}

pub fn encodeLine(allocator: std.mem.Allocator, message: Message) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, message, .{ .whitespace = .minified });
    errdefer allocator.free(json);
    const line = try allocator.alloc(u8, json.len + 1);
    @memcpy(line[0..json.len], json);
    line[json.len] = '\n';
    allocator.free(json);
    return line;
}

pub fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, len);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

pub fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const len = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    try std.base64.standard.Decoder.decode(bytes, encoded);
    return bytes;
}

fn fromWire(wire: Wire) !Message {
    const message_type = try MessageType.parse(wire.type);
    return switch (message_type) {
        .session_create => .{ .session_create = .{
            .request_id = try require(wire.request_id, "request_id"),
            .config = withHostManifest(wire.config orelse return error.MissingBspConfig, wire.host_manifest_json),
        } },
        .session_destroy => .{ .session_destroy = .{ .request_id = wire.request_id } },
        .session_ready => .{ .session_ready = .{
            .request_id = try require(wire.request_id, "request_id"),
            .session_id = try require(wire.session_id, "session_id"),
            .port = wire.port orelse return error.MissingBspPort,
        } },
        .dispatch => .{ .dispatch = .{
            .request_id = try require(wire.request_id, "request_id"),
            .request_json = try require(wire.request_json, "request_json"),
        } },
        .dispatch_result => .{ .dispatch_result = .{
            .request_id = try require(wire.request_id, "request_id"),
            .payload_json = try require(wire.payload_json, "payload_json"),
        } },
        .conversation_text => .{ .conversation_text = .{
            .request_id = try require(wire.request_id, "request_id"),
            .text = try require(wire.text, "text"),
        } },
        .conversation_result => .{ .conversation_result = .{
            .request_id = try require(wire.request_id, "request_id"),
            .payload_json = try require(wire.payload_json, "payload_json"),
        } },
        .dispatch_error => .{ .dispatch_error = .{
            .request_id = wire.request_id,
            .code = try require(wire.code, "code"),
            .message = try require(wire.message, "message"),
        } },
        .drain => .{ .drain = .{ .request_id = try require(wire.request_id, "request_id") } },
        .drain_try => .{ .drain_try = .{ .request_id = try require(wire.request_id, "request_id") } },
        .drain_result => .{ .drain_result = .{
            .request_id = try require(wire.request_id, "request_id"),
            .payload_json = try require(wire.payload_json, "payload_json"),
        } },
        .raw_ref_lookup => .{ .raw_ref_lookup = .{
            .request_id = try require(wire.request_id, "request_id"),
            .raw_ref = try require(wire.raw_ref, "raw_ref"),
        } },
        .brain_export => .{ .brain_export = .{ .request_id = try require(wire.request_id, "request_id") } },
        .brain_import => .{ .brain_import = .{
            .request_id = try require(wire.request_id, "request_id"),
            .archive_b64 = try require(wire.archive_b64, "archive_b64"),
        } },
        .host_http_begin => .{ .host_http_begin = .{
            .request_id = try require(wire.request_id, "request_id"),
            .url = try require(wire.url, "url"),
            .headers_json = try require(wire.headers_json, "headers_json"),
            .body_b64 = try require(wire.body_b64, "body_b64"),
            .timeout_ms = wire.timeout_ms orelse return error.MissingBspTimeoutMs,
            .max_response_bytes = wire.max_response_bytes orelse return error.MissingBspMaxResponseBytes,
        } },
        .host_http_complete => .{ .host_http_complete = .{
            .request_id = try require(wire.request_id, "request_id"),
            .status = try HostHttpCompletionStatus.parse(try require(wire.status, "status")),
            .data_b64 = wire.data_b64,
            .error_message = wire.@"error",
        } },
        .events_push => .{ .events_push = .{
            .request_id = try require(wire.request_id, "request_id"),
            .payload_json = try require(wire.payload_json, "payload_json"),
        } },
    };
}

fn withHostManifest(config: SessionConfig, top_level_manifest: ?[]const u8) SessionConfig {
    var resolved = config;
    if (resolved.host_manifest_json.len == 0) {
        resolved.host_manifest_json = top_level_manifest orelse "";
    }
    return resolved;
}

fn require(value: ?[]const u8, _: []const u8) ![]const u8 {
    const bytes = value orelse return error.MissingBspField;
    if (bytes.len == 0) return error.EmptyBspField;
    return bytes;
}

pub fn validateHostHttpComplete(message: HostHttpComplete) !void {
    switch (message.status) {
        .complete => {
            const data = message.data_b64 orelse return error.MissingBspHttpData;
            _ = try std.base64.standard.Decoder.calcSizeForSlice(data);
            if (message.error_message != null) return error.UnexpectedBspHttpError;
        },
        .failed => {
            if (message.error_message == null) return error.MissingBspHttpError;
            if (message.data_b64 != null) return error.UnexpectedBspHttpData;
        },
    }
}

fn writeType(jw: anytype, message_type: MessageType) !void {
    try jw.objectField("type");
    try jw.write(wireType(message_type));
}

fn writeMessageJson(message: Message, jw: anytype) !void {
    try jw.beginObject();
    switch (message) {
        .session_create => |value| {
            try writeType(jw, .session_create);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
            try jw.objectField("config");
            try jw.write(value.config);
        },
        .session_destroy => |value| {
            try writeType(jw, .session_destroy);
            if (value.request_id) |request_id| {
                try jw.objectField("request_id");
                try jw.write(request_id);
            }
        },
        .session_ready => |value| {
            try writeType(jw, .session_ready);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
            try jw.objectField("session_id");
            try jw.write(value.session_id);
            try jw.objectField("port");
            try jw.write(value.port);
        },
        .dispatch => |value| {
            try writeType(jw, .dispatch);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
            try jw.objectField("request_json");
            try jw.write(value.request_json);
        },
        .dispatch_result => |value| try writeJsonEnvelope(jw, .dispatch_result, value),
        .conversation_text => |value| {
            try writeType(jw, .conversation_text);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
            try jw.objectField("text");
            try jw.write(value.text);
        },
        .conversation_result => |value| try writeJsonEnvelope(jw, .conversation_result, value),
        .dispatch_error => |value| {
            try writeType(jw, .dispatch_error);
            if (value.request_id) |request_id| {
                try jw.objectField("request_id");
                try jw.write(request_id);
            }
            try jw.objectField("code");
            try jw.write(value.code);
            try jw.objectField("message");
            try jw.write(value.message);
        },
        .drain => |value| try writeDrain(jw, .drain, value),
        .drain_try => |value| try writeDrain(jw, .drain_try, value),
        .drain_result => |value| try writeJsonEnvelope(jw, .drain_result, value),
        .raw_ref_lookup => |value| {
            try writeType(jw, .raw_ref_lookup);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
            try jw.objectField("raw_ref");
            try jw.write(value.raw_ref);
        },
        .brain_export => |value| {
            try writeType(jw, .brain_export);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
        },
        .brain_import => |value| {
            try writeType(jw, .brain_import);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
            try jw.objectField("archive_b64");
            try jw.write(value.archive_b64);
        },
        .host_http_begin => |value| {
            try writeType(jw, .host_http_begin);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
            try jw.objectField("url");
            try jw.write(value.url);
            try jw.objectField("headers_json");
            try jw.write(value.headers_json);
            try jw.objectField("body_b64");
            try jw.write(value.body_b64);
            try jw.objectField("timeout_ms");
            try jw.write(value.timeout_ms);
            try jw.objectField("max_response_bytes");
            try jw.write(value.max_response_bytes);
        },
        .host_http_complete => |value| {
            try writeType(jw, .host_http_complete);
            try jw.objectField("request_id");
            try jw.write(value.request_id);
            try jw.objectField("status");
            try jw.write(value.status.wire());
            if (value.data_b64) |data_b64| {
                try jw.objectField("data_b64");
                try jw.write(data_b64);
            }
            if (value.error_message) |err| {
                try jw.objectField("error");
                try jw.write(err);
            }
        },
        .events_push => |value| try writeJsonEnvelope(jw, .events_push, value),
    }
    try jw.endObject();
}

fn writeDrain(jw: anytype, message_type: MessageType, value: Drain) !void {
    try writeType(jw, message_type);
    try jw.objectField("request_id");
    try jw.write(value.request_id);
}

fn writeJsonEnvelope(jw: anytype, message_type: MessageType, value: JsonEnvelope) !void {
    try writeType(jw, message_type);
    try jw.objectField("request_id");
    try jw.write(value.request_id);
    try jw.objectField("payload_json");
    try jw.write(value.payload_json);
}

test "BSP message types parse exact wire strings" {
    try std.testing.expectEqual(MessageType.host_http_begin, try MessageType.parse("host.http.begin"));
    try std.testing.expectEqual(MessageType.drain_try, try MessageType.parse("drain.try"));
    try std.testing.expectError(error.UnknownBspMessageType, MessageType.parse("host.http.pending"));
}

test "BSP host HTTP complete validates complete and failed shapes" {
    try validateHostHttpComplete(.{
        .request_id = "host-1",
        .status = .complete,
        .data_b64 = "e30=",
    });
    try validateHostHttpComplete(.{
        .request_id = "host-1",
        .status = .failed,
        .error_message = "host denied route",
    });
    try std.testing.expectError(error.MissingBspHttpData, validateHostHttpComplete(.{
        .request_id = "host-1",
        .status = .complete,
    }));
    try std.testing.expectError(error.UnexpectedBspHttpData, validateHostHttpComplete(.{
        .request_id = "host-1",
        .status = .failed,
        .data_b64 = "e30=",
        .error_message = "failed",
    }));
}

test "BSP line encoding appends newline and parser rejects embedded newline frames" {
    const allocator = std.testing.allocator;
    const line = try encodeLine(allocator, .{ .drain = .{ .request_id = "drain-1" } });
    defer allocator.free(line);
    try std.testing.expect(line.len > 0);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    var parsed = try parseLine(allocator, line[0 .. line.len - 1]);
    defer parsed.deinit();
    try std.testing.expectEqual(MessageType.drain, parsed.value.messageType());
    try std.testing.expectError(error.InvalidBspFrame, parseLine(allocator, line));
}

test "BSP parser decodes host HTTP complete status" {
    const allocator = std.testing.allocator;
    var parsed = try parseLine(allocator, "{\"type\":\"host.http.complete\",\"request_id\":\"h1\",\"status\":\"complete\",\"data_b64\":\"e30=\"}");
    defer parsed.deinit();
    try std.testing.expectEqual(MessageType.host_http_complete, parsed.value.messageType());
    try validateHostHttpComplete(parsed.value.host_http_complete);
    try std.testing.expectEqual(HostHttpCompletionStatus.complete, parsed.value.host_http_complete.status);
}

test "BSP base64 helpers round-trip newline bodies" {
    const allocator = std.testing.allocator;
    const encoded = try encodeBase64(allocator, "line one\nline two");
    defer allocator.free(encoded);
    const decoded = try decodeBase64(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("line one\nline two", decoded);
}
