const std = @import("std");

const chat = @import("api/chat_client.zig");
const app_brain = @import("app/brain.zig");
const context_gate = @import("app/context_gate.zig");
const embedded_protocol = @import("app/embedded_protocol.zig");
const config_mod = @import("core/config.zig");
const http_transport_mod = @import("api/http_transport.zig");
const files = @import("platform/common/files.zig");
const embedded_config = @import("affective_core_embedded_config.zig");
const embedded_e2e = @import("affective_core_embedded_e2e.zig");

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
    openai_api_key: AffectiveCoreEmbeddedString = .{},
    anthropic_api_key: AffectiveCoreEmbeddedString = .{},
    google_api_key: AffectiveCoreEmbeddedString = .{},
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
    runtime: app_brain.BrainRuntime,
    http_transport: HostHttpTransport,
    runtime_initialized: bool = false,
    event_queue: std.ArrayList(embedded_protocol.HostEvent) = .empty,
    context_budget: context_gate.BudgetConfig = .{},
    raw_ref_ttl_seconds: i64 = 24 * 60 * 60,
    pending_camera_permission: ?HostCapabilityPending = null,

    fn allocator(self: *AffectiveCoreEmbedded) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn io(self: *AffectiveCoreEmbedded) std.Io {
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

        if (status != 0) return error.HostHttpPostJsonFailed;
        const bytes = try embeddedStringToOwnedSlice(allocator, out_data);
        errdefer allocator.free(bytes);
        if (bytes.len > request.max_response_bytes) return error.StreamTooLong;
        return bytes;
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
    handle.runtime_initialized = false;
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
    embedded_config.seedProviderEnvironment(allocator, &handle.env, raw_config.*) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not configure embedded provider credentials", err);
    };

    const base_cfg = embedded_config.makeConfig(allocator, raw_config.*) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not build embedded config", err);
    };
    var cfg = base_cfg.withRuntimeOptions(allocator, handle.io()) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not load embedded runtime options", err);
    };
    cfg = embedded_config.restoreHostControlledPaths(allocator, raw_config.*, cfg) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not restore embedded host paths", err);
    };
    if (ensureParentDirsOrFailure(handle, out_error, cfg)) |status| return status;
    handle.runtime = app_brain.BrainRuntime.initEmbeddedMacos(allocator, handle.io(), handle.http_transport.client(), &handle.env, cfg) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not initialize embedded AffectiveCore runtime", err);
    };
    handle.runtime_initialized = true;
    handle.runtime.brain.deps.capabilities = manifest.capabilities;
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
    if (ctx.runtime_initialized) ctx.runtime.deinit();
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
    const output = dispatchJson(ctx, request_json) catch |err| {
        if (err == error.StreamTooLong) {
            return protocolError(
                ctx,
                out_data,
                "",
                "stream_too_large",
                "dispatch failed because a bounded stream exceeded its byte limit; check preceding TRACE commands.command.error lines for local command overflow or HTTP response_too_large lines for provider overflow; use embedded API v2 for budgeted envelopes",
            );
        }
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
    const events = ctx.event_queue.items;
    const output = embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, "", events, .{ .kind = "drain" }) catch |err| {
        return runtimeError(ctx, out_error, "could not encode drained events", err);
    };
    ctx.event_queue.clearRetainingCapacity();
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_dispatch_json_v2(
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
        return protocolErrorV2(ctx, out_data, "", "invalid_request", "missing dispatch request JSON");
    };
    const output = dispatchJsonV2(ctx, request_json) catch |err| {
        const message = std.fmt.allocPrint(std.heap.page_allocator, "dispatch v2 failed: {s}", .{@errorName(err)}) catch "dispatch v2 failed";
        defer if (!std.mem.eql(u8, message, "dispatch v2 failed")) std.heap.page_allocator.free(message);
        return protocolErrorV2(ctx, out_data, "", "runtime_error", message);
    };
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_drain_events_json_v2(
    handle: ?*AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    const request_id = "";
    const compacted = context_gate.compactEvents(ctx.allocator(), ctx.runtime.brain.now_seconds, request_id, ctx.event_queue.items, ctx.context_budget) catch |err| {
        return runtimeError(ctx, out_error, "could not compact drained events", err);
    };
    persistRawRefs(ctx, compacted.raw_refs) catch |err| {
        return runtimeError(ctx, out_error, "could not store compacted drained event refs", err);
    };
    const budget = context_gate.budgetWithResult(ctx.allocator(), compacted.budget, 0, &.{}, false) catch |err| {
        return runtimeError(ctx, out_error, "could not build drain budget", err);
    };
    const output = embedded_protocol.successEnvelopeV2Alloc(std.heap.page_allocator, request_id, compacted.events, .{ .kind = "drain" }, budget) catch |err| {
        return runtimeError(ctx, out_error, "could not encode v2 drained events", err);
    };
    ctx.event_queue.clearRetainingCapacity();
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_raw_ref_lookup_json_v2(
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
        return protocolErrorV2(ctx, out_data, "", "invalid_request", "missing raw_ref");
    };
    const bytes = lookupRawRef(ctx, raw_ref) catch |err| {
        return protocolErrorV2(ctx, out_data, "", "raw_ref_not_found", @errorName(err));
    };
    const compacted = context_gate.compactText(ctx.allocator(), ctx.runtime.brain.now_seconds, "raw_ref_lookup", bytes, ctx.context_budget.max_result_bytes) catch |err| {
        return runtimeError(ctx, out_error, "could not compact raw ref lookup", err);
    };
    persistRawRefs(ctx, compacted.raw_refs) catch |err| {
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
    const output = embedded_protocol.successEnvelopeV2Alloc(std.heap.page_allocator, "", &[_]embedded_protocol.HostEvent{}, .{
        .event_type = "raw_ref_lookup",
        .raw_ref = raw_ref,
        .summary = compacted.summary,
    }, budget) catch |err| {
        return runtimeError(ctx, out_error, "could not encode raw ref lookup", err);
    };
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_introspect_json_v2(
    handle: ?*AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    ctx.runtime.clearEmbeddedEffects();
    const result = ctx.runtime.executeCommand(.{ .command = .introspect }) catch |err| {
        return protocolErrorV2(ctx, out_data, "", "introspect_failed", @errorName(err));
    };
    const output = encodeDispatchResultV2(ctx, "", "introspect_summary", result.observation, true) catch |err| {
        return runtimeError(ctx, out_error, "could not encode v2 introspect", err);
    };
    return success(ctx, out_data, output);
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
    const result = ctx.runtime.conversationTurn(text) catch |err| {
        return runtimeError(ctx, out_error, "conversation_turn failed", err);
    };
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
    const output = dispatchTool(ctx, name, parsed.value) catch |err| {
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
    const result = ctx.runtime.executeCommand(.{ .command = .introspect }) catch |err| {
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
    embedded_config.trySeedProviderEnvironment(allocator, &env, raw_config.*) catch |err| {
        return runtimeError(null, out_error, "could not configure embedded provider credentials", err);
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

fn dispatchTool(ctx: *AffectiveCoreEmbedded, name: []const u8, args: std.json.Value) ![]u8 {
    if (std.mem.eql(u8, name, "conversation_turn")) {
        const result = try ctx.runtime.conversationTurn(try requireString(args, "text"));
        return std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, name, "short_touch") or std.mem.eql(u8, name, "button_short_touch")) {
        const result = try ctx.runtime.shortTouchActivation();
        return std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, name, "long_touch") or std.mem.eql(u8, name, "button_long_touch")) {
        const result = try ctx.runtime.longTouchActivation();
        return std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, name, "brain_inspect")) {
        const info = try ctx.runtime.inspectBrain(ctx.io());
        return std.json.Stringify.valueAlloc(std.heap.page_allocator, info, .{ .whitespace = .indent_2 });
    }
    if (std.mem.eql(u8, name, "introspect") or std.mem.eql(u8, name, "inner_state")) {
        return try executeCommand(ctx, .{ .command = .introspect });
    }
    if (std.mem.eql(u8, name, "request_orientation")) {
        return try executeCommand(ctx, .{ .command = .request_orientation });
    }
    if (std.mem.eql(u8, name, "memory_index")) return try memoryIndex(ctx);
    if (std.mem.eql(u8, name, "remember_memory")) {
        return try executeCommand(ctx, .{
            .command = .remember_memory,
            .text = try requireString(args, "text"),
            .tags = try getStringArray(ctx.allocator(), args, "tags"),
        });
    }
    if (std.mem.eql(u8, name, "recall_memory")) {
        return try executeCommand(ctx, .{
            .command = .recall_memory,
            .query = getString(args, "query") orelse "",
            .tags = try getStringArray(ctx.allocator(), args, "tags"),
        });
    }
    if (std.mem.eql(u8, name, "choose_attention")) return try executeCommand(ctx, .{ .command = .choose_attention });
    if (std.mem.eql(u8, name, "consolidate_memory")) return try executeCommand(ctx, .{ .command = .consolidate_memory });
    if (std.mem.eql(u8, name, "dream")) {
        return try executeCommand(ctx, .{
            .command = .dream,
            .text = getString(args, "text"),
            .tags = try getStringArray(ctx.allocator(), args, "tags"),
            .heat_bias = getString(args, "heat_bias"),
        });
    }
    if (std.mem.eql(u8, name, "set_reminder")) {
        return try executeCommand(ctx, .{
            .command = .set_reminder,
            .schedule = try requireString(args, "schedule"),
            .text = try requireString(args, "text"),
        });
    }
    if (std.mem.eql(u8, name, "list_reminders")) return try listReminders(ctx);
    return error.UnknownEmbeddedTool;
}

fn dispatchJson(ctx: *AffectiveCoreEmbedded, request_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, request_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) {
        return embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, "", "invalid_request", "dispatch request must be a JSON object", false);
    }
    const root = parsed.value.object;
    const request_id = getStringFromObject(root, "request_id") orelse "";
    const api_version = getIntegerFromObject(root, "api_version") orelse 0;
    if (api_version != embedded_protocol.api_version) {
        return embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "unsupported_api_version", "expected api_version 1", false);
    }
    const event = root.get("event") orelse {
        return embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing event", false);
    };
    if (event != .object) {
        return embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "event must be a JSON object", false);
    }
    const event_object = event.object;
    const event_type = getStringFromObject(event_object, "type") orelse {
        return embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing event.type", false);
    };

    ctx.runtime.clearEmbeddedEffects();
    const output = if (std.mem.eql(u8, event_type, "speech_transcript") or std.mem.eql(u8, event_type, "typed_text")) blk: {
        const text = getStringFromObject(event_object, "text") orelse "";
        const result = ctx.runtime.conversationTurn(text) catch |err| switch (err) {
            error.FrontendCaptureRequested => break :blk try encodeDispatchResult(ctx, request_id, event_type, .{
                .kind = "capture_requested",
                .message = "frontend camera capture requested",
            }),
            else => return err,
        };
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "conversation_turn", .conversation_turn = result });
    } else if (std.mem.eql(u8, event_type, "short_touch")) blk: {
        const result = try ctx.runtime.shortTouchActivation();
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "activation", .activation = "short_touch", .command_result = result });
    } else if (std.mem.eql(u8, event_type, "long_touch")) blk: {
        const result = try ctx.runtime.longTouchActivation();
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "activation", .activation = "long_touch", .command_result = result });
    } else if (std.mem.eql(u8, event_type, "poke_sequence")) blk: {
        const pulse_summary = try pokeSequencePulseSummary(ctx.allocator(), event_object);
        _ = try ctx.runtime.brain.observeSenseStimulus(.{
            .kind = .poke_sequence,
            .source = "affective_core_embedded",
            .signature = pulse_summary,
            .raw_magnitude = pokeSequenceMagnitude(event_object),
            .threat = 0,
            .curiosity = 0.40,
            .metadata = pulse_summary,
        });
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{
            .kind = "stimulus",
            .stimulus = "poke_sequence",
            .conversation_turn = .{
                .user_text = "",
                .spoken_text = "Poke received.",
                .user_summary = pulse_summary,
                .brain_summary = "Acknowledged a local poke stimulus without calling a provider.",
                .interrupted_by = null,
            },
        });
    } else if (std.mem.eql(u8, event_type, "tool_call")) blk: {
        const name = getStringFromObject(event_object, "name") orelse {
            return embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "invalid_request", "missing tool_call name", false);
        };
        var empty_args = try std.json.ObjectMap.init(std.heap.page_allocator, &.{}, &.{});
        defer empty_args.deinit(std.heap.page_allocator);
        const empty_args_value = std.json.Value{ .object = empty_args };
        const args = event_object.get("arguments") orelse empty_args_value;
        const tool_output = dispatchTool(ctx, name, args) catch |err| switch (err) {
            error.FrontendCaptureRequested => break :blk try encodeDispatchResult(ctx, request_id, event_type, .{
                .kind = "capture_requested",
                .tool_name = name,
                .message = "frontend camera capture requested",
            }),
            else => return err,
        };
        defer std.heap.page_allocator.free(tool_output);
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "tool_call", .tool_name = name, .output_json = tool_output });
    } else if (std.mem.eql(u8, event_type, "maintenance_tick")) blk: {
        try ctx.runtime.brain.runMaintenance(ctx.io());
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "maintenance_tick" });
    } else if (std.mem.eql(u8, event_type, "autonomy_tick")) blk: {
        try ctx.runtime.brain.runAutonomyTick(ctx.io());
        break :blk try encodeDispatchResult(ctx, request_id, event_type, .{ .kind = "autonomy_tick" });
    } else {
        return embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, "unknown_event_type", "unknown embedded event type", false);
    };
    return output;
}

