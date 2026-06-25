const std = @import("std");

const command_log_mod = @import("../platform/common/command_log.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const speech_mod = @import("../api/speech_client.zig");
const chat = @import("../api/chat_client.zig");

pub const api_version: u8 = 1;
pub const api_version_v2: u8 = 2;

pub const HostEvent = struct {
    type: []const u8,
    request_id: ?[]const u8 = null,
    role: ?[]const u8 = null,
    text: ?[]const u8 = null,
    state: ?[]const u8 = null,
    enabled: ?bool = null,
    kind: ?[]const u8 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    sense: ?[]const u8 = null,
    eyes: ?[]const u8 = null,
    mouth: ?[]const u8 = null,
    duration_ms: ?u32 = null,
    raw_ref: ?[]const u8 = null,
    original_bytes: ?usize = null,
};

pub const HostManifest = struct {
    api_version: u8,
    platform: []const u8,
    capabilities: chat.CapabilitySet,
    feature_flags: std.json.ObjectMap,
    max_envelope_bytes: usize = 16 * 1024,
    max_event_count: usize = 12,
    max_event_text_bytes: usize = 768,
    raw_ref_ttl_seconds: i64 = 24 * 60 * 60,
};

pub fn defaultMacosManifestJson() []const u8 {
    return
    \\{
    \\  "api_version": 1,
    \\  "platform": "macos",
    \\  "storage_provider": "file_backed_migration",
    \\  "capabilities": [
    \\    "speech_transcript",
    \\    "typed_text",
    \\    "poke_sequence",
    \\    "short_touch",
    \\    "long_touch",
    \\    "tool_call",
    \\    "speech_output",
    \\    "event_envelope",
    \\    "event_drain",
    \\    "uploaded_media_read",
    \\    "stored_memory_read",
    \\    "stored_memory_write",
    \\    "stored_image_read",
    \\    "identity_recognition",
    \\    "introspection",
    \\    "time_lookup",
    \\    "power_status",
    \\    "storage_fullness",
    \\    "database_stats",
    \\    "reminder_io",
    \\    "image_generation",
    \\    "face_picture_update",
    \\    "local_process_io",
    \\    "facial_expression_output"
    \\  ],
    \\  "feature_flags": {
    \\    "streaming_events": true,
    \\    "logical_store": false
    \\  }
    \\}
    ;
}

pub fn parseHostManifest(allocator: std.mem.Allocator, json: []const u8) !HostManifest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHostManifest;
    const object = parsed.value.object;
    const api = getInteger(object, "api_version") orelse return error.MissingHostManifestApiVersion;
    if (api != api_version and api != api_version_v2) return error.UnsupportedHostManifestApiVersion;
    const platform = getString(object, "platform") orelse return error.MissingHostManifestPlatform;
    const capabilities_value = object.get("capabilities") orelse return error.MissingHostManifestCapabilities;
    if (capabilities_value != .array) return error.InvalidHostManifestCapabilities;
    const flags_value = object.get("feature_flags") orelse return error.MissingHostManifestFeatureFlags;
    if (flags_value != .object) return error.InvalidHostManifestFeatureFlags;

    var capabilities = chat.CapabilitySet{};
    for (capabilities_value.array.items) |item| {
        if (item != .string) return error.InvalidHostManifestCapabilities;
        applyCapability(&capabilities, item.string) catch |err| switch (err) {
            error.UnknownHostCapability => return err,
        };
    }

    return .{
        .api_version = @intCast(api),
        .platform = try allocator.dupe(u8, platform),
        .capabilities = capabilities,
        .feature_flags = try cloneObjectMap(allocator, flags_value.object),
        .max_envelope_bytes = @intCast(getInteger(object, "max_envelope_bytes") orelse 16 * 1024),
        .max_event_count = @intCast(getInteger(object, "max_event_count") orelse 12),
        .max_event_text_bytes = @intCast(getInteger(object, "max_event_text_bytes") orelse 768),
        .raw_ref_ttl_seconds = getInteger(object, "raw_ref_ttl_seconds") orelse 24 * 60 * 60,
    };
}

