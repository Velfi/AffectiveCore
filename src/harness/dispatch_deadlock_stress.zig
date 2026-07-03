const std = @import("std");
const embedded = @import("../affective_core_embedded.zig");
const embedded_config = @import("../affective_core_embedded_config.zig");
const embedding_port = @import("../core/port_embedding.zig");
const hash_vector = @import("../core/hash_vector.zig");

const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;
const AffectiveCoreEmbeddedConfig = embedded.AffectiveCoreEmbeddedConfig;
const AffectiveCoreEmbeddedStatus = embedded.AffectiveCoreEmbeddedStatus;
const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;
const affective_core_embedded_create = embedded.affective_core_embedded_create;
const affective_core_embedded_destroy = embedded.affective_core_embedded_destroy;
const affective_core_embedded_dispatch_json = embedded.affective_core_embedded_dispatch_json;
const affective_core_embedded_free_global_string = embedded.affective_core_embedded_free_global_string;
const stringSlice = embedded_config.stringSlice;

pub const Options = struct {
    cycles: usize = 64,
    pressure_per_cycle: usize = 16,
    seed: u64 = 0x646561646c6f636b,
    root: []const u8 = "data/test/dispatch_deadlock_stress",
    timeout_ms: u64 = 1_500,
    verbose: bool = false,
    exit_on_deadlock: bool = false,
};

pub const Stats = struct {
    cycles: usize = 0,
    pressure_dispatches: usize = 0,
    queued_acks: usize = 0,
    runtime_busy_errors: usize = 0,
    completed_blocking_dispatches: usize = 0,
};

const DispatchResult = struct {
    status: c_int = -1,
    response_contains_queued_ack: bool = false,
    response_contains_busy_error: bool = false,
};

const SlowHostState = struct {
    poll_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    begin_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    url: []const u8 = "",
    body: []const u8 = "",

    fn resetForCycle(self: *SlowHostState) void {
        self.poll_count.store(0, .release);
        self.release.store(false, .release);
        self.begin_count.store(0, .release);
        if (self.url.len > 0) std.heap.page_allocator.free(self.url);
        if (self.body.len > 0) std.heap.page_allocator.free(self.body);
        self.url = "";
        self.body = "";
    }

    fn deinit(self: *SlowHostState) void {
        self.resetForCycle();
    }
};

const ThreadDispatch = struct {
    handle: ?*AffectiveCoreEmbedded,
    request: []const u8,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: DispatchResult = .{},

    fn run(self: *ThreadDispatch) void {
        self.result = dispatch(self.handle, self.request);
        self.done.store(true, .release);
    }
};

const HostJsonResponse = struct {
    json: []const u8,
    owned: bool = false,

    fn deinit(self: HostJsonResponse) void {
        if (self.owned) std.heap.page_allocator.free(self.json);
    }
};

threadlocal var stress_io_threaded: std.Io.Threaded = .init_single_threaded;

fn stressIo() std.Io {
    return stress_io_threaded.io();
}

pub fn run(allocator: std.mem.Allocator, options: Options) !Stats {
    const io = stressIo();
    _ = std.Io.Dir.cwd().deleteTree(io, options.root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, options.root);
    try prepareEmbeddedBrainRoot(io, options.root);

    const manifest = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "fixtures/embedded_api/manifest_macos.json",
        allocator,
        .limited(128 * 1024),
    );
    defer allocator.free(manifest);

    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();
    var stats: Stats = .{};
    var cycle: usize = 0;
    while (cycle < options.cycles) : (cycle += 1) {
        try runFreshCycle(allocator, manifest, random, options, cycle, &stats);
        stats.cycles += 1;
        if (options.verbose and cycle % 64 == 0) {
            std.debug.print("dispatch-deadlock-stress progress cycle={d}/{d}\n", .{ cycle + 1, options.cycles });
        }
    }
    return stats;
}

