const std = @import("std");

const chat = @import("api/chat_client.zig");
const brain_container = @import("app/brain_container.zig");
const app_core = @import("app/app_core.zig");
const host_profiles = @import("app/host_profiles.zig");
const context_gate = @import("app/context_gate.zig");
const embedded_protocol = @import("app/embedded_protocol.zig");
const config_mod = @import("core/config.zig");
const brain_mod = @import("core/brain.zig");
const http_transport_mod = @import("api/http_transport.zig");
const files = @import("platform/common/files.zig");
const input_mod = @import("platform/common/input.zig");
const brain_storage = @import("storage/brain_storage.zig");
const embedded_config = @import("affective_core_embedded_config.zig");
const embedded_e2e = @import("affective_core_embedded_e2e.zig");
const embedded_v2 = @import("affective_core_embedded_v2.zig");
const embedded_dispatch = @import("affective_core_embedded_dispatch.zig");

pub const AffectiveCoreEmbeddedString = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

pub const AffectiveCoreEmbeddedConfig = extern struct {
    brain_id: AffectiveCoreEmbeddedString = .{},
    brain_root: AffectiveCoreEmbeddedString = .{},
    conversation_models: AffectiveCoreEmbeddedString = .{},
    conversation_reasoning_effort: AffectiveCoreEmbeddedString = .{},
    image_generation_model: AffectiveCoreEmbeddedString = .{},
    image_generation_output_dir: AffectiveCoreEmbeddedString = .{},
    memory_path: AffectiveCoreEmbeddedString = .{},
    graph_path: AffectiveCoreEmbeddedString = .{},
    schedule_path: AffectiveCoreEmbeddedString = .{},
    events_path: AffectiveCoreEmbeddedString = .{},
    maintenance_state_path: AffectiveCoreEmbeddedString = .{},
    face_embeddings_dir: AffectiveCoreEmbeddedString = .{},
    host_manifest_json: AffectiveCoreEmbeddedString = .{},
};

pub const AffectiveCoreEmbeddedHttpPostJsonFn = *const fn (
    ?*anyopaque,
    AffectiveCoreEmbeddedString,
    AffectiveCoreEmbeddedString,
    AffectiveCoreEmbeddedString,
    ?*AffectiveCoreEmbeddedString,
    ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int;

pub const AffectiveCoreEmbeddedFreeHostStringFn = *const fn (
    ?*anyopaque,
    AffectiveCoreEmbeddedString,
) callconv(.c) void;

pub const AffectiveCoreEmbeddedHostServices = extern struct {
    ctx: ?*anyopaque = null,
    http_post_json: ?AffectiveCoreEmbeddedHttpPostJsonFn = null,
    free_string: ?AffectiveCoreEmbeddedFreeHostStringFn = null,
};

pub const AffectiveCoreEmbeddedStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    initialization_failed = 2,
    runtime_error = 3,
};

pub const AffectiveCoreEmbedded = struct {
    arena: std.heap.ArenaAllocator = undefined,
    io_threaded: std.Io.Threaded = .init_single_threaded,
    env: std.process.Environ.Map,
    brain: brain_mod.Brain,
    storage_backend: ?brain_storage.BrainStorage = null,
    host_effects: ?*embedded_protocol.HostEffectCollector = null,
    http_transport: HostHttpTransport,
    brain_initialized: bool = false,
    event_queue: std.ArrayList(embedded_protocol.HostEvent) = .empty,
    context_budget: context_gate.BudgetConfig = .{},
    raw_ref_ttl_seconds: i64 = 24 * 60 * 60,
    pending_camera_permission: ?HostCapabilityPending = null,

    pub fn allocator(self: *AffectiveCoreEmbedded) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn io(self: *AffectiveCoreEmbedded) std.Io {
        return self.io_threaded.io();
    }
};

const FailingHttpTransport = struct {
    fn client(self: *FailingHttpTransport) http_transport_mod.Client {
        return .{ .ctx = self, .postJsonFn = postJson };
    }

    fn postJson(_: *anyopaque, _: std.mem.Allocator, _: http_transport_mod.JsonPostRequest) ![]u8 {
        return error.HostHttpTransportRequired;
    }
};

