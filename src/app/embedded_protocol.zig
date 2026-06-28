const std = @import("std");

const event_log_mod = @import("../platform/common/event_log.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
const mise_en_scene_mod = @import("../core/port_mise_en_scene.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const speech_mod = @import("../api/speech_client.zig");
const chat = @import("../api/chat_client.zig");

pub const HostEvent = struct {
    id: ?[]const u8 = null,
    type: []const u8,
    request_id: ?[]const u8 = null,
    activity_id: ?[]const u8 = null,
    expression_id: ?[]const u8 = null,
    modality: ?[]const u8 = null,
    visibility: ?[]const u8 = null,
    capability: ?[]const u8 = null,
    status: ?[]const u8 = null,
    reason: ?[]const u8 = null,
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
    path: ?[]const u8 = null,
    url: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    raw_ref: ?[]const u8 = null,
    original_bytes: ?usize = null,
    theme_color: ?[]const u8 = null,

    pub fn jsonStringify(self: HostEvent, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id orelse self.stableID());
        try jw.objectField("trace_id");
        try jw.write(self.id orelse self.stableID());
        if (self.request_id) |request_id| {
            try jw.objectField("turn_id");
            try jw.write(request_id);
        }
        if (self.activity_id) |activity_id| {
            try jw.objectField("activity_id");
            try jw.write(activity_id);
        }
        try jw.objectField("source");
        try jw.write(if (std.mem.eql(u8, self.role orelse "", "user")) "user" else "brain");
        try jw.objectField("target");
        try jw.write("host");
        try jw.objectField("visibility");
        try jw.write(self.visibility orelse "public");
        try jw.objectField("presentation");
        try jw.write(if (std.mem.eql(u8, self.type, "expression")) "chat" else if (std.mem.eql(u8, self.type, "mise_en_scene")) "status" else "log");
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("payload");
        try self.writePayload(jw);
        try jw.endObject();
    }

    fn stableID(self: HostEvent) []const u8 {
        return self.expression_id orelse self.request_id orelse self.type;
    }

    fn writePayload(self: HostEvent, jw: anytype) !void {
        try jw.beginObject();
        if (std.mem.eql(u8, self.type, "expression")) {
            try jw.objectField("expression");
            try self.writeExpressionPayload(jw);
        } else if (std.mem.eql(u8, self.type, "sense_request")) {
            try jw.objectField("sense_request");
            try self.writeSenseRequestPayload(jw);
        } else if (std.mem.eql(u8, self.type, "capability_request")) {
            try jw.objectField("capability_request");
            try self.writeActionRequestPayload(jw);
        } else if (std.mem.eql(u8, self.type, "mise_en_scene")) {
            try jw.objectField("mise_en_scene");
            try self.writeMiseEnScenePayload(jw);
        } else {
            try jw.objectField("control");
            try self.writeControlPayload(jw);
        }
        try jw.endObject();
    }

    fn writeExpressionPayload(self: HostEvent, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("modality");
        try jw.write(self.modality orelse "text");
        try jw.objectField("role");
        try jw.write(self.role orelse "brain");
        try writeOptionalString(jw, "title", self.title);
        try writeOptionalString(jw, "text", self.text orelse self.body);
        try jw.objectField("media");
        try jw.beginArray();
        if (self.path != null or self.url != null) {
            try jw.write(.{
                .kind = self.modality orelse "media",
                .path = self.path,
                .url = self.url,
                .mime_type = self.mime_type,
                .caption = self.caption,
            });
        }
        try jw.endArray();
        try writeOptionalString(jw, "expression_id", self.expression_id);
        try writeOptionalString(jw, "eyes", self.eyes);
        try writeOptionalString(jw, "mouth", self.mouth);
        if (self.duration_ms) |duration_ms| {
            try jw.objectField("duration_ms");
            try jw.write(duration_ms);
        }
        try jw.endObject();
    }

    fn writeSenseRequestPayload(self: HostEvent, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("sense_id");
        try jw.write(self.sense orelse "unknown");
        try jw.objectField("sense");
        try jw.write(self.sense orelse "unknown");
        try jw.objectField("direction");
        try jw.write("pull");
        try jw.objectField("response_presentation");
        try jw.write("status");
        try jw.endObject();
    }

    fn writeActionRequestPayload(self: HostEvent, jw: anytype) !void {
        const capability = self.capability orelse "unknown";
        try jw.beginObject();
        try jw.objectField("action_id");
        try jw.write(self.id orelse self.stableID());
        try jw.objectField("action");
        try jw.write(if (std.mem.eql(u8, capability, "speech_output")) "speak" else capability);
        try jw.objectField("arguments");
        try jw.beginObject();
        if (self.text) |text| {
            try jw.objectField("text");
            try jw.write(text);
        }
        try jw.endObject();
        try jw.objectField("requires");
        try jw.beginArray();
        try jw.write(capability);
        try jw.endArray();
        try jw.objectField("await_response");
        try jw.write(false);
        try jw.endObject();
    }

    fn writeControlPayload(self: HostEvent, jw: anytype) !void {
        try jw.beginObject();
        if (self.enabled) |enabled| {
            try jw.objectField("send_enabled");
            try jw.write(enabled);
        }
        try jw.objectField("status");
        try jw.write(self.state orelse self.title orelse self.text orelse self.body orelse self.kind orelse self.type);
        try jw.endObject();
    }

    fn writeMiseEnScenePayload(self: HostEvent, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("name");
        try jw.write(self.title orelse self.text orelse "brain");
        if (self.theme_color) |theme_color| {
            try jw.objectField("theme_color");
            try jw.write(theme_color);
        }
        try jw.endObject();
    }

    fn writeOptionalString(jw: anytype, field: []const u8, value: ?[]const u8) !void {
        if (value) |actual| {
            try jw.objectField(field);
            try jw.write(actual);
        }
    }
};

pub const HostManifest = struct {
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
    \\  "platform": "macos",
    \\  "storage_provider": "file_backed_migration",
    \\  "capabilities": [
    \\    "speech_input",
    \\    "text_input",
    \\    "poke_sequence",
    \\    "short_touch",
    \\    "long_touch",
    \\    "speech_output",
    \\    "event_envelope",
    \\    "event_drain",
    \\    "uploaded_media_read",
    \\    "stored_memory_read",
    \\    "stored_memory_write",
    \\    "stored_image_read",
    \\    "camera_capture",
    \\    "provider_vision_completion",
    \\    "identity_recognition",
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
    if (std.mem.eql(u8, name, "camera_capture")) capabilities.live_camera = true else if (std.mem.eql(u8, name, "button_activation") or std.mem.eql(u8, name, "short_touch") or std.mem.eql(u8, name, "poke_sequence")) capabilities.button_activation = true else if (std.mem.eql(u8, name, "button_hold_state") or std.mem.eql(u8, name, "long_touch")) capabilities.button_hold_state = true else if (std.mem.eql(u8, name, "provider_vision_completion")) {
        capabilities.visual_description = true;
        capabilities.visual_comparison = true;
    } else if (std.mem.eql(u8, name, "face_identification") or std.mem.eql(u8, name, "identity_recognition") or std.mem.eql(u8, name, "recognition")) capabilities.identity_recognition = true else if (std.mem.eql(u8, name, "memory_read") or std.mem.eql(u8, name, "stored_memory_read")) capabilities.stored_memory_read = true else if (std.mem.eql(u8, name, "memory_write") or std.mem.eql(u8, name, "stored_memory_write")) capabilities.stored_memory_write = true else if (std.mem.eql(u8, name, "stored_image_read")) capabilities.stored_image_read = true else if (std.mem.eql(u8, name, "time_lookup")) capabilities.time_lookup = true else if (std.mem.eql(u8, name, "orientation_read") or std.mem.eql(u8, name, "orientation_query")) capabilities.orientation_query = true else if (std.mem.eql(u8, name, "power_status")) capabilities.power_status = true else if (std.mem.eql(u8, name, "storage_fullness")) capabilities.storage_fullness = true else if (std.mem.eql(u8, name, "database_stats")) capabilities.database_stats = true else if (std.mem.eql(u8, name, "speech_output")) capabilities.speech_output = true else if (std.mem.eql(u8, name, "text_input") or std.mem.eql(u8, name, "speech_input")) capabilities.user_input = true else if (std.mem.eql(u8, name, "reminder_read") or std.mem.eql(u8, name, "reminder_write") or std.mem.eql(u8, name, "reminder_io") or std.mem.eql(u8, name, "notification_schedule")) capabilities.reminder_io = true else if (std.mem.eql(u8, name, "provider_image_generation") or std.mem.eql(u8, name, "image_generation")) capabilities.image_generation = true else if (std.mem.eql(u8, name, "face_enrollment") or std.mem.eql(u8, name, "face_picture_update")) capabilities.face_picture_update = true else if (std.mem.eql(u8, name, "email_delivery")) capabilities.email_delivery = true else if (std.mem.eql(u8, name, "local_process_io")) capabilities.local_process_io = true else if (std.mem.eql(u8, name, "uploaded_media_read") or std.mem.eql(u8, name, "media_uploaded")) capabilities.uploaded_media_read = true else if (std.mem.eql(u8, name, "audio_classification")) capabilities.audio_classification = true else if (std.mem.eql(u8, name, "audio_transcription")) capabilities.audio_transcription = true else if (std.mem.eql(u8, name, "video_inspection")) capabilities.video_inspection = true else if (std.mem.eql(u8, name, "facial_expression_output")) capabilities.facial_expression_output = true else if (std.mem.eql(u8, name, "motion_gesture_read") or std.mem.eql(u8, name, "microphone_capture") or std.mem.eql(u8, name, "provider_text_completion") or std.mem.eql(u8, name, "file_import") or std.mem.eql(u8, name, "file_export") or std.mem.eql(u8, name, "import_brain") or std.mem.eql(u8, name, "export_brain") or std.mem.eql(u8, name, "event_envelope") or std.mem.eql(u8, name, "event_drain") or std.mem.eql(u8, name, "sense_catalog") or std.mem.eql(u8, name, "sense_status") or std.mem.eql(u8, name, "sense_observation") or std.mem.eql(u8, name, "mailbox_read") or std.mem.eql(u8, name, "brain_mode_read")) {} else return error.UnknownHostCapability;
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
    const path = try std.fmt.allocPrint(allocator, "fixtures/embedded_api/{s}", .{name});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(16 * 1024));
}

test "embedded host manifest maps declared capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fixture = try readEmbeddedFixture(allocator, "manifest_macos.json");
    const manifest = try parseHostManifest(allocator, fixture);
    try std.testing.expectEqualStrings("macos", manifest.platform);
    try std.testing.expect(manifest.capabilities.button_activation);
    try std.testing.expect(manifest.capabilities.button_hold_state);
    try std.testing.expect(manifest.capabilities.user_input);
    try std.testing.expect(manifest.capabilities.speech_output);
    try std.testing.expect(manifest.capabilities.stored_memory_read);
    try std.testing.expect(manifest.capabilities.stored_memory_write);
    try std.testing.expect(manifest.capabilities.identity_recognition);
    try std.testing.expect(manifest.capabilities.visual_description);
    try std.testing.expect(manifest.capabilities.reminder_io);
    try std.testing.expect(manifest.capabilities.facial_expression_output);
    try std.testing.expect(manifest.capabilities.live_camera);
}