fn runFreshCycle(
    allocator: std.mem.Allocator,
    manifest: []const u8,
    random: std.Random,
    options: Options,
    cycle: usize,
    stats: *Stats,
) !void {
    const cycle_root = try std.fmt.allocPrint(allocator, "{s}/cycle_{d}", .{ options.root, cycle });
    defer allocator.free(cycle_root);
    const io = stressIo();
    _ = std.Io.Dir.cwd().deleteTree(io, cycle_root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, cycle_root);
    try prepareEmbeddedBrainRoot(io, cycle_root);

    var slow_host = SlowHostState{};
    defer slow_host.deinit();
    var host_services = embedded.AffectiveCoreEmbeddedHostServices{
        .ctx = &slow_host,
        .http_post_json_begin = slowHostHttpPostJsonBegin,
        .http_post_json_poll = slowHostHttpPostJsonPoll,
        .free_string = freeHostHttpString,
    };

    const cfg = try makeConfig(allocator, cycle_root, manifest);
    defer freeConfig(allocator, cfg);
    var handle: ?*AffectiveCoreEmbedded = null;
    var create_error = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &host_services, &handle, &create_error);
    defer affective_core_embedded_free_global_string(create_error);
    if (created_status != @intFromEnum(AffectiveCoreEmbeddedStatus.ok)) {
        const message = stringSlice(create_error) orelse "embedded create failed";
        std.debug.print("dispatch-deadlock-stress create failed cycle={d}: {s}\n", .{ cycle, message });
        return error.CreateFailed;
    }
    defer affective_core_embedded_destroy(handle);

    _ = dispatch(handle, "{\"request_id\":\"stress-connect\",\"event\":{\"type\":\"connect\"}}");
    try runCycle(allocator, handle, &slow_host, random, options, cycle, stats);
}

fn runCycle(
    allocator: std.mem.Allocator,
    handle: ?*AffectiveCoreEmbedded,
    slow_host: *SlowHostState,
    random: std.Random,
    options: Options,
    cycle: usize,
    stats: *Stats,
) !void {
    const blocking_request = try std.fmt.allocPrint(
        allocator,
        "{{\"request_id\":\"stress-block-{d}\",\"event\":{{\"type\":\"stimulus_ingest\",\"kind\":\"speech\",\"text\":\"blocking dispatch {d}\"}}}}",
        .{ cycle, cycle },
    );
    defer allocator.free(blocking_request);

    var blocking = ThreadDispatch{ .handle = handle, .request = blocking_request };
    const blocking_thread = try std.Thread.spawn(.{}, ThreadDispatch.run, .{&blocking});
    var blocking_joined = false;
    defer if (!blocking_joined) {
        slow_host.release.store(true, .release);
        blocking_thread.join();
    };

    try joinWithWatchdog(blocking_thread, &blocking, options, cycle, 0, "nonblocking dispatch");
    blocking_joined = true;
    stats.completed_blocking_dispatches += 1;

    var pressure_index: usize = 0;
    while (pressure_index < options.pressure_per_cycle) : (pressure_index += 1) {
        const request = try randomPressureRequest(allocator, random, cycle, pressure_index);
        defer allocator.free(request);
        var pressure = ThreadDispatch{ .handle = handle, .request = request };
        const thread = try std.Thread.spawn(.{}, ThreadDispatch.run, .{&pressure});
        try joinWithWatchdog(thread, &pressure, options, cycle, pressure_index, "pressure dispatch");
        stats.pressure_dispatches += 1;
        if (pressure.result.response_contains_queued_ack) stats.queued_acks += 1;
        if (pressure.result.response_contains_busy_error) stats.runtime_busy_errors += 1;
    }

    slow_host.release.store(true, .release);
}

fn waitForPollOrDone(
    blocking: *ThreadDispatch,
    slow_host: *SlowHostState,
    options: Options,
    cycle: usize,
) !void {
    var remaining_ms = options.timeout_ms;
    while (remaining_ms > 0) : (remaining_ms -= 1) {
        if (slow_host.poll_count.load(.acquire) > 0) return;
        if (blocking.done.load(.acquire)) {
            reportDeadlock(options, cycle, 0, "blocking dispatch finished before host poll");
            return error.BlockingDispatchDidNotReachHostPoll;
        }
        watchdogPause();
    }
    reportDeadlock(options, cycle, 0, "blocking dispatch never reached host poll");
    return error.DeadlockWatchdogTimeout;
}

fn joinWithWatchdog(
    thread: std.Thread,
    dispatch_state: *ThreadDispatch,
    options: Options,
    cycle: usize,
    pressure_index: usize,
    label: []const u8,
) !void {
    var remaining_ms = options.timeout_ms;
    while (remaining_ms > 0) : (remaining_ms -= 1) {
        if (dispatch_state.done.load(.acquire)) {
            thread.join();
            return;
        }
        watchdogPause();
    }
    reportDeadlock(options, cycle, pressure_index, label);
    if (options.exit_on_deadlock) std.process.exit(2);
    return error.DeadlockWatchdogTimeout;
}

