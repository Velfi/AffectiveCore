const std = @import("std");

const embedded_boundary = @import("affective_core_embedded_boundary.zig");
pub const panic = embedded_boundary.Panic;

const chat = @import("api/chat_client.zig");
const brain_container = @import("app/brain_container.zig");
const host_profiles = @import("app/host_profiles.zig");
const context_gate = @import("app/context_gate.zig");
const embedded_protocol = @import("app/embedded_protocol.zig");
const request_timings = @import("core/request_timings.zig");
const config_mod = @import("core/config.zig");
const brain_mod = @import("core/brain.zig");
const ai_provider = @import("api/random_provider_client.zig");
const http_transport_mod = @import("api/http_transport.zig");
const http_log = @import("api/http_log.zig");
const files = @import("platform/common/files.zig");
const brain_storage = @import("storage/brain_storage.zig");
const embedded_config = @import("affective_core_embedded_config.zig");
const embedded_e2e = @import("affective_core_embedded_e2e.zig");
const embedded_dispatch = @import("affective_core_embedded_dispatch.zig");
const stimulus_inbox_mod = @import("core/stimulus_inbox.zig");
const error_descriptions = @import("core/error_descriptions.zig");

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
    maintenance_state_path: AffectiveCoreEmbeddedString = .{},
    face_embeddings_dir: AffectiveCoreEmbeddedString = .{},
    host_manifest_json: AffectiveCoreEmbeddedString = .{},
};

pub const host_http_poll_complete: c_int = 0;
pub const host_http_poll_failed: c_int = 1;
pub const host_http_poll_pending: c_int = 2;

