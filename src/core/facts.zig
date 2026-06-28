const std = @import("std");
const ports = @import("ports.zig");
const schema = ports.schema;

pub const test_first_turned_on_at_unix_seconds: i64 = 1_781_222_400;
pub const conversation_self_facts_max_bytes: usize = 8192;

pub fn formatSummary(allocator: std.mem.Allocator, records: []const schema.FactRecord, now_seconds: i64, max_bytes: ?usize) ![]const u8 {
    var inactive_count: usize = 0;
    var active_count: usize = 0;
    var runtime_seconds: ?i64 = null;
    for (records) |record| {
        try validateRecord(record);
        if (!record.active) {
            inactive_count += 1;
            continue;
        }
        active_count += 1;
        if (std.ascii.eqlIgnoreCase(record.key, "first_turned_on_at_unix_seconds")) {
            const first_on = try std.fmt.parseInt(i64, record.value, 10);
            if (first_on <= 0) return error.InvalidFirstTurnedOnAt;
            if (now_seconds < first_on) return error.ClockBeforeFirstTurnOn;
            runtime_seconds = now_seconds - first_on;
        }
    }

    var footer = std.ArrayList(u8).empty;
    defer footer.deinit(allocator);
    if (runtime_seconds) |seconds| {
        try footer.print(allocator, "- total_run_time_seconds: {d}\n- total_run_time: ", .{seconds});
        try appendDuration(allocator, &footer, seconds);
        try footer.append(allocator, '\n');
    }
    try footer.print(allocator, "- inactive_fact_count: {d}\n", .{inactive_count});

    const header = "Self facts:\n";
    const none_active = "- none active\n";
    const truncation_prefix = "- conversation_self_facts_truncated: ";
    var truncation_buf: [128]u8 = undefined;
    const truncation_suffix = " active facts; use introspect query=facts for the full list\n";
    const truncation_reserve = truncation_prefix.len + truncation_buf.len + truncation_suffix.len;

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, header);
    var shown_active: usize = 0;
    var truncated = false;
    for (records) |record| {
        if (!record.active) continue;
        var line = std.ArrayList(u8).empty;
        defer line.deinit(allocator);
        try line.print(allocator, "- {s}: {s} [fact_id={s} confidence={d:.3} updated_at={s} tags=", .{ record.key, record.value, record.fact_id, record.confidence, record.updated_at });
        try appendTags(allocator, &line, record.tags);
        try line.appendSlice(allocator, "]\n");

        if (max_bytes) |limit| {
            const projected = out.items.len + line.items.len + footer.items.len;
            if (active_count > shown_active and projected + truncation_reserve > limit) {
                truncated = true;
                break;
            }
            if (projected > limit) {
                truncated = true;
                break;
            }
        }
        try out.appendSlice(allocator, line.items);
        shown_active += 1;
    }
    if (active_count == 0) try out.appendSlice(allocator, none_active);
    if (truncated) {
        const truncation = try std.fmt.bufPrint(
            &truncation_buf,
            "{d}/{d}",
            .{ shown_active, active_count },
        );
        try out.appendSlice(allocator, truncation_prefix);
        try out.appendSlice(allocator, truncation);
        try out.appendSlice(allocator, truncation_suffix);
    }
    try out.appendSlice(allocator, footer.items);
    if (max_bytes) |limit| std.debug.assert(out.items.len <= limit);
    return out.toOwnedSlice(allocator);
}

pub fn activeFactValue(records: []const schema.FactRecord, key: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (records) |record| {
        if (record.active and std.ascii.eqlIgnoreCase(record.key, key)) found = record.value;
    }
    return found;
}

fn validateRecord(record: schema.FactRecord) !void {
    if (record.fact_id.len == 0) return error.EmptyFactId;
    if (record.key.len == 0) return error.EmptyFactKey;
    if (record.value.len == 0) return error.EmptyFactValue;
    if (record.created_at.len == 0) return error.EmptyFactCreatedAt;
    if (record.updated_at.len == 0) return error.EmptyFactUpdatedAt;
    if (record.confidence < 0 or record.confidence > 1) return error.InvalidFactConfidence;
    for (record.tags) |tag| if (tag.len == 0) return error.EmptyFactTag;
}

