const std = @import("std");
const embedded = @import("../affective_core_embedded.zig");
const embedded_config = @import("../affective_core_embedded_config.zig");
const mock_host = @import("../mcp_host/mock_host.zig");

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
    iterations: usize = 4096,
    seed: u64 = 0x667269656e646c79,
    root: []const u8 = "data/test/embedded_ffi_fuzz_run",
    verbose: bool = false,
};

pub const Stats = struct {
    dispatches: usize = 0,
    ok: usize = 0,
    invalid_argument: usize = 0,
    runtime_error: usize = 0,
    unexpected_status: usize = 0,
    connect_ok: usize = 0,
};

pub const DispatchOutcome = enum {
    ok,
    invalid_argument,
    runtime_error,
    unexpected,
};

threadlocal var fuzz_io_threaded: std.Io.Threaded = .init_single_threaded;

fn fuzzIo() std.Io {
    return fuzz_io_threaded.io();
}

pub fn run(allocator: std.mem.Allocator, options: Options) !Stats {
    const io = fuzzIo();
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

    var mock = mock_host.MockHost{ .mode = .default };
    const host_services = mock.hostServices();

    const cfg = try makeConfig(allocator, options.root, manifest);
    defer freeConfig(allocator, cfg);
    var handle: ?*AffectiveCoreEmbedded = null;
    var create_error = AffectiveCoreEmbeddedString{};
    const created_status = affective_core_embedded_create(&cfg, &host_services, &handle, &create_error);
    defer affective_core_embedded_free_global_string(create_error);
    if (created_status != @intFromEnum(AffectiveCoreEmbeddedStatus.ok)) {
        const message = stringSlice(create_error) orelse "embedded create failed";
        std.debug.print("embedded create failed: {s}\n", .{message});
        return error.CreateFailed;
    }
    defer affective_core_embedded_destroy(handle);

    var stats: Stats = .{};
    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();

    try runStaticCorpus(handle, &stats, options.verbose);

    // Regression: connect must not recurse via stimulus poll (stack overflow).
    var connect_index: usize = 0;
    while (connect_index < 8) : (connect_index += 1) {
        const request = try std.fmt.allocPrint(allocator, "{{\"request_id\":\"connect-{d}\",\"event\":{{\"type\":\"connect\"}}}}", .{connect_index});
        defer allocator.free(request);
        const outcome = dispatch(handle, request);
        recordOutcome(&stats, outcome);
        if (outcome == .ok) stats.connect_ok += 1;
    }

    // Queued ingest while dispatch lock is held exercises tryAcquireDispatchOrQueueMessage.
    const queued_ingest_corpus = [_][]const u8{
        "{\"request_id\":\"queued-ingest\",\"event\":{\"type\":\"stimulus_ingest\",\"text\":\"rapid follow-up\"}}",
        "{\"request_id\":\"queued-user-text\",\"event\":{\"type\":\"user_text\",\"text\":\"hello while busy\"}}",
        "{\"request_id\":\"queued-interrupt\",\"event\":{\"type\":\"interrupt\",\"text\":\"stop\",\"reason\":\"fuzz\"}}",
    };
    for (queued_ingest_corpus) |request| {
        _ = dispatch(handle, request);
        recordOutcome(&stats, dispatch(handle, "{\"request_id\":\"busy-connect\",\"event\":{\"type\":\"connect\"}}"));
    }

    var i: usize = 0;
    while (i < options.iterations) : (i += 1) {
        var bytes: [1024]u8 = undefined;
        const len = random.intRangeLessThan(usize, 0, bytes.len + 1);
        random.bytes(bytes[0..len]);
        recordOutcome(&stats, dispatch(handle, bytes[0..len]));

        const generated = try randomHostMessage(allocator, random, i);
        defer allocator.free(generated);
        recordOutcome(&stats, dispatch(handle, generated));

        if (i % 16 == 0) {
            const connect_request = try std.fmt.allocPrint(allocator, "{{\"request_id\":\"fuzz-connect-{d}\",\"event\":{{\"type\":\"connect\"}}}}", .{i});
            defer allocator.free(connect_request);
            const outcome = dispatch(handle, connect_request);
            recordOutcome(&stats, outcome);
            if (outcome == .ok) stats.connect_ok += 1;
        }
    }

    if (options.verbose) {
        std.debug.print(
            "embedded ffi fuzz: dispatches={d} ok={d} invalid_argument={d} runtime_error={d} unexpected={d} connect_ok={d}\n",
            .{
                stats.dispatches,
                stats.ok,
                stats.invalid_argument,
                stats.runtime_error,
                stats.unexpected_status,
                stats.connect_ok,
            },
        );
    }

    return stats;
}

fn runStaticCorpus(handle: ?*AffectiveCoreEmbedded, stats: *Stats, verbose: bool) !void {
    const corpus = [_][]const u8{
        "",
        "\x00\x01\x02\xff",
        "not json",
        "null",
        "[]",
        "{}",
        "{\"event\":null}",
        "{\"request_id\":42,\"event\":{\"type\":false}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"connect\"}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"host_attach\",\"host_id\":\"fuzz-host\",\"platform\":\"macos\"}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"stimulus_ingest\",\"text\":\"queued during fuzz\"}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"user_text\",\"text\":\"hello fuzz\"}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"sense_observation\",\"sense\":\"orientation\",\"observation\":{\"summary\":\"north\"}}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"sense_observation\",\"sense\":\"camera\",\"observation\":{\"path\":\"/tmp/x.jpg\",\"mime_type\":\"image/jpeg\",\"source\":\"fuzz\"}}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"poke_sequence\",\"pulses\":[{\"press_ms\":120,\"pause_before_ms\":0}]}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"sense_observation\",\"sense\":\"orientation\",\"observation\":{\"confidence\":1.0e309,\"summary\":false}}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"poke_sequence\",\"pulses\":[null,{\"press_ms\":-999999999999,\"pause_before_ms\":\"bad\"},{\"press_ms\":1.0e308}]}}",
    };
    for (corpus) |request| {
        const outcome = dispatch(handle, request);
        recordOutcome(stats, outcome);
        if (verbose and outcome == .unexpected) {
            std.debug.print("unexpected status for corpus request len={d}\n", .{request.len});
        }
    }
}

