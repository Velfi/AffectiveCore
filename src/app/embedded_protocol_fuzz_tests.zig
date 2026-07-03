const std = @import("std");
const embedded_protocol = @import("embedded_protocol.zig");
const json_fuzz = @import("../harness/json_fuzz.zig");

const parseHostManifest = embedded_protocol.parseHostManifest;

test "host manifest parser rejects malformed manifests with errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const corpus = [_][]const u8{
        "",
        "not json",
        "null",
        "[]",
        "42",
        "{}",
        "{\"platform\":42}",
        "{\"platform\":\"macos\"}",
        "{\"platform\":\"macos\",\"capabilities\":{}}",
        "{\"platform\":\"macos\",\"capabilities\":[42]}",
        "{\"platform\":\"macos\",\"capabilities\":[\"definitely_not_a_capability\"],\"feature_flags\":{}}",
        "{\"platform\":\"macos\",\"capabilities\":[],\"feature_flags\":[]}",
        "{\"platform\":\"macos\",\"capabilities\":[],\"feature_flags\":{},\"max_envelope_bytes\":-1}",
        "{\"platform\":\"macos\",\"capabilities\":[],\"feature_flags\":{},\"max_event_count\":-9223372036854775808}",
        "{\"platform\":\"macos\",\"capabilities\":[],\"feature_flags\":{},\"max_event_text_bytes\":-42}",
    };
    for (corpus) |manifest_json| {
        try std.testing.expectError(error.Invalid, wrapAnyError(parseHostManifest(allocator, manifest_json)));
    }
}

test "host manifest parser accepts extreme but non-negative budgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const manifest = try parseHostManifest(allocator,
        \\{"platform":"android","capabilities":[],"feature_flags":{},
        \\ "max_envelope_bytes":9223372036854775807,"max_event_count":0,
        \\ "max_event_text_bytes":1,"raw_ref_ttl_seconds":-1}
    );
    try std.testing.expectEqual(@as(usize, 9223372036854775807), manifest.max_envelope_bytes);
    try std.testing.expectEqual(@as(usize, 0), manifest.max_event_count);
}

test "host manifest parser survives fuzzed manifests" {
    var prng = std.Random.DefaultPrng.init(0x6d616e6966657374);
    const random = prng.random();

    const budget_keys = [_][]const u8{ "max_envelope_bytes", "max_event_count", "max_event_text_bytes", "raw_ref_ttl_seconds" };

    var iteration: usize = 0;
    while (iteration < 1024) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var out = std.ArrayList(u8).empty;
        if (random.boolean()) {
            // Structured manifest with randomized field values.
            try out.appendSlice(allocator, "{\"platform\":");
            if (random.boolean()) try out.appendSlice(allocator, "\"fuzz\"") else try json_fuzz.appendRandomScalar(allocator, &out, random);
            try out.appendSlice(allocator, ",\"capabilities\":");
            if (random.boolean()) try out.appendSlice(allocator, "[\"time_lookup\"]") else try json_fuzz.appendRandomValue(allocator, &out, random, 2);
            try out.appendSlice(allocator, ",\"feature_flags\":");
            if (random.boolean()) try out.appendSlice(allocator, "{}") else try json_fuzz.appendRandomValue(allocator, &out, random, 3);
            for (budget_keys) |key| {
                if (random.boolean()) continue;
                try out.append(allocator, ',');
                try out.print(allocator, "\"{s}\":", .{key});
                try json_fuzz.appendRandomScalar(allocator, &out, random);
            }
            try out.append(allocator, '}');
        } else {
            try json_fuzz.appendRandomValue(allocator, &out, random, 4);
        }

        const manifest = parseHostManifest(allocator, out.items) catch continue;
        // The platform slice is duplicated out of the input, so it can never
        // be longer than the manifest JSON itself.
        try std.testing.expect(manifest.platform.len <= out.items.len);
        for (manifest.feature_flags.keys()) |key| try std.testing.expect(key.len <= out.items.len);
    }
}

// Collapses every parse failure to one error so corpus entries can assert
// "some error" without enumerating which one.
fn wrapAnyError(result: anytype) error{Invalid}!@TypeOf(result catch unreachable) {
    return result catch error.Invalid;
}
