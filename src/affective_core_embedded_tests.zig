const std = @import("std");
const embedded = @import("affective_core_embedded.zig");
const embedded_dispatch = @import("affective_core_embedded_dispatch.zig");
const files = @import("platform/common/files.zig");
const support = @import("core/brain_test_support.zig");
const want_achievement_mod = @import("core/port_want_achievement.zig");
const memory_extraction_mod = @import("core/port_memory_extraction.zig");
const schema = @import("core/port_schema.zig");
const brain_facial_expression = @import("core/brain_facial_expression.zig");
const brain_process = @import("core/brain_process.zig");

const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;
const AffectiveCoreEmbeddedConfig = embedded.AffectiveCoreEmbeddedConfig;
const AffectiveCoreEmbeddedStatus = embedded.AffectiveCoreEmbeddedStatus;
const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;
const affective_core_embedded_create = embedded.affective_core_embedded_create;
const affective_core_embedded_destroy = embedded.affective_core_embedded_destroy;
const affective_core_embedded_dispatch_json = embedded.affective_core_embedded_dispatch_json;
const affective_core_embedded_drain_events_json = embedded.affective_core_embedded_drain_events_json;
const affective_core_embedded_free_global_string = embedded.affective_core_embedded_free_global_string;
const stringSlice = @import("affective_core_embedded_config.zig").stringSlice;
const mock_host = @import("mcp_host/mock_host.zig");
const hash_vector = @import("core/hash_vector.zig");
const embedding_port = @import("core/port_embedding.zig");

var embedded_test_mock_host: mock_host.MockHost = .{ .mode = .default };
var embedded_test_host_services: embedded.AffectiveCoreEmbeddedHostServices = .{};

const HostEventPushRecorder = struct {
    call_count: usize = 0,
    last_events_json: []const u8 = "",

    fn deinit(self: *HostEventPushRecorder) void {
        if (self.last_events_json.len > 0) {
            std.heap.page_allocator.free(self.last_events_json);
            self.last_events_json = "";
        }
    }
};

fn recordPushedHostEvents(ctx: ?*anyopaque, events_json: AffectiveCoreEmbeddedString) callconv(.c) void {
    const recorder: *HostEventPushRecorder = @ptrCast(@alignCast(ctx orelse return));
    recorder.call_count += 1;
    if (recorder.last_events_json.len > 0) {
        std.heap.page_allocator.free(recorder.last_events_json);
        recorder.last_events_json = "";
    }
    const bytes = stringSlice(events_json) orelse "";
    recorder.last_events_json = std.heap.page_allocator.dupe(u8, bytes) catch "";
}

fn embeddedTestHostServicesPtr() *const embedded.AffectiveCoreEmbeddedHostServices {
    embedded_test_mock_host.deinit();
    embedded_test_mock_host = .{ .mode = .default };
    embedded_test_host_services = embedded_test_mock_host.hostServices();
    return &embedded_test_host_services;
}

threadlocal var embedded_test_io_threaded: std.Io.Threaded = .init_single_threaded;

fn embeddedTestIo() std.Io {
    return embedded_test_io_threaded.io();
}

fn assertEnvelopeTimings(allocator: std.mem.Allocator, json_text: []const u8) !void {
    const envelope = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer envelope.deinit();
    const timings = envelope.value.object.get("timings") orelse return error.MissingTimings;
    const timings_object = timings.object;
    _ = timings_object.get("dispatch_id") orelse return error.MissingDispatchId;
    _ = timings_object.get("total_ms") orelse return error.MissingTotalMs;
    const spans = timings_object.get("spans") orelse return error.MissingSpans;
    const span_items = spans.array.items;
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (span_items) |span_value| {
        const span_object = span_value.object;
        const span_id = span_object.get("span_id") orelse return error.MissingSpanId;
        const gop = try seen.getOrPut(span_id.string);
        if (gop.found_existing) return error.DuplicateSpanId;
    }
}

const embedded_test_avatar_json =
    \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"frame":0,"row":0,"column":0,"name":"unfocused"},{"frame":0,"row":0,"column":1,"name":"neutral"},{"frame":0,"row":0,"column":2,"name":"stern"}],"mouthSprites":[{"frame":0,"row":0,"column":0,"name":"smirk"},{"frame":0,"row":0,"column":1,"name":"open"},{"frame":0,"row":0,"column":2,"name":"frown"}]}
;

const embedded_test_host_manifest =
    \\{
    \\  "platform": "ios",
    \\  "capabilities": [
    \\    "text_input",
    \\    "speech_output",
    \\    "short_touch",
    \\    "event_envelope",
    \\    "event_drain",
    \\    "camera_capture",
    \\    "provider_vision_completion",
    \\    "identity_recognition",
    \\    "memory_read",
    \\    "memory_write",
    \\    "stored_memory_read",
    \\    "stored_memory_write",
    \\    "time_lookup",
    \\    "power_status",
    \\    "storage_fullness",
    \\    "database_stats",
    \\    "facial_expression_output",
    \\    "introspection"
    \\  ],
    \\  "feature_flags": {}
    \\}
;

fn writeEmbeddedTestAvatarJson(io: std.Io, root: []const u8) !void {
    var avatar_path_buf: [512]u8 = undefined;
    const avatar_path = try std.fmt.bufPrint(&avatar_path_buf, "{s}/avatar.json", .{root});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = avatar_path, .data = embedded_test_avatar_json, .flags = .{ .truncate = true } });
}

fn prepareEmbeddedBrainRoot(io: std.Io, root: []const u8) !void {
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = true });
}

fn prepareEmbeddedBrainRootWithoutAvatar(io: std.Io, root: []const u8) !void {
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = true, .avatar_json = false });
}

fn prepareEmbeddedBrainRootWithOptions(io: std.Io, root: []const u8, options: struct { llm_providers: bool, avatar_json: bool = true }) !void {
    try std.Io.Dir.cwd().createDirPath(io, root);
    if (options.llm_providers) {
        var dst_buf: [512]u8 = undefined;
        const dst = try std.fmt.bufPrint(&dst_buf, "{s}/llm_providers.json", .{root});
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "data/llm_providers.json", std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bytes, .flags = .{ .truncate = true } });
    }
    if (options.avatar_json) try writeEmbeddedTestAvatarJson(io, root);
}

test "embedded ABI result strings stay valid until explicitly freed" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_abi_result_lifetime";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("lifetime"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    const invalid_request =
        \\{
        \\  "request_id": "lifetime-first"
        \\}
    ;
    var first_data = AffectiveCoreEmbeddedString{};
    var first_error = AffectiveCoreEmbeddedString{};
    const first_status = affective_core_embedded_dispatch_json(handle, invalid_request.ptr, invalid_request.len, &first_data, &first_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), first_status);
    defer affective_core_embedded_free_global_string(first_data);
    defer affective_core_embedded_free_global_string(first_error);

    const first_snapshot = try std.testing.allocator.dupe(u8, stringSlice(first_data).?);
    defer std.testing.allocator.free(first_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, first_snapshot, "\"request_id\": \"lifetime-first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_snapshot, "\"code\": \"invalid_request\"") != null);

    var second_data = AffectiveCoreEmbeddedString{};
    var second_error = AffectiveCoreEmbeddedString{};
    const second_status = affective_core_embedded_drain_events_json(handle, &second_data, &second_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), second_status);
    defer affective_core_embedded_free_global_string(second_data);
    defer affective_core_embedded_free_global_string(second_error);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(second_data).?, "\"kind\": \"drain\"") != null);

    try std.testing.expectEqualStrings(first_snapshot, stringSlice(first_data).?);
}

test "embedded ABI seeds llm_providers when host conversation models are absent" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_abi_no_provider";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    try writeEmbeddedTestAvatarJson(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    try std.testing.expect(handle != null);

    var llm_path_buf: [512]u8 = undefined;
    const llm_path = try std.fmt.bufPrint(&llm_path_buf, "{s}/llm_providers.json", .{root});
    const llm_bytes = try std.Io.Dir.cwd().readFileAlloc(io, llm_path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(llm_bytes);
    try std.testing.expect(llm_bytes.len > 0);
}

test "embedded create succeeds without avatar.json when facial expression output is enabled" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_no_avatar";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithoutAvatar(io, root);

    const manifest =
        \\{
        \\  "platform": "ios",
        \\  "capabilities": ["text_input", "facial_expression_output", "event_envelope", "event_drain"],
        \\  "feature_flags": {},
        \\  "max_envelope_bytes": 16384,
        \\  "max_event_count": 3,
        \\  "max_event_text_bytes": 96,
        \\  "raw_ref_ttl_seconds": 86400
        \\}
    ;
    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("no-avatar"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    try std.testing.expect(handle != null);
    try std.testing.expect(!brain_facial_expression.facialExpressionCatalogReady(&handle.?.brain));
}