fn dispatchJsonV2(ctx: *AffectiveCoreEmbedded, request_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, request_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) {
        return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, "", "invalid_request", "dispatch request must be a JSON object", false, emptyBudget(ctx));
    }
    const root = parsed.value.object;
    const request_id = getStringFromObject(root, "request_id") orelse "";
    const api_version = getIntegerFromObject(root, "api_version") orelse 0;
    if (api_version != embedded_protocol.api_version_v2) {
        return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "unsupported_api_version", "expected api_version 2", false, emptyBudget(ctx));
    }
    const event = root.get("event") orelse {
        return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "invalid_request", "missing event", false, emptyBudget(ctx));
    };
    if (event != .object) {
        return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "invalid_request", "event must be a JSON object", false, emptyBudget(ctx));
    }
    const event_object = event.object;
    const event_type = getStringFromObject(event_object, "type") orelse {
        return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "invalid_request", "missing event.type", false, emptyBudget(ctx));
    };

    ctx.runtime.clearEmbeddedEffects();
    if (std.mem.eql(u8, event_type, "speech_transcript") or std.mem.eql(u8, event_type, "typed_text")) {
        const text = getStringFromObject(event_object, "text") orelse "";
        const result = ctx.runtime.conversationTurn(text) catch |err| {
            if (err == error.FrontendCaptureRequested and ctx.pending_camera_permission != null) {
                return try encodeDispatchResultV2(ctx, request_id, event_type, try pendingCapabilitySummary(ctx), false);
            }
            if (err == error.FrontendOrientationRequested) {
                return try encodeDispatchResultV2(ctx, request_id, event_type, "frontend orientation requested", false);
            }
            return try encodeErrorResultV2(ctx, request_id, event_type, "conversation_turn_failed", @errorName(err));
        };
        const result_json = try std.json.Stringify.valueAlloc(ctx.allocator(), result, .{ .whitespace = .indent_2 });
        return try encodeDispatchResultV2(ctx, request_id, event_type, result_json, true);
    }
    if (std.mem.eql(u8, event_type, "interrupt")) {
        const text = getStringFromObject(event_object, "text") orelse "";
        const reason = getStringFromObject(event_object, "reason") orelse "user_interrupt";
        const interrupted_action = getStringFromObject(event_object, "interrupted_action") orelse "unknown";
        const canceled_count = getIntegerFromObject(event_object, "canceled_queued_action_count") orelse 0;
        const metadata = try std.fmt.allocPrint(ctx.allocator(), "reason={s} interrupted_action={s} canceled_queued_action_count={d} text={s}", .{
            reason,
            interrupted_action,
            canceled_count,
            text,
        });
        _ = try ctx.runtime.brain.observeSenseStimulus(.{
            .kind = .interrupt,
            .source = "affective_host",
            .signature = reason,
            .raw_magnitude = 0.70,
            .threat = 0,
            .curiosity = 0.35,
            .metadata = metadata,
        });
        const result_text = try std.fmt.allocPrint(ctx.allocator(), "interrupt: {s}", .{metadata});
        return try encodeDispatchResultV2(ctx, request_id, event_type, result_text, false);
    }
    if (std.mem.eql(u8, event_type, "short_touch")) {
        const result = try ctx.runtime.shortTouchActivation();
        const result_json = try std.json.Stringify.valueAlloc(ctx.allocator(), result, .{ .whitespace = .indent_2 });
        return try encodeDispatchResultV2(ctx, request_id, event_type, result_json, true);
    }
    if (std.mem.eql(u8, event_type, "long_touch")) {
        const result = try ctx.runtime.longTouchActivation();
        const result_json = try std.json.Stringify.valueAlloc(ctx.allocator(), result, .{ .whitespace = .indent_2 });
        return try encodeDispatchResultV2(ctx, request_id, event_type, result_json, true);
    }
    if (std.mem.eql(u8, event_type, "poke_sequence")) {
        const pulse_summary = try pokeSequencePulseSummary(ctx.allocator(), event_object);
        ctx.runtime.clearEmbeddedEffects();
        _ = try ctx.runtime.brain.observeSenseStimulus(.{
            .kind = .poke_sequence,
            .source = "affective_core_embedded",
            .signature = pulse_summary,
            .raw_magnitude = pokeSequenceMagnitude(event_object),
            .threat = 0,
            .curiosity = 0.40,
            .metadata = pulse_summary,
        });
        ctx.runtime.runStimulusAutonomy() catch |err| switch (err) {
            error.MissingAutonomyPlanner, error.MissingPsycheService, error.LocalDateUnavailable => {},
            else => return try encodeErrorResultV2(ctx, request_id, event_type, "stimulus_autonomy_failed", @errorName(err)),
        };
        return try encodeDispatchResultV2(ctx, request_id, event_type, "", false);
    }
    if (std.mem.eql(u8, event_type, "sense_observation")) {
        const sense = getStringFromObject(event_object, "sense") orelse "";
        const observation_value = event_object.get("observation") orelse {
            return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "invalid_request", "missing sense observation", false, emptyBudget(ctx));
        };
        if (observation_value != .object) {
            return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "invalid_request", "sense observation must be an object", false, emptyBudget(ctx));
        }
        const observation = observation_value.object;
        if (std.mem.eql(u8, sense, "orientation")) {
            const posture = getStringFromObject(observation, "posture") orelse "unknown";
            const summary = getStringFromObject(observation, "summary") orelse "Orientation observed.";
            const confidence = getNumberFromObject(observation, "confidence") orelse 0;
            const metadata = try std.fmt.allocPrint(ctx.allocator(), "posture={s} confidence={d:.2} summary={s}", .{ posture, confidence, summary });
            _ = try ctx.runtime.brain.observeSenseStimulus(.{
                .kind = .orientation,
                .source = "affective_orientation",
                .signature = posture,
                .raw_magnitude = @floatCast(@min(@max(confidence, 0), 1)),
                .threat = 0,
                .curiosity = 0.12,
                .metadata = metadata,
            });
            const result_text = try std.fmt.allocPrint(ctx.allocator(), "orientation: {s}", .{summary});
            return try encodeDispatchResultV2(ctx, request_id, event_type, result_text, false);
        }
        if (std.mem.eql(u8, sense, "camera")) {
            const path = getStringFromObject(observation, "path") orelse "";
            const mime_type = getStringFromObject(observation, "mime_type") orelse "image/jpeg";
            const source = getStringFromObject(observation, "source") orelse "affective_camera";
            const owned_path = try ctx.allocator().dupe(u8, path);
            const metadata = try std.fmt.allocPrint(ctx.allocator(), "path={s} mime_type={s} source={s}", .{ owned_path, mime_type, source });
            _ = try ctx.runtime.brain.observeSenseStimulus(.{
                .kind = .visual,
                .source = "affective_camera",
                .signature = owned_path,
                .raw_magnitude = 0.75,
                .threat = 0,
                .curiosity = 0.50,
                .metadata = metadata,
            });
            ctx.runtime.brain.last_visual_observation_path = owned_path;
            ctx.runtime.brain.last_visual_update_seconds = ctx.runtime.brain.now_seconds;
            ctx.runtime.brain.last_visual_observation_uploaded = false;
            const result_text = try std.fmt.allocPrint(ctx.allocator(), "camera: observed image at {s}", .{owned_path});
            return try encodeDispatchResultV2(ctx, request_id, event_type, result_text, false);
        }
        return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "unknown_sense", "unknown sense observation", false, emptyBudget(ctx));
    }
    if (std.mem.eql(u8, event_type, "host_capability_status")) {
        try applyHostCapabilityStatus(ctx, request_id, event_object);
        return try encodeDispatchResultV2(ctx, request_id, event_type, try hostCapabilityStatusSummary(ctx, event_object), false);
    }
    if (std.mem.eql(u8, event_type, "tool_call")) {
        const name = getStringFromObject(event_object, "name") orelse {
            return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "invalid_request", "missing tool_call name", false, emptyBudget(ctx));
        };
        if (std.mem.eql(u8, name, "raw_ref_lookup")) {
            const raw_ref = getStringFromObject(event_object, "raw_ref") orelse return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "invalid_request", "missing raw_ref", false, emptyBudget(ctx));
            const bytes = lookupRawRef(ctx, raw_ref) catch |err| return try encodeErrorResultV2(ctx, request_id, event_type, "raw_ref_not_found", @errorName(err));
            return try encodeDispatchResultV2(ctx, request_id, event_type, bytes, true);
        }
        var empty_args = try std.json.ObjectMap.init(std.heap.page_allocator, &.{}, &.{});
        defer empty_args.deinit(std.heap.page_allocator);
        const empty_args_value = std.json.Value{ .object = empty_args };
        const args = event_object.get("arguments") orelse empty_args_value;
        const tool_output = dispatchTool(ctx, name, args) catch |err| {
            if (err == error.FrontendCaptureRequested and ctx.pending_camera_permission != null) {
                return try encodeDispatchResultV2(ctx, request_id, event_type, try pendingCapabilitySummary(ctx), false);
            }
            if (err == error.FrontendOrientationRequested) {
                return try encodeDispatchResultV2(ctx, request_id, event_type, "frontend orientation requested", false);
            }
            return try encodeErrorResultV2(ctx, request_id, event_type, "tool_call_failed", @errorName(err));
        };
        defer std.heap.page_allocator.free(tool_output);
        return try encodeDispatchResultV2(ctx, request_id, event_type, tool_output, true);
    }
    if (std.mem.eql(u8, event_type, "raw_ref_lookup")) {
        const raw_ref = getStringFromObject(event_object, "raw_ref") orelse {
            return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "invalid_request", "missing raw_ref", false, emptyBudget(ctx));
        };
        const bytes = lookupRawRef(ctx, raw_ref) catch |err| return try encodeErrorResultV2(ctx, request_id, event_type, "raw_ref_not_found", @errorName(err));
        return try encodeDispatchResultV2(ctx, request_id, event_type, bytes, true);
    }
    if (std.mem.eql(u8, event_type, "maintenance_tick")) {
        ctx.runtime.brain.runMaintenance(ctx.io()) catch |err| return try encodeErrorResultV2(ctx, request_id, event_type, "maintenance_failed", @errorName(err));
        return try encodeDispatchResultV2(ctx, request_id, event_type, "maintenance_tick", false);
    }
    if (std.mem.eql(u8, event_type, "autonomy_tick")) {
        ctx.runtime.brain.runAutonomyTick(ctx.io()) catch |err| return try encodeErrorResultV2(ctx, request_id, event_type, "autonomy_failed", @errorName(err));
        return try encodeDispatchResultV2(ctx, request_id, event_type, "autonomy_tick", false);
    }
    if (std.mem.eql(u8, event_type, "introspect_summary")) {
        const result = ctx.runtime.executeCommand(.{ .command = .introspect }) catch |err| return try encodeErrorResultV2(ctx, request_id, event_type, "introspect_failed", @errorName(err));
        return try encodeDispatchResultV2(ctx, request_id, event_type, result.observation, true);
    }
    return try embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, "unknown_event_type", "unknown embedded event type", false, emptyBudget(ctx));
}

