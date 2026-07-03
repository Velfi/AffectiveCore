const std = @import("std");

const app_core = @import("app/app_core.zig");
const embedded = @import("affective_core_embedded.zig");
const embedded_config = @import("affective_core_embedded_config.zig");
const input_mod = @import("platform/common/input.zig");
const protocol = @import("session/protocol.zig");

const net = std.Io.net;
const posix = std.posix;

extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;

const max_frame_bytes = 16 * 1024 * 1024;

pub const DispatchMode = enum {
    serial,
    concurrent,
    parallel,

    pub fn fromName(raw: []const u8) DispatchMode {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) return .concurrent;
        if (std.ascii.eqlIgnoreCase(trimmed, "serial") or
            std.ascii.eqlIgnoreCase(trimmed, "single") or
            std.ascii.eqlIgnoreCase(trimmed, "single_lane") or
            std.ascii.eqlIgnoreCase(trimmed, "single-lane"))
        {
            return .serial;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "parallel")) return .parallel;
        if (std.ascii.eqlIgnoreCase(trimmed, "concurrent") or
            std.ascii.eqlIgnoreCase(trimmed, "queueable") or
            std.ascii.eqlIgnoreCase(trimmed, "multiplexed"))
        {
            return .concurrent;
        }
        return .concurrent;
    }

    pub fn fromEnvironment(env: *const std.process.Environ.Map) DispatchMode {
        return fromName(env.get("AFFECTIVE_BSP_DISPATCH_MODE") orelse "");
    }

    fn allowsParallelSessionDispatch(self: DispatchMode) bool {
        return switch (self) {
            .serial => false,
            .concurrent, .parallel => true,
        };
    }
};

const Completion = struct {
    status: protocol.HostHttpCompletionStatus,
    data: ?[]u8 = null,
    error_message: ?[]u8 = null,

    fn deinit(self: Completion, allocator: std.mem.Allocator) void {
        if (self.data) |data| allocator.free(data);
        if (self.error_message) |message| allocator.free(message);
    }
};

const SessionServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: net.Stream,
    port: u16,
    writer_mutex: std.Io.Mutex = .init,
    completion_mutex: std.Io.Mutex = .init,
    completion_cond: std.Io.Condition = .init,
    completions: std.StringHashMap(Completion),
    next_host_request_id: usize = 1,
    handle: ?*embedded.AffectiveCoreEmbedded = null,
    session_id: []u8,
    shutting_down: bool = false,
    dispatch_mode: DispatchMode,
    dispatch_lane_mutex: std.Io.Mutex = .init,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stream: net.Stream,
        port: u16,
        env: *const std.process.Environ.Map,
    ) !SessionServer {
        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .port = port,
            .completions = std.StringHashMap(Completion).init(allocator),
            .session_id = try std.fmt.allocPrint(allocator, "bsp-{d}", .{port}),
            .dispatch_mode = DispatchMode.fromEnvironment(env),
        };
    }

    fn deinit(self: *SessionServer) void {
        if (self.handle) |handle| {
            embedded.affective_core_embedded_destroy(handle);
            self.handle = null;
        }
        var it = self.completions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.completions.deinit();
        self.allocator.free(self.session_id);
    }

    fn serve(self: *SessionServer) !void {
        var read_buffer: [64 * 1024]u8 = undefined;
        var reader_state = self.stream.reader(self.io, &read_buffer);
        const reader = &reader_state.interface;
        while (!self.shutting_down) {
            const raw_line = (try reader.takeDelimiter('\n')) orelse return;
            const line = std.mem.trimEnd(u8, raw_line, "\r");
            if (line.len == 0) continue;
            if (line.len > max_frame_bytes) {
                try self.sendError(null, "frame_too_large", "BSP frame exceeded maximum size");
                continue;
            }
            try self.handleLine(line);
        }
    }

    fn handleLine(self: *SessionServer, line: []const u8) !void {
        var parsed = protocol.parseLine(self.allocator, line) catch |err| {
            try self.sendError(null, "invalid_frame", @errorName(err));
            return;
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .session_create => |message| try self.handleSessionCreate(message),
            .session_destroy => |message| {
                self.shutting_down = true;
                if (message.request_id) |request_id| {
                    try self.sendJSON(.{
                        .type = "session.destroyed",
                        .request_id = request_id,
                    });
                }
            },
            .host_http_complete => |message| try self.completeHostHTTP(message),
            .dispatch => |message| try self.spawnDispatch(message.request_id, message.request_json, .dispatch),
            .conversation_text => |message| try self.spawnDispatch(message.request_id, message.text, .conversation_text),
            .drain => |message| try self.spawnDispatch(message.request_id, "", .drain),
            .drain_try => |message| try self.spawnDispatch(message.request_id, "", .drain_try),
            else => try self.sendError(requestIdOf(parsed.value), "unsupported_message", "BSP message is not supported by this session service"),
        }
    }

    const OwnedSessionCreate = struct {
        request_id: []u8,
        config: OwnedSessionConfig,

        fn deinit(self: OwnedSessionCreate, allocator: std.mem.Allocator) void {
            allocator.free(self.request_id);
            self.config.deinit(allocator);
        }
    };

    const OwnedSessionConfig = struct {
        brain_id: []u8,
        brain_root: []u8,
        conversation_models: []u8,
        conversation_reasoning_effort: []u8,
        image_generation_model: []u8,
        image_generation_output_dir: []u8,
        memory_path: []u8,
        graph_path: []u8,
        schedule_path: []u8,
        maintenance_state_path: []u8,
        face_embeddings_dir: []u8,
        host_manifest_json: []u8,

        fn asProtocol(self: OwnedSessionConfig) protocol.SessionConfig {
            return .{
                .brain_id = self.brain_id,
                .brain_root = self.brain_root,
                .conversation_models = self.conversation_models,
                .conversation_reasoning_effort = self.conversation_reasoning_effort,
                .image_generation_model = self.image_generation_model,
                .image_generation_output_dir = self.image_generation_output_dir,
                .memory_path = self.memory_path,
                .graph_path = self.graph_path,
                .schedule_path = self.schedule_path,
                .maintenance_state_path = self.maintenance_state_path,
                .face_embeddings_dir = self.face_embeddings_dir,
                .host_manifest_json = self.host_manifest_json,
            };
        }

        fn deinit(self: OwnedSessionConfig, allocator: std.mem.Allocator) void {
            allocator.free(self.brain_id);
            allocator.free(self.brain_root);
            allocator.free(self.conversation_models);
            allocator.free(self.conversation_reasoning_effort);
            allocator.free(self.image_generation_model);
            allocator.free(self.image_generation_output_dir);
            allocator.free(self.memory_path);
            allocator.free(self.graph_path);
            allocator.free(self.schedule_path);
            allocator.free(self.maintenance_state_path);
            allocator.free(self.face_embeddings_dir);
            allocator.free(self.host_manifest_json);
        }
    };

    fn handleSessionCreate(self: *SessionServer, message: protocol.SessionCreate) !void {
        if (self.handle != null) {
            try self.sendError(message.request_id, "session_exists", "session already created on this connection");
            return;
        }
        if (message.config.host_manifest_json.len == 0) {
            try self.sendError(message.request_id, "invalid_config", "session.create requires host_manifest_json");
            return;
        }
        const owned = try self.cloneSessionCreate(message);
        errdefer owned.deinit(self.allocator);
        const thread = try std.Thread.spawn(.{}, sessionCreateThreadMain, .{ self, owned });
        thread.detach();
    }

    fn cloneSessionCreate(self: *SessionServer, message: protocol.SessionCreate) !OwnedSessionCreate {
        return .{
            .request_id = try self.allocator.dupe(u8, message.request_id),
            .config = .{
                .brain_id = try self.allocator.dupe(u8, message.config.brain_id),
                .brain_root = try self.allocator.dupe(u8, message.config.brain_root),
                .conversation_models = try self.allocator.dupe(u8, message.config.conversation_models),
                .conversation_reasoning_effort = try self.allocator.dupe(u8, message.config.conversation_reasoning_effort),
                .image_generation_model = try self.allocator.dupe(u8, message.config.image_generation_model),
                .image_generation_output_dir = try self.allocator.dupe(u8, message.config.image_generation_output_dir),
                .memory_path = try self.allocator.dupe(u8, message.config.memory_path),
                .graph_path = try self.allocator.dupe(u8, message.config.graph_path),
                .schedule_path = try self.allocator.dupe(u8, message.config.schedule_path),
                .maintenance_state_path = try self.allocator.dupe(u8, message.config.maintenance_state_path),
                .face_embeddings_dir = try self.allocator.dupe(u8, message.config.face_embeddings_dir),
                .host_manifest_json = try self.allocator.dupe(u8, message.config.host_manifest_json),
            },
        };
    }

    fn sessionCreateThreadMain(self: *SessionServer, owned: OwnedSessionCreate) void {
        defer owned.deinit(self.allocator);
        self.runSessionCreate(owned.request_id, owned.config.asProtocol()) catch |err| {
            self.sendError(owned.request_id, "session_create_failed", @errorName(err)) catch {};
        };
    }

    fn runSessionCreate(self: *SessionServer, request_id: []const u8, config: protocol.SessionConfig) !void {
        var out_handle: ?*embedded.AffectiveCoreEmbedded = null;
        var out_error = embedded.AffectiveCoreEmbeddedString{};
        const services = embedded.AffectiveCoreEmbeddedHostServices{
            .ctx = self,
            .http_post_json_begin = hostHttpBegin,
            .http_post_json_poll = hostHttpPoll,
            .free_string = freeHostString,
            .on_host_events = onHostEvents,
        };
        const embedded_config_value = toEmbeddedConfig(config);
        const status = embedded.affective_core_embedded_create(&embedded_config_value, &services, &out_handle, &out_error);
        defer embedded.affective_core_embedded_free_global_string(out_error);
        if (status != @intFromEnum(embedded.AffectiveCoreEmbeddedStatus.ok)) {
            const message_text = embeddedStringSlice(out_error) orelse "could not create BSP session";
            try self.sendError(request_id, "session_create_failed", message_text);
            return;
        }
        self.handle = out_handle;
        try self.sendJSON(.{
            .type = "session.ready",
            .request_id = request_id,
            .session_id = self.session_id,
            .port = self.port,
        });
    }

    const DispatchKind = enum { dispatch, conversation_text, drain, drain_try };

    fn spawnDispatch(self: *SessionServer, request_id: []const u8, request_json: []const u8, kind: DispatchKind) !void {
        if (self.handle == null) {
            try self.sendError(request_id, "session_not_ready", "session.create must complete before dispatch");
            return;
        }
        const owned_request_id = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(owned_request_id);
        const owned_request_json = try self.allocator.dupe(u8, request_json);
        errdefer self.allocator.free(owned_request_json);
        const thread = try std.Thread.spawn(.{}, dispatchThreadMain, .{ self, owned_request_id, owned_request_json, kind });
        thread.detach();
    }

    fn dispatchThreadMain(self: *SessionServer, request_id: []u8, request_json: []u8, kind: DispatchKind) void {
        defer self.allocator.free(request_id);
        defer self.allocator.free(request_json);
        self.runDispatch(request_id, request_json, kind) catch |err| {
            self.sendError(request_id, "dispatch_failed", @errorName(err)) catch {};
        };
    }

    fn runDispatch(self: *SessionServer, request_id: []const u8, request_json: []const u8, kind: DispatchKind) !void {
        if (!self.dispatch_mode.allowsParallelSessionDispatch()) {
            try self.dispatch_lane_mutex.lock(self.io);
            defer self.dispatch_lane_mutex.unlock(self.io);
        }
        const handle = self.handle orelse return error.MissingSession;
        if (kind == .conversation_text) {
            const payload = try self.runConversationText(handle, request_json, request_id);
            defer self.allocator.free(payload);
            try self.sendEnvelope("conversation.result", request_id, payload);
            return;
        }
        var out_data = embedded.AffectiveCoreEmbeddedString{};
        var out_error = embedded.AffectiveCoreEmbeddedString{};
        const status = switch (kind) {
            .dispatch => embedded.affective_core_embedded_dispatch_json(handle, request_json.ptr, request_json.len, &out_data, &out_error),
            .conversation_text => unreachable,
            .drain => embedded.affective_core_embedded_drain_events_json(handle, &out_data, &out_error),
            .drain_try => embedded.affective_core_embedded_try_drain_events_json(handle, &out_data, &out_error),
        };
        defer embedded.affective_core_embedded_free_global_string(out_data);
        defer embedded.affective_core_embedded_free_global_string(out_error);
        if (status != @intFromEnum(embedded.AffectiveCoreEmbeddedStatus.ok)) {
            const message_text = embeddedStringSlice(out_error) orelse "core dispatch failed";
            try self.sendError(request_id, "runtime_error", message_text);
            return;
        }
        const payload = embeddedStringSlice(out_data) orelse "{}";
        const response_type = switch (kind) {
            .dispatch => "dispatch.result",
            .conversation_text => unreachable,
            .drain, .drain_try => "drain.result",
        };
        try self.sendEnvelope(response_type, request_id, payload);
    }

    fn runConversationText(
        self: *SessionServer,
        handle: *embedded.AffectiveCoreEmbedded,
        text: []const u8,
        request_id: []const u8,
    ) ![]u8 {
        handle.resetDispatchScratch();
        handle.clearHttpTransportLastError();
        handle.wireDispatchScratchToLlmClients();
        handle.brain.clearChatParseFailure();
        embedded.clearHostEffects(handle);
        try handle.brain.beginRequestTimings(request_id);
        defer handle.brain.resetRequestTimings();
        const outcome = try app_core.handleUserText(
            &handle.brain,
            try input_mod.HeardSpeech.typed(handle.allocator(), text),
            .{ .request_id = request_id },
        );
        return try std.json.Stringify.valueAlloc(self.allocator, outcome, .{ .whitespace = .indent_2 });
    }

    fn completeHostHTTP(self: *SessionServer, message: protocol.HostHttpComplete) !void {
        try protocol.validateHostHttpComplete(message);
        var completion = Completion{ .status = message.status };
        errdefer completion.deinit(self.allocator);
        switch (message.status) {
            .complete => {
                const data_b64 = message.data_b64 orelse return error.MissingBspHttpData;
                completion.data = try protocol.decodeBase64(self.allocator, data_b64);
            },
            .failed => {
                completion.error_message = try self.allocator.dupe(u8, message.error_message orelse "host HTTP request failed");
            },
        }
        try self.completion_mutex.lock(self.io);
        defer self.completion_mutex.unlock(self.io);
        const result = try self.completions.getOrPut(message.request_id);
        if (result.found_existing) {
            result.value_ptr.*.deinit(self.allocator);
            self.allocator.free(result.key_ptr.*);
            result.key_ptr.* = try self.allocator.dupe(u8, message.request_id);
        } else {
            result.key_ptr.* = try self.allocator.dupe(u8, message.request_id);
        }
        result.value_ptr.* = completion;
        self.completion_cond.broadcast(self.io);
    }

    fn beginHostHTTP(self: *SessionServer, url: []const u8, headers_json: []const u8, body: []const u8, out_request_id: ?*embedded.AffectiveCoreEmbeddedString, out_error: ?*embedded.AffectiveCoreEmbeddedString) c_int {
        const request_id = std.fmt.allocPrint(self.allocator, "host-http-{d}", .{self.next_host_request_id}) catch {
            setEmbeddedString(out_error, ownedHostString(self.allocator, "could not allocate host HTTP request id") catch .{});
            return 1;
        };
        self.next_host_request_id += 1;
        const body_b64 = protocol.encodeBase64(self.allocator, body) catch |err| {
            self.allocator.free(request_id);
            setEmbeddedString(out_error, ownedHostString(self.allocator, @errorName(err)) catch .{});
            return 1;
        };
        defer self.allocator.free(body_b64);
        self.sendJSON(.{
            .type = "host.http.begin",
            .request_id = request_id,
            .url = url,
            .headers_json = headers_json,
            .body_b64 = body_b64,
            .timeout_ms = 120000,
            .max_response_bytes = @as(usize, 16 * 1024 * 1024),
        }) catch |err| {
            self.allocator.free(request_id);
            setEmbeddedString(out_error, ownedHostString(self.allocator, @errorName(err)) catch .{});
            return 1;
        };
        setEmbeddedString(out_request_id, .{ .ptr = request_id.ptr, .len = request_id.len });
        setEmbeddedString(out_error, .{});
        return 0;
    }

    fn pollHostHTTP(self: *SessionServer, request_id: []const u8, out_data: ?*embedded.AffectiveCoreEmbeddedString, out_error: ?*embedded.AffectiveCoreEmbeddedString) c_int {
        self.completion_mutex.lockUncancelable(self.io);
        defer self.completion_mutex.unlock(self.io);
        const removed = self.completions.fetchRemove(request_id) orelse return embedded.host_http_poll_pending;
        defer self.allocator.free(removed.key);
        var completion = removed.value;
        defer completion.deinit(self.allocator);
        switch (completion.status) {
            .complete => {
                const data = completion.data orelse &[_]u8{};
                const copy = self.allocator.dupe(u8, data) catch {
                    setEmbeddedString(out_error, ownedHostString(self.allocator, "could not allocate host HTTP response") catch .{});
                    return embedded.host_http_poll_failed;
                };
                setEmbeddedString(out_data, .{ .ptr = copy.ptr, .len = copy.len });
                setEmbeddedString(out_error, .{});
                return embedded.host_http_poll_complete;
            },
            .failed => {
                const message = completion.error_message orelse "host HTTP request failed";
                setEmbeddedString(out_error, ownedHostString(self.allocator, message) catch .{});
                setEmbeddedString(out_data, .{});
                return embedded.host_http_poll_failed;
            },
        }
    }

    fn sendHostEvents(self: *SessionServer, events_json: []const u8) void {
        self.sendJSON(.{
            .type = "events.push",
            .request_id = "events-push",
            .events_json = events_json,
        }) catch {};
    }

    fn sendEnvelope(self: *SessionServer, response_type: []const u8, request_id: []const u8, payload_json: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload_json, .{}) catch |err| {
            try self.sendError(request_id, "malformed_core_envelope", @errorName(err));
            return;
        };
        defer parsed.deinit();
        try self.sendJSON(.{
            .type = response_type,
            .request_id = request_id,
            .envelope = parsed.value,
        });
    }

    fn sendError(self: *SessionServer, request_id: ?[]const u8, code: []const u8, message: []const u8) !void {
        if (request_id) |id| {
            try self.sendJSON(.{
                .type = "dispatch.error",
                .request_id = id,
                .code = code,
                .message = message,
            });
        } else {
            try self.sendJSON(.{
                .type = "dispatch.error",
                .code = code,
                .message = message,
            });
        }
    }

    fn sendJSON(self: *SessionServer, value: anytype) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, value, .{ .whitespace = .minified });
        defer self.allocator.free(json);
        try self.writer_mutex.lock(self.io);
        defer self.writer_mutex.unlock(self.io);
        var write_buffer: [64 * 1024]u8 = undefined;
        var writer_state = self.stream.writer(self.io, &write_buffer);
        const writer = &writer_state.interface;
        try writer.writeAll(json);
        try writer.writeByte('\n');
        try writer.flush();
    }
};