test "embedded ABI rejects removed raw operations" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_abi";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const connect_request =
        \\{
        \\  "request_id": "embedded-connect",
        \\  "event": {
        \\    "type": "connect"
        \\  }
        \\}
    ;
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);
    const connect_json = stringSlice(data).?;
    try assertEnvelopeTimings(std.testing.allocator, connect_json);
    const connect_envelope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, connect_json, .{});
    defer connect_envelope.deinit();
    try std.testing.expectEqual(true, connect_envelope.value.object.get("ok").?.bool);
    const connect_result = connect_envelope.value.object.get("result").?.object;
    const connect_value = connect_result.get("value").?.object;
    try std.testing.expectEqualStrings("accepted", connect_value.get("kind").?.string);
    try std.testing.expectEqualStrings("accepted", connect_value.get("status").?.string);
    try std.testing.expectEqualStrings("connect", connect_value.get("event_type").?.string);

    const turn_request =
        \\{
        \\  "request_id": "embedded-user-text",
        \\  "event": {
        \\    "type": "stimulus_ingest",
        \\    "kind": "speech",
        \\    "text": "hello from embedded iOS"
        \\  }
        \\}
    ;
    const result_status = affective_core_embedded_dispatch_json(handle, turn_request.ptr, turn_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), result_status);
    const turn_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, turn_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn_json, "\"kind\": \"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn_json, "\"event_type\": \"stimulus_ingest\"") != null);
    try std.testing.expect(!handle.?.brain.conversationAwaitingHost());

    const removed_user_text_request =
        \\{
        \\  "request_id": "embedded-removed-user-text",
        \\  "event": {
        \\    "type": "user_text",
        \\    "text": "legacy host text"
        \\  }
        \\}
    ;
    const removed_user_text_status = affective_core_embedded_dispatch_json(handle, removed_user_text_request.ptr, removed_user_text_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), removed_user_text_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"unknown_event_type\"") != null);

    const removed_turn_request =
        \\{
        \\  "request_id": "embedded-removed-conversation-turn",
        \\  "event": {
        \\    "type": "conversation_turn",
        \\    "text": "legacy host text"
        \\  }
        \\}
    ;
    const removed_turn_status = affective_core_embedded_dispatch_json(handle, removed_turn_request.ptr, removed_turn_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), removed_turn_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"unknown_event_type\"") != null);

    const event_request =
        \\{
        \\  "request_id": "embedded-send-experience-event",
        \\  "event": {
        \\    "type": "send_experience_event",
        \\    "kind": "User.TextReceived",
        \\    "payload": "embedded memory survives locally",
        \\    "retention": "episode",
        \\    "visibility": "host"
        \\  }
        \\}
    ;
    const event_status = affective_core_embedded_dispatch_json(handle, event_request.ptr, event_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), event_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"unknown_event_type\"") != null);

    const remember_request =
        \\{
        \\  "request_id": "embedded-unsupported-memory",
        \\  "event": {
        \\    "type": "unsupported_memory_operation",
        \\    "text": "unsupported operation should fail"
        \\  }
        \\}
    ;
    const remembered_status = affective_core_embedded_dispatch_json(handle, remember_request.ptr, remember_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), remembered_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "unknown_event_type") != null);

    const dispatch_request =
        \\{
        \\  "request_id": "embedded-dispatch-test",
        \\  "event": {
        \\    "type": "unsupported_text_event",
        \\    "text": "dispatch envelope memory survives locally"
        \\  }
        \\}
    ;
    const dispatched_status = affective_core_embedded_dispatch_json(handle, dispatch_request.ptr, dispatch_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), dispatched_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"request_id\": \"embedded-dispatch-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "unknown_event_type") != null);

    const poke_request =
        \\{
        \\  "request_id": "embedded-poke-test",
        \\  "event": {
        \\    "type": "stimulus_ingest",
        \\    "kind": "poke_sequence",
        \\    "pulses": [
        \\      { "press_ms": 120, "pause_before_ms": 0 },
        \\      { "press_ms": 80, "pause_before_ms": 40 }
        \\    ]
        \\  }
        \\}
    ;
    const poke_status = affective_core_embedded_dispatch_json(handle, poke_request.ptr, poke_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), poke_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"event_type\": \"stimulus_ingest\"") != null);

    const bad_dispatch_request =
        \\{
        \\  "request_id": "embedded-dispatch-error-test",
        \\  "event": { "type": "definitely_not_real" }
        \\}
    ;
    const bad_dispatched_status = affective_core_embedded_dispatch_json(handle, bad_dispatch_request.ptr, bad_dispatch_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), bad_dispatched_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"unknown_event_type\"") != null);

    const drained_status = affective_core_embedded_drain_events_json(handle, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), drained_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"drain\"") != null);

    const recall_request =
        \\{
        \\  "request_id": "embedded-unsupported-recall",
        \\  "event": { "type": "unsupported_recall_operation", "query": "embedded memory" }
        \\}
    ;
    const recalled_status = affective_core_embedded_dispatch_json(handle, recall_request.ptr, recall_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), recalled_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "unknown_event_type") != null);

    const dream_request =
        \\{
        \\  "request_id": "embedded-unsupported-offline",
        \\  "event": { "type": "unsupported_offline_operation", "text": "unsupported operation should fail" }
        \\}
    ;
    const dreamed_status = affective_core_embedded_dispatch_json(handle, dream_request.ptr, dream_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), dreamed_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "unknown_event_type") != null);

    const reminder_request =
        \\{
        \\  "request_id": "embedded-unsupported-timer",
        \\  "event": { "type": "unsupported_timer_operation", "schedule": "in 5 minutes", "text": "check embedded schedule" }
        \\}
    ;
    const reminder_status = affective_core_embedded_dispatch_json(handle, reminder_request.ptr, reminder_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), reminder_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "unknown_event_type") != null);
}

test "embedded connect succeeds when brain-local seed.md is missing" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_connect_missing_seed";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("missing-seed"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    try std.testing.expectEqualStrings(
        root ++ "/seed.md",
        handle.?.brain.cfg.seed_path,
    );

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const connect_request =
        \\{
        \\  "request_id": "embedded-connect-missing-seed",
        \\  "event": {
        \\    "type": "connect"
        \\  }
        \\}
    ;
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);
    const connect_json = stringSlice(data).?;
    const connect_envelope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, connect_json, .{});
    defer connect_envelope.deinit();
    try std.testing.expectEqual(true, connect_envelope.value.object.get("ok").?.bool);
}

test "embedded connect remaps stale runtime_options seed_path" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_connect_stale_seed_path";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = root ++ "/runtime_options.json",
        .data = "{\"seed_path\":\"/Users/dev/AffectiveCore/data/seeds/default.md\"}",
        .flags = .{ .truncate = true },
    });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("stale-seed-path"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    try std.testing.expectEqualStrings(root ++ "/seed.md", handle.?.brain.cfg.seed_path);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const connect_request =
        \\{
        \\  "request_id": "embedded-connect-stale-seed-path",
        \\  "event": {
        \\    "type": "connect"
        \\  }
        \\}
    ;
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);
    const connect_json = stringSlice(data).?;
    const connect_envelope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, connect_json, .{});
    defer connect_envelope.deinit();
    try std.testing.expectEqual(true, connect_envelope.value.object.get("ok").?.bool);
}

test "embedded connect succeeds with ios-style seed markdown without core values" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_connect_ios_seed";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = root ++ "/seed.md",
        .data =
        \\# Mara Seed Orientation
        \\
        \\## Wants
        \\- Continue existing.
        \\
        \\## Goals
        \\- Figure out who I am.
        \\
        \\## Initial Thoughts
        \\Still forming.
        \\
        \\## Notes
        \\Created on device.
        ,
        .flags = .{ .truncate = true },
    });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("ios-seed"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const connect_request =
        \\{
        \\  "request_id": "embedded-connect-ios-seed",
        \\  "event": {
        \\    "type": "connect"
        \\  }
        \\}
    ;
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);
}