fn reportDeadlock(options: Options, cycle: usize, pressure_index: usize, label: []const u8) void {
    std.debug.print(
        "dispatch-deadlock-stress DEADLOCK seed=0x{x} cycle={d} pressure={d} label=\"{s}\" timeout_ms={d}\n",
        .{ options.seed, cycle, pressure_index, label, options.timeout_ms },
    );
}

fn watchdogPause() void {
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        std.Thread.yield() catch {};
    }
}

fn dispatch(handle: ?*AffectiveCoreEmbedded, request: []const u8) DispatchResult {
    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};
    const status = affective_core_embedded_dispatch_json(
        handle,
        if (request.len == 0) null else request.ptr,
        request.len,
        &data,
        &runtime_error,
    );
    defer affective_core_embedded_free_global_string(data);
    defer affective_core_embedded_free_global_string(runtime_error);

    const response = stringSlice(data) orelse "";
    const error_text = stringSlice(runtime_error) orelse "";
    return .{
        .status = status,
        .response_contains_queued_ack = std.mem.indexOf(u8, response, "_queued") != null,
        .response_contains_busy_error = std.mem.indexOf(u8, error_text, "already in progress") != null or
            std.mem.indexOf(u8, response, "already in progress") != null,
    };
}

fn randomPressureRequest(
    allocator: std.mem.Allocator,
    random: std.Random,
    cycle: usize,
    pressure_index: usize,
) ![]u8 {
    const choice = random.intRangeLessThan(u8, 0, 7);
    return switch (choice) {
        0 => std.fmt.allocPrint(allocator, "{{\"request_id\":\"stress-ingest-{d}-{d}\",\"event\":{{\"type\":\"stimulus_ingest\",\"kind\":\"speech\",\"text\":\"pressure {d}\"}}}}", .{ cycle, pressure_index, pressure_index }),
        1 => std.fmt.allocPrint(allocator, "{{\"request_id\":\"stress-typing-{d}-{d}\",\"event\":{{\"type\":\"stimulus_ingest\",\"kind\":\"typing\",\"text\":\"typing {d}\"}}}}", .{ cycle, pressure_index, pressure_index }),
        2 => std.fmt.allocPrint(allocator, "{{\"request_id\":\"stress-interrupt-{d}-{d}\",\"event\":{{\"type\":\"stimulus_ingest\",\"kind\":\"interrupt\",\"text\":\"stop\",\"reason\":\"stress\"}}}}", .{ cycle, pressure_index }),
        3 => std.fmt.allocPrint(allocator, "{{\"request_id\":\"stress-sense-status-{d}-{d}\",\"event\":{{\"type\":\"host_update\",\"kind\":\"sense_status\",\"sense\":\"camera\",\"status\":\"pending\",\"reason\":\"stress\"}}}}", .{ cycle, pressure_index }),
        4 => std.fmt.allocPrint(allocator, "{{\"request_id\":\"stress-capability-{d}-{d}\",\"event\":{{\"type\":\"host_update\",\"kind\":\"capability_status\",\"capability_id\":\"take_picture\",\"status\":\"available\",\"reason\":\"stress\"}}}}", .{ cycle, pressure_index }),
        5 => std.fmt.allocPrint(allocator, "{{\"request_id\":\"stress-connect-{d}-{d}\",\"event\":{{\"type\":\"connect\"}}}}", .{ cycle, pressure_index }),
        else => std.fmt.allocPrint(allocator, "{{\"request_id\":\"stress-read-models-{d}-{d}\",\"event\":{{\"type\":\"brain_read\",\"kind\":\"models_snapshot\"}}}}", .{ cycle, pressure_index }),
    };
}