pub const AffectiveCoreEmbeddedHttpPostJsonBeginFn = *const fn (
    ?*anyopaque,
    AffectiveCoreEmbeddedString,
    AffectiveCoreEmbeddedString,
    AffectiveCoreEmbeddedString,
    ?*AffectiveCoreEmbeddedString,
    ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int;

pub const AffectiveCoreEmbeddedHttpPostJsonPollFn = *const fn (
    ?*anyopaque,
    AffectiveCoreEmbeddedString,
    ?*AffectiveCoreEmbeddedString,
    ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int;

pub const AffectiveCoreEmbeddedFreeHostStringFn = *const fn (
    ?*anyopaque,
    AffectiveCoreEmbeddedString,
) callconv(.c) void;

pub const AffectiveCoreEmbeddedOnHostEventsFn = *const fn (
    ?*anyopaque,
    AffectiveCoreEmbeddedString,
) callconv(.c) void;

pub const AffectiveCoreEmbeddedHostServices = extern struct {
    ctx: ?*anyopaque = null,
    http_post_json_begin: ?AffectiveCoreEmbeddedHttpPostJsonBeginFn = null,
    http_post_json_poll: ?AffectiveCoreEmbeddedHttpPostJsonPollFn = null,
    free_string: ?AffectiveCoreEmbeddedFreeHostStringFn = null,
    on_host_events: ?AffectiveCoreEmbeddedOnHostEventsFn = null,
};

pub const AffectiveCoreEmbeddedStatus = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    initialization_failed = 2,
    runtime_error = 3,
};

pub const AffectiveCoreEmbedded = struct {
    arena: std.heap.ArenaAllocator = undefined,
    brain_arena: std.heap.ArenaAllocator = undefined,
    scratch_arena: std.heap.ArenaAllocator = undefined,
    io_threaded: std.Io.Threaded = .init_single_threaded,
    env: std.process.Environ.Map,
    brain: brain_mod.Brain,
    llm_provider_clients: []*ai_provider.RandomProviderClient = &.{},
    storage_backend: ?brain_storage.BrainStorage = null,
    host_effects: ?*embedded_protocol.HostEffectCollector = null,
    host_capabilities: chat.CapabilitySet = .{},
    http_transport: HostHttpTransport,
    brain_initialized: bool = false,
    event_queue: std.ArrayList(embedded_protocol.HostEvent) = .empty,
    context_budget: context_gate.BudgetConfig = .{},
    raw_ref_ttl_seconds: i64 = 24 * 60 * 60,
    pending_camera_permission: ?HostCapabilityPending = null,
    dispatch_mutex: std.atomic.Mutex = .unlocked,
    stimulus_queue_mutex: std.atomic.Mutex = .unlocked,
    pending_stimulus_requests: std.ArrayList([]const u8) = .empty,

    pub fn queuePendingStimulusRequest(self: *AffectiveCoreEmbedded, request_json: []const u8) !void {
        lockStimulusQueue(self);
        defer unlockStimulusQueue(self);
        const owned = try std.heap.page_allocator.dupe(u8, request_json);
        errdefer std.heap.page_allocator.free(owned);
        // page_allocator: this queue is touched from arbitrary host threads while
        // the arena allocator is only safe on the dispatching thread.
        try self.pending_stimulus_requests.append(std.heap.page_allocator, owned);
    }

    pub fn flushPendingStimulusRequests(self: *AffectiveCoreEmbedded) !void {
        // Take ownership of the queued requests under the lock, but apply them
        // after releasing it: applying a message can re-enter this function
        // (e.g. autonomy_tick -> pollStimulusInbox -> stimulus_poll callback),
        // which would self-deadlock on the non-reentrant spinlock.
        const pending = blk: {
            lockStimulusQueue(self);
            defer unlockStimulusQueue(self);
            if (self.pending_stimulus_requests.items.len == 0) return;
            break :blk try self.pending_stimulus_requests.toOwnedSlice(std.heap.page_allocator);
        };
        defer {
            for (pending) |json| std.heap.page_allocator.free(json);
            std.heap.page_allocator.free(pending);
        }
        for (pending) |json| {
            embedded_dispatch.applyQueuedMessage(self, json) catch {};
        }
    }

    pub fn pollStimulusInboxCallback(ctx: ?*anyopaque) !void {
        const embedded_ctx: *AffectiveCoreEmbedded = @ptrCast(@alignCast(ctx.?));
        try embedded_ctx.flushPendingStimulusRequests();
    }

    pub fn allocator(self: *AffectiveCoreEmbedded) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn brainAllocator(self: *AffectiveCoreEmbedded) std.mem.Allocator {
        return self.brain_arena.allocator();
    }

    /// Transient allocator for per-dispatch work (JSON compaction, envelope staging).
    /// Reset via `resetDispatchScratch` after each dispatch boundary.
    pub fn dispatchScratch(self: *AffectiveCoreEmbedded) std.mem.Allocator {
        return self.scratch_arena.allocator();
    }

    pub fn wireDispatchScratchToLlmClients(self: *AffectiveCoreEmbedded) void {
        const scratch = self.dispatchScratch();
        for (self.llm_provider_clients) |client| {
            client.http_response_allocator = scratch;
        }
    }

    pub fn clearDispatchScratchWiring(self: *AffectiveCoreEmbedded) void {
        for (self.llm_provider_clients) |client| {
            client.http_response_allocator = null;
        }
    }

    pub fn resetDispatchScratch(self: *AffectiveCoreEmbedded) void {
        self.clearDispatchScratchWiring();
        _ = self.scratch_arena.reset(.free_all);
    }

    pub fn brainArenaQueryCapacity(self: *AffectiveCoreEmbedded) usize {
        return self.brain_arena.queryCapacity();
    }

    pub fn dispatchScratchQueryCapacity(self: *AffectiveCoreEmbedded) usize {
        return self.scratch_arena.queryCapacity();
    }

    pub fn clearHttpTransportLastError(self: *AffectiveCoreEmbedded) void {
        self.http_transport.releaseLastError();
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

const host_error_detail_unavailable = "host error (detail unavailable)";

const HostHttpTransport = struct {
    services: AffectiveCoreEmbeddedHostServices = .{},
    failing: FailingHttpTransport = .{},
    error_allocator: std.mem.Allocator = undefined,
    last_error: ?[]const u8 = null,
    owner: ?*AffectiveCoreEmbedded = null,

    fn init(services: ?*const AffectiveCoreEmbeddedHostServices, error_allocator: std.mem.Allocator) HostHttpTransport {
        return .{
            .services = if (services) |value| value.* else .{},
            .error_allocator = error_allocator,
        };
    }

    fn hasAsyncHostHttp(self: *const HostHttpTransport) bool {
        return self.services.http_post_json_begin != null and
            self.services.http_post_json_poll != null and
            self.services.free_string != null;
    }

    fn client(self: *HostHttpTransport) http_transport_mod.Client {
        if (!self.hasAsyncHostHttp()) {
            return self.failing.client();
        }
        return .{ .ctx = self, .postJsonFn = postJson };
    }

    fn postJson(ctx: *anyopaque, allocator: std.mem.Allocator, request: http_transport_mod.JsonPostRequest) ![]u8 {
        const self: *HostHttpTransport = @ptrCast(@alignCast(ctx));
        const begin = self.services.http_post_json_begin orelse return error.HostHttpTransportRequired;
        const poll = self.services.http_post_json_poll orelse return error.HostHttpTransportRequired;
        const free_string = self.services.free_string orelse return error.HostHttpTransportRequired;

        const headers_json = try std.json.Stringify.valueAlloc(allocator, request.headers, .{});
        defer allocator.free(headers_json);

        var out_request_id = AffectiveCoreEmbeddedString{};
        var begin_error = AffectiveCoreEmbeddedString{};
        const begin_status = begin(
            self.services.ctx,
            sliceToEmbeddedString(request.url),
            sliceToEmbeddedString(headers_json),
            sliceToEmbeddedString(request.body),
            &out_request_id,
            &begin_error,
        );
        defer free_string(self.services.ctx, out_request_id);
        defer free_string(self.services.ctx, begin_error);
        if (begin_status != 0) {
            self.rememberLastError(begin_error);
            if (self.owner) |embedded| {
                if (self.last_error) |detail| embedded.brain.rememberHostHttpErrorDetail(detail) catch {};
            }
            http_log.logErrorWithHostDetail(request.url, error.HostHttpPostJsonFailed, self.last_error);
            return error.HostHttpPostJsonFailed;
        }

        while (true) {
            var out_data = AffectiveCoreEmbeddedString{};
            var poll_error = AffectiveCoreEmbeddedString{};
            const poll_status = poll(
                self.services.ctx,
                out_request_id,
                &out_data,
                &poll_error,
            );
            defer free_string(self.services.ctx, out_data);
            defer free_string(self.services.ctx, poll_error);

            switch (poll_status) {
                host_http_poll_complete => {
                    if (self.owner) |embedded| embedded.brain.clearHostHttpErrorDetail();
                    const bytes = try embeddedStringToOwnedSlice(allocator, out_data);
                    errdefer allocator.free(bytes);
                    if (bytes.len > request.max_response_bytes) return error.StreamTooLong;
                    return bytes;
                },
                host_http_poll_failed => {
                    self.rememberLastError(poll_error);
                    if (self.owner) |embedded| {
                        if (self.last_error) |detail| embedded.brain.rememberHostHttpErrorDetail(detail) catch {};
                    }
                    http_log.logErrorWithHostDetail(request.url, error.HostHttpPostJsonFailed, self.last_error);
                    return error.HostHttpPostJsonFailed;
                },
                host_http_poll_pending => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => {
                    self.rememberLastError(poll_error);
                    http_log.logErrorWithHostDetail(request.url, error.HostHttpPostJsonFailed, self.last_error);
                    return error.HostHttpPostJsonFailed;
                },
            }
        }
    }

    fn releaseLastError(self: *HostHttpTransport) void {
        if (self.last_error) |prev| {
            if (prev.ptr != host_error_detail_unavailable.ptr) {
                self.error_allocator.free(prev);
            }
            self.last_error = null;
        }
    }

    fn rememberLastError(self: *HostHttpTransport, out_error: AffectiveCoreEmbeddedString) void {
        const bytes = embedded_config.stringSlice(out_error) orelse "";
        const trimmed = std.mem.trim(u8, bytes, &std.ascii.whitespace);
        self.releaseLastError();
        if (trimmed.len == 0) return;
        self.last_error = self.error_allocator.dupe(u8, trimmed) catch host_error_detail_unavailable;
    }
};

fn hostSystemSensesHttpClient(http_transport_state: *HostHttpTransport) ?http_transport_mod.Client {
    if (http_transport_state.hasAsyncHostHttp()) {
        return http_transport_state.client();
    }
    return null;
}

fn validateEmbeddedHostServices(host_services: ?*const AffectiveCoreEmbeddedHostServices) ?[]const u8 {
    const services = host_services orelse return "embedded create requires host services";
    if (services.http_post_json_begin == null or services.http_post_json_poll == null or services.free_string == null) {
        return "embedded create requires async host HTTP services (begin, poll, free_string)";
    }
    return null;
}

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
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return embeddedExportPanicFailure(out_error);
    defer export_guard.deinit();

    setHandle(out_handle, null);
    setString(out_error, .{});

    const raw_config = config orelse {
        return createFailure(out_error, "missing embedded config");
    };
    embedded_config.validateEmbeddedConfig(raw_config.*) catch {
        return invalidArgumentFailure(out_error, "invalid embedded config string field");
    };
    if (validateEmbeddedHostServices(host_services)) |message| {
        return createFailure(out_error, message);
    }

    const handle = std.heap.page_allocator.create(AffectiveCoreEmbedded) catch {
        return createFailure(out_error, "could not allocate embedded AffectiveCore handle");
    };
    errdefer std.heap.page_allocator.destroy(handle);

    handle.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    handle.brain_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    handle.scratch_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    handle.io_threaded = .init_single_threaded;
    const allocator = handle.allocator();
    const brain_allocator = handle.brainAllocator();
    handle.env = std.process.Environ.Map.init(allocator);
    handle.http_transport = HostHttpTransport.init(host_services, allocator);
    handle.brain_initialized = false;
    handle.storage_backend = null;
    handle.host_effects = null;
    handle.event_queue = .empty;
    handle.context_budget = .{};
    handle.raw_ref_ttl_seconds = 24 * 60 * 60;
    handle.pending_camera_permission = null;
    handle.dispatch_mutex = .unlocked;
    handle.stimulus_queue_mutex = .unlocked;
    handle.pending_stimulus_requests = .empty;
    const manifest_json = embedded_config.validatedStringSlice(raw_config.host_manifest_json) catch {
        return createFailureWithHandle(handle, out_error, "invalid embedded host_manifest_json", error.InvalidEmbeddedString);
    };
    if (manifest_json.len == 0) {
        return createFailureWithHandle(handle, out_error, "embedded create requires host_manifest_json from the host app", error.MissingHostManifestCapabilities);
    }
    const manifest = embedded_protocol.parseHostManifest(allocator, manifest_json) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not parse embedded host manifest", err);
    };
    embedded_config.configureHostProviderRouting(allocator, &handle.env, raw_config.*) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not configure embedded host provider routing", err);
    };

    const base_cfg = embedded_config.makeConfig(brain_allocator, raw_config.*) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not build embedded config", err);
    };
    var local_filesystem = files.LocalFileSystem{};
    var cfg = base_cfg.ensureBrainPaths(brain_allocator) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not resolve embedded brain paths", err);
    };
    config_mod.provisionBrainConfigFiles(brain_allocator, local_filesystem.filesystem(), handle.io(), cfg) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not provision embedded brain config files", err);
    };
    cfg = cfg.loadForBrain(brain_allocator, local_filesystem.filesystem(), handle.io()) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not load embedded brain config", err);
    };
    cfg = embedded_config.restoreHostControlledPaths(brain_allocator, raw_config.*, cfg) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not restore embedded host paths", err);
    };
    if (ensureParentDirsOrFailure(handle, out_error, cfg)) |status| return status;
    const host_system_senses_http = hostSystemSensesHttpClient(&handle.http_transport);
    const host_http_available = host_services != null and host_services.?.http_post_json_begin != null;
    const embedded_brain_host = host_profiles.initEmbeddedMacosBrainHost(
        brain_allocator,
        handle.io(),
        handle.http_transport.client(),
        cfg,
        manifest.capabilities,
        host_system_senses_http,
        host_http_available,
    ) catch |err| {
        return createFailureWithHandle(handle, out_error, "could not initialize embedded AffectiveCore runtime", err);
    };
    handle.brain = embedded_brain_host.brain;
    handle.brain.deps.stimulus_poll = AffectiveCoreEmbedded.pollStimulusInboxCallback;
    handle.brain.deps.stimulus_poll_ctx = handle;
    handle.http_transport.owner = handle;
    embedded_brain_host.chat_service.parse_failure_brain = &handle.brain;
    embedded_brain_host.autonomy_planner.parse_failure_brain = &handle.brain;
    handle.llm_provider_clients = embedded_brain_host.llm_provider_clients;
    brain_mod.wireLlmStatsRecorder(&handle.brain, handle.llm_provider_clients);
    handle.storage_backend = embedded_brain_host.storage;
    handle.host_effects = embedded_brain_host.effects;
    handle.host_capabilities = manifest.capabilities;
    handle.brain.recoverStuckBrainMode() catch |err| {
        return createFailureWithHandle(handle, out_error, "could not recover embedded brain mode", err);
    };
    handle.brain.restorePersistedActivity() catch |err| {
        return createFailureWithHandle(handle, out_error, "could not restore persisted activity", err);
    };
    handle.brain_initialized = true;
    syncContextBudgetFromHost(handle, manifest);
    handle.raw_ref_ttl_seconds = manifest.raw_ref_ttl_seconds;

    setHandle(out_handle, handle);
    return @intFromEnum(AffectiveCoreEmbeddedStatus.ok);
}