fn pokeSequencePulseSummary(allocator: std.mem.Allocator, event_object: std.json.ObjectMap) ![]const u8 {
    const pulses = event_object.get("pulses") orelse {
        return try allocator.dupe(u8, "poke_sequence pulse_count=0");
    };
    if (pulses != .array) {
        return try allocator.dupe(u8, "poke_sequence pulse_count=0");
    }

    var pulse_count: usize = 0;
    var total_press_ms: f64 = 0;
    var total_pause_ms: f64 = 0;
    var max_press_ms: f64 = 0;
    for (pulses.array.items) |pulse| {
        if (pulse != .object) continue;
        const press_ms = getNumberFromObject(pulse.object, "press_ms") orelse 0;
        const pause_before_ms = getNumberFromObject(pulse.object, "pause_before_ms") orelse 0;
        pulse_count += 1;
        total_press_ms += press_ms;
        total_pause_ms += pause_before_ms;
        max_press_ms = @max(max_press_ms, press_ms);
    }
    return try std.fmt.allocPrint(
        allocator,
        "poke_sequence pulse_count={d} total_press_ms={d:.0} total_pause_before_ms={d:.0} max_press_ms={d:.0}",
        .{ pulse_count, total_press_ms, total_pause_ms, max_press_ms },
    );
}

