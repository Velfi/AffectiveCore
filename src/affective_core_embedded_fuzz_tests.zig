const std = @import("std");
const embedded = @import("affective_core_embedded.zig");
const embedded_ffi_fuzz = @import("harness/embedded_ffi_fuzz.zig");

const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;
const AffectiveCoreEmbeddedConfig = embedded.AffectiveCoreEmbeddedConfig;
const AffectiveCoreEmbeddedStatus = embedded.AffectiveCoreEmbeddedStatus;
const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;
const affective_core_embedded_create = embedded.affective_core_embedded_create;
const affective_core_embedded_destroy = embedded.affective_core_embedded_destroy;
const affective_core_embedded_free_global_string = embedded.affective_core_embedded_free_global_string;
const stringSlice = @import("affective_core_embedded_config.zig").stringSlice;
const mock_host = @import("mcp_host/mock_host.zig");

var embedded_fuzz_test_mock_host: mock_host.MockHost = .{ .mode = .default };
var embedded_fuzz_test_host_services: embedded.AffectiveCoreEmbeddedHostServices = .{};

fn embeddedFuzzTestHostServicesPtr() *const embedded.AffectiveCoreEmbeddedHostServices {
    embedded_fuzz_test_host_services = embedded_fuzz_test_mock_host.hostServices();
    return &embedded_fuzz_test_host_services;
}

threadlocal var embedded_fuzz_test_io_threaded: std.Io.Threaded = .init_single_threaded;

fn embeddedFuzzTestIo() std.Io {
    return embedded_fuzz_test_io_threaded.io();
}

fn prepareEmbeddedBrainRoot(io: std.Io, root: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dst_buf: [512]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/llm_providers.json", .{root});
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "data/llm_providers.json", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bytes, .flags = .{ .truncate = true } });
}

test "embedded dispatch survives fuzzed host messages" {
    const stats = try embedded_ffi_fuzz.run(std.testing.allocator, .{
        .iterations = 256,
        .root = "data/test/embedded_fuzz",
    });
    try std.testing.expect(stats.dispatches > 0);
    try std.testing.expectEqual(@as(usize, 0), stats.unexpected_status);
    try std.testing.expect(stats.connect_ok >= 8);
}

test "connect dispatch does not recurse through stimulus poll" {
    const stats = try embedded_ffi_fuzz.run(std.testing.allocator, .{
        .iterations = 0,
        .root = "data/test/embedded_fuzz_connect_regression",
    });
    try std.testing.expectEqual(@as(usize, 8), stats.connect_ok);
}

test "embedded create rejects null pointer with non-zero length" {
    const io = embeddedFuzzTestIo();
    const root = "data/test/embedded_fuzz_invalid_create";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    var cfg = AffectiveCoreEmbeddedConfig{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(root ++ "/memory/people.sqlite"),
        .graph_path = str(root ++ "/memory/relationships.sqlite"),
        .schedule_path = str(root ++ "/maintenance.md"),
        .maintenance_state_path = str(root ++ "/maintenance_state.json"),
        .face_embeddings_dir = str(root ++ "/memory/face_embeddings"),
        .host_manifest_json = .{ .ptr = null, .len = 8 },
    };
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, embeddedFuzzTestHostServicesPtr(), &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.invalid_argument)), created_status);
    try std.testing.expect(handle == null);
}

test "embedded dispatch with mock host survives malformed host responses" {
    const io = embeddedFuzzTestIo();
    const root = "data/test/embedded_fuzz_mock_host";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, "fixtures/embedded_api/manifest_macos.json", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(manifest);

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
    var mock = mock_host.MockHost{ .mode = .upstream_rejected };
    const host_services = mock.hostServices();
    var handle: ?*AffectiveCoreEmbedded = null;
    var error_message = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &host_services, &handle, &error_message);
    defer affective_core_embedded_free_global_string(error_message);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)), created_status);
    defer affective_core_embedded_destroy(handle);

    const request =
        \\{"request_id":"fuzz-host","event":{"type":"poke_sequence","pulses":[{"press_ms":120,"pause_before_ms":0}]}}
    ;
    try std.testing.expect(embedded_ffi_fuzz.dispatch(handle, request) != .unexpected);
}

fn str(value: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = value.ptr, .len = value.len };
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