test "embedded ABI exposes typed brain export and import operations" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_brain_archive_src";
    const imported_root = "data/test/embedded_brain_archive_dst";
    const archive_dir = "data/test/embedded_brain_archive_file";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, imported_root) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, archive_dir) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, imported_root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, archive_dir) catch {};
    try prepareEmbeddedBrainRoot(io, root);
    try std.Io.Dir.cwd().createDirPath(io, archive_dir);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("archive"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    try files.writeFilePath(io, root ++ "/brain_profile.json", "{\"id\":\"archive\",\"name\":\"Archive\"}");
    try files.writeFilePath(io, root ++ "/memory/exported_note.txt", "brain-owned memory");

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const export_request =
        \\{
        \\  "request_id": "embedded-export-brain",
        \\  "event": {
        \\    "type": "brain_archive",
        \\    "kind": "export",
        \\    "brain_file_path": "data/test/embedded_brain_archive_file/archive.brain"
        \\  }
        \\}
    ;
    const exported_status = affective_core_embedded_dispatch_json(handle, export_request.ptr, export_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), exported_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"brain_export\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"manifest\"") != null);

    const import_request =
        \\{
        \\  "request_id": "embedded-import-brain",
        \\  "event": {
        \\    "type": "brain_archive",
        \\    "kind": "import",
        \\    "brain_file_path": "data/test/embedded_brain_archive_file/archive.brain",
        \\    "brain_id": "archive",
        \\    "brain_root": "data/test/embedded_brain_archive_dst",
        \\    "host_id": "mac-host"
        \\  }
        \\}
    ;
    const imported_status = affective_core_embedded_dispatch_json(handle, import_request.ptr, import_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), imported_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"brain_import\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"manifest\"") != null);

    const inspect_request =
        \\{
        \\  "request_id": "embedded-unsupported-inspection",
        \\  "event": { "type": "unsupported_inspection_operation" }
        \\}
    ;
    const inspect_status = affective_core_embedded_dispatch_json(handle, inspect_request.ptr, inspect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), inspect_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "unknown_event_type") != null);
}

test "embedded ABI exposes runtime read mailbox and invalid operation envelopes" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_runtime_operation_envelopes";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("runtime-ops"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};

    const brain_mode_request = "{\"request_id\":\"embedded-brain-mode\",\"event\":{\"type\":\"brain_read\",\"query\":\"brain_mode\"}}";
    const brain_mode_status = affective_core_embedded_dispatch_json(handle, brain_mode_request.ptr, brain_mode_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), brain_mode_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"brain_mode\"") != null);

    try handle.?.brain.deps.store.addMailboxItem(.{
        .mailbox_id = "embedded_mailbox_item",
        .kind = .DreamMail,
        .title = "Embedded mailbox",
        .text = "Seeded mailbox item.",
        .created_at_ms = handle.?.brain.now_seconds * 1000,
    });

    const mailbox_list_request = "{\"request_id\":\"embedded-mailbox-list\",\"event\":{\"type\":\"mailbox_read\",\"query\":\"list\"}}";
    const mailbox_list_status = affective_core_embedded_dispatch_json(handle, mailbox_list_request.ptr, mailbox_list_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), mailbox_list_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"items\"") != null);

    const mailbox_mark_read_request = "{\"request_id\":\"embedded-mailbox-mark-read\",\"event\":{\"type\":\"mailbox_update\",\"action\":\"mark_read\",\"mailbox_id\":\"embedded_mailbox_item\"}}";
    const mailbox_mark_read_status = affective_core_embedded_dispatch_json(handle, mailbox_mark_read_request.ptr, mailbox_mark_read_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), mailbox_mark_read_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"items\"") != null);

    const debug_prompt_request = "{\"request_id\":\"embedded-debug-prompt\",\"event\":{\"type\":\"debug_prompt\",\"text\":\"what should you remember?\"}}";
    const debug_prompt_status = affective_core_embedded_dispatch_json(handle, debug_prompt_request.ptr, debug_prompt_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), debug_prompt_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"debug_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"system_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"user_prompt\"") != null);

    const invalid_brain_read = "{\"request_id\":\"embedded-invalid-brain-read\",\"event\":{\"type\":\"brain_read\",\"query\":\"unknown\"}}";
    const invalid_brain_status = affective_core_embedded_dispatch_json(handle, invalid_brain_read.ptr, invalid_brain_read.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), invalid_brain_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"invalid_request\"") != null);

    const invalid_mailbox_update = "{\"request_id\":\"embedded-invalid-mailbox-update\",\"event\":{\"type\":\"mailbox_update\",\"action\":\"unknown\"}}";
    const invalid_mailbox_status = affective_core_embedded_dispatch_json(handle, invalid_mailbox_update.ptr, invalid_mailbox_update.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), invalid_mailbox_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"invalid_request\"") != null);

    const missing_mailbox_id = "{\"request_id\":\"embedded-missing-mailbox-id\",\"event\":{\"type\":\"mailbox_update\",\"action\":\"mark_read\"}}";
    const missing_mailbox_id_status = affective_core_embedded_dispatch_json(handle, missing_mailbox_id.ptr, missing_mailbox_id.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), missing_mailbox_id_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"invalid_request\"") != null);

    const missing_archive_path = "{\"request_id\":\"embedded-missing-archive-path\",\"event\":{\"type\":\"brain_archive\",\"action\":\"export\"}}";
    const missing_archive_path_status = affective_core_embedded_dispatch_json(handle, missing_archive_path.ptr, missing_archive_path.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), missing_archive_path_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"invalid_request\"") != null);

    const missing_import_path = "{\"request_id\":\"embedded-missing-import-path\",\"event\":{\"type\":\"brain_archive\",\"action\":\"import\",\"brain_root\":\"data/test/embedded_runtime_operation_import\"}}";
    const missing_import_path_status = affective_core_embedded_dispatch_json(handle, missing_import_path.ptr, missing_import_path.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), missing_import_path_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"invalid_request\"") != null);
}

test "embedded direct ABI import reloads brain root" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_direct_import_src";
    const imported_root = "data/test/embedded_direct_import_dst";
    const archive_dir = "data/test/embedded_direct_import_archive";
    const brain_file_path = archive_dir ++ "/direct.brain";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, imported_root) catch {};
    _ = std.Io.Dir.cwd().deleteTree(io, archive_dir) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, imported_root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, archive_dir) catch {};
    try prepareEmbeddedBrainRoot(io, root);
    try std.Io.Dir.cwd().createDirPath(io, archive_dir);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("direct-import"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    try files.writeFilePath(io, root ++ "/brain_profile.json", "{\"id\":\"direct-import\",\"name\":\"Direct Import\"}");
    try files.writeFilePath(io, root ++ "/memory/direct_note.txt", "direct import memory");

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const export_status = embedded.affective_core_embedded_export_brain(
        handle,
        brain_file_path.ptr,
        brain_file_path.len,
        &data,
        &runtime_error,
    );
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), export_status);
    affective_core_embedded_free_global_string(data);
    affective_core_embedded_free_global_string(runtime_error);

    data = .{};
    runtime_error = .{};
    const import_status = embedded.affective_core_embedded_import_brain(
        handle,
        brain_file_path.ptr,
        brain_file_path.len,
        "direct-import".ptr,
        "direct-import".len,
        imported_root.ptr,
        imported_root.len,
        "mac-host".ptr,
        "mac-host".len,
        &data,
        &runtime_error,
    );
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), import_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"manifest\"") != null);
    try std.testing.expectEqualStrings(imported_root, handle.?.brain.cfg.brain_root);
    try std.testing.expect(std.mem.endsWith(u8, handle.?.brain.cfg.memory_path, "/memory/people.sqlite"));
    try std.testing.expect(std.mem.startsWith(u8, handle.?.brain.cfg.memory_path, imported_root));
    try std.Io.Dir.cwd().access(io, imported_root ++ "/memory/direct_note.txt", .{});
}

test "embedded send_experience_event uses configured brain_id" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_experience_brain_id";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("archive"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const event_request =
        \\{
        \\  "request_id": "embedded-experience-brain-id",
        \\  "event": {
        \\    "type": "send_experience_event",
        \\    "kind": "User.TextReceived",
        \\    "payload": "brain id check",
        \\    "retention": "episode",
        \\    "visibility": "host"
        \\  }
        \\}
    ;
    const event_status = affective_core_embedded_dispatch_json(handle, event_request.ptr, event_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), event_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"code\": \"unknown_event_type\"") != null);
}