fn pokeSequenceMagnitude(event_object: std.json.ObjectMap) f32 {
    const pulses = event_object.get("pulses") orelse return 0.20;
    if (pulses != .array) return 0.20;
    var total_press_ms: f64 = 0;
    var max_press_ms: f64 = 0;
    for (pulses.array.items) |pulse| {
        if (pulse != .object) continue;
        const press_ms = getNumberFromObject(pulse.object, "press_ms") orelse 0;
        total_press_ms += press_ms;
        max_press_ms = @max(max_press_ms, press_ms);
    }
    return @floatCast(@min(1.0, 0.20 + total_press_ms / 2400.0 + max_press_ms / 1800.0));
}

fn applyHostCapabilityStatus(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_object: std.json.ObjectMap) !void {
    const capability = getStringFromObject(event_object, "capability") orelse "";
    const status = getStringFromObject(event_object, "status") orelse "";
    if (!std.mem.eql(u8, capability, "camera")) return;

    if (std.mem.eql(u8, status, "pending")) {
        const pending_request_id = getStringFromObject(event_object, "request_id") orelse request_id;
        const reason = getStringFromObject(event_object, "reason") orelse "host capability pending";
        ctx.pending_camera_permission = .{
            .request_id = try ctx.allocator().dupe(u8, pending_request_id),
            .pending_since_unix_ms = getIntegerFromObject(event_object, "pending_since_unix_ms") orelse 0,
            .reason = try ctx.allocator().dupe(u8, reason),
        };
        return;
    }

    if (std.mem.eql(u8, status, "available") or std.mem.eql(u8, status, "denied") or std.mem.eql(u8, status, "unavailable")) {
        ctx.pending_camera_permission = null;
    }
}