test "BSP dispatch mode parses host-compatible names" {
    try std.testing.expectEqual(DispatchMode.concurrent, DispatchMode.fromName(""));
    try std.testing.expectEqual(DispatchMode.serial, DispatchMode.fromName("serial"));
    try std.testing.expectEqual(DispatchMode.serial, DispatchMode.fromName("single-lane"));
    try std.testing.expectEqual(DispatchMode.concurrent, DispatchMode.fromName("concurrent"));
    try std.testing.expectEqual(DispatchMode.concurrent, DispatchMode.fromName("multiplexed"));
    try std.testing.expectEqual(DispatchMode.parallel, DispatchMode.fromName("parallel"));
    try std.testing.expectEqual(DispatchMode.concurrent, DispatchMode.fromName("unknown"));
}

test "BSP dispatch mode exposes session dispatch parallelism contract" {
    try std.testing.expect(!DispatchMode.serial.allowsParallelSessionDispatch());
    try std.testing.expect(DispatchMode.concurrent.allowsParallelSessionDispatch());
    try std.testing.expect(DispatchMode.parallel.allowsParallelSessionDispatch());
}

fn requestIdOf(message: protocol.Message) ?[]const u8 {
    return switch (message) {
        .session_create => |value| value.request_id,
        .session_destroy => |value| value.request_id,
        .dispatch => |value| value.request_id,
        .drain => |value| value.request_id,
        .drain_try => |value| value.request_id,
        .raw_ref_lookup => |value| value.request_id,
        .brain_export => |value| value.request_id,
        .brain_import => |value| value.request_id,
        .host_http_complete => |value| value.request_id,
        else => null,
    };
}