const HostHttpTransport = struct {
    services: AffectiveCoreEmbeddedHostServices = .{},
    failing: FailingHttpTransport = .{},
    last_error: ?[]const u8 = null,

    fn init(services: ?*const AffectiveCoreEmbeddedHostServices) HostHttpTransport {
        return .{ .services = if (services) |value| value.* else .{} };
    }

    fn client(self: *HostHttpTransport) http_transport_mod.Client {
        if (self.services.http_post_json == null or self.services.free_string == null) {
            return self.failing.client();
        }
        return .{ .ctx = self, .postJsonFn = postJson };
    }

    fn postJson(ctx: *anyopaque, allocator: std.mem.Allocator, request: http_transport_mod.JsonPostRequest) ![]u8 {
        const self: *HostHttpTransport = @ptrCast(@alignCast(ctx));
        const post_json = self.services.http_post_json orelse return error.HostHttpTransportRequired;
        const free_string = self.services.free_string orelse return error.HostHttpTransportRequired;

        const headers_json = try std.json.Stringify.valueAlloc(allocator, request.headers, .{});
        defer allocator.free(headers_json);

        var out_data = AffectiveCoreEmbeddedString{};
        var out_error = AffectiveCoreEmbeddedString{};
        const status = post_json(
            self.services.ctx,
            sliceToEmbeddedString(request.url),
            sliceToEmbeddedString(headers_json),
            sliceToEmbeddedString(request.body),
            &out_data,
            &out_error,
        );
        defer free_string(self.services.ctx, out_data);
        defer free_string(self.services.ctx, out_error);

        if (status != 0) {
            self.rememberLastError(allocator, out_error);
            return error.HostHttpPostJsonFailed;
        }
        const bytes = try embeddedStringToOwnedSlice(allocator, out_data);
        errdefer allocator.free(bytes);
        if (bytes.len > request.max_response_bytes) return error.StreamTooLong;
        return bytes;
    }

    fn rememberLastError(self: *HostHttpTransport, allocator: std.mem.Allocator, out_error: AffectiveCoreEmbeddedString) void {
        const bytes = embedded_config.stringSlice(out_error) orelse "";
        const trimmed = std.mem.trim(u8, bytes, &std.ascii.whitespace);
        if (trimmed.len == 0) {
            self.last_error = null;
            return;
        }
        self.last_error = allocator.dupe(u8, trimmed) catch trimmed;
    }
};

const HostCapabilityPending = struct {
    request_id: []const u8,
    pending_since_unix_ms: i64,
    reason: []const u8,
};

pub export fn affective_core_embedded_create(
    config: ?*const AffectiveCoreEmbeddedConfig,
    host_services: ?*const AffectiveCoreEmbeddedHostServices,
    out_handle: ?*?*AffectiveCoreEmbedded,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setHandle(out_handle, null);
    setString(out_error, .{});

    const raw_config = config orelse {
        return createFailure(out_error, "missing embedded config");
    };

    const handle = std.heap.page_allocator.create(AffectiveCoreEmbedded) catch {
        return createFailure(out_error, "could not allocate embedded AffectiveCore handle");
    };
    errdefer std.heap.page_allocator.destroy(handle);

    handle.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    handle.io_threaded = .init_single_threaded;
    const allocator = handle.allocator();
    handle.env = std.process.Environ.Map.init(allocator);
    handle.http_transport = HostHttpTransport.init(host_services);
    handle.brain_initialized = false;
    handle.storage_backend = null;
    handle.host_effects = null;
    handle.event_queue = .empty;
    handle.context_budget = .{};
    handle.raw_ref_ttl_seconds = 24 * 60 * 60;
    handle.pending_camera_permission = null;
    const manifest_json = embedded_config.stringSlice(raw_config.host_manifest_json) orelse "";
    const manifest = embedded_protocol.parseHostManifest(
        allocator,
        if (manifest_json.len == 0) embedded_protocol.defaultMacosManifestJson() else manifest_json,
    ) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not parse embedded host manifest", err);
    };
    embedded_config.configureHostProviderRouting(allocator, &handle.env, raw_config.*) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not configure embedded host provider routing", err);
    };

    const base_cfg = embedded_config.makeConfig(allocator, raw_config.*) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not build embedded config", err);
    };
    var local_filesystem = files.LocalFileSystem{};
    var cfg = base_cfg.withRuntimeOptions(allocator, local_filesystem.filesystem(), handle.io()) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not load embedded runtime options", err);
    };
    cfg = embedded_config.restoreHostControlledPaths(allocator, raw_config.*, cfg) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not restore embedded host paths", err);
    };
    if (ensureParentDirsOrFailure(handle, out_error, cfg)) |status| return status;
    const embedded_brain_host = host_profiles.initEmbeddedMacosBrainHost(allocator, handle.io(), handle.http_transport.client(), cfg, manifest.capabilities) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not initialize embedded AffectiveCore runtime", err);
    };
    handle.brain = embedded_brain_host.brain;
    handle.storage_backend = embedded_brain_host.storage;
    handle.host_effects = embedded_brain_host.effects;
    handle.brain_initialized = true;
    handle.context_budget = .{
        .max_envelope_bytes = manifest.max_envelope_bytes,
        .max_event_count = manifest.max_event_count,
        .max_event_text_bytes = manifest.max_event_text_bytes,
    };
    handle.raw_ref_ttl_seconds = manifest.raw_ref_ttl_seconds;

    setHandle(out_handle, handle);
    return @intFromEnum(AffectiveCoreEmbeddedStatus.ok);
}