fn hostCapabilityStatusSummary(ctx: *AffectiveCoreEmbedded, event_object: std.json.ObjectMap) ![]const u8 {
    const capability = getStringFromObject(event_object, "capability") orelse "unknown";
    const status = getStringFromObject(event_object, "status") orelse "unknown";
    const elapsed = getIntegerFromObject(event_object, "pending_elapsed_ms") orelse 0;
    const reason = getStringFromObject(event_object, "reason") orelse "";
    return try std.fmt.allocPrint(ctx.allocator(), "host_capability_status: {s}={s} pending_elapsed_ms={d} reason={s}", .{ capability, status, elapsed, reason });
}

fn pendingCapabilitySummary(ctx: *AffectiveCoreEmbedded) ![]const u8 {
    if (ctx.pending_camera_permission) |pending| {
        return try std.fmt.allocPrint(ctx.allocator(), "camera permission pending; request_id={s} pending_since_unix_ms={d} reason={s}", .{ pending.request_id, pending.pending_since_unix_ms, pending.reason });
    }
    return try ctx.allocator().dupe(u8, "host capability pending");
}

fn encodeDispatchResult(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, result: anytype) ![]u8 {
    const events = ctx.runtime.embeddedEvents();
    const correlated_events = try correlateEvents(ctx, request_id, events);
    try appendQueuedEvents(ctx, correlated_events);
    return embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, correlated_events, .{
        .event_type = event_type,
        .value = result,
    });
}