test "embedded host manifest accepts android budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const manifest = try parseHostManifest(allocator,
        \\{
        \\  "platform": "android",
        \\  "capabilities": ["text_input", "poke_sequence", "event_envelope", "event_drain"],
        \\  "feature_flags": {},
        \\  "max_envelope_bytes": 8192,
        \\  "max_event_count": 4,
        \\  "max_event_text_bytes": 128,
        \\  "raw_ref_ttl_seconds": 60
        \\}
    );
    try std.testing.expectEqualStrings("android", manifest.platform);
    try std.testing.expectEqual(@as(usize, 8192), manifest.max_envelope_bytes);
    try std.testing.expectEqual(@as(usize, 4), manifest.max_event_count);
    try std.testing.expectEqual(@as(usize, 128), manifest.max_event_text_bytes);
    try std.testing.expectEqual(@as(i64, 60), manifest.raw_ref_ttl_seconds);
}

test "embedded host manifest accepts generic sense capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const manifest = try parseHostManifest(allocator,
        \\{
        \\  "platform": "ios",
        \\  "capabilities": ["text_input", "sense_catalog", "sense_status", "sense_observation"],
        \\  "feature_flags": {}
        \\}
    );
    try std.testing.expect(manifest.capabilities.user_input);
}

test "embedded host manifest rejects unknown introspection capability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.UnknownHostCapability, parseHostManifest(allocator,
        \\{
        \\  "platform": "macos",
        \\  "capabilities": ["text_input", "introspection"],
        \\  "feature_flags": {}
        \\}
    ));
}