pub export fn affective_core_embedded_destroy(handle: ?*AffectiveCoreEmbedded) void {
    const ctx = handle orelse return;
    if (ctx.storage_backend) |*storage| {
        storage.deinit(ctx.allocator());
        ctx.storage_backend = null;
    }
    ctx.env.deinit();
    ctx.io_threaded.deinit();
    ctx.arena.deinit();
    std.heap.page_allocator.destroy(ctx);
}

pub export fn affective_core_embedded_dispatch_json(
    handle: ?*AffectiveCoreEmbedded,
    request_json_ptr: ?[*]const u8,
    request_json_len: usize,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    const request_json = embedded_config.requiredSlice(request_json_ptr, request_json_len) catch {
        return protocolError(ctx, out_data, "", "invalid_request", "missing dispatch request JSON");
    };
    const output = embedded_v2.dispatchJson(ctx, request_json) catch |err| {
        const message = std.fmt.allocPrint(std.heap.page_allocator, "dispatch failed: {s}", .{@errorName(err)}) catch "dispatch failed";
        defer if (!std.mem.eql(u8, message, "dispatch failed")) std.heap.page_allocator.free(message);
        return protocolError(ctx, out_data, "", "runtime_error", message);
    };
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_drain_events_json(
    handle: ?*AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    const request_id = "";
    const compacted = context_gate.compactEvents(ctx.allocator(), ctx.brain.now_seconds, request_id, ctx.event_queue.items, ctx.context_budget) catch |err| {
        return runtimeError(ctx, out_error, "could not compact drained events", err);
    };
    embedded_v2.persistRawRefs(ctx, compacted.raw_refs) catch |err| {
        return runtimeError(ctx, out_error, "could not store compacted drained event refs", err);
    };
    const budget = context_gate.budgetWithResult(ctx.allocator(), compacted.budget, 0, &.{}, false) catch |err| {
        return runtimeError(ctx, out_error, "could not build drain budget", err);
    };
    const output = embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, compacted.events, .{ .kind = "drain" }, budget) catch |err| {
        return runtimeError(ctx, out_error, "could not encode drained events", err);
    };
    ctx.event_queue.clearRetainingCapacity();
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_raw_ref_lookup_json(
    handle: ?*AffectiveCoreEmbedded,
    raw_ref_ptr: ?[*]const u8,
    raw_ref_len: usize,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    const raw_ref = embedded_config.requiredSlice(raw_ref_ptr, raw_ref_len) catch {
        return protocolError(ctx, out_data, "", "invalid_request", "missing raw_ref");
    };
    const bytes = embedded_v2.lookupRawRef(ctx, raw_ref) catch |err| {
        return protocolError(ctx, out_data, "", "raw_ref_not_found", @errorName(err));
    };
    const compacted = context_gate.compactText(ctx.allocator(), ctx.brain.now_seconds, "raw_ref_lookup", bytes, ctx.context_budget.max_result_bytes) catch |err| {
        return runtimeError(ctx, out_error, "could not compact raw ref lookup", err);
    };
    embedded_v2.persistRawRefs(ctx, compacted.raw_refs) catch |err| {
        return runtimeError(ctx, out_error, "could not store nested raw refs", err);
    };
    const base_budget: context_gate.BudgetReport = .{
        .max_bytes = ctx.context_budget.max_envelope_bytes,
        .used_bytes = 0,
        .compacted = false,
        .dropped_event_count = 0,
        .raw_refs = &.{},
    };
    const budget = context_gate.budgetWithResult(ctx.allocator(), base_budget, compacted.summary.len, compacted.raw_refs, compacted.compacted) catch |err| {
        return runtimeError(ctx, out_error, "could not build raw ref budget", err);
    };
    const output = embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, "", &[_]embedded_protocol.HostEvent{}, .{
        .event_type = "raw_ref_lookup",
        .raw_ref = raw_ref,
        .summary = compacted.summary,
    }, budget) catch |err| {
        return runtimeError(ctx, out_error, "could not encode raw ref lookup", err);
    };
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_introspect_json(
    handle: ?*AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    clearHostEffects(ctx);
    const result = app_core.executeBrainCommand(ctx.allocator(), &ctx.brain, .{ .command = .introspect }) catch |err| {
        return protocolError(ctx, out_data, "", "introspect_failed", @errorName(err));
    };
    const output = embedded_v2.encodeDispatchResult(ctx, "", "introspect_summary", result.observation, true) catch |err| {
        return runtimeError(ctx, out_error, "could not encode introspect", err);
    };
    return success(ctx, out_data, output);
}

pub fn clearHostEffects(ctx: *AffectiveCoreEmbedded) void {
    if (ctx.host_effects) |effects| effects.clear();
}

pub fn hostEvents(ctx: *AffectiveCoreEmbedded) []const embedded_protocol.HostEvent {
    if (ctx.host_effects) |effects| return effects.items();
    return &[_]embedded_protocol.HostEvent{};
}

pub export fn affective_core_embedded_free_global_string(string: AffectiveCoreEmbeddedString) void {
    const bytes = embedded_config.stringSlice(string) orelse return;
    std.heap.page_allocator.free(bytes);
}

pub export fn affective_core_embedded_conversation_turn(
    handle: ?*AffectiveCoreEmbedded,
    text_ptr: ?[*]const u8,
    text_len: usize,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    const text = embedded_config.requiredSlice(text_ptr, text_len) catch {
        return runtimeFailure(ctx, out_error, "missing conversation text");
    };
    const result = app_core.conversationResult(ctx.brain.handleConversationText(embedded_dispatch.tryTypedSpeech(ctx, text) catch |err| {
        return runtimeError(ctx, out_error, "could not build conversation input", err);
    }) catch |err| {
        return runtimeError(ctx, out_error, "conversation_turn failed", err);
    });
    const json = std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 }) catch |err| {
        return runtimeError(ctx, out_error, "could not encode conversation_turn response", err);
    };
    return success(ctx, out_data, json);
}