fn applyCapability(capabilities: *chat.CapabilitySet, name: []const u8) !void {
    if (std.mem.eql(u8, name, "live_camera")) capabilities.live_camera = true else if (std.mem.eql(u8, name, "button_activation") or std.mem.eql(u8, name, "short_touch") or std.mem.eql(u8, name, "poke_sequence")) capabilities.button_activation = true else if (std.mem.eql(u8, name, "button_hold_state") or std.mem.eql(u8, name, "long_touch")) capabilities.button_hold_state = true else if (std.mem.eql(u8, name, "visual_description")) capabilities.visual_description = true else if (std.mem.eql(u8, name, "visual_comparison")) capabilities.visual_comparison = true else if (std.mem.eql(u8, name, "identity_recognition")) capabilities.identity_recognition = true else if (std.mem.eql(u8, name, "stored_memory_read")) capabilities.stored_memory_read = true else if (std.mem.eql(u8, name, "stored_memory_write")) capabilities.stored_memory_write = true else if (std.mem.eql(u8, name, "stored_image_read")) capabilities.stored_image_read = true else if (std.mem.eql(u8, name, "introspection")) capabilities.introspection = true else if (std.mem.eql(u8, name, "time_lookup")) capabilities.time_lookup = true else if (std.mem.eql(u8, name, "orientation_query")) capabilities.orientation_query = true else if (std.mem.eql(u8, name, "power_status")) capabilities.power_status = true else if (std.mem.eql(u8, name, "storage_fullness")) capabilities.storage_fullness = true else if (std.mem.eql(u8, name, "database_stats")) capabilities.database_stats = true else if (std.mem.eql(u8, name, "speech_output")) capabilities.speech_output = true else if (std.mem.eql(u8, name, "user_input") or std.mem.eql(u8, name, "speech_transcript") or std.mem.eql(u8, name, "typed_text")) capabilities.user_input = true else if (std.mem.eql(u8, name, "reminder_io")) capabilities.reminder_io = true else if (std.mem.eql(u8, name, "image_generation")) capabilities.image_generation = true else if (std.mem.eql(u8, name, "face_picture_update")) capabilities.face_picture_update = true else if (std.mem.eql(u8, name, "email_delivery")) capabilities.email_delivery = true else if (std.mem.eql(u8, name, "local_process_io")) capabilities.local_process_io = true else if (std.mem.eql(u8, name, "uploaded_media_read") or std.mem.eql(u8, name, "media_uploaded")) capabilities.uploaded_media_read = true else if (std.mem.eql(u8, name, "audio_classification")) capabilities.audio_classification = true else if (std.mem.eql(u8, name, "audio_transcription")) capabilities.audio_transcription = true else if (std.mem.eql(u8, name, "video_inspection")) capabilities.video_inspection = true else if (std.mem.eql(u8, name, "facial_expression_output")) capabilities.facial_expression_output = true else if (std.mem.eql(u8, name, "tool_call") or std.mem.eql(u8, name, "maintenance_tick") or std.mem.eql(u8, name, "autonomy_tick") or std.mem.eql(u8, name, "event_envelope") or std.mem.eql(u8, name, "event_drain") or std.mem.eql(u8, name, "sense_observation")) {} else return error.UnknownHostCapability;
}

fn cloneObjectMap(allocator: std.mem.Allocator, object: std.json.ObjectMap) std.mem.Allocator.Error!std.json.ObjectMap {
    var keys = try allocator.alloc([]const u8, object.count());
    var values = try allocator.alloc(std.json.Value, object.count());
    var it = object.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        keys[i] = try allocator.dupe(u8, entry.key_ptr.*);
        values[i] = try cloneJsonValue(allocator, entry.value_ptr.*);
    }
    return std.json.ObjectMap.init(allocator, keys, values);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |inner| .{ .bool = inner },
        .integer => |inner| .{ .integer = inner },
        .float => |inner| .{ .float = inner },
        .number_string => |inner| .{ .number_string = try allocator.dupe(u8, inner) },
        .string => |inner| .{ .string = try allocator.dupe(u8, inner) },
        .array => |inner| blk: {
            var out = std.json.Array.init(allocator);
            for (inner.items) |item| try out.append(try cloneJsonValue(allocator, item));
            break :blk .{ .array = out };
        },
        .object => |inner| .{ .object = try cloneObjectMap(allocator, inner) },
    };
}

fn getString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getInteger(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn readEmbeddedFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "fixtures/embedded_api_v1/{s}", .{name});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(16 * 1024));
}

test "embedded host manifest maps declared capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fixture = try readEmbeddedFixture(allocator, "manifest_macos.json");
    const manifest = try parseHostManifest(allocator, fixture);
    try std.testing.expectEqual(@as(u8, 1), manifest.api_version);
    try std.testing.expectEqualStrings("macos", manifest.platform);
    try std.testing.expect(manifest.capabilities.button_activation);
    try std.testing.expect(manifest.capabilities.button_hold_state);
    try std.testing.expect(manifest.capabilities.user_input);
    try std.testing.expect(manifest.capabilities.speech_output);
    try std.testing.expect(manifest.capabilities.stored_memory_read);
    try std.testing.expect(manifest.capabilities.stored_memory_write);
    try std.testing.expect(manifest.capabilities.identity_recognition);
    try std.testing.expect(manifest.capabilities.reminder_io);
    try std.testing.expect(manifest.capabilities.facial_expression_output);
    try std.testing.expect(!manifest.capabilities.live_camera);
}