pub export fn affective_core_embedded_destroy(handle: ?*AffectiveCoreEmbedded) void {
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return;
    defer export_guard.deinit();

    const ctx = handle orelse return;
    for (ctx.pending_stimulus_requests.items) |json| std.heap.page_allocator.free(json);
    ctx.pending_stimulus_requests.deinit(std.heap.page_allocator);
    if (ctx.storage_backend) |*storage| {
        storage.deinit(ctx.brainAllocator());
        ctx.storage_backend = null;
    }
    ctx.env.deinit();
    ctx.io_threaded.deinit();
    ctx.scratch_arena.deinit();
    ctx.brain_arena.deinit();
    ctx.arena.deinit();
    std.heap.page_allocator.destroy(ctx);
}

fn tryAcquireDispatch(ctx: *AffectiveCoreEmbedded, out_data: ?*AffectiveCoreEmbeddedString, _: ?*AffectiveCoreEmbeddedString) ?c_int {
    if (!ctx.dispatch_mutex.tryLock()) {
        return protocolError(ctx, out_data, "", "runtime_error", "embedded dispatch already in progress on this handle");
    }
    return null;
}

fn tryAcquireDispatchOrQueueMessage(
    ctx: *AffectiveCoreEmbedded,
    request_json: []const u8,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) ?c_int {
    if (ctx.dispatch_mutex.tryLock()) return null;
    const meta = embedded_dispatch.parseDispatchRequestMeta(request_json);
    if (!embedded_dispatch.isQueueableWhileBusyEventType(meta.eventType())) {
        return protocolError(ctx, out_data, "", "runtime_error", "embedded dispatch already in progress on this handle");
    }
    ctx.queuePendingStimulusRequest(request_json) catch |err| {
        return runtimeError(ctx, out_error, "could not queue embedded message", err);
    };
    const output = embedded_dispatch.encodeQueuedAck(ctx, meta.requestId(), meta.eventType()) catch |err| {
        return runtimeError(ctx, out_error, "could not encode queued response", err);
    };
    return success(ctx, out_data, output);
}