fn encodeDispatchResultV2(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, result_text: []const u8, raw_result: bool) ![]u8 {
    const compacted_events = try context_gate.compactEvents(ctx.allocator(), ctx.runtime.brain.now_seconds, request_id, ctx.runtime.embeddedEvents(), ctx.context_budget);
    try persistRawRefs(ctx, compacted_events.raw_refs);
    const envelope_events = try filterSuppressedEvents(ctx, compacted_events.events);
    try appendQueuedEvents(ctx, envelope_events);

    const compacted_result = try context_gate.compactText(ctx.allocator(), ctx.runtime.brain.now_seconds, event_type, result_text, ctx.context_budget.max_result_bytes);
    try persistRawRefs(ctx, compacted_result.raw_refs);
    const budget = try context_gate.budgetWithResult(ctx.allocator(), compacted_events.budget, compacted_result.summary.len, compacted_result.raw_refs, compacted_result.compacted);
    const output = try embedded_protocol.successEnvelopeV2Alloc(std.heap.page_allocator, request_id, envelope_events, .{
        .event_type = event_type,
        .summary = compacted_result.summary,
        .raw_result = raw_result,
    }, budget);
    if (output.len > ctx.context_budget.max_envelope_bytes) {
        std.heap.page_allocator.free(output);
        return try minimalEnvelopeV2(ctx, request_id, event_type, "compacted envelope exceeded max_bytes");
    }
    return output;
}

