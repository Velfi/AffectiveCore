const std = @import("std");
const embedded = @import("affective_core_embedded.zig");

const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;
const AffectiveCoreEmbeddedConfig = embedded.AffectiveCoreEmbeddedConfig;
const AffectiveCoreEmbeddedStatus = embedded.AffectiveCoreEmbeddedStatus;
const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;
const affective_core_embedded_create = embedded.affective_core_embedded_create;
const affective_core_embedded_destroy = embedded.affective_core_embedded_destroy;
const affective_core_embedded_conversation_turn = embedded.affective_core_embedded_conversation_turn;
const affective_core_embedded_call_tool = embedded.affective_core_embedded_call_tool;
const affective_core_embedded_dispatch_json = embedded.affective_core_embedded_dispatch_json;
const affective_core_embedded_dispatch_json_v2 = embedded.affective_core_embedded_dispatch_json_v2;
const affective_core_embedded_drain_events_json = embedded.affective_core_embedded_drain_events_json;
const affective_core_embedded_drain_events_json_v2 = embedded.affective_core_embedded_drain_events_json_v2;
const affective_core_embedded_raw_ref_lookup_json_v2 = embedded.affective_core_embedded_raw_ref_lookup_json_v2;
const affective_core_embedded_introspect_json_v2 = embedded.affective_core_embedded_introspect_json_v2;
const affective_core_embedded_free_global_string = embedded.affective_core_embedded_free_global_string;
const stringSlice = @import("affective_core_embedded_config.zig").stringSlice;

test "embedded ABI result strings stay valid until explicitly freed" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = "data/test/embedded_abi_result_lifetime";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("lifetime"),
        .brain_root = str(root),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .events_path = str(root ++ "/events.jsonl"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    const invalid_request =
        \\{
        \\  "api_version": 2,
        \\  "request_id": "lifetime-first"
        \\}
    ;
    var first_data = AffectiveCoreEmbeddedString{};
    var first_error = AffectiveCoreEmbeddedString{};
    const first_status = affective_core_embedded_dispatch_json_v2(handle, invalid_request.ptr, invalid_request.len, &first_data, &first_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), first_status);
    defer affective_core_embedded_free_global_string(first_data);
    defer affective_core_embedded_free_global_string(first_error);

    const first_snapshot = try std.testing.allocator.dupe(u8, stringSlice(first_data).?);
    defer std.testing.allocator.free(first_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, first_snapshot, "\"request_id\": \"lifetime-first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_snapshot, "\"code\": \"invalid_request\"") != null);

    var second_data = AffectiveCoreEmbeddedString{};
    var second_error = AffectiveCoreEmbeddedString{};
    const second_status = affective_core_embedded_drain_events_json_v2(handle, &second_data, &second_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), second_status);
    defer affective_core_embedded_free_global_string(second_data);
    defer affective_core_embedded_free_global_string(second_error);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(second_data).?, "\"kind\": \"drain\"") != null);

    try std.testing.expectEqualStrings(first_snapshot, stringSlice(first_data).?);
}