test "host effect collector emits mise en scene from output port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var collector = HostEffectCollector.init(arena.allocator());
    const output = collector.miseEnSceneOutput();
    try output.apply("Mara", "green");

    const events = collector.items();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("mise_en_scene", events[0].type);
    try std.testing.expectEqualStrings("Mara", events[0].title.?);
    try std.testing.expectEqualStrings("green", events[0].theme_color.?);
}

test "host effect collector emits mise en scene payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var collector = HostEffectCollector.init(arena.allocator());
    try collector.appendMiseEnScene("Mara", "green");

    const events = collector.items();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("mise_en_scene", events[0].type);
    try std.testing.expectEqualStrings("Mara", events[0].title.?);
    try std.testing.expectEqualStrings("green", events[0].theme_color.?);
}

test "host effect collector emits public expressions for text and face output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var collector = HostEffectCollector.init(arena.allocator());
    try collector.appendEventLog("brain", "Brain", "Hello there.");
    try collector.appendFacialExpression(.{ .eyes = "focused", .mouth = "smile_closed" });

    const events = collector.items();
    try std.testing.expectEqualStrings("state", events[0].type);
    try std.testing.expectEqualStrings("expression", events[1].type);
    try std.testing.expectEqualStrings("text", events[1].modality.?);
    try std.testing.expectEqualStrings("public", events[1].visibility.?);
    try std.testing.expectEqualStrings("brain", events[1].role.?);
    try std.testing.expectEqualStrings("Hello there.", events[1].text.?);

    try std.testing.expectEqualStrings("expression", events[2].type);
    try std.testing.expectEqualStrings("face", events[2].modality.?);
    try std.testing.expectEqualStrings("focused", events[2].eyes.?);
    try std.testing.expectEqualStrings("smile_closed", events[2].mouth.?);
    try std.testing.expectEqualStrings("capability_request", events[3].type);
    try std.testing.expectEqualStrings("facial_expression_output", events[3].capability.?);
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
            .type = "capability_request",
            .capability = try self.allocator.dupe(u8, "speech_output"),
            .modality = try self.allocator.dupe(u8, "audio"),
            .visibility = try self.allocator.dupe(u8, "public"),
            .role = try self.allocator.dupe(u8, "brain"),
            .text = try self.allocator.dupe(u8, text),
        });
    }

    pub fn appendEventLog(self: *HostEffectCollector, kind: []const u8, title: []const u8, body: []const u8) !void {
        const normalized_kind = if (std.mem.eql(u8, kind, "brain")) "brain" else kind;
        const owned_kind = try self.allocator.dupe(u8, normalized_kind);
        const owned_title = try self.allocator.dupe(u8, title);
        const owned_body = try self.allocator.dupe(u8, body);
        try self.events.append(self.allocator, .{
            .type = "state",
            .kind = owned_kind,
            .title = owned_title,
            .body = owned_body,
        });
        if (std.mem.eql(u8, normalized_kind, "brain")) {
            try self.appendExpression(.{
                .modality = "text",
                .role = "brain",
                .title = title,
                .text = body,
            });
        } else if (std.mem.eql(u8, normalized_kind, "user")) {
            try self.appendExpression(.{
                .modality = "text",
                .role = "user",
                .title = title,
                .text = body,
            });
        } else if (std.mem.eql(u8, normalized_kind, "state")) {
            try self.events.append(self.allocator, .{
                .type = "state",
                .state = owned_title,
                .text = owned_body,
            });
        }
    }

    pub fn appendSendEnabled(self: *HostEffectCollector, enabled: bool) !void {
        try self.events.append(self.allocator, .{
            .type = "control",
            .state = try self.allocator.dupe(u8, "send_enabled"),
            .enabled = enabled,
        });
    }

    pub fn appendFacialExpression(self: *HostEffectCollector, expression: facial_expression.Expression) !void {
        try self.appendExpression(.{
            .modality = "face",
            .role = "brain",
            .eyes = expression.eyes,
            .mouth = expression.mouth,
            .duration_ms = expression.duration_ms,
        });
        try self.events.append(self.allocator, .{
            .type = "capability_request",
            .capability = try self.allocator.dupe(u8, "facial_expression_output"),
            .modality = try self.allocator.dupe(u8, "face"),
            .visibility = try self.allocator.dupe(u8, "public"),
            .eyes = try self.allocator.dupe(u8, expression.eyes),
            .mouth = try self.allocator.dupe(u8, expression.mouth),
            .duration_ms = expression.duration_ms,
        });
    }

    const ExpressionDraft = struct {
        modality: []const u8,
        role: []const u8 = "brain",
        title: ?[]const u8 = null,
        text: ?[]const u8 = null,
        eyes: ?[]const u8 = null,
        mouth: ?[]const u8 = null,
        duration_ms: ?u32 = null,
        path: ?[]const u8 = null,
        url: ?[]const u8 = null,
        mime_type: ?[]const u8 = null,
        caption: ?[]const u8 = null,
    };

    fn appendExpression(self: *HostEffectCollector, draft: ExpressionDraft) !void {
        const expression_id = try std.fmt.allocPrint(self.allocator, "expression_{d}", .{self.events.items.len});
        try self.events.append(self.allocator, .{
            .type = "expression",
            .expression_id = expression_id,
            .modality = try self.allocator.dupe(u8, draft.modality),
            .visibility = try self.allocator.dupe(u8, "public"),
            .role = try self.allocator.dupe(u8, draft.role),
            .title = if (draft.title) |value| try self.allocator.dupe(u8, value) else null,
            .text = if (draft.text) |value| try self.allocator.dupe(u8, value) else null,
            .eyes = if (draft.eyes) |value| try self.allocator.dupe(u8, value) else null,
            .mouth = if (draft.mouth) |value| try self.allocator.dupe(u8, value) else null,
            .duration_ms = draft.duration_ms,
            .path = if (draft.path) |value| try self.allocator.dupe(u8, value) else null,
            .url = if (draft.url) |value| try self.allocator.dupe(u8, value) else null,
            .mime_type = if (draft.mime_type) |value| try self.allocator.dupe(u8, value) else null,
            .caption = if (draft.caption) |value| try self.allocator.dupe(u8, value) else null,
        });
    }

    pub fn appendMiseEnScene(self: *HostEffectCollector, name: []const u8, theme_color: ?[]const u8) !void {
        try self.events.append(self.allocator, .{
            .type = "mise_en_scene",
            .visibility = try self.allocator.dupe(u8, "public"),
            .title = try self.allocator.dupe(u8, name),
            .theme_color = if (theme_color) |color| try self.allocator.dupe(u8, color) else null,
        });
    }

    pub fn appendCaptureRequested(self: *HostEffectCollector, title: []const u8, body: []const u8) !void {
        try self.events.append(self.allocator, .{
            .type = "sense_request",
            .sense = try self.allocator.dupe(u8, "camera"),
            .title = try self.allocator.dupe(u8, title),
            .body = try self.allocator.dupe(u8, body),
        });
    }

    pub fn appendSenseRequested(self: *HostEffectCollector, sense: []const u8, title: []const u8, body: []const u8) !void {
        try self.events.append(self.allocator, .{
            .type = "sense_request",
            .sense = try self.allocator.dupe(u8, sense),
            .title = try self.allocator.dupe(u8, title),
            .body = try self.allocator.dupe(u8, body),
        });
    }

    pub fn speechService(self: *HostEffectCollector) speech_mod.SpeechService {
        return .{ .ctx = self, .synthesizeFn = synthesize };
    }

    pub fn speaker(self: *HostEffectCollector) speaker_mod.Speaker {
        return .{ .ctx = self, .playFileFn = playFile, .playFileBackgroundFn = playFileBackground };
    }

    pub fn eventLog(self: *HostEffectCollector) event_log_mod.EventLog {
        return .{ .ctx = self, .appendFn = appendEventLogFromContext, .setSendEnabledFn = setSendEnabledFromContext };
    }

    pub fn facialExpressionOutput(self: *HostEffectCollector) facial_expression.Output {
        return .{ .ctx = self, .showFn = showFacialExpressionFromContext };
    }

    pub fn miseEnSceneOutput(self: *HostEffectCollector) mise_en_scene_mod.Output {
        return .{ .ctx = self, .applyFn = applyMiseEnSceneFromContext };
    }

    fn synthesize(ctx: *anyopaque, allocator: std.mem.Allocator, text: []const u8) !speech_mod.AudioFile {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendSpeechRequested(text);
        self.speech_index += 1;
        return .{ .path = try std.fmt.allocPrint(allocator, "embedded://speech/{d}", .{self.speech_index}) };
    }

    fn playFile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {}

    fn playFileBackground(_: *anyopaque, _: std.mem.Allocator, _: []const u8) !void {}

    fn appendEventLogFromContext(ctx: *anyopaque, kind: []const u8, title: []const u8, body: []const u8) !void {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendEventLog(kind, title, body);
    }

    fn setSendEnabledFromContext(ctx: *anyopaque, enabled: bool) !void {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendSendEnabled(enabled);
    }

    fn showFacialExpressionFromContext(ctx: *anyopaque, expression: facial_expression.Expression) !void {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendFacialExpression(expression);
    }

    fn applyMiseEnSceneFromContext(ctx: *anyopaque, name: []const u8, theme_color: ?[]const u8) !void {
        const self: *HostEffectCollector = @ptrCast(@alignCast(ctx));
        try self.appendMiseEnScene(name, theme_color);
    }
};

pub fn successEnvelopeAlloc(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    events: []const HostEvent,
    result: anytype,
    budget: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .request_id = request_id,
        .ok = true,
        .events = events,
        .result = result,
        .budget = budget,
    }, .{ .whitespace = .indent_2 });
}

pub fn errorEnvelopeAlloc(
    allocator: std.mem.Allocator,
    request_id: []const u8,
    code: []const u8,
    message: []const u8,
    recoverable: bool,
    budget: anytype,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
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