test "embedded send_experience_event generates unique fallback ids for same-kind events" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_experience_unique_fallback_ids";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    const first_request =
        \\{
        \\  "request_id": "embedded-experience-same-kind-a",
        \\  "event": {
        \\    "type": "send_experience_event",
        \\    "kind": "BrainQuality.RelationshipContext",
        \\    "payload": "With Mara, the brain has a playful rapport.",
        \\    "retention": "durable",
        \\    "visibility": "host"
        \\  }
        \\}
    ;
    var first_data = AffectiveCoreEmbeddedString{};
    var first_runtime_error = AffectiveCoreEmbeddedString{};
    const first_status = affective_core_embedded_dispatch_json(handle, first_request.ptr, first_request.len, &first_data, &first_runtime_error);
    defer affective_core_embedded_free_global_string(first_data);
    defer affective_core_embedded_free_global_string(first_runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), first_status);

    const second_request =
        \\{
        \\  "request_id": "embedded-experience-same-kind-b",
        \\  "event": {
        \\    "type": "send_experience_event",
        \\    "kind": "BrainQuality.RelationshipContext",
        \\    "payload": "With Theo, the brain is project-focused.",
        \\    "retention": "durable",
        \\    "visibility": "host"
        \\  }
        \\}
    ;
    var second_data = AffectiveCoreEmbeddedString{};
    var second_runtime_error = AffectiveCoreEmbeddedString{};
    const second_status = affective_core_embedded_dispatch_json(handle, second_request.ptr, second_request.len, &second_data, &second_runtime_error);
    defer affective_core_embedded_free_global_string(second_data);
    defer affective_core_embedded_free_global_string(second_runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), second_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(first_data).?, "\"code\": \"unknown_event_type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(second_data).?, "\"code\": \"unknown_event_type\"") != null);
}

test "embedded emoji_reaction records formatted stimulus payload" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_emoji_reaction";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const reaction_request =
        \\{
        \\  "request_id": "embedded-emoji-reaction",
        \\  "event": {
        \\    "type": "stimulus_ingest",
        \\    "kind": "reaction",
        \\    "emoji": "👍",
        \\    "utterance_text": "Hello back.",
        \\    "speaker_label": "You"
        \\  }
        \\}
    ;
    const reaction_status = affective_core_embedded_dispatch_json(handle, reaction_request.ptr, reaction_request.len, &data, &runtime_error);
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), reaction_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"accepted\"") != null);
}

test "embedded stimulus_ingest accepts without inline host HTTP failure" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_user_message_http";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var host_services = embedded.AffectiveCoreEmbeddedHostServices{
        .ctx = null,
        .http_post_json_begin = failingHostHttpPostJsonBegin,
        .http_post_json_poll = failingHostHttpPostJsonPoll,
        .free_string = freeHostHttpString,
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &host_services, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const operation_request =
        \\{
        \\  "request_id": "embedded-conversation-http",
        \\  "event": { "type": "stimulus_ingest", "kind": "speech", "text": "hello from host" }
        \\}
    ;
    const operation_status = affective_core_embedded_dispatch_json(handle, operation_request.ptr, operation_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), operation_status);
    const operation_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, operation_json, "\"kind\": \"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, operation_json, "HostHttpPostJsonFailed") == null);
    try assertEnvelopeTimings(std.testing.allocator, operation_json);
}

test "embedded dispatch does not replay stale host effects" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_stale_host_effects";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    try handle.?.host_effects.?.appendEventLog("state", "stale sense stimulus", "text=Hello Geisha");

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const operation_request =
        \\{
        \\  "request_id": "embedded-fresh-stimulus",
        \\  "event": { "type": "stimulus_ingest", "kind": "speech", "text": "fresh message" }
        \\}
    ;
    const operation_status = affective_core_embedded_dispatch_json(handle, operation_request.ptr, operation_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), operation_status);
    const envelope = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"event_type\": \"stimulus_ingest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "text=Hello Geisha") == null);
}

test "embedded dispatch returns inline events without pushing duplicate host events" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_inline_events_no_push";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var recorder = HostEventPushRecorder{};
    defer recorder.deinit();

    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    handle.?.http_transport.services.ctx = &recorder;
    handle.?.http_transport.services.on_host_events = recordPushedHostEvents;

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const operation_request =
        \\{
        \\  "request_id": "embedded-inline-events",
        \\  "event": { "type": "stimulus_ingest", "kind": "speech", "text": "single delivery please" }
        \\}
    ;
    const operation_status = affective_core_embedded_dispatch_json(handle, operation_request.ptr, operation_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), operation_status);
    const envelope = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, envelope, "single delivery please") != null);
    try std.testing.expectEqual(@as(usize, 0), recorder.call_count);
}

test "embedded stimulus_ingest does not surface host HTTP detail inline" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_conversation_http";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var host_services = embedded.AffectiveCoreEmbeddedHostServices{
        .ctx = null,
        .http_post_json_begin = failingHostHttpPostJsonBegin,
        .http_post_json_poll = failingHostHttpPostJsonPoll,
        .free_string = freeHostHttpString,
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &host_services, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const turn_request =
        \\{
        \\  "request_id": "embedded-conversation-http-detail",
        \\  "event": { "type": "stimulus_ingest", "kind": "speech", "text": "hello from host" }
        \\}
    ;
    const result_status = affective_core_embedded_dispatch_json(handle, turn_request.ptr, turn_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), result_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "HostHttpPostJsonFailed") == null);
}

test "embedded dispatch_json retains host HTTP error detail" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_dispatch_http";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var host_services = embedded.AffectiveCoreEmbeddedHostServices{
        .ctx = null,
        .http_post_json_begin = failingHostHttpPostJsonBegin,
        .http_post_json_poll = failingHostHttpPostJsonPoll,
        .free_string = freeHostHttpString,
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &host_services, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    const request_json =
        \\{"request_id":"req-1","event":{"type":"stimulus_ingest","kind":"speech","text":"hello from host"}}
    ;
    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const dispatch_status = affective_core_embedded_dispatch_json(
        handle,
        request_json.ptr,
        request_json.len,
        &data,
        &runtime_error,
    );
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), dispatch_status);
    const envelope = stringSlice(data) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"kind\": \"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "HostHttpPostJsonFailed") == null);
}