test "embedded ABI rejects conversation turns without configured provider chat" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = "data/test/embedded_abi";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .events_path = str(root ++ "/events.jsonl"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    const text = "hello from embedded iOS";
    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const result_status = affective_core_embedded_conversation_turn(handle, text.ptr, text.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.runtime_error)), result_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(runtime_error).?, "NoConversationModelsConfigured") != null);

    const remember_name = "remember_memory";
    const remember_args = "{\"text\":\"embedded memory survives locally\",\"tags\":[\"embedded\",\"ios\"]}";
    const remembered_status = affective_core_embedded_call_tool(handle, remember_name.ptr, remember_name.len, remember_args.ptr, remember_args.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), remembered_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"command\": \"remember_memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ended_with_speech\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "memory_saved") != null);

    const dispatch_request =
        \\{
        \\  "api_version": 1,
        \\  "request_id": "embedded-dispatch-test",
        \\  "event": {
        \\    "type": "tool_call",
        \\    "name": "remember_memory",
        \\    "arguments": {
        \\      "text": "dispatch envelope memory survives locally",
        \\      "tags": ["embedded", "dispatch"]
        \\    }
        \\  }
        \\}
    ;
    const dispatched_status = affective_core_embedded_dispatch_json(handle, dispatch_request.ptr, dispatch_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), dispatched_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"api_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"request_id\": \"embedded-dispatch-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"event_type\": \"tool_call\"") != null);

    const poke_request =
        \\{
        \\  "api_version": 1,
        \\  "request_id": "embedded-poke-test",
        \\  "event": {
        \\    "type": "poke_sequence",
        \\    "pulses": [
        \\      { "press_ms": 120, "pause_before_ms": 0 },
        \\      { "press_ms": 80, "pause_before_ms": 40 }
        \\    ]
        \\  }
        \\}
    ;
    const poke_status = affective_core_embedded_dispatch_json(handle, poke_request.ptr, poke_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), poke_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"stimulus\": \"poke_sequence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "Poke received.") != null);

    const bad_dispatch_request =
        \\{
        \\  "api_version": 1,
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
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"api_version\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"drain\"") != null);

    const recall_name = "recall_memory";
    const recall_args = "{\"query\":\"embedded memory\",\"tags\":[\"ios\"]}";
    const recalled_status = affective_core_embedded_call_tool(handle, recall_name.ptr, recall_name.len, recall_args.ptr, recall_args.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), recalled_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"command\": \"recall_memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "embedded memory survives locally") != null);

    const reminder_name = "set_reminder";
    const reminder_args = "{\"schedule\":\"in 5 minutes\",\"text\":\"check embedded schedule\"}";
    const reminder_status = affective_core_embedded_call_tool(handle, reminder_name.ptr, reminder_name.len, reminder_args.ptr, reminder_args.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), reminder_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "reminder_set") != null);

    const list_name = "list_reminders";
    const listed_status = affective_core_embedded_call_tool(handle, list_name.ptr, list_name.len, null, 0, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), listed_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "check embedded schedule") != null);
}