fn lockStimulusQueue(ctx: *AffectiveCoreEmbedded) void {
    while (!ctx.stimulus_queue_mutex.tryLock()) {}
}

fn unlockStimulusQueue(ctx: *AffectiveCoreEmbedded) void {
    ctx.stimulus_queue_mutex.unlock();
}

fn releaseDispatch(ctx: *AffectiveCoreEmbedded) void {
    ctx.dispatch_mutex.unlock();
}

pub export fn affective_core_embedded_dispatch_json(
    handle: ?*AffectiveCoreEmbedded,
    request_json_ptr: ?[*]const u8,
    request_json_len: usize,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return embeddedExportPanicFailure(out_error);
    defer export_guard.deinit();

    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    const request_json = embedded_config.requiredSlice(request_json_ptr, request_json_len) catch {
        return protocolError(ctx, out_data, "", "invalid_request", "missing dispatch request JSON");
    };
    if (tryAcquireDispatchOrQueueMessage(ctx, request_json, out_data, out_error)) |status| return status;
    defer releaseDispatch(ctx);
    const output = embedded_dispatch.dispatchJson(ctx, request_json) catch |err| {
        const message = allocDispatchFailureMessage(ctx, err) catch "dispatch failed";
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
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return embeddedExportPanicFailure(out_error);
    defer export_guard.deinit();

    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    if (tryAcquireDispatch(ctx, out_data, out_error)) |status| return status;
    defer releaseDispatch(ctx);
    defer ctx.resetDispatchScratch();
    const request_id = "";
    ctx.brain.beginRequestTimings(request_id) catch |err| {
        return runtimeError(ctx, out_error, "could not begin request timings", err);
    };
    defer ctx.brain.resetRequestTimings();
    const scratch = ctx.dispatchScratch();
    const compacted = context_gate.compactEvents(scratch, ctx.brain.now_seconds, request_id, ctx.brain.activeActivityId() orelse "", ctx.event_queue.items, ctx.context_budget) catch |err| {
        return runtimeError(ctx, out_error, "could not compact drained events", err);
    };
    embedded_dispatch.persistRawRefs(ctx, compacted.raw_refs) catch |err| {
        return runtimeError(ctx, out_error, "could not store compacted drained event refs", err);
    };
    const budget = context_gate.budgetWithResult(scratch, compacted.budget, 0, &.{}, false) catch |err| {
        return runtimeError(ctx, out_error, "could not build drain budget", err);
    };
    var timings = embedded_dispatch.finishDispatchTimings(ctx) catch |err| {
        return runtimeError(ctx, out_error, "could not finish drain request timings", err);
    };
    defer embedded_dispatch.deinitDispatchTimingsReport(ctx, &timings);
    const output = embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, compacted.events, .{ .kind = "drain" }, budget, timings, null) catch |err| {
        return runtimeError(ctx, out_error, "could not encode drained events", err);
    };
    ctx.event_queue.clearRetainingCapacity();
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_try_drain_events_json(
    handle: ?*AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return embeddedExportPanicFailure(out_error);
    defer export_guard.deinit();

    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    if (!ctx.dispatch_mutex.tryLock()) {
        return protocolError(ctx, out_data, "", "runtime_error", "embedded dispatch already in progress on this handle");
    }
    defer releaseDispatch(ctx);
    defer ctx.resetDispatchScratch();
    const request_id = "";
    ctx.brain.beginRequestTimings(request_id) catch |err| {
        return runtimeError(ctx, out_error, "could not begin request timings", err);
    };
    defer ctx.brain.resetRequestTimings();
    const scratch = ctx.dispatchScratch();
    const compacted = context_gate.compactEvents(scratch, ctx.brain.now_seconds, request_id, ctx.brain.activeActivityId() orelse "", ctx.event_queue.items, ctx.context_budget) catch |err| {
        return runtimeError(ctx, out_error, "could not compact drained events", err);
    };
    embedded_dispatch.persistRawRefs(ctx, compacted.raw_refs) catch |err| {
        return runtimeError(ctx, out_error, "could not store compacted drained event refs", err);
    };
    const budget = context_gate.budgetWithResult(scratch, compacted.budget, 0, &.{}, false) catch |err| {
        return runtimeError(ctx, out_error, "could not build drain budget", err);
    };
    var timings = embedded_dispatch.finishDispatchTimings(ctx) catch |err| {
        return runtimeError(ctx, out_error, "could not finish drain request timings", err);
    };
    defer embedded_dispatch.deinitDispatchTimingsReport(ctx, &timings);
    const output = embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, request_id, compacted.events, .{ .kind = "drain" }, budget, timings, null) catch |err| {
        return runtimeError(ctx, out_error, "could not encode drained events", err);
    };
    ctx.event_queue.clearRetainingCapacity();
    return success(ctx, out_data, output);
}

