const std = @import("std");
const chat = @import("chat_client.zig");
const json_fuzz = @import("../harness/json_fuzz.zig");

const parseChatTurn = chat.parseChatTurn;

const valid_turn_json =
    \\{"action_pressures":[{"action":"say","text":"good to see you"}],
    \\ "user_summary":"greeted me","brain_summary":"said hello back",
    \\ "reasoning_effort":"low","effort_tier":"routine","turn_complete":true}
;

test "parseChatTurn rejects malformed provider bodies with errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const corpus = [_][]const u8{
        "\x00\x01\xff",
        "not json",
        "null",
        "[]",
        "42",
        "{\"action_pressures\":42}",
        "{\"action_pressures\":[42]}",
        "{\"action_pressures\":[{}]}",
        "{\"action_pressures\":[{\"action\":null}]}",
        "{\"action_pressures\":[{\"action\":\"say\",\"delay_ms\":-1}]}",
        "{\"action_pressures\":[{\"action\":\"say\",\"delay_ms\":4294967296}]}",
        "{\"action_pressures\":[{\"action\":\"say\",\"tags\":[42]}]}",
        "{\"action_pressures\":[{\"action\":\"say\",\"tags\":\"solo\"}]}",
        "{\"parameter\":{\"action_pressures\":42}}",
        "{\"parameter\":null}",
    };
    for (corpus) |body| {
        const result = parseChatTurn(allocator, body, "hello");
        try std.testing.expect(std.meta.isError(result));
    }
}

test "parseChatTurn survives fuzzed provider bodies" {
    var prng = std.Random.DefaultPrng.init(0x636861745f747572);
    const random = prng.random();

    const optional_keys = [_][]const u8{ "user_summary", "brain_summary", "reasoning_effort", "effort_tier", "turn_complete" };
    const pressure_keys = [_][]const u8{ "action", "origin", "delay_ms", "scale", "text", "query", "memory_id", "person_id", "name", "image_path", "schedule", "to", "subject", "heat_bias", "eyes", "mouth", "duration_ms", "keep_existing", "tags" };

    var iteration: usize = 0;
    while (iteration < 1024) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var out = std.ArrayList(u8).empty;
        switch (random.intRangeLessThan(u8, 0, 4)) {
            0 => try json_fuzz.appendRandomValue(allocator, &out, random, 4),
            1 => {
                const corrupted = try json_fuzz.mutate(allocator, random, valid_turn_json);
                try out.appendSlice(allocator, corrupted);
            },
            else => {
                // Structured turn with randomly typed field values.
                try out.appendSlice(allocator, "{\"action_pressures\":[");
                const count = random.intRangeLessThan(usize, 0, 4);
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    if (i > 0) try out.append(allocator, ',');
                    try out.append(allocator, '{');
                    var first = true;
                    for (pressure_keys) |key| {
                        if (random.intRangeLessThan(u8, 0, 4) != 0) continue;
                        if (!first) try out.append(allocator, ',');
                        first = false;
                        try out.print(allocator, "\"{s}\":", .{key});
                        if (std.mem.eql(u8, key, "action") and random.boolean()) {
                            try out.appendSlice(allocator, "\"say\"");
                        } else {
                            try json_fuzz.appendRandomScalar(allocator, &out, random);
                        }
                    }
                    try out.append(allocator, '}');
                }
                try out.append(allocator, ']');
                for (optional_keys) |key| {
                    if (random.boolean()) continue;
                    try out.print(allocator, ",\"{s}\":", .{key});
                    try json_fuzz.appendRandomScalar(allocator, &out, random);
                }
                try out.append(allocator, '}');
            },
        }

        const turn = parseChatTurn(allocator, out.items, "hello fuzz") catch continue;
        // Accepted turns must be internally consistent: summaries are capped
        // at 160 bytes and every proposal's owned strings must be real slices.
        try std.testing.expect(turn.user_summary.len <= 160);
        try std.testing.expect(turn.brain_summary.len <= 160);
        for (turn.action_pressures) |pressure| {
            if (pressure.text) |text| try std.testing.expect(text.len <= out.items.len);
            for (pressure.tags) |tag| try std.testing.expect(tag.len <= out.items.len);
        }
    }
}