test "embedded v2 budgets local stimulus and exposes raw refs" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = "data/test/embedded_v2";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const manifest =
        \\{
        \\  "api_version": 2,
        \\  "platform": "android",
        \\  "capabilities": ["typed_text", "poke_sequence", "tool_call", "event_envelope", "event_drain", "introspection", "orientation_query", "sense_observation"],
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
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .events_path = str(root ++ "/events.jsonl"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};

    const huge_text = "oversized diagnostic text " ** 200;
    const remember_args = try std.fmt.allocPrint(std.testing.allocator, "{{\"text\":\"{s}\",\"tags\":[\"embedded\",\"v2\"]}}", .{huge_text});
    defer std.testing.allocator.free(remember_args);
    const remember_name = "remember_memory";
    const remembered_status = affective_core_embedded_call_tool(handle, remember_name.ptr, remember_name.len, remember_args.ptr, remember_args.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), remembered_status);

    const poke_request =
        \\{
        \\  "api_version": 2,
        \\  "request_id": "embedded-poke-v2",
        \\  "event": {
        \\    "type": "poke_sequence",
        \\    "pulses": [
        \\      { "press_ms": 120, "pause_before_ms": 0 },
        \\      { "press_ms": 80, "pause_before_ms": 40 }
        \\    ]
        \\  }
        \\}
    ;
    const poke_status = affective_core_embedded_dispatch_json_v2(handle, poke_request.ptr, poke_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), poke_status);
    const poke_json = stringSlice(data).?;
    try std.testing.expect(poke_json.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "\"api_version\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "\"event_type\": \"poke_sequence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "Poke received.") == null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "provider_response_too_large") == null);

    const orientation_request =
        \\{
        \\  "api_version": 2,
        \\  "request_id": "embedded-orientation-request-v2",
        \\  "event": {
        \\    "type": "tool_call",
        \\    "name": "request_orientation",
        \\    "arguments": {}
        \\  }
        \\}
    ;
    const orientation_request_status = affective_core_embedded_dispatch_json_v2(handle, orientation_request.ptr, orientation_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), orientation_request_status);
    const orientation_request_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, orientation_request_json, "\"type\": \"sense_requested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, orientation_request_json, "\"sense\": \"orientation\"") != null);

    const orientation_observation =
        \\{
        \\  "api_version": 2,
        \\  "request_id": "embedded-orientation-observation-v2",
        \\  "event": {
        \\    "type": "sense_observation",
        \\    "sense": "orientation",
        \\    "observation": {
        \\      "posture": "face_up",
        \\      "confidence": 0.98,
        \\      "summary": "The device is lying face up."
        \\    }
        \\  }
        \\}
    ;
    const orientation_observation_status = affective_core_embedded_dispatch_json_v2(handle, orientation_observation.ptr, orientation_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), orientation_observation_status);
    const orientation_observation_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, orientation_observation_json, "\"event_type\": \"sense_observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, orientation_observation_json, "orientation: The device is lying face up.") != null);

    const camera_permission_pending =
        \\{
        \\  "api_version": 2,
        \\  "request_id": "embedded-camera-permission-pending-v2",
        \\  "event": {
        \\    "type": "host_capability_status",
        \\    "capability": "camera",
        \\    "status": "pending",
        \\    "pending_since_unix_ms": 1780000000000,
        \\    "pending_elapsed_ms": 42,
        \\    "reason": "OS camera permission prompt"
        \\  }
        \\}
    ;
    const camera_permission_pending_status = affective_core_embedded_dispatch_json_v2(handle, camera_permission_pending.ptr, camera_permission_pending.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), camera_permission_pending_status);
    const camera_permission_pending_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, camera_permission_pending_json, "\"event_type\": \"host_capability_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, camera_permission_pending_json, "camera=pending") != null);

    const camera_observation =
        \\{
        \\  "api_version": 2,
        \\  "request_id": "embedded-camera-observation-v2",
        \\  "event": {
        \\    "type": "sense_observation",
        \\    "sense": "camera",
        \\    "observation": {
        \\      "path": "/tmp/affective-camera.jpg",
        \\      "mime_type": "image/jpeg",
        \\      "source": "affective_requested_capture"
        \\    }
        \\  }
        \\}
    ;
    const camera_observation_status = affective_core_embedded_dispatch_json_v2(handle, camera_observation.ptr, camera_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), camera_observation_status);
    const camera_observation_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, camera_observation_json, "\"event_type\": \"sense_observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, camera_observation_json, "camera: observed image at /tmp/affective-camera.jpg") != null);
    try std.testing.expectEqualStrings("/tmp/affective-camera.jpg", handle.?.runtime.brain.last_visual_observation_path.?);

    const churn_request =
        \\{
        \\  "api_version": 2,
        \\  "request_id": "embedded-camera-path-churn-v2",
        \\  "event": {
        \\    "type": "sense_observation",
        \\    "sense": "orientation",
        \\    "observation": {
        \\      "posture": "portrait",
        \\      "confidence": 0.72,
        \\      "summary": "Parser allocation churn after camera observation."
        \\    }
        \\  }
        \\}
    ;
    const churn_status = affective_core_embedded_dispatch_json_v2(handle, churn_request.ptr, churn_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), churn_status);
    try std.testing.expectEqualStrings("/tmp/affective-camera.jpg", handle.?.runtime.brain.last_visual_observation_path.?);

    const introspect_status = affective_core_embedded_introspect_json_v2(handle, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), introspect_status);
    const introspect_json = stringSlice(data).?;
    try std.testing.expect(introspect_json.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, introspect_json, "\"event_type\": \"introspect_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, introspect_json, "\"raw_refs\"") != null);

    const raw_ref = try firstRawRef(std.testing.allocator, introspect_json);
    defer std.testing.allocator.free(raw_ref);
    const lookup_status = affective_core_embedded_raw_ref_lookup_json_v2(handle, raw_ref.ptr, raw_ref.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), lookup_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"event_type\": \"raw_ref_lookup\"") != null);

    const drained_status = affective_core_embedded_drain_events_json_v2(handle, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), drained_status);
    try std.testing.expect(stringSlice(data).?.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"drain\"") != null);
}