fn filterSuppressedEvents(ctx: *AffectiveCoreEmbedded, events: []const embedded_protocol.HostEvent) ![]const embedded_protocol.HostEvent {
    if (ctx.pending_camera_permission == null) return events;
    var filtered = std.ArrayList(embedded_protocol.HostEvent).empty;
    for (events) |event| {
        if (std.mem.eql(u8, event.type, "capture_requested")) continue;
        try filtered.append(ctx.allocator(), event);
    }
    return try filtered.toOwnedSlice(ctx.allocator());
}

fn encodeErrorResultV2(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, code: []const u8, message: []const u8) ![]u8 {
    const text = try std.fmt.allocPrint(ctx.allocator(), "{s}: {s}", .{ code, message });
    return encodeDispatchResultV2(ctx, request_id, event_type, text, false);
}

fn minimalEnvelopeV2(ctx: *AffectiveCoreEmbedded, request_id: []const u8, event_type: []const u8, summary: []const u8) ![]u8 {
    const budget = context_gate.BudgetReport{
        .max_bytes = ctx.context_budget.max_envelope_bytes,
        .used_bytes = summary.len,
        .compacted = true,
        .dropped_event_count = ctx.runtime.embeddedEvents().len,
        .raw_refs = &.{},
    };
    return embedded_protocol.successEnvelopeV2Alloc(std.heap.page_allocator, request_id, &[_]embedded_protocol.HostEvent{}, .{
        .event_type = event_type,
        .summary = summary,
        .raw_result = false,
    }, budget);
}

fn appendQueuedEvents(ctx: *AffectiveCoreEmbedded, events: []const embedded_protocol.HostEvent) !void {
    for (events) |event| try ctx.event_queue.append(ctx.allocator(), event);
}

fn correlateEvents(ctx: *AffectiveCoreEmbedded, request_id: []const u8, events: []const embedded_protocol.HostEvent) ![]embedded_protocol.HostEvent {
    const out = try ctx.allocator().alloc(embedded_protocol.HostEvent, events.len);
    for (events, 0..) |event, i| {
        out[i] = event;
        out[i].request_id = if (request_id.len == 0) null else try ctx.allocator().dupe(u8, request_id);
    }
    return out;
}

fn protocolError(
    ctx: *AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    request_id: []const u8,
    code: []const u8,
    message: []const u8,
) c_int {
    const output = embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, code, message, false) catch {
        return runtimeFailure(ctx, null, "could not encode embedded protocol error");
    };
    return success(ctx, out_data, output);
}

fn protocolErrorV2(
    ctx: *AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    request_id: []const u8,
    code: []const u8,
    message: []const u8,
) c_int {
    const output = embedded_protocol.errorEnvelopeV2Alloc(std.heap.page_allocator, request_id, code, message, false, emptyBudget(ctx)) catch {
        return runtimeFailure(ctx, null, "could not encode embedded protocol v2 error");
    };
    return success(ctx, out_data, output);
}