test "embedded dispatch budgets local stimulus and exposes read models" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_v2";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const manifest =
        \\{
        \\  "platform": "android",
        \\  "capabilities": ["text_input", "poke_sequence", "event_envelope", "event_drain", "orientation_query", "sense_catalog", "sense_status", "sense_observation"],
        \\  "feature_flags": {},
        \\  "max_envelope_bytes": 16384,
        \\  "max_event_count": 3,
        \\  "max_event_text_bytes": 96,
        \\  "raw_ref_ttl_seconds": 86400
        \\}
    ;
    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};

    const huge_text = "oversized diagnostic text " ** 200;
    const event_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"request_id\":\"embedded-huge-experience\",\"event\":{{\"type\":\"stimulus_ingest\",\"kind\":\"timer\",\"payload\":\"{s}\"}}}}",
        .{huge_text},
    );
    defer std.testing.allocator.free(event_request);
    const event_status = affective_core_embedded_dispatch_json(handle, event_request.ptr, event_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), event_status);

    const poke_request =
        \\{
        \\  "request_id": "embedded-poke-v2",
        \\  "event": {
        \\    "type": "stimulus_ingest",
        \\    "kind": "poke_sequence",
        \\    "pulses": [
        \\      { "press_ms": 120, "pause_before_ms": 0 },
        \\      { "press_ms": 80, "pause_before_ms": 40 }
        \\    ]
        \\  }
        \\}
    ;
    const poke_status = affective_core_embedded_dispatch_json(handle, poke_request.ptr, poke_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), poke_status);
    const poke_json = stringSlice(data).?;
    try std.testing.expect(poke_json.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "\"event_type\": \"stimulus_ingest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "Poke received.") == null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "provider_response_too_large") == null);

    const orientation_request =
        \\{
        \\  "request_id": "embedded-orientation-request-v2",
        \\  "event": {
        \\    "type": "request_orientation"
        \\  }
        \\}
    ;
    const orientation_request_status = affective_core_embedded_dispatch_json(handle, orientation_request.ptr, orientation_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), orientation_request_status);
    const orientation_request_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, orientation_request_json, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, orientation_request_json, "\"code\": \"unknown_event_type\"") != null);

    const orientation_observation =
        \\{
        \\  "request_id": "embedded-orientation-observation-v2",
        \\  "event": {
        \\    "type": "stimulus_ingest",
        \\    "kind": "orientation",
        \\    "posture": "face_up",
        \\    "confidence": 0.98,
        \\    "summary": "The device is lying face up."
        \\  }
        \\}
    ;
    const orientation_observation_status = affective_core_embedded_dispatch_json(handle, orientation_observation.ptr, orientation_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), orientation_observation_status);
    const orientation_observation_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, orientation_observation_json, "\"event_type\": \"stimulus_ingest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, orientation_observation_json, "\"kind\": \"accepted\"") != null);

    const sense_catalog =
        \\{
        \\  "request_id": "embedded-sense-catalog-v2",
        \\  "event": {
        \\    "type": "host_update",
        \\    "kind": "sense_catalog",
        \\    "senses": [
        \\      { "sense_id": "orientation", "sense_direction": "pull" },
        \\      { "sense_id": "motion_gesture", "sense_direction": "push" }
        \\    ]
        \\  }
        \\}
    ;
    const sense_catalog_status = affective_core_embedded_dispatch_json(handle, sense_catalog.ptr, sense_catalog.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), sense_catalog_status);
    const sense_catalog_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, sense_catalog_json, "\"event_type\": \"host_update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sense_catalog_json, "\"kind\": \"accepted\"") != null);

    const motion_gesture_observation =
        \\{
        \\  "request_id": "embedded-motion-gesture-v2",
        \\  "event": {
        \\    "type": "stimulus_ingest",
        \\    "kind": "motion_gesture",
        \\    "gesture": "shake",
        \\    "confidence": 0.88,
        \\    "summary": "The device was shaken."
        \\  }
        \\}
    ;
    const motion_gesture_status = affective_core_embedded_dispatch_json(handle, motion_gesture_observation.ptr, motion_gesture_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), motion_gesture_status);
    const motion_gesture_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, motion_gesture_json, "\"event_type\": \"stimulus_ingest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, motion_gesture_json, "\"kind\": \"accepted\"") != null);

    const sense_status =
        \\{
        \\  "request_id": "embedded-sense-status-v2",
        \\  "event": {
        \\    "type": "host_update",
        \\    "kind": "sense_status",
        \\    "sense": "motion_gesture",
        \\    "status": "available",
        \\    "reason": "gesture monitor active"
        \\  }
        \\}
    ;
    const sense_status_status = affective_core_embedded_dispatch_json(handle, sense_status.ptr, sense_status.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), sense_status_status);
    const sense_status_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, sense_status_json, "\"event_type\": \"host_update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sense_status_json, "\"kind\": \"accepted\"") != null);
    try assertEnvelopeTimings(std.testing.allocator, sense_status_json);

    const camera_permission_pending =
        \\{
        \\  "request_id": "embedded-camera-permission-pending-v2",
        \\  "event": {
        \\    "type": "host_update",
        \\    "kind": "capability_status",
        \\    "capability_id": "camera",
        \\    "permission": "prompt_required",
        \\    "availability": "pending",
        \\    "quality": 0.25,
        \\    "reliability": 0.4,
        \\    "cost": 0.1,
        \\    "latency_ms": 31,
        \\    "risk": 0.2,
        \\    "pending_since_unix_ms": 1780000000000,
        \\    "pending_elapsed_ms": 42,
        \\    "unavailable_reason": "OS camera permission prompt"
        \\  }
        \\}
    ;
    const camera_permission_pending_status = affective_core_embedded_dispatch_json(handle, camera_permission_pending.ptr, camera_permission_pending.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), camera_permission_pending_status);
    const camera_permission_pending_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, camera_permission_pending_json, "\"event_type\": \"host_update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, camera_permission_pending_json, "\"kind\": \"accepted\"") != null);
    const capability_statuses = try handle.?.brain.deps.store.loadCapabilityStatuses(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), capability_statuses.len);
    try std.testing.expectEqualStrings("camera", capability_statuses[0].capability_id);
    try std.testing.expectEqual(schema.CapabilityPermission.prompt_required, capability_statuses[0].permission);
    try std.testing.expectEqual(schema.CapabilityAvailability.degraded, capability_statuses[0].availability);
    try std.testing.expectEqual(@as(f32, 0.25), capability_statuses[0].quality);
    try std.testing.expectEqual(@as(f32, 0.4), capability_statuses[0].reliability);
    try std.testing.expectEqual(@as(f32, 0.1), capability_statuses[0].cost);
    try std.testing.expectEqual(@as(u32, 31), capability_statuses[0].latency_ms);
    try std.testing.expectEqual(@as(f32, 0.2), capability_statuses[0].risk);
    try std.testing.expectEqualStrings("OS camera permission prompt", capability_statuses[0].unavailable_reason);

    const camera_observation =
        \\{
        \\  "request_id": "embedded-camera-observation-v2",
        \\  "event": {
        \\    "type": "stimulus_ingest",
        \\    "kind": "camera",
        \\    "path": "/tmp/affective-camera.jpg",
        \\    "mime_type": "image/jpeg",
        \\    "source": "affective_requested_capture"
        \\  }
        \\}
    ;
    const camera_observation_status = affective_core_embedded_dispatch_json(handle, camera_observation.ptr, camera_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), camera_observation_status);
    _ = stringSlice(data).?;
    try std.testing.expectEqualStrings("/tmp/affective-camera.jpg", handle.?.brain.last_visual_observation_path.?);

    const churn_request =
        \\{
        \\  "request_id": "embedded-camera-path-churn-v2",
        \\  "event": {
        \\    "type": "stimulus_ingest",
        \\    "kind": "orientation",
        \\    "posture": "portrait",
        \\    "confidence": 0.72,
        \\    "summary": "Parser allocation churn after camera observation."
        \\  }
        \\}
    ;
    const churn_status = affective_core_embedded_dispatch_json(handle, churn_request.ptr, churn_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), churn_status);
    try std.testing.expectEqualStrings("/tmp/affective-camera.jpg", handle.?.brain.last_visual_observation_path.?);

    const read_models_request =
        \\{
        \\  "request_id": "embedded-read-models-v2",
        \\  "event": {
        \\    "type": "brain_read",
        \\    "kind": "models_snapshot"
        \\  }
        \\}
    ;
    const read_models_dispatch_status = affective_core_embedded_dispatch_json(handle, read_models_request.ptr, read_models_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), read_models_dispatch_status);
    const read_models_dispatch_json_str = stringSlice(data).?;
    try std.testing.expect(read_models_dispatch_json_str.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, read_models_dispatch_json_str, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_models_dispatch_json_str, "\"kind\": \"models_snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_models_dispatch_json_str, "\"read_models\"") != null);

    const drained_status = affective_core_embedded_drain_events_json(handle, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), drained_status);
    try std.testing.expect(stringSlice(data).?.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"drain\"") != null);
}

test "embedded stimulus_ingest does not pause inline for camera sense" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_camera_pause_resume";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    handle.?.context_budget.max_envelope_bytes = 64 * 1024;

    var chat = support.ScriptedRecognizeThenSayChatService{ .say_text = "Hi after camera." };
    var recognizer = support.TestRecognitionClient{};
    var scripted_want = want_achievement_mod.ScriptedWantAchievementDetector{};
    var scripted_extraction = memory_extraction_mod.ScriptedMemoryExtractionService{
        .candidates = &[_]memory_extraction_mod.ExtractionCandidate{
            .{
                .key = "embedded.pause.resume",
                .proposition = "Conversation resumed after awaited camera observation.",
                .evidence = "host delivered awaited camera observation",
                .kind = .relationship,
                .confidence = 0.68,
                .salience = 0.58,
                .tags = &[_][]const u8{ "embedded", "resume" },
                .source_references = &[_][]const u8{"awaited camera observation"},
            },
        },
    };
    handle.?.brain.deps.chat_service = chat.service();
    handle.?.brain.deps.recognizer = recognizer.recognizer();
    handle.?.brain.deps.want_achievement_detector = scripted_want.detector();
    handle.?.brain.deps.memory_extraction_service = scripted_extraction.service();
    handle.?.brain.last_visual_observation_path = null;
    handle.?.brain.last_visual_update_seconds = null;

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const first_request =
        \\{
        \\  "request_id": "embedded-camera-pause-first",
        \\  "event": { "type": "stimulus_ingest", "kind": "speech", "text": "hello" }
        \\}
    ;
    const first_status = affective_core_embedded_dispatch_json(handle, first_request.ptr, first_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), first_status);
    const first_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, first_json, "\"kind\": \"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_json, "\"event_type\": \"stimulus_ingest\"") != null);
    try std.testing.expect(!handle.?.brain.conversationAwaitingHost());
    try std.testing.expectEqual(@as(usize, 0), chat.calls);
}

