const std = @import("std");
const embedded = @import("affective_core_embedded.zig");
const files = @import("platform/common/files.zig");
const support = @import("core/brain_test_support.zig");
const want_achievement_mod = @import("core/port_want_achievement.zig");
const memory_extraction_mod = @import("core/port_memory_extraction.zig");
const memory_selection_mod = @import("core/port_memory_selection.zig");
const schema = @import("core/port_schema.zig");

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

threadlocal var embedded_test_io_threaded: std.Io.Threaded = .init_single_threaded;

fn embeddedTestIo() std.Io {
    return embedded_test_io_threaded.io();
}

fn prepareEmbeddedBrainRoot(io: std.Io, root: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dst_buf: [512]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/llm_providers.json", .{root});
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "data/llm_providers.json", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bytes, .flags = .{ .truncate = true } });
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

test "embedded ABI seeds llm_providers when host conversation models are absent" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_abi_no_provider";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
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

test "embedded ABI rejects removed raw operations" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_abi";
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
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
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
    const connect_envelope = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, connect_json, .{});
    defer connect_envelope.deinit();
    try std.testing.expectEqual(true, connect_envelope.value.object.get("ok").?.bool);
    const connect_result = connect_envelope.value.object.get("result").?.object;
    const connect_value = connect_result.get("value").?.object;
    try std.testing.expectEqualStrings("connect", connect_value.get("kind").?.string);
    try std.testing.expect(connect_value.get("read_models") != null);
    const connect_events = try handle.?.brain.deps.store.loadExperienceEvents(std.testing.allocator);
    try std.testing.expect(connect_events.len > 0);
    try std.testing.expectEqualStrings("Host.Connected", connect_events[connect_events.len - 1].kind);

    const turn_request =
        \\{
        \\  "request_id": "embedded-user-text",
        \\  "event": {
        \\    "type": "user_text",
        \\    "text": "hello from embedded iOS"
        \\  }
        \\}
    ;
    const result_status = affective_core_embedded_dispatch_json(handle, turn_request.ptr, turn_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), result_status);
    const turn_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, turn_json, "\"ok\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn_json, "Something went wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, turn_json, "HostHttpTransportRequired") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"User.TextReceived\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"payload\": \"embedded memory survives locally\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"retention\": \"episode\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"visibility\": \"host\"") != null);

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
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
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
        \\    "type": "export_brain",
        \\    "brain_file_path": "data/test/embedded_brain_archive_file/archive.brain"
        \\  }
        \\}
    ;
    const exported_status = affective_core_embedded_dispatch_json(handle, export_request.ptr, export_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), exported_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"manifest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"brain_id\": \"archive\"") != null);

    const import_request =
        \\{
        \\  "request_id": "embedded-import-brain",
        \\  "event": {
        \\    "type": "import_brain",
        \\    "brain_file_path": "data/test/embedded_brain_archive_file/archive.brain",
        \\    "brain_id": "archive",
        \\    "brain_root": "data/test/embedded_brain_archive_dst",
        \\    "host_id": "mac-host"
        \\  }
        \\}
    ;
    const imported_status = affective_core_embedded_dispatch_json(handle, import_request.ptr, import_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), imported_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"manifest\"") != null);
    try std.Io.Dir.cwd().access(io, imported_root ++ "/memory/exported_note.txt", .{});
    const imported_memory = try files.readFileAllocPath(io, imported_root ++ "/memory/exported_note.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(imported_memory);
    try std.testing.expectEqualStrings("brain-owned memory", imported_memory);
    try std.testing.expectEqualStrings(imported_root, handle.?.brain.cfg.brain_root);
    try std.testing.expect(std.mem.endsWith(u8, handle.?.brain.cfg.memory_path, "/memory/people.sqlite"));
    try std.testing.expect(std.mem.startsWith(u8, handle.?.brain.cfg.memory_path, imported_root));

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
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
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
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
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
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"brain_id\": \"archive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"visibility\": \"host\"") != null);
}

test "embedded user_text operation reports host HTTP failures" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_user_message_http";
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
    };
    var host_services = embedded.AffectiveCoreEmbeddedHostServices{
        .ctx = null,
        .http_post_json = failingHostHttpPostJson,
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
        \\  "event": { "type": "user_text", "text": "hello from host" }
        \\}
    ;
    const operation_status = affective_core_embedded_dispatch_json(handle, operation_request.ptr, operation_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), operation_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "Something went wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "HostHttpPostJsonFailed") != null);
}