pub export fn affective_core_embedded_call_tool(
    handle: ?*AffectiveCoreEmbedded,
    name_ptr: ?[*]const u8,
    name_len: usize,
    args_json_ptr: ?[*]const u8,
    args_json_len: usize,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    const name = embedded_config.requiredSlice(name_ptr, name_len) catch {
        return runtimeFailure(ctx, out_error, "missing embedded tool name");
    };
    const args_json = if (args_json_len == 0) "{}" else embedded_config.optionalSlice(args_json_ptr, args_json_len) orelse "{}";
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, args_json, .{}) catch |err| {
        return runtimeError(ctx, out_error, "could not parse embedded tool arguments", err);
    };
    defer parsed.deinit();
    const output = embedded_dispatch.dispatchTool(ctx, name, parsed.value) catch |err| {
        return runtimeError(ctx, out_error, "embedded tool call failed", err);
    };
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_introspect(
    handle: ?*AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    const result = app_core.executeBrainCommand(ctx.allocator(), &ctx.brain, .{ .command = .introspect }) catch |err| {
        return runtimeError(ctx, out_error, "introspect failed", err);
    };
    const copy = std.heap.page_allocator.dupe(u8, result.observation) catch |err| {
        return runtimeError(ctx, out_error, "could not copy introspect response", err);
    };
    return success(ctx, out_data, copy);
}

pub export fn affective_core_embedded_api_e2e(
    config: ?*const AffectiveCoreEmbeddedConfig,
    host_services: ?*const AffectiveCoreEmbeddedHostServices,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const raw_config = config orelse return runtimeFailure(null, out_error, "missing embedded config");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const io = io_threaded.io();
    var env = std.process.Environ.Map.init(allocator);
    embedded_config.tryConfigureHostProviderRouting(allocator, &env, raw_config.*) catch |err| {
        return runtimeError(null, out_error, "could not configure embedded host provider routing", err);
    };
    const cfg = embedded_config.makeConfig(allocator, raw_config.*) catch |err| {
        return runtimeError(null, out_error, "could not build embedded e2e config", err);
    };
    embedded_config.ensureParentDirs(io, cfg) catch |err| {
        return runtimeError(null, out_error, "could not create embedded e2e directories", err);
    };
    var http_transport = HostHttpTransport.init(host_services);
    const report = embedded_e2e.runApiE2E(allocator, io, http_transport.client(), &env, cfg) catch |err| {
        return runtimeError(null, out_error, "embedded api e2e failed", err);
    };
    const copy = std.heap.page_allocator.dupe(u8, report) catch |err| {
        return runtimeError(null, out_error, "could not copy embedded api e2e report", err);
    };
    return success(null, out_data, copy);
}

