const mock_host = @import("mcp_host/mock_host.zig");

var geisha_repro_mock_host: mock_host.MockHost = .{ .mode = .default };
var geisha_repro_host_services: embedded.AffectiveCoreEmbeddedHostServices = .{};

fn geishaReproHostServicesPtr() *const embedded.AffectiveCoreEmbeddedHostServices {
    geisha_repro_host_services = geisha_repro_mock_host.hostServices();
    return &geisha_repro_host_services;
}

const std = @import("std");
const embedded = @import("affective_core_embedded.zig");
const support = @import("core/brain_test_support.zig");

const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;
const AffectiveCoreEmbeddedConfig = embedded.AffectiveCoreEmbeddedConfig;
const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;
const AffectiveCoreEmbeddedStatus = embedded.AffectiveCoreEmbeddedStatus;
const affective_core_embedded_create = embedded.affective_core_embedded_create;
const affective_core_embedded_destroy = embedded.affective_core_embedded_destroy;
const affective_core_embedded_dispatch_json = embedded.affective_core_embedded_dispatch_json;
const affective_core_embedded_free_global_string = embedded.affective_core_embedded_free_global_string;
const stringSlice = @import("affective_core_embedded_config.zig").stringSlice;

const host_manifest =
    \\{
    \\  "platform": "macos",
    \\  "capabilities": [
    \\    "text_input",
    \\    "speech_output",
    \\    "camera_capture",
    \\    "identity_recognition",
    \\    "stored_memory_read",
    \\    "stored_memory_write",
    \\    "introspection"
    \\  ],
    \\  "feature_flags": {}
    \\}
;

test "repro geisha user_text against live brain sqlite" {
    const flag = std.c.getenv("AFFECTIVE_GEISHA_REPRO") orelse return error.SkipZigTest;
    const flag_slice = std.mem.span(flag);
    if (flag_slice.len == 0 or (flag_slice.len == 1 and flag_slice[0] == '0')) return error.SkipZigTest;

    const root_ptr = std.c.getenv("AFFECTIVE_GEISHA_REPRO_BRAIN_ROOT") orelse return error.SkipZigTest;
    const root = std.mem.span(root_ptr);

    var memory_path_buf: [640]u8 = undefined;
    var graph_path_buf: [640]u8 = undefined;
    var schedule_path_buf: [640]u8 = undefined;
    var maintenance_state_path_buf: [640]u8 = undefined;
    var face_embeddings_dir_buf: [640]u8 = undefined;
    const memory_path = try std.fmt.bufPrint(&memory_path_buf, "{s}/memory/people.sqlite", .{root});
    const graph_path = try std.fmt.bufPrint(&graph_path_buf, "{s}/memory/relationships.sqlite", .{root});
    const schedule_path = try std.fmt.bufPrint(&schedule_path_buf, "{s}/maintenance.md", .{root});
    const maintenance_state_path = try std.fmt.bufPrint(&maintenance_state_path_buf, "{s}/maintenance_state.json", .{root});
    const face_embeddings_dir = try std.fmt.bufPrint(&face_embeddings_dir_buf, "{s}/memory/face_embeddings", .{root});

    const cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("2b63154e-188b-4cc2-b69c-4d7b65caf62d"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(memory_path),
        .graph_path = str(graph_path),
        .schedule_path = str(schedule_path),
        .maintenance_state_path = str(maintenance_state_path),
        .face_embeddings_dir = str(face_embeddings_dir),
        .host_manifest_json = str(host_manifest),
    };

    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, geishaReproHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    if (created_status != @intFromEnum(AffectiveCoreEmbeddedStatus.ok)) {
        std.debug.print("GEISHA_REPRO create failed status={d} error={s}\n", .{ created_status, stringSlice(error_message) orelse "(none)" });
    }
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    var chat = support.ScriptedRecognizeThenSayChatService{ .say_text = "Hello back." };
    handle.?.brain.deps.chat_service = chat.service();

    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const request =
        \\{
        \\  "request_id": "geisha-repro",
        \\  "event": { "type": "user_text", "text": "Hello Geisha" }
        \\}
    ;
    const status = affective_core_embedded_dispatch_json(handle, request.ptr, request.len, &data, &runtime_error);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), status);
    const json = stringSlice(data) orelse return error.MissingDispatchJson;
    try std.testing.expect(json.len > 0);
}

fn str(value: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = value.ptr, .len = value.len };
}