fn hostHttpBegin(ctx: ?*anyopaque, url: embedded.AffectiveCoreEmbeddedString, headers_json: embedded.AffectiveCoreEmbeddedString, body: embedded.AffectiveCoreEmbeddedString, out_request_id: ?*embedded.AffectiveCoreEmbeddedString, out_error: ?*embedded.AffectiveCoreEmbeddedString) callconv(.c) c_int {
    const self: *SessionServer = @ptrCast(@alignCast(ctx.?));
    return self.beginHostHTTP(
        embeddedStringSlice(url) orelse "",
        embeddedStringSlice(headers_json) orelse "[]",
        embeddedStringSlice(body) orelse "",
        out_request_id,
        out_error,
    );
}

fn hostHttpPoll(ctx: ?*anyopaque, request_id: embedded.AffectiveCoreEmbeddedString, out_data: ?*embedded.AffectiveCoreEmbeddedString, out_error: ?*embedded.AffectiveCoreEmbeddedString) callconv(.c) c_int {
    const self: *SessionServer = @ptrCast(@alignCast(ctx.?));
    return self.pollHostHTTP(embeddedStringSlice(request_id) orelse "", out_data, out_error);
}

fn freeHostString(ctx: ?*anyopaque, string: embedded.AffectiveCoreEmbeddedString) callconv(.c) void {
    const self: *SessionServer = @ptrCast(@alignCast(ctx.?));
    const bytes = embeddedStringSlice(string) orelse return;
    if (bytes.len == 0) return;
    self.allocator.free(@constCast(bytes));
}

