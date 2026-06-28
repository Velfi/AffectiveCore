const std = @import("std");
const embedded = @import("../affective_core_embedded.zig");
const embedded_config = @import("../affective_core_embedded_config.zig");
const files = @import("../platform/common/files.zig");
const mock_host = @import("mock_host.zig");
const scenario_mod = @import("scenario.zig");
const requests = @import("requests.zig");

const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;
const AffectiveCoreEmbeddedConfig = embedded.AffectiveCoreEmbeddedConfig;
const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;
const AffectiveCoreEmbeddedStatus = embedded.AffectiveCoreEmbeddedStatus;

pub const Options = struct {
    brain_root: []const u8 = "data/test/mcp_host/default",
    brain_id: []const u8 = "mcp-host",
    manifest_path: []const u8 = "fixtures/embedded_api/manifest_macos.json",
    scenario: []const u8 = "default",
    fresh: bool = false,
    conversation_models: []const u8 = "openai:gpt-4.1-nano",
};

pub const Session = struct {
    arena: std.heap.ArenaAllocator,
    mock_host: *mock_host.MockHost,
    handle: *AffectiveCoreEmbedded,
    host_setup_done: bool = false,

    pub fn open(io: std.Io, options: Options) !Session {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();

        const brain_root = try allocator.dupe(u8, options.brain_root);
        if (options.fresh) {
            _ = std.Io.Dir.cwd().deleteTree(io, brain_root) catch {};
        }
        try ensureBrainLayout(io, brain_root);

        const manifest = try files.readFileAllocPath(io, options.manifest_path, allocator, .limited(1024 * 1024));
        const mode = try scenario_mod.parseMode(options.scenario);

        const mock = try allocator.create(mock_host.MockHost);
        mock.* = .{ .mode = mode };

        const memory_path = try std.fs.path.join(allocator, &.{ brain_root, "memory/people.sqlite" });
        const graph_path = try std.fs.path.join(allocator, &.{ brain_root, "memory/relationships.sqlite" });
        const schedule_path = try std.fs.path.join(allocator, &.{ brain_root, "maintenance.md" });
        const maintenance_state_path = try std.fs.path.join(allocator, &.{ brain_root, "maintenance_state.json" });
        const face_embeddings_dir = try std.fs.path.join(allocator, &.{ brain_root, "memory/face_embeddings" });

        const cfg = AffectiveCoreEmbeddedConfig{
            .brain_id = str(options.brain_id),
            .brain_root = str(brain_root),
            .conversation_models = str(options.conversation_models),
            .memory_path = str(memory_path),
            .graph_path = str(graph_path),
            .schedule_path = str(schedule_path),
            .maintenance_state_path = str(maintenance_state_path),
            .face_embeddings_dir = str(face_embeddings_dir),
            .host_manifest_json = str(manifest),
        };

        var error_message = AffectiveCoreEmbeddedString{};
        const host_services = mock.hostServices();
        var handle: ?*AffectiveCoreEmbedded = null;
        const status = embedded.affective_core_embedded_create(&cfg, &host_services, &handle, &error_message);
        defer embedded.affective_core_embedded_free_global_string(error_message);
        if (status != @intFromEnum(AffectiveCoreEmbeddedStatus.ok)) {
            const detail = embedded_config.stringSlice(error_message) orelse "embedded create failed";
            std.debug.print("mcp-host init failed: {s}\n", .{detail});
            return error.EmbeddedCreateFailed;
        }

        handle.?.context_budget.max_envelope_bytes = 64 * 1024;
        try scenario_mod.apply(handle.?, allocator, options.scenario);

        return .{
            .arena = arena,
            .mock_host = mock,
            .handle = handle.?,
        };
    }

    pub fn deinit(self: *Session) void {
        embedded.affective_core_embedded_destroy(self.handle);
        self.arena.deinit();
    }

    pub fn setupHost(self: *Session) !void {
        if (self.host_setup_done) return;
        const connect_json = try requests.connect("mcp-host-connect");
        defer self.arena.allocator().free(connect_json);
        _ = try self.dispatch(connect_json);

        const attach_json = try requests.hostAttach("mcp-host-attach", "mcp-host");
        defer self.arena.allocator().free(attach_json);
        _ = try self.dispatch(attach_json);
        self.host_setup_done = true;
    }

    pub fn dispatch(self: *Session, request_json: []const u8) ![]u8 {
        var data = AffectiveCoreEmbeddedString{};
        var runtime_error = AffectiveCoreEmbeddedString{};
        defer embedded.affective_core_embedded_free_global_string(data);
        defer embedded.affective_core_embedded_free_global_string(runtime_error);

        const status = embedded.affective_core_embedded_dispatch_json(
            self.handle,
            request_json.ptr,
            request_json.len,
            &data,
            &runtime_error,
        );
        if (status != @intFromEnum(AffectiveCoreEmbeddedStatus.ok)) {
            const detail = embedded_config.stringSlice(runtime_error) orelse "dispatch failed";
            std.debug.print("dispatch runtime error: {s}\n", .{detail});
            return error.EmbeddedDispatchFailed;
        }
        const slice = embedded_config.stringSlice(data) orelse return error.EmptyDispatchResponse;
        return try self.arena.allocator().dupe(u8, slice);
    }

    pub fn drain(self: *Session) ![]u8 {
        var data = AffectiveCoreEmbeddedString{};
        var runtime_error = AffectiveCoreEmbeddedString{};
        defer embedded.affective_core_embedded_free_global_string(data);
        defer embedded.affective_core_embedded_free_global_string(runtime_error);

        const status = embedded.affective_core_embedded_drain_events_json(self.handle, &data, &runtime_error);
        if (status != @intFromEnum(AffectiveCoreEmbeddedStatus.ok)) {
            const detail = embedded_config.stringSlice(runtime_error) orelse "drain failed";
            std.debug.print("drain runtime error: {s}\n", .{detail});
            return error.EmbeddedDrainFailed;
        }
        const slice = embedded_config.stringSlice(data) orelse return error.EmptyDrainResponse;
        return try self.arena.allocator().dupe(u8, slice);
    }
};

fn str(value: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = value.ptr, .len = value.len };
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

test "session dispatches user_text through embedded envelope" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var session = try Session.open(io, .{
        .brain_root = "data/test/mcp_host_session",
        .fresh = true,
    });
    defer session.deinit();
    try session.setupHost();
    try session.setupHost();

    const response = try session.dispatch(
        \\{"request_id":"mcp-host-hello","event":{"type":"user_text","text":"hello from mcp host"}}
    );
    try std.testing.expect(std.mem.indexOf(u8, response, "\"event_type\": \"user_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"outcome\"") != null);
}