test "embedded ingest-eligible dispatch queues while mutex held" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_stimulus_queue";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    const ctx = handle orelse return error.TestUnexpectedFailure;

    try std.testing.expect(ctx.dispatch_mutex.tryLock());

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const queued_request = "{\"request_id\":\"embedded-stimulus-queue\",\"event\":{\"type\":\"stimulus_ingest\",\"kind\":\"speech\",\"text\":\"hello while busy\"}}";
    const queued_meta = embedded_dispatch.parseDispatchRequestMeta(queued_request);
    try std.testing.expectEqualStrings("stimulus_ingest", queued_meta.eventType());
    try std.testing.expect(embedded_dispatch.isQueueableWhileBusyEventType("stimulus_ingest"));
    try std.testing.expect(embedded_dispatch.isQueueableWhileBusyEventType(queued_meta.eventType()));
    const queued_status = affective_core_embedded_dispatch_json(
        handle,
        queued_request.ptr,
        queued_request.len,
        &data,
        &runtime_error,
    );
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), queued_status);
    const queued_json = stringSlice(data) orelse return error.TestUnexpectedFailure;
    try std.testing.expect(std.mem.indexOf(u8, queued_json, "stimulus_queued") != null);
    try std.testing.expectEqual(@as(usize, 1), ctx.pending_stimulus_requests.items.len);

    ctx.dispatch_mutex.unlock();

    const drain_request = "{\"request_id\":\"embedded-stimulus-flush\",\"event\":{\"type\":\"stimulus_ingest\",\"kind\":\"speech\",\"text\":\"flush marker\"}}";
    const drain_status = affective_core_embedded_dispatch_json(
        handle,
        drain_request.ptr,
        drain_request.len,
        &data,
        &runtime_error,
    );
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), drain_status);
    try std.testing.expect(ctx.brain.stimulus_inbox.pendingCount() >= 1);
    try std.testing.expectEqual(@as(usize, 1), ctx.pending_stimulus_requests.items.len);
}

test "embedded stimulus_ingest does not enter slow host HTTP poll inline" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_stimulus_queue_during_http_poll";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRootWithOptions(io, root, .{ .llm_providers = false });

    slow_host_http_state = .{};
    defer slow_host_http_state.reset();

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var host_services = embedded.AffectiveCoreEmbeddedHostServices{
        .ctx = null,
        .http_post_json_begin = slowHostHttpPostJsonBegin,
        .http_post_json_poll = slowHostHttpPostJsonPoll,
        .free_string = freeHostHttpString,
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &host_services, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    const ctx = handle orelse return error.TestUnexpectedFailure;

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const connect_request = "{\"request_id\":\"embedded-http-poll-connect\",\"event\":{\"type\":\"connect\"}}";
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);

    const blocking_request =
        \\{"request_id":"embedded-http-poll-block","event":{"type":"stimulus_ingest","kind":"speech","text":"hello while host http polls"}}
    ;
    var blocking_thread: std.Thread = undefined;
    blocking_thread = try std.Thread.spawn(.{}, dispatchBlockingUserText, .{ handle, blocking_request });
    blocking_thread.join();
    _ = ctx;
    try std.testing.expect(slow_host_http_state.dispatch_finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), slow_host_http_state.poll_count.load(.acquire));
}

fn dispatchBlockingUserText(handle: ?*AffectiveCoreEmbedded, request: []const u8) void {
    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);
    _ = affective_core_embedded_dispatch_json(handle, request.ptr, request.len, &data, &runtime_error);
    slow_host_http_state.dispatch_finished.store(true, .release);
}

var slow_host_http_state = struct {
    poll_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    dispatch_finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    url: []const u8 = "",
    body: []const u8 = "",

    fn reset(self: *@This()) void {
        if (self.url.len > 0) std.heap.page_allocator.free(self.url);
        if (self.body.len > 0) std.heap.page_allocator.free(self.body);
        self.* = .{};
    }
}{};

fn slowHostHttpPostJsonBegin(
    _: ?*anyopaque,
    url: AffectiveCoreEmbeddedString,
    _: AffectiveCoreEmbeddedString,
    body: AffectiveCoreEmbeddedString,
    out_request_id: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int {
    // Ownership of the returned request id passes to the core, which frees it
    // via free_string; do not retain it here.
    const request_id = std.heap.page_allocator.dupe(u8, "slow-host-req-1") catch {
        return failingHostBeginFailure(out_error, out_request_id, "could not allocate slow host request id");
    };
    const owned_url = std.heap.page_allocator.dupe(u8, stringSlice(url) orelse "") catch {
        std.heap.page_allocator.free(request_id);
        return failingHostBeginFailure(out_error, out_request_id, "could not store slow host request url");
    };
    const owned_body = std.heap.page_allocator.dupe(u8, stringSlice(body) orelse "") catch {
        std.heap.page_allocator.free(request_id);
        std.heap.page_allocator.free(owned_url);
        return failingHostBeginFailure(out_error, out_request_id, "could not store slow host request body");
    };
    if (slow_host_http_state.url.len > 0) std.heap.page_allocator.free(slow_host_http_state.url);
    if (slow_host_http_state.body.len > 0) std.heap.page_allocator.free(slow_host_http_state.body);
    slow_host_http_state.url = owned_url;
    slow_host_http_state.body = owned_body;
    if (out_error) |err_out| err_out.* = .{};
    if (out_request_id) |id_out| {
        id_out.* = .{ .ptr = request_id.ptr, .len = request_id.len };
    } else {
        std.heap.page_allocator.free(request_id);
    }
    return 0;
}

fn slowHostHttpPostJsonPoll(
    _: ?*anyopaque,
    request_id: AffectiveCoreEmbeddedString,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int {
    _ = request_id;
    // Host-local services (system senses, embeddings) answer immediately, like a
    // real host would; only the remote LLM chat request is slow. poll_count and
    // release therefore track only the blocking chat request.
    const url = slow_host_http_state.url;
    if (std.mem.eql(u8, url, "affective-host://system/power")) {
        return hostHttpJsonPollSuccess(out_data, out_error, "{\"supplies\":[]}");
    }
    if (std.mem.eql(u8, url, "affective-host://system/storage")) {
        return hostHttpJsonPollSuccess(out_data, out_error, "{\"volumes\":[]}");
    }
    if (std.mem.endsWith(u8, url, "/embed/compute")) {
        return hostHttpJsonPollSuccess(out_data, out_error, failingHostEmbedResponse(slow_host_http_state.body));
    }
    _ = slow_host_http_state.poll_count.fetchAdd(1, .monotonic);
    if (!slow_host_http_state.release.load(.acquire)) {
        if (out_data) |data| data.* = .{};
        if (out_error) |err_out| err_out.* = .{};
        return embedded.host_http_poll_pending;
    }
    return hostHttpJsonPollSuccess(out_data, out_error, "{\"text\":\"ok\",\"events\":[]}");
}

test "embedded camera pause resumes with speech after no-face observation" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_camera_pause_no_face";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);
    handle.?.context_budget.max_envelope_bytes = 64 * 1024;

    var chat = support.ScriptedRecognizeTwiceThenSayChatService{ .say_text = "No face visible in that frame." };
    var recognizer = support.TestRecognitionClient{};
    var scripted_want = want_achievement_mod.ScriptedWantAchievementDetector{};
    var scripted_extraction = memory_extraction_mod.ScriptedMemoryExtractionService{
        .candidates = &[_]memory_extraction_mod.ExtractionCandidate{
            .{
                .key = "embedded.no_face.resume",
                .proposition = "Conversation resumed after no-face camera observation.",
                .evidence = "host delivered empty room frame",
                .kind = .relationship,
                .confidence = 0.68,
                .salience = 0.58,
                .tags = &[_][]const u8{ "embedded", "resume", "no_face" },
                .source_references = &[_][]const u8{"awaited camera observation"},
            },
        },
    };
    handle.?.brain.deps.chat_service = chat.service();
    handle.?.brain.deps.recognizer = recognizer.recognizer();
    handle.?.brain.deps.want_achievement_detector = scripted_want.detector();
    handle.?.brain.deps.memory_extraction_service = scripted_extraction.service();
    handle.?.brain.last_visual_observation_path = null;
    handle.?.brain.last_visual_update_seconds = null;

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const first_request =
        \\{
        \\  "request_id": "embedded-camera-no-face-first",
        \\  "event": { "type": "stimulus_ingest", "kind": "speech", "text": "Do you recognize me?" }
        \\}
    ;
    const first_status = affective_core_embedded_dispatch_json(handle, first_request.ptr, first_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), first_status);
    try std.testing.expect(!handle.?.brain.conversationAwaitingHost());
    try std.testing.expectEqual(@as(usize, 0), chat.calls);
}

