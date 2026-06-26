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
const affective_core_embedded_drain_events_json = embedded.affective_core_embedded_drain_events_json;
const affective_core_embedded_raw_ref_lookup_json = embedded.affective_core_embedded_raw_ref_lookup_json;
const affective_core_embedded_introspect_json = embedded.affective_core_embedded_introspect_json;
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
        try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"request_id\": \"embedded-dispatch-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"event_type\": \"tool_call\"") != null);

    const poke_request =
        \\{
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
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"event_type\": \"poke_sequence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"raw_result\": false") != null);

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
        \\  "platform": "android",
        \\  "capabilities": ["typed_text", "poke_sequence", "tool_call", "event_envelope", "event_drain", "introspection", "orientation_query", "sense_catalog", "sense_status", "sense_observation"],
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
    const poke_status = affective_core_embedded_dispatch_json(handle, poke_request.ptr, poke_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), poke_status);
    const poke_json = stringSlice(data).?;
    try std.testing.expect(poke_json.len <= 16 * 1024);
        try std.testing.expect(std.mem.indexOf(u8, poke_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "\"event_type\": \"poke_sequence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "Poke received.") == null);
    try std.testing.expect(std.mem.indexOf(u8, poke_json, "provider_response_too_large") == null);

    const orientation_request =
        \\{
        \\  "request_id": "embedded-orientation-request-v2",
        \\  "event": {
        \\    "type": "tool_call",
        \\    "name": "request_orientation",
        \\    "arguments": {}
        \\  }
        \\}
    ;
    const orientation_request_status = affective_core_embedded_dispatch_json(handle, orientation_request.ptr, orientation_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), orientation_request_status);
    const orientation_request_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, orientation_request_json, "\"type\": \"sense_request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, orientation_request_json, "\"sense\": \"orientation\"") != null);

    const orientation_observation =
        \\{
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
    const orientation_observation_status = affective_core_embedded_dispatch_json(handle, orientation_observation.ptr, orientation_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), orientation_observation_status);
    const orientation_observation_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, orientation_observation_json, "\"event_type\": \"sense_observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, orientation_observation_json, "orientation: The device is lying face up.") != null);

    const sense_catalog =
        \\{
        \\  "request_id": "embedded-sense-catalog-v2",
        \\  "event": {
        \\    "type": "sense_catalog",
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
    try std.testing.expect(std.mem.indexOf(u8, sense_catalog_json, "\"event_type\": \"sense_catalog\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sense_catalog_json, "sense_catalog: count=2") != null);

    const motion_gesture_observation =
        \\{
        \\  "request_id": "embedded-motion-gesture-v2",
        \\  "event": {
        \\    "type": "sense_observation",
        \\    "sense": "motion_gesture",
        \\    "observation": {
        \\      "gesture": "shake",
        \\      "confidence": 0.88,
        \\      "summary": "The device was shaken."
        \\    }
        \\  }
        \\}
    ;
    const motion_gesture_status = affective_core_embedded_dispatch_json(handle, motion_gesture_observation.ptr, motion_gesture_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), motion_gesture_status);
    const motion_gesture_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, motion_gesture_json, "\"event_type\": \"sense_observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, motion_gesture_json, "motion_gesture: The device was shaken.") != null);

    const sense_status =
        \\{
        \\  "request_id": "embedded-sense-status-v2",
        \\  "event": {
        \\    "type": "sense_status",
        \\    "sense": "motion_gesture",
        \\    "status": "available",
        \\    "reason": "gesture monitor active"
        \\  }
        \\}
    ;
    const sense_status_status = affective_core_embedded_dispatch_json(handle, sense_status.ptr, sense_status.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), sense_status_status);
    const sense_status_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, sense_status_json, "\"event_type\": \"sense_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sense_status_json, "sense_status: motion_gesture=available") != null);

    const camera_permission_pending =
        \\{
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
    const camera_permission_pending_status = affective_core_embedded_dispatch_json(handle, camera_permission_pending.ptr, camera_permission_pending.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), camera_permission_pending_status);
    const camera_permission_pending_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, camera_permission_pending_json, "\"event_type\": \"host_capability_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, camera_permission_pending_json, "camera=pending") != null);

    const camera_observation =
        \\{
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
    const camera_observation_status = affective_core_embedded_dispatch_json(handle, camera_observation.ptr, camera_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), camera_observation_status);
    const camera_observation_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, camera_observation_json, "\"event_type\": \"sense_observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, camera_observation_json, "camera: observed image at /tmp/affective-camera.jpg") != null);
    try std.testing.expectEqualStrings("/tmp/affective-camera.jpg", handle.?.brain.last_visual_observation_path.?);

    const churn_request =
        \\{
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
    const churn_status = affective_core_embedded_dispatch_json(handle, churn_request.ptr, churn_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), churn_status);
    try std.testing.expectEqualStrings("/tmp/affective-camera.jpg", handle.?.brain.last_visual_observation_path.?);

    const introspect_status = affective_core_embedded_introspect_json(handle, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), introspect_status);
    const introspect_json = stringSlice(data).?;
    try std.testing.expect(introspect_json.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, introspect_json, "\"event_type\": \"introspect_summary\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, introspect_json, "\"raw_refs\"") != null);

    const raw_ref = try firstRawRef(std.testing.allocator, introspect_json);
    defer std.testing.allocator.free(raw_ref);
    const lookup_status = affective_core_embedded_raw_ref_lookup_json(handle, raw_ref.ptr, raw_ref.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), lookup_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"event_type\": \"raw_ref_lookup\"") != null);

    const drained_status = affective_core_embedded_drain_events_json(handle, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), drained_status);
    try std.testing.expect(stringSlice(data).?.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"drain\"") != null);
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