pub fn pushHostEventsToHost(ctx: *AffectiveCoreEmbedded, events: []const embedded_protocol.HostEvent) void {
    const on_host_events = ctx.http_transport.services.on_host_events orelse return;
    if (events.len == 0) return;
    const events_json = std.json.Stringify.valueAlloc(std.heap.page_allocator, events, .{}) catch return;
    defer std.heap.page_allocator.free(events_json);
    on_host_events(ctx.http_transport.services.ctx, sliceToEmbeddedString(events_json));
}

pub export fn affective_core_embedded_raw_ref_lookup_json(
    handle: ?*AffectiveCoreEmbedded,
    raw_ref_ptr: ?[*]const u8,
    raw_ref_len: usize,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return embeddedExportPanicFailure(out_error);
    defer export_guard.deinit();

    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    if (tryAcquireDispatch(ctx, out_data, out_error)) |status| return status;
    defer releaseDispatch(ctx);
    defer ctx.resetDispatchScratch();
    const raw_ref = embedded_config.requiredSlice(raw_ref_ptr, raw_ref_len) catch {
        return protocolError(ctx, out_data, "", "invalid_request", "missing raw_ref");
    };
    ctx.brain.beginRequestTimings("raw_ref_lookup") catch |err| {
        return runtimeError(ctx, out_error, "could not begin request timings", err);
    };
    defer ctx.brain.resetRequestTimings();
    const bytes = embedded_dispatch.lookupRawRef(ctx, raw_ref) catch |err| {
        const message = allocEmbeddedErrorMessage(ctx, "raw_ref_not_found", err) catch {
            return protocolError(ctx, out_data, "", "raw_ref_not_found", embeddedErrorName(ctx, err));
        };
        defer std.heap.page_allocator.free(message);
        return protocolError(ctx, out_data, "", "raw_ref_not_found", message);
    };
    var timings = embedded_dispatch.finishDispatchTimings(ctx) catch |err| {
        return runtimeError(ctx, out_error, "could not finish raw ref lookup timings", err);
    };
    defer embedded_dispatch.deinitDispatchTimingsReport(ctx, &timings);
    const output = embedded_protocol.successEnvelopeAlloc(std.heap.page_allocator, "", &[_]embedded_protocol.HostEvent{}, .{
        .event_type = "raw_ref_lookup",
        .value = .{
            .kind = "raw_ref_lookup",
            .raw_ref = raw_ref,
            .content = bytes,
        },
    }, embedded_dispatch.emptyBudget(ctx), timings, null) catch |err| {
        return runtimeError(ctx, out_error, "could not encode raw ref lookup", err);
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
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return;
    defer export_guard.deinit();

    const bytes = embedded_config.validatedStringSlice(string) catch return;
    if (bytes.len == 0) return;
    std.heap.page_allocator.free(@constCast(bytes));
}

pub export fn affective_core_embedded_export_brain(
    handle: ?*AffectiveCoreEmbedded,
    brain_file_path_ptr: ?[*]const u8,
    brain_file_path_len: usize,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return embeddedExportPanicFailure(out_error);
    defer export_guard.deinit();

    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    if (tryAcquireDispatch(ctx, out_data, out_error)) |status| return status;
    defer releaseDispatch(ctx);
    defer ctx.resetDispatchScratch();
    const brain_file_path = embedded_config.requiredSlice(brain_file_path_ptr, brain_file_path_len) catch {
        return runtimeFailure(ctx, out_error, "missing brain export file path");
    };
    const manifest = brain_container.exportBrain(ctx.dispatchScratch(), ctx.io(), ctx.brain.cfg, brain_file_path) catch |err| {
        return runtimeError(ctx, out_error, "embedded brain export failed", err);
    };
    _ = ctx.brain.recordSimpleExperienceEvent("Brain.Exported", .system, brain_file_path) catch {};
    const output = std.json.Stringify.valueAlloc(std.heap.page_allocator, struct { manifest: brain_container.BrainManifest }{ .manifest = manifest }, .{ .whitespace = .indent_2 }) catch |err| {
        return runtimeError(ctx, out_error, "could not encode brain export response", err);
    };
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_import_brain(
    handle: ?*AffectiveCoreEmbedded,
    brain_file_path_ptr: ?[*]const u8,
    brain_file_path_len: usize,
    brain_id_ptr: ?[*]const u8,
    brain_id_len: usize,
    brain_root_ptr: ?[*]const u8,
    brain_root_len: usize,
    host_id_ptr: ?[*]const u8,
    host_id_len: usize,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return embeddedExportPanicFailure(out_error);
    defer export_guard.deinit();

    setString(out_data, .{});
    setString(out_error, .{});

    const ctx = handle orelse return runtimeFailure(null, out_error, "missing embedded AffectiveCore handle");
    if (tryAcquireDispatch(ctx, out_data, out_error)) |status| return status;
    defer releaseDispatch(ctx);
    defer ctx.resetDispatchScratch();
    const brain_file_path = embedded_config.requiredSlice(brain_file_path_ptr, brain_file_path_len) catch {
        return runtimeFailure(ctx, out_error, "missing brain import file path");
    };
    const maybe_brain_id = optionalNonEmptySlice(brain_id_ptr, brain_id_len) catch {
        return invalidArgumentFailure(out_error, "invalid brain_id slice");
    };
    const inspected = if (maybe_brain_id == null)
        brain_container.inspectBrainFile(ctx.allocator(), ctx.io(), brain_file_path) catch |err| {
            return runtimeError(ctx, out_error, "embedded brain import inspect failed", err);
        }
    else
        null;
    const brain_id = maybe_brain_id orelse inspected.?.brain_id;
    const brain_root = optionalNonEmptySlice(brain_root_ptr, brain_root_len) catch {
        return invalidArgumentFailure(out_error, "invalid brain_root slice");
    } orelse ctx.brain.cfg.brain_root;
    const manifest = brain_container.importBrain(ctx.allocator(), ctx.io(), brain_file_path, .{
        .brain_id = brain_id,
        .brain_root = brain_root,
    }) catch |err| {
        return runtimeError(ctx, out_error, "embedded brain import failed", err);
    };
    reloadEmbeddedBrain(ctx, manifest.brain_id, brain_root) catch |err| {
        return runtimeError(ctx, out_error, "embedded brain import reload failed", err);
    };
    const host_id = optionalNonEmptySlice(host_id_ptr, host_id_len) catch {
        return invalidArgumentFailure(out_error, "invalid host_id slice");
    } orelse ctx.brain.currentHostId();
    const payload = if (host_id.len > 0)
        std.fmt.allocPrint(ctx.dispatchScratch(), "brain_id={s}; brain_root={s}; host_id={s}", .{ manifest.brain_id, brain_root, host_id }) catch ""
    else
        std.fmt.allocPrint(ctx.dispatchScratch(), "brain_id={s}; brain_root={s}", .{ manifest.brain_id, brain_root }) catch "";
    if (payload.len > 0) _ = ctx.brain.recordSimpleExperienceEvent("Brain.Imported", .system, payload) catch {};
    if (host_id.len > 0) _ = ctx.brain.recordSimpleExperienceEvent("Host.BindingChangedAfterImport", .host, host_id) catch {};
    const output = std.json.Stringify.valueAlloc(std.heap.page_allocator, struct { manifest: brain_container.BrainManifest }{ .manifest = manifest }, .{ .whitespace = .indent_2 }) catch |err| {
        return runtimeError(ctx, out_error, "could not encode brain import response", err);
    };
    return success(ctx, out_data, output);
}

pub export fn affective_core_embedded_api_e2e(
    config: ?*const AffectiveCoreEmbeddedConfig,
    host_services: ?*const AffectiveCoreEmbeddedHostServices,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) c_int {
    var export_guard = embedded_boundary.ExportGuard.init();
    if (export_guard.panicked) return embeddedExportPanicFailure(out_error);
    defer export_guard.deinit();

    setString(out_data, .{});
    setString(out_error, .{});

    const raw_config = config orelse return runtimeFailure(null, out_error, "missing embedded config");
    embedded_config.validateEmbeddedConfig(raw_config.*) catch {
        return invalidArgumentFailure(out_error, "invalid embedded config string field");
    };
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
    var http_transport = HostHttpTransport.init(host_services, allocator);
    const report = embedded_e2e.runApiE2E(allocator, io, http_transport.client(), &env, cfg) catch |err| {
        return runtimeError(null, out_error, "embedded api e2e failed", err);
    };
    const copy = std.heap.page_allocator.dupe(u8, report) catch |err| {
        return runtimeError(null, out_error, "could not copy embedded api e2e report", err);
    };
    return success(null, out_data, copy);
}

fn syncContextBudgetFromHost(ctx: *AffectiveCoreEmbedded, manifest: embedded_protocol.HostManifest) void {
    ctx.context_budget = .{
        .max_envelope_bytes = manifest.max_envelope_bytes,
        .max_event_count = manifest.max_event_count,
        .max_event_text_bytes = manifest.max_event_text_bytes,
    };
}

pub fn reloadEmbeddedBrain(ctx: *AffectiveCoreEmbedded, brain_id: []const u8, brain_root: []const u8) !void {
    const main_allocator = ctx.allocator();
    const brain_allocator = ctx.brainAllocator();
    const cfg_snapshot = try embedded_config.snapshotConfigPathsForRebind(main_allocator, ctx.brain.cfg);
    if (ctx.storage_backend) |*storage| {
        storage.deinit(brain_allocator);
        ctx.storage_backend = null;
    }
    _ = ctx.brain_arena.reset(.free_all);
    ctx.host_effects = null;
    ctx.event_queue.clearRetainingCapacity();
    ctx.pending_camera_permission = null;

    var cfg = try embedded_config.rebindConfigBrainRoot(brain_allocator, cfg_snapshot, brain_id, brain_root);
    var local_filesystem = files.LocalFileSystem{};
    try config_mod.provisionBrainConfigFiles(brain_allocator, local_filesystem.filesystem(), ctx.io(), cfg);
    cfg = try cfg.loadForBrain(brain_allocator, local_filesystem.filesystem(), ctx.io());
    try embedded_config.ensureParentDirs(ctx.io(), cfg);

    const embedded_brain_host = try host_profiles.initEmbeddedMacosBrainHost(
        brain_allocator,
        ctx.io(),
        ctx.http_transport.client(),
        cfg,
        ctx.host_capabilities,
        hostSystemSensesHttpClient(&ctx.http_transport),
        ctx.http_transport.hasAsyncHostHttp(),
    );
    ctx.brain = embedded_brain_host.brain;
    ctx.brain.deps.stimulus_poll = AffectiveCoreEmbedded.pollStimulusInboxCallback;
    ctx.brain.deps.stimulus_poll_ctx = ctx;
    ctx.http_transport.owner = ctx;
    embedded_brain_host.chat_service.parse_failure_brain = &ctx.brain;
    embedded_brain_host.autonomy_planner.parse_failure_brain = &ctx.brain;
    ctx.llm_provider_clients = embedded_brain_host.llm_provider_clients;
    brain_mod.wireLlmStatsRecorder(&ctx.brain, ctx.llm_provider_clients);
    ctx.storage_backend = embedded_brain_host.storage;
    ctx.host_effects = embedded_brain_host.effects;
    if (ctx.host_capabilities.facial_expression_output) {
        _ = try ctx.brain.refreshFacialExpressionCatalog();
    }
    ctx.brain_initialized = true;

    const payload = try std.fmt.allocPrint(brain_allocator, "brain_id={s}; brain_root={s}", .{ brain_id, brain_root });
    _ = try ctx.brain.recordSimpleExperienceEvent("Brain.RuntimeReloaded", .system, payload);
}

pub fn hostHttpErrorDetail(ctx: *AffectiveCoreEmbedded, err: anyerror) ?[]const u8 {
    if (err != error.HostHttpPostJsonFailed) return null;
    return lastHostHttpErrorDetail(ctx);
}

fn lastHostHttpErrorDetail(ctx: *AffectiveCoreEmbedded) ?[]const u8 {
    const detail = ctx.http_transport.last_error orelse return null;
    if (detail.len == 0) return null;
    return detail;
}

pub fn embeddedErrorName(ctx: *AffectiveCoreEmbedded, err: anyerror) []const u8 {
    return hostHttpErrorDetail(ctx, err) orelse @errorName(err);
}

pub fn hostHttpFailureMessage(ctx: *AffectiveCoreEmbedded, prefix: []const u8, err: anyerror) ?[]const u8 {
    if (hostHttpErrorDetail(ctx, err) == null) return null;
    return std.fmt.allocPrint(ctx.allocator(), "{s}: {s}", .{ prefix, embeddedErrorName(ctx, err) }) catch embeddedErrorName(ctx, err);
}

fn allocEmbeddedErrorMessage(ctx: *AffectiveCoreEmbedded, prefix: []const u8, err: anyerror) ![]u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}", .{ prefix, embeddedErrorName(ctx, err) });
}