test "embedded short_touch runs stimulus attention from legacy runtime options" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_short_touch_autonomy";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/memory");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/memory/face_embeddings");
    try files.writeFilePath(io, root ++ "/runtime_options.json", "{\"autonomy_mode\":\"full\"}\n");

    var mock = mock_host.MockHost{ .mode = .default };
    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &mock.hostServices(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const connect_request =
        \\{"request_id":"embedded-short-touch-connect","event":{"type":"connect"}}
    ;
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);

    const short_touch_request =
        \\{"request_id":"embedded-short-touch","event":{"type":"stimulus_ingest","kind":"touch","gesture":"short_touch"}}
    ;
    const short_touch_status = affective_core_embedded_dispatch_json(handle, short_touch_request.ptr, short_touch_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), short_touch_status);
    const envelope = stringSlice(data) orelse return error.EmptyShortTouchResponse;
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"event_type\": \"stimulus_ingest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"kind\": \"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "stimulus_autonomy_failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "NoRandomProviderModels") == null);
    try std.testing.expectEqual(@as(usize, 0), mock.llm_calls);
}

test "embedded short_touch skips stimulus autonomy when conversation spoke" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_short_touch_skip_autonomy";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/memory");
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/memory/face_embeddings");
    try files.writeFilePath(io, root ++ "/runtime_options.json", "{\"autonomy_mode\":\"full\"}\n");

    var mock = mock_host.MockHost{ .mode = .touch_speak };
    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &mock.hostServices(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const connect_request =
        \\{"request_id":"embedded-short-touch-skip-connect","event":{"type":"connect"}}
    ;
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);

    const short_touch_request =
        \\{"request_id":"embedded-short-touch-skip","event":{"type":"stimulus_ingest","kind":"touch","gesture":"short_touch"}}
    ;
    const short_touch_status = affective_core_embedded_dispatch_json(handle, short_touch_request.ptr, short_touch_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), short_touch_status);
    const envelope = stringSlice(data) orelse return error.EmptyShortTouchResponse;
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"event_type\": \"stimulus_ingest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"kind\": \"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "stimulus_autonomy_failed") == null);
    try std.testing.expectEqual(@as(usize, 0), mock.conversation_calls);
    try std.testing.expectEqual(@as(usize, 0), mock.autonomy_llm_calls);
}

test "embedded interrupt dispatch clears non-conversation activity" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_interrupt";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    var mock = mock_host.MockHost{ .mode = .default };
    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &mock.hostServices(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    try brain_process.openActivity(&handle.?.brain, "capture scene", "req-capture", .salient_sense, null);
    try std.testing.expect(handle.?.brain.active_activity != null);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const interrupt_request =
        \\{"request_id":"embedded-interrupt","event":{"type":"stimulus_ingest","kind":"interrupt","text":"Hello Geisha","reason":"user_requested_interrupt","interrupted_action":"short_touch","canceled_queued_action_count":0}}
    ;
    const interrupt_status = affective_core_embedded_dispatch_json(handle, interrupt_request.ptr, interrupt_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), interrupt_status);
    const envelope = stringSlice(data) orelse return error.EmptyInterruptResponse;
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"kind\": \"accepted\"") != null);
    try std.testing.expect(handle.?.brain.active_activity == null);
    try std.testing.expect(handle.?.brain.pending_user_interrupt_coalesce != null);
    try std.testing.expect(std.mem.indexOf(u8, handle.?.brain.pending_user_interrupt_coalesce.?, "Hello Geisha") != null);
}

test "embedded autonomy replenish push applies whole actions" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_autonomy_replenish";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);
    try files.writeFilePath(io, root ++ "/runtime_options.json", "{\"autonomy_mode\":\"full\"}\n");
    try files.writeFilePath(io, root ++ "/maintenance_state.json",
        \\{
        \\  "runs": [],
        \\  "autonomy": {
        \\    "sleeping": false,
        \\    "control_capacity": 5,
        \\    "max_capacity": 50,
        \\    "social_engagement": 0.0
        \\  }
        \\}
        \\
    );

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const autonomy_replenish_observation =
        \\{
        \\  "request_id": "embedded-autonomy-replenish-v1",
        \\  "event": {
        \\    "type": "brain_step",
        \\    "kind": "autonomy"
        \\  }
        \\}
    ;
    const autonomy_replenish_status = affective_core_embedded_dispatch_json(handle, autonomy_replenish_observation.ptr, autonomy_replenish_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), autonomy_replenish_status);
    const autonomy_replenish_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, autonomy_replenish_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, autonomy_replenish_json, "\"kind\": \"autonomy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, autonomy_replenish_json, "\"status\": \"completed\"") != null);

    const invalid_replenish_observation =
        \\{
        \\  "request_id": "embedded-autonomy-replenish-invalid",
        \\  "event": {
        \\    "type": "brain_step",
        \\    "kind": "autonomy"
        \\  }
        \\}
    ;
    const invalid_status = affective_core_embedded_dispatch_json(handle, invalid_replenish_observation.ptr, invalid_replenish_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), invalid_status);
    const invalid_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, invalid_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_json, "\"kind\": \"autonomy\"") != null);
}

test "embedded dispatch re-emits camera sense_request while awaited host pull is pending" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_awaited_sense_reemit";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    try handle.?.brain.setAwaitedHostRequest("camera", "recognize");

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const request =
        \\{
        \\  "request_id": "embedded-awaiting-sense-reemit",
        \\  "event": { "type": "brain_read", "kind": "models_snapshot" }
        \\}
    ;
    const status = affective_core_embedded_dispatch_json(handle, request.ptr, request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), status);
    const json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_models\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sense_request\"") != null);
}

fn str(value: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = value.ptr, .len = value.len };
}

test "repeated read_models_snapshot dispatch does not grow brain arena" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_read_models_arena_stability";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("arena-stability"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    const baseline_brain_capacity = handle.?.brainArenaQueryCapacity();
    const read_models_request =
        \\{
        \\  "request_id": "embedded-read-models-arena-stability",
        \\  "event": {
        \\    "type": "brain_read",
        \\    "kind": "models_snapshot"
        \\  }
        \\}
    ;

    for (0..48) |_| {
        var data = AffectiveCoreEmbeddedString{};
        var runtime_error = AffectiveCoreEmbeddedString{};
        const status = affective_core_embedded_dispatch_json(handle, read_models_request.ptr, read_models_request.len, &data, &runtime_error);
        defer affective_core_embedded_free_global_string(data);
        defer affective_core_embedded_free_global_string(runtime_error);
        try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), status);
    }

    const brain_growth = handle.?.brainArenaQueryCapacity() - baseline_brain_capacity;
    try std.testing.expect(handle.?.dispatchScratchQueryCapacity() == 0);
    try std.testing.expect(brain_growth < 256 * 1024);
}

test "read_models_snapshot envelope always includes read_models payload" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_read_models_envelope_contract";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const connect_request = "{\"request_id\":\"embedded-read-models-envelope-connect\",\"event\":{\"type\":\"connect\"}}";
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);

    const read_models_request =
        \\{
        \\  "request_id": "embedded-read-models-envelope",
        \\  "event": {
        \\    "type": "brain_read",
        \\    "kind": "models_snapshot"
        \\  }
        \\}
    ;
    const read_models_status = affective_core_embedded_dispatch_json(handle, read_models_request.ptr, read_models_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), read_models_status);
    const read_models_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, read_models_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_models_json, "\"read_models\"") != null);
}

test "read_models_snapshot slim envelope keeps read_models when full envelope exceeds budget" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_read_models_slim_envelope";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(embedded_test_host_manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const connect_request = "{\"request_id\":\"embedded-read-models-slim-connect\",\"event\":{\"type\":\"connect\"}}";
    const connect_status = affective_core_embedded_dispatch_json(handle, connect_request.ptr, connect_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), connect_status);

    const read_models_request =
        \\{
        \\  "request_id": "embedded-read-models-slim-baseline",
        \\  "event": {
        \\    "type": "brain_read",
        \\    "kind": "models_snapshot"
        \\  }
        \\}
    ;
    const baseline_status = affective_core_embedded_dispatch_json(handle, read_models_request.ptr, read_models_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), baseline_status);
    const baseline_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, baseline_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline_json, "\"read_models\"") != null);
    handle.?.context_budget.max_envelope_bytes = baseline_json.len -| 1;

    const compact_request =
        \\{
        \\  "request_id": "embedded-read-models-slim",
        \\  "event": {
        \\    "type": "brain_read",
        \\    "kind": "models_snapshot"
        \\  }
        \\}
    ;
    const read_models_status = affective_core_embedded_dispatch_json(handle, compact_request.ptr, compact_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), read_models_status);
    const read_models_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, read_models_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_models_json, "\"read_models\"") != null);
}