fn onHostEvents(ctx: ?*anyopaque, events_json: embedded.AffectiveCoreEmbeddedString) callconv(.c) void {
    const self: *SessionServer = @ptrCast(@alignCast(ctx.?));
    self.sendHostEvents(embeddedStringSlice(events_json) orelse "[]");
}

fn ownedHostString(allocator: std.mem.Allocator, bytes: []const u8) !embedded.AffectiveCoreEmbeddedString {
    const copy = try allocator.dupe(u8, bytes);
    return .{ .ptr = copy.ptr, .len = copy.len };
}

fn setEmbeddedString(out_string: ?*embedded.AffectiveCoreEmbeddedString, string: embedded.AffectiveCoreEmbeddedString) void {
    if (out_string) |out| out.* = string;
}

fn embeddedStringSlice(string: embedded.AffectiveCoreEmbeddedString) ?[]const u8 {
    const ptr = string.ptr orelse return null;
    if (string.len == 0) return "";
    return ptr[0..string.len];
}

fn toEmbeddedConfig(config: protocol.SessionConfig) embedded.AffectiveCoreEmbeddedConfig {
    return .{
        .brain_id = toEmbeddedString(config.brain_id),
        .brain_root = toEmbeddedString(config.brain_root),
        .conversation_models = toEmbeddedString(config.conversation_models),
        .conversation_reasoning_effort = toEmbeddedString(config.conversation_reasoning_effort),
        .image_generation_model = toEmbeddedString(config.image_generation_model),
        .image_generation_output_dir = toEmbeddedString(config.image_generation_output_dir),
        .memory_path = toEmbeddedString(config.memory_path),
        .graph_path = toEmbeddedString(config.graph_path),
        .schedule_path = toEmbeddedString(config.schedule_path),
        .maintenance_state_path = toEmbeddedString(config.maintenance_state_path),
        .face_embeddings_dir = toEmbeddedString(config.face_embeddings_dir),
        .host_manifest_json = toEmbeddedString(config.host_manifest_json),
    };
}