test "embedded dispatch survives fuzzed host messages" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = "data/test/embedded_fuzz";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const manifest =
        \\{
        \\  "api_version": 2,
        \\  "platform": "android",
        \\  "capabilities": ["typed_text", "poke_sequence", "tool_call", "event_envelope", "event_drain", "introspection", "orientation_query", "sense_observation"],
        \\  "feature_flags": {},
        \\  "max_envelope_bytes": 4096,
        \\  "max_event_count": 4,
        \\  "max_event_text_bytes": 96,
        \\  "raw_ref_ttl_seconds": 60
        \\}
    ;
    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .events_path = str(root ++ "/events.jsonl"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = str(manifest),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var prng = std.Random.DefaultPrng.init(0x667269656e646c79);
    const random = prng.random();

    const corpus = [_][]const u8{
        "",
        "\x00\x01\x02\xff",
        "not json",
        "null",
        "[]",
        "{}",
        "{\"api_version\":1}",
        "{\"api_version\":2,\"event\":null}",
        "{\"api_version\":2,\"request_id\":42,\"event\":{\"type\":false}}",
        "{\"api_version\":2,\"request_id\":\"seed\",\"event\":{\"type\":\"tool_call\",\"name\":\"remember_memory\",\"arguments\":[]}}",
        "{\"api_version\":2,\"request_id\":\"seed\",\"event\":{\"type\":\"sense_observation\",\"sense\":\"orientation\",\"observation\":{\"confidence\":1.0e309,\"summary\":false}}}",
        "{\"api_version\":2,\"request_id\":\"seed\",\"event\":{\"type\":\"poke_sequence\",\"pulses\":[null,{\"press_ms\":-999999999999,\"pause_before_ms\":\"bad\"},{\"press_ms\":1.0e308}]}}",
    };
    for (corpus) |request| {
        try expectDispatchDoesNotCrash(handle, request);
    }

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var bytes: [768]u8 = undefined;
        const len = random.intRangeLessThan(usize, 0, bytes.len + 1);
        random.bytes(bytes[0..len]);
        try expectDispatchDoesNotCrash(handle, bytes[0..len]);
    }

    var generated_index: usize = 0;
    while (generated_index < 256) : (generated_index += 1) {
        const request = try randomHostMessage(std.testing.allocator, random, generated_index);
        defer std.testing.allocator.free(request);
        try expectDispatchDoesNotCrash(handle, request);
    }
}

fn firstRawRef(allocator: std.mem.Allocator, json: []const u8) ![]const u8 {
    const needle = "raw_event_";
    const start = std.mem.indexOf(u8, json, needle) orelse return error.MissingRawRef;
    var end = start;
    while (end < json.len) : (end += 1) {
        const ch = json[end];
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_') continue;
        break;
    }
    return allocator.dupe(u8, json[start..end]);
}

fn str(value: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = value.ptr, .len = value.len };
}

fn expectDispatchDoesNotCrash(handle: ?*AffectiveCoreEmbedded, request: []const u8) !void {
    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};

    const v1_status = affective_core_embedded_dispatch_json(handle, if (request.len == 0) null else request.ptr, request.len, &data, &runtime_error);
    try expectEmbeddedStatus(v1_status);
    try expectResultShape(v1_status, data, runtime_error);

    const v2_status = affective_core_embedded_dispatch_json_v2(handle, if (request.len == 0) null else request.ptr, request.len, &data, &runtime_error);
    try expectEmbeddedStatus(v2_status);
    try expectResultShape(v2_status, data, runtime_error);
}

fn expectEmbeddedStatus(status: c_int) !void {
    try std.testing.expect(status == @as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)) or
        status == @as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.invalid_argument)) or
        status == @as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.runtime_error)));
}

fn expectResultShape(status: c_int, data: AffectiveCoreEmbeddedString, runtime_error: AffectiveCoreEmbeddedString) !void {
    if (status == @as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok))) {
        const bytes = stringSlice(data).?;
        try std.testing.expect(bytes.len > 0);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
        return;
    }

    const message = stringSlice(runtime_error).?;
    try std.testing.expect(message.len > 0);
}