test "embedded host manifest rejects unsupported versions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.UnsupportedHostManifestApiVersion, parseHostManifest(allocator,
        \\{
        \\  "api_version": 3,
        \\  "platform": "android",
        \\  "capabilities": [],
        \\  "feature_flags": {}
        \\}
    ));
}

test "embedded host manifest accepts android v2 budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const manifest = try parseHostManifest(allocator,
        \\{
        \\  "api_version": 2,
        \\  "platform": "android",
        \\  "capabilities": ["typed_text", "poke_sequence", "event_envelope", "event_drain", "introspection"],
        \\  "feature_flags": {},
        \\  "max_envelope_bytes": 8192,
        \\  "max_event_count": 4,
        \\  "max_event_text_bytes": 128,
        \\  "raw_ref_ttl_seconds": 60
        \\}
    );
    try std.testing.expectEqual(@as(u8, 2), manifest.api_version);
    try std.testing.expectEqualStrings("android", manifest.platform);
    try std.testing.expectEqual(@as(usize, 8192), manifest.max_envelope_bytes);
    try std.testing.expectEqual(@as(usize, 4), manifest.max_event_count);
    try std.testing.expectEqual(@as(usize, 128), manifest.max_event_text_bytes);
    try std.testing.expectEqual(@as(i64, 60), manifest.raw_ref_ttl_seconds);
}

test "embedded api v1 fixtures keep stable envelope shapes" {
    const request_fixtures = [_][]const u8{
        "speech_transcript_request.json",
        "typed_text_request.json",
        "short_touch_request.json",
        "long_touch_request.json",
        "poke_sequence_request.json",
        "tool_call_request.json",
    };
    for (request_fixtures) |name| {
        const fixture = try readEmbeddedFixture(std.testing.allocator, name);
        defer std.testing.allocator.free(fixture);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const object = parsed.value.object;
        try std.testing.expectEqual(@as(i64, 1), getInteger(object, "api_version").?);
        try std.testing.expect(getString(object, "request_id").?.len > 0);
        try std.testing.expect(object.get("event").? == .object);
        try std.testing.expect(getString(object.get("event").?.object, "type").?.len > 0);
    }

    const response_fixtures = [_][]const u8{
        "success_response.json",
        "error_response.json",
        "drain_response.json",
    };
    for (response_fixtures) |name| {
        const fixture = try readEmbeddedFixture(std.testing.allocator, name);
        defer std.testing.allocator.free(fixture);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        const object = parsed.value.object;
        try std.testing.expectEqual(@as(i64, 1), getInteger(object, "api_version").?);
        try std.testing.expect(object.get("ok").? == .bool);
        try std.testing.expect(object.get("events").? == .array);
        if (object.get("error")) |err_value| {
            try std.testing.expect(err_value == .object);
            try std.testing.expect(getString(err_value.object, "code").?.len > 0);
            try std.testing.expect(getString(err_value.object, "message").?.len > 0);
        }
    }
}