test "embedded user_text retains host HTTP error detail" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_conversation_http";
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
    };
    var host_services = embedded.AffectiveCoreEmbeddedHostServices{
        .ctx = null,
        .http_post_json = failingHostHttpPostJson,
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
        \\  "event": { "type": "user_text", "text": "hello from host" }
        \\}
    ;
    const result_status = affective_core_embedded_dispatch_json(handle, turn_request.ptr, turn_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), result_status);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "Something went wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "HostHttpPostJsonFailed") != null);
}

test "embedded dispatch_json retains host HTTP error detail" {
    const io = embeddedTestIo();
    const root = "data/test/embedded_dispatch_http";
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
    };
    var host_services = embedded.AffectiveCoreEmbeddedHostServices{
        .ctx = null,
        .http_post_json = failingHostHttpPostJson,
        .free_string = freeHostHttpString,
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &host_services, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    const request_json =
        \\{"request_id":"req-1","event":{"type":"user_text","text":"hello from host"}}
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
    try std.testing.expect(std.mem.indexOf(u8, envelope, "Something went wrong") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "HostHttpPostJsonFailed") != null);
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
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};

    const huge_text = "oversized diagnostic text " ** 200;
    const event_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"request_id\":\"embedded-huge-experience\",\"event\":{{\"type\":\"send_experience_event\",\"kind\":\"User.TextReceived\",\"payload\":\"{s}\",\"retention\":\"episode\",\"visibility\":\"host\"}}}}",
        .{huge_text},
    );
    defer std.testing.allocator.free(event_request);
    const event_status = affective_core_embedded_dispatch_json(handle, event_request.ptr, event_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), event_status);

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
        \\    "type": "capability_status",
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
    try std.testing.expect(std.mem.indexOf(u8, camera_permission_pending_json, "\"event_type\": \"capability_status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, camera_permission_pending_json, "camera=pending") != null);
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
    _ = stringSlice(data).?;
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

    const read_models_request =
        \\{
        \\  "request_id": "embedded-read-models-v2",
        \\  "event": {
        \\    "type": "read_models_snapshot"
        \\  }
        \\}
    ;
    const read_models_dispatch_status = affective_core_embedded_dispatch_json(handle, read_models_request.ptr, read_models_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), read_models_dispatch_status);
    const read_models_dispatch_json_str = stringSlice(data).?;
    try std.testing.expect(read_models_dispatch_json_str.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, read_models_dispatch_json_str, "\"event_type\": \"read_models_snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_models_dispatch_json_str, "\"read_models\"") != null);

    const drained_status = affective_core_embedded_drain_events_json(handle, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), drained_status);
    try std.testing.expect(stringSlice(data).?.len <= 16 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, stringSlice(data).?, "\"kind\": \"drain\"") != null);
}

test "embedded user_text pauses for camera sense then resumes on observation" {
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
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
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
    var scripted_selection = memory_selection_mod.ScriptedMemorySelectionService{
        .summary = "Embedded test memory selection summary.",
    };
    handle.?.brain.deps.memory_selection_service = scripted_selection.service();
    handle.?.brain.last_visual_observation_path = null;
    handle.?.brain.last_visual_update_seconds = null;

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const first_request =
        \\{
        \\  "request_id": "embedded-camera-pause-first",
        \\  "event": { "type": "user_text", "text": "hello" }
        \\}
    ;
    const first_status = affective_core_embedded_dispatch_json(handle, first_request.ptr, first_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), first_status);
    const first_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, first_json, "\"kind\": \"user_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_json, "\"outcome\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_json, "Chose to look at who is here.") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_json, "spoken_text") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_json, "\"awaiting_host_sense\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_json, "\"activity_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_json, "\"activity_state\": \"active\"") != null);
    try std.testing.expect(handle.?.brain.conversationAwaitingHost());
    try std.testing.expectEqual(@as(usize, 1), chat.calls);

    const drained_after_first = affective_core_embedded_drain_events_json(handle, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), drained_after_first);

    const camera_observation =
        \\{
        \\  "request_id": "embedded-camera-pause-resume",
        \\  "event": {
        \\    "type": "sense_observation",
        \\    "sense": "camera",
        \\    "observation": {
        \\      "path": "fixtures/visitors/unknown_01.jpg",
        \\      "mime_type": "image/jpeg",
        \\      "source": "affective_requested_capture"
        \\    }
        \\  }
        \\}
    ;
    const resume_status = affective_core_embedded_dispatch_json(handle, camera_observation.ptr, camera_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), resume_status);
    const resume_json = stringSlice(data) orelse return error.EmptyResumeResponse;
    try std.testing.expect(resume_json.len > 0);
    try std.testing.expect(!handle.?.brain.conversationAwaitingHost());
    try std.testing.expect(handle.?.brain.pending_deferred_heard_speech == null);
    try std.testing.expect(std.mem.indexOf(u8, resume_json, "\"outcome\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resume_json, "Hi after camera.") != null);
    try std.testing.expect(chat.calls >= 2);
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
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
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
    var scripted_selection = memory_selection_mod.ScriptedMemorySelectionService{
        .summary = "Embedded no-face memory selection summary.",
    };
    handle.?.brain.deps.memory_selection_service = scripted_selection.service();
    handle.?.brain.last_visual_observation_path = null;
    handle.?.brain.last_visual_update_seconds = null;

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const first_request =
        \\{
        \\  "request_id": "embedded-camera-no-face-first",
        \\  "event": { "type": "user_text", "text": "Do you recognize me?" }
        \\}
    ;
    const first_status = affective_core_embedded_dispatch_json(handle, first_request.ptr, first_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), first_status);
    try std.testing.expect(handle.?.brain.conversationAwaitingHost());
    try std.testing.expectEqual(@as(usize, 1), chat.calls);

    const camera_observation =
        \\{
        \\  "request_id": "embedded-camera-no-face-resume",
        \\  "event": {
        \\    "type": "sense_observation",
        \\    "sense": "camera",
        \\    "observation": {
        \\      "path": "fixtures/empty/empty_room_01.jpg",
        \\      "mime_type": "image/jpeg",
        \\      "source": "affective_requested_capture"
        \\    }
        \\  }
        \\}
    ;
    const resume_status = affective_core_embedded_dispatch_json(handle, camera_observation.ptr, camera_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), resume_status);
    const resume_json = stringSlice(data) orelse return error.EmptyResumeResponse;
    try std.testing.expect(!handle.?.brain.conversationAwaitingHost());
    try std.testing.expect(std.mem.indexOf(u8, resume_json, "No face visible in that frame.") != null);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
}