fn randomHostMessage(allocator: std.mem.Allocator, random: std.Random, index: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"api_version\":");
    switch (random.intRangeLessThan(u8, 0, 5)) {
        0 => try out.appendSlice(allocator, "1"),
        1 => try out.appendSlice(allocator, "2"),
        2 => try out.appendSlice(allocator, "0"),
        3 => try out.appendSlice(allocator, "\"2\""),
        else => try out.appendSlice(allocator, "999999999999"),
    }

    if (random.boolean()) {
        try out.appendSlice(allocator, ",\"request_id\":");
        try appendRandomJsonScalar(allocator, &out, random, "request", index);
    }

    try out.appendSlice(allocator, ",\"event\":");
    switch (random.intRangeLessThan(u8, 0, 8)) {
        0 => try out.appendSlice(allocator, "null"),
        1 => try out.appendSlice(allocator, "[]"),
        2 => try out.appendSlice(allocator, "42"),
        else => try appendRandomEvent(allocator, &out, random, index),
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendRandomEvent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random, index: usize) !void {
    try out.append(allocator, '{');
    try out.appendSlice(allocator, "\"type\":");
    const event_type = switch (random.intRangeLessThan(u8, 0, 10)) {
        0 => "typed_text",
        1 => "speech_transcript",
        2 => "poke_sequence",
        3 => "tool_call",
        4 => "sense_observation",
        5 => "raw_ref_lookup",
        6 => "maintenance_tick",
        7 => "autonomy_tick",
        8 => "definitely_not_real",
        else => "",
    };
    try appendJsonString(allocator, out, event_type);

    switch (random.intRangeLessThan(u8, 0, 7)) {
        0 => {
            try out.appendSlice(allocator, ",\"text\":");
            try appendRandomJsonScalar(allocator, out, random, "text", index);
        },
        1 => {
            try out.appendSlice(allocator, ",\"name\":");
            try appendJsonString(allocator, out, switch (random.intRangeLessThan(u8, 0, 5)) {
                0 => "remember_memory",
                1 => "recall_memory",
                2 => "request_orientation",
                3 => "raw_ref_lookup",
                else => "missing_tool",
            });
            try out.appendSlice(allocator, ",\"arguments\":");
            try appendRandomArguments(allocator, out, random, index);
        },
        2 => {
            try out.appendSlice(allocator, ",\"pulses\":[");
            const count = random.intRangeLessThan(usize, 0, 8);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (i > 0) try out.append(allocator, ',');
                const pulse = try std.fmt.allocPrint(allocator, "{{\"press_ms\":{d},\"pause_before_ms\":{d}}}", .{
                    random.int(i64),
                    random.int(i64),
                });
                defer allocator.free(pulse);
                try out.appendSlice(allocator, pulse);
            }
            try out.append(allocator, ']');
        },
        3 => {
            try out.appendSlice(allocator, ",\"sense\":\"orientation\",\"observation\":");
            try appendRandomArguments(allocator, out, random, index);
        },
        4 => {
            try out.appendSlice(allocator, ",\"raw_ref\":");
            try appendRandomJsonScalar(allocator, out, random, "raw_event", index);
        },
        else => {},
    }
    try out.append(allocator, '}');
}

fn appendRandomArguments(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random, index: usize) !void {
    switch (random.intRangeLessThan(u8, 0, 5)) {
        0 => try out.appendSlice(allocator, "null"),
        1 => try out.appendSlice(allocator, "[]"),
        2 => try out.appendSlice(allocator, "{\"tags\":[1,false,null],\"text\":42}"),
        else => {
            try out.appendSlice(allocator, "{\"text\":");
            try appendRandomJsonScalar(allocator, out, random, "memory", index);
            try out.appendSlice(allocator, ",\"schedule\":");
            try appendRandomJsonScalar(allocator, out, random, "schedule", index);
            try out.appendSlice(allocator, ",\"summary\":");
            try appendRandomJsonScalar(allocator, out, random, "summary", index);
            try out.appendSlice(allocator, ",\"confidence\":");
            try appendRandomInteger(allocator, out, random);
            try out.append(allocator, '}');
        },
    }
}

fn appendRandomJsonScalar(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    random: std.Random,
    prefix: []const u8,
    index: usize,
) !void {
    switch (random.intRangeLessThan(u8, 0, 7)) {
        0 => try out.appendSlice(allocator, "null"),
        1 => try out.appendSlice(allocator, "true"),
        2 => try appendRandomInteger(allocator, out, random),
        3 => try out.appendSlice(allocator, "[]"),
        4 => try out.appendSlice(allocator, "{}"),
        else => {
            const text = try std.fmt.allocPrint(allocator, "{s}_{d}_{d}", .{ prefix, index, random.int(u32) });
            defer allocator.free(text);
            try appendJsonString(allocator, out, text);
        },
    }
}

fn appendRandomInteger(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{random.int(i64)});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}