pub const HostEffectCollector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(HostEvent) = .empty,
    speech_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator) HostEffectCollector {
        return .{ .allocator = allocator };
    }

    pub fn clear(self: *HostEffectCollector) void {
        self.events.clearRetainingCapacity();
    }

    pub fn items(self: *HostEffectCollector) []const HostEvent {
        return self.events.items;
    }

    pub fn appendSpeechRequested(self: *HostEffectCollector, text: []const u8) !void {
        try self.events.append(self.allocator, .{
            .type = "speech_requested",
            .text = try self.allocator.dupe(u8, text),
        });
    }

    pub fn appendCommandLog(self: *HostEffectCollector, kind: []const u8, title: []const u8, body: []const u8) !void {
        const normalized_kind = if (std.mem.eql(u8, kind, "brain")) "brain" else kind;
        const owned_kind = try self.allocator.dupe(u8, normalized_kind);
        const owned_title = try self.allocator.dupe(u8, title);
        const owned_body = try self.allocator.dupe(u8, body);
        try self.events.append(self.allocator, .{
            .type = "command_log",
            .kind = owned_kind,
            .title = owned_title,
            .body = owned_body,
        });
        if (std.mem.eql(u8, normalized_kind, "brain") or std.mem.eql(u8, normalized_kind, "user")) {
            try self.events.append(self.allocator, .{
                .type = "chat_message",
                .role = owned_kind,
                .title = owned_title,
                .text = owned_body,
            });
        } else if (std.mem.eql(u8, normalized_kind, "state")) {
            try self.events.append(self.allocator, .{
                .type = "state_changed",
                .state = owned_title,
                .text = owned_body,
            });
        }
    }

    pub fn appendSendEnabled(self: *HostEffectCollector, enabled: bool) !void {
        try self.events.append(self.allocator, .{
            .type = "send_enabled_changed",
            .enabled = enabled,
        });
    }

    pub fn appendFacialExpression(self: *HostEffectCollector, expression: facial_expression.Expression) !void {
        try self.events.append(self.allocator, .{
            .type = "facial_expression_requested",
            .eyes = try self.allocator.dupe(u8, expression.eyes),
            .mouth = try self.allocator.dupe(u8, expression.mouth),
            .duration_ms = expression.duration_ms,
        });
    }

    pub fn appendCaptureRequested(self: *HostEffectCollector, title: []const u8, body: []const u8) !void {
        try self.events.append(self.allocator, .{
            .type = "capture_requested",
            .title = try self.allocator.dupe(u8, title),
            .body = try self.allocator.dupe(u8, body),
        });
    }

    pub fn appendSenseRequested(self: *HostEffectCollector, sense: []const u8, title: []const u8, body: []const u8) !void {
        try self.events.append(self.allocator, .{
            .type = "sense_requested",
            .sense = try self.allocator.dupe(u8, sense),
            .title = try self.allocator.dupe(u8, title),
            .body = try self.allocator.dupe(u8, body),
        });
    }

    pub fn speechService(self: *HostEffectCollector) speech_mod.SpeechService {
        return .{ .ctx = self, .synthesizeFn = synthesize };
    }

    pub fn speaker(self: *HostEffectCollector) speaker_mod.Speaker {
        return .{ .ctx = self, .playFileFn = playFile };
    }

    pub fn commandLog(self: *HostEffectCollector) command_log_mod.CommandLog {
        return .{ .ctx = self, .appendFn = appendCommandLogFromContext, .setSendEnabledFn = setSendEnabledFromContext };
    }

    pub fn facialExpressionOutput(self: *HostEffectCollector) facial_expression.Output {
        return .{ .ctx = self, .showFn = showFacialExpressionFromContext };
    }

    fn synthesize(ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8) !speech_mod.AudioFile {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendSpeechRequested(text);
        self.speech_index += 1;
        return .{ .path = try std.fmt.allocPrint(allocator, "embedded://speech/{d}", .{self.speech_index}) };
    }

    fn playFile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {}

    fn appendCommandLogFromContext(ctx: *anyopaque, kind: []const u8, title: []const u8, body: []const u8) !void {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendCommandLog(kind, title, body);
    }

    fn setSendEnabledFromContext(ctx: *anyopaque, enabled: bool) !void {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendSendEnabled(enabled);
    }

    fn showFacialExpressionFromContext(ctx: *anyopaque, expression: facial_expression.Expression) !void {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendFacialExpression(expression);
    }
};

pub fn successEnvelopeAlloc(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    events: []const HostEvent,
    result: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .api_version = api_version,
        .request_id = request_id,
        .ok = true,
        .events = events,
        .result = result,
    }, .{ .whitespace = .indent_2 });
}

pub fn successEnvelopeV2Alloc(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    events: []const HostEvent,
    result: anytype,
    budget: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .api_version = api_version_v2,
        .request_id = request_id,
        .ok = true,
        .events = events,
        .result = result,
        .budget = budget,
    }, .{ .whitespace = .indent_2 });
}

pub fn errorEnvelopeV2Alloc(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    code: []const u8,
    message: []const u8,
    recoverable: bool,
    budget: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .api_version = api_version_v2,
        .request_id = request_id,
        .ok = false,
        .events = &[_]HostEvent{},
        .@"error" = .{
            .code = code,
            .message = message,
            .recoverable = recoverable,
        },
        .budget = budget,
    }, .{ .whitespace = .indent_2 });
}

pub fn errorEnvelopeAlloc(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    code: []const u8,
    message: []const u8,
    recoverable: bool,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .api_version = api_version,
        .request_id = request_id,
        .ok = false,
        .events = &[_]HostEvent{},
        .@"error" = .{
            .code = code,
            .message = message,
            .recoverable = recoverable,
        },
    }, .{ .whitespace = .indent_2 });
}