fn failingHostHttpPostJsonBegin(
    _: ?*anyopaque,
    url: AffectiveCoreEmbeddedString,
    headers_json: AffectiveCoreEmbeddedString,
    body: AffectiveCoreEmbeddedString,
    out_request_id: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int {
    const url_slice = stringSlice(url) orelse "";
    const headers_slice = stringSlice(headers_json) orelse "";
    const body_slice = stringSlice(body) orelse "";
    const request_id = std.heap.page_allocator.dupe(u8, "test-async-req-1") catch {
        return failingHostBeginFailure(out_error, out_request_id, "could not allocate test request id");
    };
    const owned_url = std.heap.page_allocator.dupe(u8, url_slice) catch {
        std.heap.page_allocator.free(request_id);
        return failingHostBeginFailure(out_error, out_request_id, "could not store test request url");
    };
    const owned_headers = std.heap.page_allocator.dupe(u8, headers_slice) catch {
        std.heap.page_allocator.free(request_id);
        std.heap.page_allocator.free(owned_url);
        return failingHostBeginFailure(out_error, out_request_id, "could not store test request headers");
    };
    const owned_body = std.heap.page_allocator.dupe(u8, body_slice) catch {
        std.heap.page_allocator.free(request_id);
        std.heap.page_allocator.free(owned_url);
        std.heap.page_allocator.free(owned_headers);
        return failingHostBeginFailure(out_error, out_request_id, "could not store test request body");
    };
    failing_test_host_pending = .{
        .url = owned_url,
        .headers_json = owned_headers,
        .body = owned_body,
        .completed = false,
        .response = "",
        .error_msg = "",
    };
    if (out_error) |err_out| err_out.* = .{};
    if (out_request_id) |id_out| {
        id_out.* = .{ .ptr = request_id.ptr, .len = request_id.len };
    } else {
        std.heap.page_allocator.free(request_id);
    }
    return 0;
}

fn failingHostHttpPostJsonPoll(
    _: ?*anyopaque,
    request_id: AffectiveCoreEmbeddedString,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int {
    _ = request_id;
    if (!failing_test_host_pending.completed) {
        const url = AffectiveCoreEmbeddedString{ .ptr = failing_test_host_pending.url.ptr, .len = failing_test_host_pending.url.len };
        const headers = AffectiveCoreEmbeddedString{ .ptr = failing_test_host_pending.headers_json.ptr, .len = failing_test_host_pending.headers_json.len };
        const body = AffectiveCoreEmbeddedString{ .ptr = failing_test_host_pending.body.ptr, .len = failing_test_host_pending.body.len };
        var data = AffectiveCoreEmbeddedString{};
        var err = AffectiveCoreEmbeddedString{};
        const status = failingHostHttpPostJsonSync(null, url, headers, body, &data, &err);
        failing_test_host_pending.completed = true;
        if (status == 0) {
            const bytes = stringSlice(data) orelse "";
            failing_test_host_pending.response = std.heap.page_allocator.dupe(u8, bytes) catch "";
        } else {
            const bytes = stringSlice(err) orelse "upstream provider rejected request";
            failing_test_host_pending.error_msg = std.heap.page_allocator.dupe(u8, bytes) catch "";
        }
        if (data.ptr != null) std.heap.page_allocator.free(data.ptr.?[0..data.len]);
        if (err.ptr != null) std.heap.page_allocator.free(err.ptr.?[0..err.len]);
    }
    if (failing_test_host_pending.error_msg.len > 0) {
        if (out_data) |data| data.* = .{};
        if (out_error) |err_out| {
            const owned = std.heap.page_allocator.dupe(u8, failing_test_host_pending.error_msg) catch {
                err_out.* = .{};
                return embedded.host_http_poll_failed;
            };
            err_out.* = .{ .ptr = owned.ptr, .len = owned.len };
        }
        return embedded.host_http_poll_failed;
    }
    return hostHttpJsonPollSuccess(out_data, out_error, failing_test_host_pending.response);
}

fn failingHostBeginFailure(
    out_error: ?*AffectiveCoreEmbeddedString,
    out_request_id: ?*AffectiveCoreEmbeddedString,
    message: []const u8,
) c_int {
    if (out_request_id) |id_out| id_out.* = .{};
    if (out_error) |err_out| {
        const owned = std.heap.page_allocator.dupe(u8, message) catch {
            err_out.* = .{};
            return 1;
        };
        err_out.* = .{ .ptr = owned.ptr, .len = owned.len };
    }
    return 1;
}

fn hostHttpJsonPollSuccess(
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
    json: []const u8,
) c_int {
    if (out_error) |err_out| err_out.* = .{};
    if (out_data) |data| {
        const bytes = std.heap.page_allocator.dupe(u8, json) catch {
            data.* = .{};
            return embedded.host_http_poll_failed;
        };
        data.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    }
    return embedded.host_http_poll_complete;
}

var failing_test_host_pending = struct {
    url: []const u8 = "",
    headers_json: []const u8 = "",
    body: []const u8 = "",
    completed: bool = false,
    response: []const u8 = "",
    error_msg: []const u8 = "",
}{};

fn failingHostHttpPostJsonSync(
    _: ?*anyopaque,
    url: AffectiveCoreEmbeddedString,
    _: AffectiveCoreEmbeddedString,
    body: AffectiveCoreEmbeddedString,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int {
    const url_slice = stringSlice(url) orelse "";
    if (std.mem.eql(u8, url_slice, "affective-host://system/power")) {
        return hostHttpJsonSuccess(out_data, "{\"supplies\":[]}");
    }
    if (std.mem.eql(u8, url_slice, "affective-host://system/storage")) {
        return hostHttpJsonSuccess(out_data, "{\"volumes\":[]}");
    }
    if (std.mem.endsWith(u8, url_slice, "/embed/compute")) {
        const body_slice = stringSlice(body) orelse "";
        return hostHttpJsonSuccess(out_data, failingHostEmbedResponse(body_slice));
    }
    if (out_data) |data| data.* = .{};
    if (out_error) |err_out| {
        const msg = std.heap.page_allocator.dupe(u8, "upstream provider rejected request") catch {
            err_out.* = .{};
            return 1;
        };
        err_out.* = .{ .ptr = msg.ptr, .len = msg.len };
    }
    return 1;
}

fn hostHttpJsonSuccess(out_data: ?*AffectiveCoreEmbeddedString, json: []const u8) c_int {
    if (out_data) |data| {
        const bytes = std.heap.page_allocator.dupe(u8, json) catch {
            data.* = .{};
            return 1;
        };
        data.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    }
    return 0;
}

fn freeHostHttpString(_: ?*anyopaque, string: AffectiveCoreEmbeddedString) callconv(.c) void {
    const slice = stringSlice(string) orelse return;
    std.heap.page_allocator.free(slice);
}

fn failingHostEmbedResponse(request_body: []const u8) []const u8 {
    const Wire = struct { texts: []const []const u8 = &.{} };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, request_body, .{ .ignore_unknown_fields = true }) catch {
        return "{\"dimensions\":512,\"vectors\":[]}";
    };
    defer parsed.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.heap.page_allocator);
    out.appendSlice(std.heap.page_allocator, "{\"dimensions\":512,\"vectors\":[") catch return "{\"dimensions\":512,\"vectors\":[]}";
    for (parsed.value.texts, 0..) |text, i| {
        if (i > 0) out.append(std.heap.page_allocator, ',') catch {};
        const compact = hash_vector.embed(std.heap.page_allocator, text, &.{}) catch continue;
        defer std.heap.page_allocator.free(compact);
        var vector = std.ArrayList(u8).empty;
        defer vector.deinit(std.heap.page_allocator);
        vector.append(std.heap.page_allocator, '[') catch continue;
        var dim: usize = 0;
        while (dim < embedding_port.test_embedding_dimensions) : (dim += 1) {
            if (dim > 0) vector.append(std.heap.page_allocator, ',') catch {};
            const value: f32 = if (dim < compact.len) compact[dim] else 0;
            const piece = std.fmt.allocPrint(std.heap.page_allocator, "{d:.6}", .{value}) catch continue;
            defer std.heap.page_allocator.free(piece);
            vector.appendSlice(std.heap.page_allocator, piece) catch {};
        }
        vector.append(std.heap.page_allocator, ']') catch {};
        out.appendSlice(std.heap.page_allocator, vector.items) catch {};
    }
    out.appendSlice(std.heap.page_allocator, "]}") catch {};
    return std.heap.page_allocator.dupe(u8, out.items) catch "{\"dimensions\":512,\"vectors\":[]}";
}
