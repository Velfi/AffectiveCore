const std = @import("std");
const embedded = @import("affective_core_embedded.zig");

const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;
const AffectiveCoreEmbeddedConfig = embedded.AffectiveCoreEmbeddedConfig;
const AffectiveCoreEmbeddedStatus = embedded.AffectiveCoreEmbeddedStatus;
const AffectiveCoreEmbedded = embedded.AffectiveCoreEmbedded;
const affective_core_embedded_create = embedded.affective_core_embedded_create;
const affective_core_embedded_destroy = embedded.affective_core_embedded_destroy;
const affective_core_embedded_dispatch_json = embedded.affective_core_embedded_dispatch_json;
const affective_core_embedded_free_global_string = embedded.affective_core_embedded_free_global_string;
const stringSlice = @import("affective_core_embedded_config.zig").stringSlice;

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
    const io = embeddedFuzzTestIo();
    const root = "data/test/embedded_fuzz";
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try prepareEmbeddedBrainRoot(io, root);

    const manifest =
        \\{
        \\  "platform": "android",
        \\  "capabilities": ["text_input", "poke_sequence", "event_envelope", "event_drain", "orientation_query", "sense_observation"],
        \\  "feature_flags": {},
        \\  "max_envelope_bytes": 4096,
        \\  "max_event_count": 4,
        \\  "max_event_text_bytes": 96,
        \\  "raw_ref_ttl_seconds": 60
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

    var prng = std.Random.DefaultPrng.init(0x667269656e646c79);
    const random = prng.random();

    const corpus = [_][]const u8{
        "",
        "\x00\x01\x02\xff",
        "not json",
        "null",
        "[]",
        "{}",
        "{\"event\":null}",
        "{\"request_id\":42,\"event\":{\"type\":false}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"sense_observation\",\"sense\":\"orientation\",\"observation\":{\"confidence\":1.0e309,\"summary\":false}}}",
        "{\"request_id\":\"seed\",\"event\":{\"type\":\"poke_sequence\",\"pulses\":[null,{\"press_ms\":-999999999999,\"pause_before_ms\":\"bad\"},{\"press_ms\":1.0e308}]}}",
    };
    for (corpus) |request| {
        try expectDispatchDoesNotCrash(handle, request);
    }

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var bytes: [768]u8 = undefined;
        const len = random.intRangeLessThan(usize, 0, bytes.len + 1);
        random.bytes(bytes[0..len]);
        try expectDispatchDoesNotCrash(handle, bytes[0..len]);
    }

    var generated_index: usize = 0;
    while (generated_index < 256) : (generated_index += 1) {
        const request = try randomHostMessage(std.testing.allocator, random, generated_index);
        defer std.testing.allocator.free(request);
        try expectDispatchDoesNotCrash(handle, request);
    }
}

fn str(value: []const u8) AffectiveCoreEmbeddedString {
    return .{ .ptr = value.ptr, .len = value.len };
}

fn expectDispatchDoesNotCrash(handle: ?*AffectiveCoreEmbedded, request: []const u8) !void {
    var data = AffectiveCoreEmbeddedString{};
    var runtime_error = AffectiveCoreEmbeddedString{};

    const status = affective_core_embedded_dispatch_json(handle, if (request.len == 0) null else request.ptr, request.len, &data, &runtime_error);
    try expectEmbeddedStatus(status);
    try expectResultShape(status, data, runtime_error);
}

fn expectEmbeddedStatus(status: c_int) !void {
    try std.testing.expect(status == @as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.ok)) or
        status == @as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.invalid_argument)) or
        status == @as(c_int, @intFromEnum(AffectiveCoreEmbeddedStatus.runtime_error)));
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
    const event_type = switch (random.intRangeLessThan(u8, 0, 10)) {
        0 => "unsupported_text_event",
        1 => "unsupported_speech_event",
        2 => "poke_sequence",
        3 => "sense_observation",
        4 => "raw_ref_lookup",
        5 => "maintenance_tick",
        6 => "autonomy_tick",
        7 => "definitely_not_real",
        else => "",
    };
    try appendJsonString(allocator, out, event_type);

    switch (random.intRangeLessThan(u8, 0, 7)) {
        0 => {
            try out.appendSlice(allocator, ",\"text\":");
            try appendRandomJsonScalar(allocator, out, random, "text", index);
        },
        1 => {
            try out.appendSlice(allocator, ",\"name\":");
            try appendJsonString(allocator, out, switch (random.intRangeLessThan(u8, 0, 5)) {
                0 => "unsupported_memory_operation",
                1 => "unsupported_recall_operation",
                2 => "request_orientation",
                3 => "raw_ref_lookup",
                else => "missing_operation",
            });
            try out.appendSlice(allocator, ",\"arguments\":");
            try appendRandomArguments(allocator, out, random, index);
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
        4 => {
            try out.appendSlice(allocator, ",\"raw_ref\":");
            try appendRandomJsonScalar(allocator, out, random, "raw_event", index);
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
            try out.appendSlice(allocator, ",\"schedule\":");
            try appendRandomJsonScalar(allocator, out, random, "schedule", index);
            try out.appendSlice(allocator, ",\"summary\":");
            try appendRandomJsonScalar(allocator, out, random, "summary", index);
            try out.appendSlice(allocator, ",\"confidence\":");
            try appendRandomInteger(allocator, out, random);
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