test "embedded short_touch runs stimulus autonomy when runtime options enable full autonomy" {
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
        \\{"request_id":"embedded-short-touch","event":{"type":"short_touch"}}
    ;
    const short_touch_status = affective_core_embedded_dispatch_json(handle, short_touch_request.ptr, short_touch_request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), short_touch_status);
    const envelope = stringSlice(data) orelse return error.EmptyShortTouchResponse;
    try std.testing.expect(std.mem.indexOf(u8, envelope, "\"event_type\": \"short_touch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "stimulus_autonomy_failed") == null);
    try std.testing.expect(std.mem.indexOf(u8, envelope, "NoRandomProviderModels") == null);
    try std.testing.expect(mock.llm_calls >= 1);
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
        \\    "control_capacity": 0.05,
        \\    "max_capacity": 0.85,
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
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, null, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const autonomy_replenish_observation =
        \\{
        \\  "request_id": "embedded-autonomy-replenish-v1",
        \\  "event": {
        \\    "type": "sense_observation",
        \\    "sense": "autonomy_replenish",
        \\    "observation": {
        \\      "actions": 1,
        \\      "summary": "Autonomy capacity tick."
        \\    }
        \\  }
        \\}
    ;
    const autonomy_replenish_status = affective_core_embedded_dispatch_json(handle, autonomy_replenish_observation.ptr, autonomy_replenish_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), autonomy_replenish_status);
    const autonomy_replenish_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, autonomy_replenish_json, "\"event_type\": \"sense_observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, autonomy_replenish_json, "autonomy_replenish: requested=1 applied=1") != null);

    const invalid_replenish_observation =
        \\{
        \\  "request_id": "embedded-autonomy-replenish-invalid",
        \\  "event": {
        \\    "type": "sense_observation",
        \\    "sense": "autonomy_replenish",
        \\    "observation": {
        \\      "elapsed_ms": 15000
        \\    }
        \\  }
        \\}
    ;
    const invalid_status = affective_core_embedded_dispatch_json(handle, invalid_replenish_observation.ptr, invalid_replenish_observation.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), invalid_status);
    const invalid_json = stringSlice(data).?;
    try std.testing.expect(std.mem.indexOf(u8, invalid_json, "\"ok\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid_json, "observation.actions") != null);
}

fn str(value: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = value.ptr, .len = value.len };
}

fn failingHostHttpPostJson(
    _: ?*anyopaque,
    _: AffectiveCoreEmbeddedString,
    _: AffectiveCoreEmbeddedString,
    _: AffectiveCoreEmbeddedString,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int {
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

fn freeHostHttpString(_: ?*anyopaque, string: AffectiveCoreEmbeddedString) callconv(.c) void {
    const slice = stringSlice(string) orelse return;
    std.heap.page_allocator.free(slice);
}