fn emptyBudget(ctx: *AffectiveCoreEmbedded) context_gate.BudgetReport {
    return .{
        .max_bytes = ctx.context_budget.max_envelope_bytes,
        .used_bytes = 0,
        .compacted = false,
        .dropped_event_count = 0,
        .raw_refs = &.{},
    };
}

fn executeCommand(ctx: *AffectiveCoreEmbedded, command: chat.ChatCommand) ![]u8 {
    const result = try ctx.runtime.executeCommand(command);
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, result, .{ .whitespace = .indent_2 });
}

fn memoryIndex(ctx: *AffectiveCoreEmbedded) ![]u8 {
    const allocator = ctx.allocator();
    const memories = try ctx.runtime.brain.deps.store.loadMemoryRecords(allocator);
    const summaries = try ctx.runtime.brain.deps.store.loadConversationSummaries(allocator);
    var long_term: usize = 0;
    var short_term: usize = 0;
    var tags = std.ArrayList([]const u8).empty;
    for (memories) |memory| {
        switch (memory.scope) {
            .long_term => long_term += 1,
            .short_term => short_term += 1,
        }
        for (memory.tags) |tag| {
            if (tags.items.len >= 32) break;
            if (!tagInSlice(tags.items, tag)) try tags.append(allocator, tag);
        }
    }
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, struct {
        long_term: usize,
        short_term: usize,
        tags: []const []const u8,
        conversation_summaries: usize,
    }{
        .long_term = long_term,
        .short_term = short_term,
        .tags = tags.items,
        .conversation_summaries = summaries.len,
    }, .{ .whitespace = .indent_2 });
}

fn listReminders(ctx: *AffectiveCoreEmbedded) ![]u8 {
    const markdown = readFileAllocPath(ctx.io(), ctx.runtime.brain.cfg.maintenance_schedule_path, ctx.allocator(), .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    return std.json.Stringify.valueAlloc(std.heap.page_allocator, struct { markdown: []const u8 }{ .markdown = markdown }, .{ .whitespace = .indent_2 });
}

fn persistRawRefs(ctx: *AffectiveCoreEmbedded, raw_refs: []const context_gate.RawRef) !void {
    for (raw_refs) |raw_ref| {
        const path = try rawRefPath(ctx.allocator(), ctx.runtime.brain.cfg.brain_root, raw_ref.id);
        try writeFilePath(ctx.io(), path, raw_ref.bytes);
    }
}

fn lookupRawRef(ctx: *AffectiveCoreEmbedded, raw_ref: []const u8) ![]const u8 {
    if (!validRawRef(raw_ref)) return error.InvalidRawRef;
    if (rawRefExpired(ctx, raw_ref)) return error.RawRefExpired;
    const path = try rawRefPath(ctx.allocator(), ctx.runtime.brain.cfg.brain_root, raw_ref);
    return readFileAllocPath(ctx.io(), path, ctx.allocator(), .limited(8 * 1024 * 1024));
}

fn rawRefPath(allocator: std.mem.Allocator, brain_root: []const u8, raw_ref: []const u8) ![]const u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.txt", .{raw_ref});
    return std.fs.path.join(allocator, &.{ brain_root, "raw_refs", filename });
}

fn validRawRef(raw_ref: []const u8) bool {
    if (!std.mem.startsWith(u8, raw_ref, "raw_event_")) return false;
    for (raw_ref) |ch| {
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_') continue;
        return false;
    }
    return true;
}

fn rawRefExpired(ctx: *AffectiveCoreEmbedded, raw_ref: []const u8) bool {
    const prefix = "raw_event_";
    if (!std.mem.startsWith(u8, raw_ref, prefix)) return true;
    const rest = raw_ref[prefix.len..];
    const split = std.mem.indexOfScalar(u8, rest, '_') orelse return true;
    const created_at = std.fmt.parseInt(i64, rest[0..split], 10) catch return true;
    return ctx.runtime.brain.now_seconds - created_at > ctx.raw_ref_ttl_seconds;
}

fn requireString(args: std.json.Value, key: []const u8) ![]const u8 {
    return getString(args, key) orelse error.MissingRequiredString;
}

fn getString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getStringFromObject(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getIntegerFromObject(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => null,
    };
}

fn getNumberFromObject(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

fn getStringArray(allocator: std.mem.Allocator, args: std.json.Value, key: []const u8) ![]const []const u8 {
    if (args != .object) return &.{};
    const value = args.object.get(key) orelse return &.{};
    if (value != .array) return error.ExpectedStringArray;
    const out = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.ExpectedStringArray;
        out[i] = item.string;
    }
    return out;
}

fn tagInSlice(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    return files.readFileAllocPath(io, path, allocator, limit);
}

fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    return files.writeFilePath(io, path, data);
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
    const message = if (ctx) |handle|
        std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s} (last_stage={s})", .{
            prefix,
            @errorName(err),
            handle.runtime.brain.last_trace_stage,
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