pub fn dispatchTool(ctx: *AffectiveCoreEmbedded, name: []const u8, args: std.json.Value) ![]u8 {
    return embedded_dispatch.dispatchTool(ctx, name, args);
}

pub fn shortTouchActivation(ctx: *AffectiveCoreEmbedded) !app_core.CommandResult {
    return embedded_dispatch.shortTouchActivation(ctx);
}

pub fn longTouchActivation(ctx: *AffectiveCoreEmbedded) !app_core.CommandResult {
    return embedded_dispatch.longTouchActivation(ctx);
}

pub fn runStimulusAutonomy(ctx: *AffectiveCoreEmbedded) !void {
    return embedded_dispatch.runStimulusAutonomy(ctx);
}

pub fn hostHttpFailureMessage(ctx: *AffectiveCoreEmbedded, prefix: []const u8, err: anyerror) ?[]const u8 {
    if (err != error.HostHttpPostJsonFailed) return null;
    const detail = ctx.http_transport.last_error orelse return null;
    return std.fmt.allocPrint(ctx.allocator(), "{s}: {s}", .{ prefix, detail }) catch detail;
}

fn dispatchJson(ctx: *AffectiveCoreEmbedded, request_json: []const u8) ![]u8 {
    return embedded_dispatch.dispatchJson(ctx, request_json);
}

fn encodeDispatchResult(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, result: anytype) ![]u8 {
    return embedded_dispatch.encodeDispatchResult(ctx, request_id, event_type, result);
}

fn protocolError(
    ctx: *AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    request_id: []const u8,
    code: []const u8,
    message: []const u8,
) c_int {
    const output = embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, code, message, false, embedded_v2.emptyBudget(ctx)) catch {
        return runtimeFailure(ctx, null, "could not encode embedded protocol error");
    };
    return success(ctx, out_data, output);
}

pub fn tryTypedSpeech(ctx: *AffectiveCoreEmbedded, text: []const u8) !input_mod.HeardSpeech {
    return embedded_dispatch.tryTypedSpeech(ctx, text);
}

fn ensureParentDirsOrFailure(
    handle: *AffectiveCoreEmbedded,
    out_error: ?*AffectiveCoreEmbeddedString,
    cfg: config_mod.Config,
) ?c_int {
    if (ensureParentPathOrFailure(handle, out_error, "memory_path", cfg.memory_path)) |status| return status;
    if (ensureParentPathOrFailure(handle, out_error, "graph_path", cfg.graph_path)) |status| return status;
    if (ensureParentPathOrFailure(handle, out_error, "events_path", cfg.events_path)) |status| return status;
    if (ensureParentPathOrFailure(handle, out_error, "maintenance_schedule_path", cfg.maintenance_schedule_path)) |status| return status;
    if (ensureParentPathOrFailure(handle, out_error, "maintenance_state_path", cfg.maintenance_state_path)) |status| return status;
    if (cfg.face_embeddings_dir.len > 0) {
        embedded_config.ensureDir(handle.io(), cfg.face_embeddings_dir) catch |err| {
            return createPathFailureWithHandle(handle, out_error, "could not create embedded brain directory", "face_embeddings_dir", cfg.face_embeddings_dir, err);
        };
    }
    return null;
}

fn ensureParentPathOrFailure(
    handle: *AffectiveCoreEmbedded,
    out_error: ?*AffectiveCoreEmbeddedString,
    label: []const u8,
    path: []const u8,
) ?c_int {
    embedded_config.ensureParentDir(handle.io(), path) catch |err| {
        return createPathFailureWithHandle(handle, out_error, "could not create embedded brain parent directory", label, path, err);
    };
    return null;
}

fn setString(out_string: ?*AffectiveCoreEmbeddedString, string: AffectiveCoreEmbeddedString) void {
    if (out_string) |value| value.* = string;
}

fn sliceToEmbeddedString(slice: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = slice.ptr, .len = slice.len };
}