fn slowHostHttpPostJsonBegin(
    ctx: ?*anyopaque,
    url: AffectiveCoreEmbeddedString,
    _: AffectiveCoreEmbeddedString,
    body: AffectiveCoreEmbeddedString,
    out_request_id: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int {
    const state: *SlowHostState = @ptrCast(@alignCast(ctx.?));
    _ = state.begin_count.fetchAdd(1, .monotonic);
    const request_id = std.fmt.allocPrint(std.heap.page_allocator, "stress-host-{d}", .{state.begin_count.load(.acquire)}) catch {
        return hostBeginFailure(out_error, out_request_id, "could not allocate request id");
    };
    const owned_url = std.heap.page_allocator.dupe(u8, stringSlice(url) orelse "") catch {
        std.heap.page_allocator.free(request_id);
        return hostBeginFailure(out_error, out_request_id, "could not store request url");
    };
    const owned_body = std.heap.page_allocator.dupe(u8, stringSlice(body) orelse "") catch {
        std.heap.page_allocator.free(request_id);
        std.heap.page_allocator.free(owned_url);
        return hostBeginFailure(out_error, out_request_id, "could not store request body");
    };
    if (state.url.len > 0) std.heap.page_allocator.free(state.url);
    if (state.body.len > 0) std.heap.page_allocator.free(state.body);
    state.url = owned_url;
    state.body = owned_body;
    if (out_error) |err_out| err_out.* = .{};
    if (out_request_id) |id_out| {
        id_out.* = .{ .ptr = request_id.ptr, .len = request_id.len };
    } else {
        std.heap.page_allocator.free(request_id);
    }
    return 0;
}

fn slowHostHttpPostJsonPoll(
    ctx: ?*anyopaque,
    request_id: AffectiveCoreEmbeddedString,
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
) callconv(.c) c_int {
    _ = request_id;
    const state: *SlowHostState = @ptrCast(@alignCast(ctx.?));
    const url = state.url;
    if (std.mem.eql(u8, url, "affective-host://system/power")) {
        return hostPollSuccess(out_data, out_error, "{\"supplies\":[]}");
    }
    if (std.mem.eql(u8, url, "affective-host://system/storage")) {
        return hostPollSuccess(out_data, out_error, "{\"volumes\":[]}");
    }
    if (std.mem.endsWith(u8, url, "/embed/compute")) {
        const response = embedResponse(state.body);
        defer response.deinit();
        return hostPollSuccess(out_data, out_error, response.json);
    }
    _ = state.poll_count.fetchAdd(1, .monotonic);
    if (!state.release.load(.acquire)) {
        if (out_data) |data| data.* = .{};
        if (out_error) |err_out| err_out.* = .{};
        return embedded.host_http_poll_pending;
    }
    return hostPollSuccess(out_data, out_error, "{\"action_pressures\":[],\"user_summary\":\"Stress turn completed.\",\"brain_summary\":\"Stress turn completed without action.\",\"reasoning_effort\":null,\"effort_tier\":null,\"turn_complete\":true}");
}

fn hostBeginFailure(
    out_error: ?*AffectiveCoreEmbeddedString,
    out_request_id: ?*AffectiveCoreEmbeddedString,
    message: []const u8,
) c_int {
    if (out_request_id) |id_out| id_out.* = .{};
    if (out_error) |err_out| {
        const owned = std.heap.page_allocator.dupe(u8, message) catch {
            err_out.* = .{};
            return 1;
        };
        err_out.* = .{ .ptr = owned.ptr, .len = owned.len };
    }
    return 1;
}

fn hostPollSuccess(
    out_data: ?*AffectiveCoreEmbeddedString,
    out_error: ?*AffectiveCoreEmbeddedString,
    json: []const u8,
) c_int {
    if (out_error) |err_out| err_out.* = .{};
    if (out_data) |data| {
        const bytes = std.heap.page_allocator.dupe(u8, json) catch {
            data.* = .{};
            return embedded.host_http_poll_failed;
        };
        data.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    }
    return 0;
}

fn freeHostHttpString(_: ?*anyopaque, string: AffectiveCoreEmbeddedString) callconv(.c) void {
    const slice = stringSlice(string) orelse return;
    std.heap.page_allocator.free(slice);
}

fn embedResponse(request_body: []const u8) HostJsonResponse {
    const fallback: HostJsonResponse = .{ .json = "{\"dimensions\":512,\"vectors\":[]}" };
    const Wire = struct { texts: []const []const u8 = &.{} };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, request_body, .{ .ignore_unknown_fields = true }) catch {
        return fallback;
    };
    defer parsed.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.heap.page_allocator);
    out.appendSlice(std.heap.page_allocator, "{\"dimensions\":512,\"vectors\":[") catch return fallback;
    for (parsed.value.texts, 0..) |text, i| {
        if (i > 0) out.append(std.heap.page_allocator, ',') catch {};
        const compact = hash_vector.embed(std.heap.page_allocator, text, &.{}) catch continue;
        defer std.heap.page_allocator.free(compact);
        var vector = std.ArrayList(u8).empty;
        defer vector.deinit(std.heap.page_allocator);
        vector.append(std.heap.page_allocator, '[') catch continue;
        var dim: usize = 0;
        while (dim < embedding_port.test_embedding_dimensions) : (dim += 1) {
            if (dim > 0) vector.append(std.heap.page_allocator, ',') catch {};
            const value: f32 = if (dim < compact.len) compact[dim] else 0;
            const piece = std.fmt.allocPrint(std.heap.page_allocator, "{d:.6}", .{value}) catch continue;
            defer std.heap.page_allocator.free(piece);
            vector.appendSlice(std.heap.page_allocator, piece) catch {};
        }
        vector.append(std.heap.page_allocator, ']') catch {};
        out.appendSlice(std.heap.page_allocator, vector.items) catch {};
    }
    out.appendSlice(std.heap.page_allocator, "]}") catch {};
    const owned = std.heap.page_allocator.dupe(u8, out.items) catch return fallback;
    return .{ .json = owned, .owned = true };
}