fn appendTags(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tags: []const []const u8) !void {
    if (tags.len == 0) {
        try out.appendSlice(allocator, "none");
        return;
    }
    for (tags, 0..) |tag, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, tag);
    }
}

fn appendDuration(allocator: std.mem.Allocator, out: *std.ArrayList(u8), seconds: i64) !void {
    if (seconds < 0) return error.NegativeDuration;
    const days = @divTrunc(seconds, 86_400);
    const day_remainder = @rem(seconds, 86_400);
    const hours = @divTrunc(day_remainder, 3_600);
    const hour_remainder = @rem(day_remainder, 3_600);
    const minutes = @divTrunc(hour_remainder, 60);
    const secs = @rem(hour_remainder, 60);

    if (days > 0) try out.print(allocator, "{d}d ", .{days});
    if (days > 0 or hours > 0) try out.print(allocator, "{d}h ", .{hours});
    if (days > 0 or hours > 0 or minutes > 0) try out.print(allocator, "{d}m ", .{minutes});
    try out.print(allocator, "{d}s", .{secs});
}

test "formats active and inactive managed facts with runtime" {
    const records = [_]schema.FactRecord{
        .{
            .fact_id = "fact_name",
            .key = "name",
            .value = "Otto",
            .tags = @constCast(&[_][]const u8{"identity"}),
            .created_at = "1781222400",
            .updated_at = "1781222400",
        },
        .{
            .fact_id = "fact_first_on",
            .key = "first_turned_on_at_unix_seconds",
            .value = "1781222400",
            .tags = @constCast(&[_][]const u8{"runtime"}),
            .created_at = "1781222400",
            .updated_at = "1781222400",
        },
        .{
            .fact_id = "fact_old_name",
            .key = "name",
            .value = "Old",
            .active = false,
            .created_at = "1781222400",
            .updated_at = "1781222500",
        },
    };
    const text = try formatSummary(std.testing.allocator, &records, test_first_turned_on_at_unix_seconds + 90_061, null);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "name: Otto") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Old") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "total_run_time_seconds: 90061") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "total_run_time: 1d 1h 1m 1s") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "inactive_fact_count: 1") != null);
}

test "rejects invalid managed facts and impossible clocks" {
    const bad_name = [_]schema.FactRecord{.{
        .fact_id = "fact_bad",
        .key = "",
        .value = "Otto",
        .created_at = "1",
        .updated_at = "1",
    }};
    try std.testing.expectError(error.EmptyFactKey, formatSummary(std.testing.allocator, &bad_name, 1, null));

    const future_first_on = [_]schema.FactRecord{.{
        .fact_id = "fact_first_on",
        .key = "first_turned_on_at_unix_seconds",
        .value = "2000",
        .created_at = "1",
        .updated_at = "1",
    }};
    try std.testing.expectError(error.ClockBeforeFirstTurnOn, formatSummary(std.testing.allocator, &future_first_on, 1, null));
}

test "conversation self facts summary caps rendered bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var records = std.ArrayList(schema.FactRecord).empty;
    for (0..80) |i| {
        const value = try allocator.alloc(u8, 180);
        @memset(value, 'x');
        try records.append(allocator, .{
            .fact_id = try std.fmt.allocPrint(allocator, "fact_{d}", .{i}),
            .key = try std.fmt.allocPrint(allocator, "note_{d}", .{i}),
            .value = value,
            .created_at = "1781222400",
            .updated_at = "1781222400",
        });
    }

    const full = try formatSummary(allocator, records.items, test_first_turned_on_at_unix_seconds + 90_061, null);
    try std.testing.expect(full.len > conversation_self_facts_max_bytes);

    const capped = try formatSummary(allocator, records.items, test_first_turned_on_at_unix_seconds + 90_061, conversation_self_facts_max_bytes);
    try std.testing.expect(capped.len <= conversation_self_facts_max_bytes);
    try std.testing.expect(std.mem.indexOf(u8, capped, "conversation_self_facts_truncated:") != null);
}