fn embeddedStringToOwnedSlice(allocator: std.mem.Allocator, string: AffectiveCoreEmbeddedString) ![]u8 {
    const bytes = embedded_config.stringSlice(string) orelse return error.InvalidEmbeddedString;
    return try allocator.dupe(u8, bytes);
}

fn setHandle(out_handle: ?*?*AffectiveCoreEmbedded, handle: ?*AffectiveCoreEmbedded) void {
    if (out_handle) |value| value.* = handle;
}

fn success(ctx: ?*AffectiveCoreEmbedded, out_data: ?*AffectiveCoreEmbeddedString, bytes: []u8) c_int {
    _ = ctx;
    publishOwnedString(out_data, bytes);
    return @intFromEnum(AffectiveCoreEmbeddedStatus.ok);
}

fn runtimeError(
    ctx: ?*AffectiveCoreEmbedded,
    out_error: ?*AffectiveCoreEmbeddedString,
    prefix: []const u8,
    err: anyerror,
) c_int {
    if (ctx) |handle| {
        if (hostHttpFailureMessage(handle, prefix, err)) |detail| {
            const message = std.fmt.allocPrint(std.heap.page_allocator, "{s} (last_stage={s})", .{
                detail,
                handle.brain.last_trace_stage,
            }) catch return runtimeFailure(ctx, out_error, "embedded AffectiveCore runtime error");
            publishOwnedString(out_error, message);
            return @intFromEnum(AffectiveCoreEmbeddedStatus.runtime_error);
        }
    }
    const message = if (ctx) |handle|
        std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s} (last_stage={s})", .{
            prefix,
            @errorName(err),
            handle.brain.last_trace_stage,
        }) catch return runtimeFailure(ctx, out_error, "embedded AffectiveCore runtime error")
    else
        std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}", .{ prefix, @errorName(err) }) catch return runtimeFailure(ctx, out_error, "embedded AffectiveCore runtime error");
    publishOwnedString(out_error, message);
    return @intFromEnum(AffectiveCoreEmbeddedStatus.runtime_error);
}

fn runtimeFailure(
    ctx: ?*AffectiveCoreEmbedded,
    out_error: ?*AffectiveCoreEmbeddedString,
    message: []const u8,
) c_int {
    _ = ctx;
    const owned = std.heap.page_allocator.dupe(u8, message) catch return @intFromEnum(AffectiveCoreEmbeddedStatus.runtime_error);
    publishOwnedString(out_error, owned);
    return @intFromEnum(AffectiveCoreEmbeddedStatus.runtime_error);
}

fn createFailure(out_error: ?*AffectiveCoreEmbeddedString, message: []const u8) c_int {
    const owned = std.heap.page_allocator.dupe(u8, message) catch return @intFromEnum(AffectiveCoreEmbeddedStatus.initialization_failed);
    publishOwnedString(out_error, owned);
    return @intFromEnum(AffectiveCoreEmbeddedStatus.initialization_failed);
}

fn createFailureWithHandle(
    handle: *AffectiveCoreEmbedded,
    out_error: ?*AffectiveCoreEmbeddedString,
    prefix: []const u8,
    err: anyerror,
) c_int {
    const message = std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}", .{ prefix, @errorName(err) }) catch {
        affective_core_embedded_destroy(handle);
        return createFailure(out_error, prefix);
    };
    affective_core_embedded_destroy(handle);
    publishOwnedString(out_error, message);
    return @intFromEnum(AffectiveCoreEmbeddedStatus.initialization_failed);
}

fn createPathFailureWithHandle(
    handle: *AffectiveCoreEmbedded,
    out_error: ?*AffectiveCoreEmbeddedString,
    prefix: []const u8,
    label: []const u8,
    path: []const u8,
    err: anyerror,
) c_int {
    const message = std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}={s}: {s}", .{
        prefix,
        label,
        path,
        @errorName(err),
    }) catch {
        affective_core_embedded_destroy(handle);
        return createFailure(out_error, prefix);
    };
    affective_core_embedded_destroy(handle);
    publishOwnedString(out_error, message);
    return @intFromEnum(AffectiveCoreEmbeddedStatus.initialization_failed);
}

fn publishOwnedString(out_string: ?*AffectiveCoreEmbeddedString, bytes: []u8) void {
    const out = out_string orelse {
        std.heap.page_allocator.free(bytes);
        return;
    };
    out.* = .{ .ptr = bytes.ptr, .len = bytes.len };
}