fn allocEmbeddedRuntimeErrorMessage(ctx: *AffectiveCoreEmbedded, prefix: []const u8, err: anyerror) ![]u8 {
    const base = if (hostHttpErrorDetail(ctx, err)) |host_detail|
        try std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}: {s} (host_detail={s})", .{
            prefix,
            error_descriptions.name(err),
            error_descriptions.detail(err),
            host_detail,
        })
    else
        try std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}: {s}", .{
            prefix,
            error_descriptions.name(err),
            error_descriptions.detail(err),
        });
    defer std.heap.page_allocator.free(base);
    return try std.fmt.allocPrint(std.heap.page_allocator, "{s} (last_stage={s})", .{ base, ctx.brain.last_trace_stage });
}

fn allocDispatchFailureMessage(ctx: *AffectiveCoreEmbedded, err: anyerror) ![]u8 {
    const detail_owned = error_descriptions.formatFailureDetail(std.heap.page_allocator, err, ctx.brain.chatParseFailureBody()) catch null;
    const detail: []const u8 = detail_owned orelse error_descriptions.name(err);
    defer if (detail_owned != null) std.heap.page_allocator.free(detail);
    if (hostHttpErrorDetail(ctx, err) orelse lastHostHttpErrorDetail(ctx)) |host_detail| {
        return std.fmt.allocPrint(std.heap.page_allocator, "dispatch failed: {s}: {s} (host_detail={s})", .{
            error_descriptions.name(err),
            detail,
            host_detail,
        });
    }
    return std.fmt.allocPrint(std.heap.page_allocator, "dispatch failed: {s}: {s}", .{
        error_descriptions.name(err),
        detail,
    });
}