fn toEmbeddedString(bytes: []const u8) embedded.AffectiveCoreEmbeddedString {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    var requested_port: u16 = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const value = args.next() orelse return error.MissingPortArgument;
            requested_port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            requested_port = try std.fmt.parseInt(u16, arg["--port=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--help")) {
            try printUsage(init.io);
            return;
        }
    }

    var io_threaded = std.Io.Threaded.init_single_threaded;
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const listener_fd = try openLoopbackListener(requested_port);
    defer _ = posix.system.close(listener_fd);
    const bound_port = try listenerPort(listener_fd);
    try printAdvertisedPort(io, bound_port);

    const stream_fd = try acceptLoopbackClient(listener_fd);
    const stream_address = try net.IpAddress.parseIp4("127.0.0.1", bound_port);
    var stream = net.Stream{ .socket = .{ .handle = stream_fd, .address = stream_address } };
    defer stream.close(io);
    var server = try SessionServer.init(allocator, io, stream, bound_port, init.environ_map);
    defer server.deinit();
    try server.serve();
}

fn openLoopbackListener(port: u16) !posix.fd_t {
    const raw_fd = socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    switch (posix.errno(raw_fd)) {
        .SUCCESS => {},
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolUnsupportedBySystem,
        .PROTOTYPE => return error.ProtocolUnsupportedByAddressFamily,
        else => |err| return posix.unexpectedErrno(err),
    }

    const fd: posix.fd_t = @intCast(raw_fd);
    errdefer _ = posix.system.close(fd);

    const yes: c_int = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&yes));

    var address = posix.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    switch (posix.errno(posix.system.bind(fd, @ptrCast(&address), @sizeOf(posix.sockaddr.in)))) {
        .SUCCESS => {},
        .ACCES => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .BADF => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => unreachable,
        .PERM => return error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
    switch (posix.errno(posix.system.listen(fd, 128))) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        .BADF => unreachable,
        .DESTADDRREQ => return error.SocketNotBound,
        .INVAL => unreachable,
        .NOTSOCK => unreachable,
        .OPNOTSUPP => return error.OperationUnsupported,
        else => |err| return posix.unexpectedErrno(err),
    }
    return fd;
}

fn listenerPort(fd: posix.fd_t) !u16 {
    var address: posix.sockaddr.in = undefined;
    var address_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    switch (posix.errno(posix.system.getsockname(fd, @ptrCast(&address), &address_len))) {
        .SUCCESS => {},
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    }
    return std.mem.bigToNative(u16, address.port);
}

fn acceptLoopbackClient(listener_fd: posix.fd_t) !posix.fd_t {
    while (true) {
        const raw_fd = posix.system.accept(listener_fd, null, null);
        switch (posix.errno(raw_fd)) {
            .SUCCESS => return @intCast(raw_fd),
            .AGAIN => continue,
            .INTR => continue,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

fn printAdvertisedPort(io: std.Io, port: u16) !void {
    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print("AFFECTIVE_BSP_PORT={d}\n", .{port});
    try writer.flush();
}

fn printUsage(io: std.Io) !void {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.writeAll("usage: affective-core-session [--port PORT]\n");
    try writer.flush();
}