pub fn dispatch(handle: ?*AffectiveCoreEmbedded, request: []const u8) DispatchOutcome {
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

    return switch (status) {
        @intFromEnum(AffectiveCoreEmbeddedStatus.ok) => .ok,
        @intFromEnum(AffectiveCoreEmbeddedStatus.invalid_argument) => .invalid_argument,
        @intFromEnum(AffectiveCoreEmbeddedStatus.runtime_error) => .runtime_error,
        else => .unexpected,
    };
}

fn recordOutcome(stats: *Stats, outcome: DispatchOutcome) void {
    stats.dispatches += 1;
    switch (outcome) {
        .ok => stats.ok += 1,
        .invalid_argument => stats.invalid_argument += 1,
        .runtime_error => stats.runtime_error += 1,
        .unexpected => stats.unexpected_status += 1,
    }
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

fn randomHostMessage(allocator: std.mem.Allocator, random: std.Random, index: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '{');
    var needs_comma = false;
    if (random.boolean()) {
        needs_comma = true;
        try out.appendSlice(allocator, "\"request_id\":");
        try appendRandomJsonScalar(allocator, &out, random, "request", index);
    }

    if (needs_comma) try out.append(allocator, ',');
    try out.appendSlice(allocator, "\"event\":");
    switch (random.intRangeLessThan(u8, 0, 8)) {
        0 => try out.appendSlice(allocator, "null"),
        1 => try out.appendSlice(allocator, "[]"),
        2 => try out.appendSlice(allocator, "42"),
        else => try appendRandomEvent(allocator, &out, random, index),
    }
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn appendRandomEvent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random, index: usize) !void {
    try out.append(allocator, '{');
    try out.appendSlice(allocator, "\"type\":");
    const event_type = switch (random.intRangeLessThan(u8, 0, 14)) {
        0 => "connect",
        1 => "host_attach",
        2 => "stimulus_ingest",
        3 => "user_text",
        4 => "poke_sequence",
        5 => "sense_observation",
        6 => "interrupt",
        7 => "typing_activity",
        8 => "emoji_reaction",
        9 => "host_capability_manifest",
        10 => "read_models_snapshot",
        11 => "definitely_not_real",
        else => "",
    };
    try appendJsonString(allocator, out, event_type);

    switch (random.intRangeLessThan(u8, 0, 8)) {
        0 => {
            try out.appendSlice(allocator, ",\"text\":");
            try appendRandomJsonScalar(allocator, out, random, "text", index);
        },
        1 => {
            try out.appendSlice(allocator, ",\"host_id\":");
            try appendJsonString(allocator, out, "fuzz-host");
        },
        2 => {
            try out.appendSlice(allocator, ",\"pulses\":[");
            const count = random.intRangeLessThan(usize, 0, 8);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (i > 0) try out.append(allocator, ',');
                const pulse = try std.fmt.allocPrint(allocator, "{{\"press_ms\":{d},\"pause_before_ms\":{d}}}", .{
                    random.int(i64),
                    random.int(i64),
                });
                defer allocator.free(pulse);
                try out.appendSlice(allocator, pulse);
            }
            try out.append(allocator, ']');
        },
        3 => {
            try out.appendSlice(allocator, ",\"sense\":\"orientation\",\"observation\":");
            try appendRandomArguments(allocator, out, random, index);
        },
        else => {},
    }
    try out.append(allocator, '}');
}

fn appendRandomArguments(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random, index: usize) !void {
    switch (random.intRangeLessThan(u8, 0, 5)) {
        0 => try out.appendSlice(allocator, "null"),
        1 => try out.appendSlice(allocator, "[]"),
        2 => try out.appendSlice(allocator, "{\"tags\":[1,false,null],\"text\":42}"),
        else => {
            try out.appendSlice(allocator, "{\"text\":");
            try appendRandomJsonScalar(allocator, out, random, "memory", index);
            try out.appendSlice(allocator, ",\"summary\":");
            try appendRandomJsonScalar(allocator, out, random, "summary", index);
            try out.append(allocator, '}');
        },
    }
}

fn appendRandomJsonScalar(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    random: std.Random,
    prefix: []const u8,
    index: usize,
) !void {
    switch (random.intRangeLessThan(u8, 0, 7)) {
        0 => try out.appendSlice(allocator, "null"),
        1 => try out.appendSlice(allocator, "true"),
        2 => try appendRandomInteger(allocator, out, random),
        3 => try out.appendSlice(allocator, "[]"),
        4 => try out.appendSlice(allocator, "{}"),
        else => {
            const text = try std.fmt.allocPrint(allocator, "{s}_{d}_{d}", .{ prefix, index, random.int(u32) });
            defer allocator.free(text);
            try appendJsonString(allocator, out, text);
        },
    }
}

fn appendRandomInteger(allocator: std.mem.Allocator, out: *std.ArrayList(u8), random: std.Random) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{random.int(i64)});
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}