fn optionalNonEmptySlice(ptr: ?[*]const u8, len: usize) !?[]const u8 {
    if (len == 0) return null;
    return try embedded_config.requiredSlice(ptr, len);
}

fn embeddedExportPanicFailure(out_error: ?*AffectiveCoreEmbeddedString) c_int {
    std.log.err("embedded export panic: {s}", .{embedded_boundary.panicMessage()});
    return runtimeFailure(null, out_error, embedded_boundary.panicMessage());
}

fn invalidArgumentFailure(out_error: ?*AffectiveCoreEmbeddedString, message: []const u8) c_int {
    publishOwnedString(out_error, std.heap.page_allocator.dupe(u8, message) catch {
        return @intFromEnum(AffectiveCoreEmbeddedStatus.invalid_argument);
    });
    return @intFromEnum(AffectiveCoreEmbeddedStatus.invalid_argument);
}

fn protocolError(
    ctx: *AffectiveCoreEmbedded,
    out_data: ?*AffectiveCoreEmbeddedString,
    request_id: []const u8,
    code: []const u8,
    message: []const u8,
) c_int {
    const timings_allocator = if (ctx.brain.request_timings.active) ctx.brain.allocator else std.heap.page_allocator;
    var timings = if (ctx.brain.request_timings.active)
        embedded_dispatch.finishDispatchTimings(ctx) catch {
            return runtimeFailure(ctx, null, "could not finish request timings for protocol error");
        }
    else
        request_timings.emptyReport(std.heap.page_allocator, request_id) catch {
            return runtimeFailure(ctx, null, "could not encode embedded protocol error");
        };
    defer request_timings.deinitReport(timings_allocator, &timings);
    const output = embedded_protocol.errorEnvelopeAlloc(std.heap.page_allocator, request_id, code, message, false, embedded_dispatch.emptyBudget(ctx), timings, ctx.brain.dispatchContextReportView()) catch {
        return runtimeFailure(ctx, null, "could not encode embedded protocol error");
    };
    return success(ctx, out_data, output);
}

fn ensureParentDirsOrFailure(
    handle: *AffectiveCoreEmbedded,
    out_error: ?*AffectiveCoreEmbeddedString,
    cfg: config_mod.Config,
) ?c_int {
    if (ensureParentPathOrFailure(handle, out_error, "memory_path", cfg.memory_path)) |status| return status;
    if (ensureParentPathOrFailure(handle, out_error, "graph_path", cfg.graph_path)) |status| return status;
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
    const message: []u8 = if (ctx) |handle| blk: {
        break :blk allocEmbeddedRuntimeErrorMessage(handle, prefix, err) catch {
            return runtimeFailure(ctx, out_error, "embedded AffectiveCore runtime error");
        };
    } else blk: {
        break :blk std.fmt.allocPrint(std.heap.page_allocator, "{s}: {s}", .{ prefix, @errorName(err) }) catch {
            return runtimeFailure(ctx, out_error, "embedded AffectiveCore runtime error");
        };
    };
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
