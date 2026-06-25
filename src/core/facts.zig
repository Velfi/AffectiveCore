const std = @import("std");
const schema = @import("../storage/schema.zig");

pub const test_first_turned_on_at_unix_seconds: i64 = 1_781_222_400;

pub fn formatSummary(allocator: std.mem.Allocator, records: []const schema.FactRecord, now_seconds: i64) ![]const u8 {
    var inactive_count: usize = 0;
    var runtime_seconds: ?i64 = null;
    for (records) |record| {
        try validateRecord(record);
        if (!record.active) {
            inactive_count += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(record.key, "first_turned_on_at_unix_seconds")) {
            const first_on = try std.fmt.parseInt(i64, record.value, 10);
            if (first_on <= 0) return error.InvalidFirstTurnedOnAt;
            if (now_seconds < first_on) return error.ClockBeforeFirstTurnOn;
            runtime_seconds = now_seconds - first_on;
        }
    }

    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "Self facts:\n");
    var active_count: usize = 0;
    for (records) |record| {
        if (!record.active) continue;
        active_count += 1;
        try out.print(allocator, "- {s}: {s} [fact_id={s} confidence={d:.3} updated_at={s} tags=", .{ record.key, record.value, record.fact_id, record.confidence, record.updated_at });
        try appendTags(allocator, &out, record.tags);
        try out.appendSlice(allocator, "]\n");
    }
    if (active_count == 0) try out.appendSlice(allocator, "- none active\n");
    if (runtime_seconds) |seconds| {
        try out.print(allocator, "- total_run_time_seconds: {d}\n- total_run_time: ", .{seconds});
        try appendDuration(allocator, &out, seconds);
        try out.append(allocator, '\n');
    }
    try out.print(allocator, "- inactive_fact_count: {d}\n", .{inactive_count});
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
            .invalidated_at = "1781222500",
        },
    };
    const text = try formatSummary(std.testing.allocator, &records, test_first_turned_on_at_unix_seconds + 90_061);
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
    try std.testing.expectError(error.EmptyFactKey, formatSummary(std.testing.allocator, &bad_name, 1));

    const future_first_on = [_]schema.FactRecord{.{
        .fact_id = "fact_first_on",
        .key = "first_turned_on_at_unix_seconds",
        .value = "2000",
        .created_at = "1",
        .updated_at = "1",
    }};
    try std.testing.expectError(error.ClockBeforeFirstTurnOn, formatSummary(std.testing.allocator, &future_first_on, 1));
}