fn makeConfig(allocator: std.mem.Allocator, root: []const u8, manifest: []const u8) !AffectiveCoreEmbeddedConfig {
    const memory_path = try std.fmt.allocPrint(allocator, "{s}/memory/people.sqlite", .{root});
    errdefer allocator.free(memory_path);
    const graph_path = try std.fmt.allocPrint(allocator, "{s}/memory/relationships.sqlite", .{root});
    errdefer allocator.free(graph_path);
    const face_embeddings_dir = try std.fmt.allocPrint(allocator, "{s}/memory/face_embeddings", .{root});
    errdefer allocator.free(face_embeddings_dir);
    const schedule_path = try std.fmt.allocPrint(allocator, "{s}/maintenance.md", .{root});
    errdefer allocator.free(schedule_path);
    const maintenance_state_path = try std.fmt.allocPrint(allocator, "{s}/maintenance_state.json", .{root});
    errdefer allocator.free(maintenance_state_path);

    return .{
        .brain_id = str("default"),
        .brain_root = str(root),
        .conversation_models = str("openai:gpt-4.1-nano"),
        .memory_path = str(memory_path),
        .graph_path = str(graph_path),
        .schedule_path = str(schedule_path),
        .maintenance_state_path = str(maintenance_state_path),
        .face_embeddings_dir = str(face_embeddings_dir),
        .host_manifest_json = str(manifest),
    };
}

fn freeConfig(allocator: std.mem.Allocator, cfg: AffectiveCoreEmbeddedConfig) void {
    freeOwnedConfigString(allocator, cfg.memory_path);
    freeOwnedConfigString(allocator, cfg.graph_path);
    freeOwnedConfigString(allocator, cfg.face_embeddings_dir);
    freeOwnedConfigString(allocator, cfg.schedule_path);
    freeOwnedConfigString(allocator, cfg.maintenance_state_path);
}

fn freeOwnedConfigString(allocator: std.mem.Allocator, string: AffectiveCoreEmbeddedString) void {
    if (string.len == 0) return;
    const ptr = string.ptr orelse return;
    allocator.free(ptr[0..string.len]);
}

fn prepareEmbeddedBrainRoot(io: std.Io, root: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, root);
    var dst_buf: [512]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/llm_providers.json", .{root});
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "data/llm_providers.json", std.heap.page_allocator, .limited(64 * 1024));
    defer std.heap.page_allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = bytes, .flags = .{ .truncate = true } });
}

fn str(value: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = value.ptr, .len = value.len };
}

test "dispatch deadlock stress covers blocked host poll re-entry" {
    const stats = try run(std.testing.allocator, .{
        .cycles = 4,
        .pressure_per_cycle = 6,
        .root = "data/test/dispatch_deadlock_stress_unit",
        .timeout_ms = 2_000,
    });
    try std.testing.expectEqual(@as(usize, 4), stats.cycles);
    try std.testing.expect(stats.pressure_dispatches > 0);
    try std.testing.expectEqual(@as(usize, 0), stats.runtime_busy_errors);
    try std.testing.expectEqual(stats.cycles, stats.completed_blocking_dispatches);
}
