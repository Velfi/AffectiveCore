const std = @import("std");
const schema = @import("../storage/schema.zig");
const time = @import("time.zig");

pub fn knownGreeting(allocator: std.mem.Allocator, person: schema.Person, change_summary: ?[]const u8, now_seconds: i64) ![]u8 {
    if (change_summary) |change| {
        if (isNotableChange(change)) return std.fmt.allocPrint(allocator, "Welcome back, {s}. I notice {s}.", .{ person.display_name, change });
    }
    const days = time.daysBetweenUnixish(person.last_seen_at, now_seconds);
    if (days >= 2 and days < 9999) {
        return std.fmt.allocPrint(allocator, "Welcome back, {s}. It has been {d} days.", .{ person.display_name, days });
    }
    return std.fmt.allocPrint(allocator, "Welcome back, {s}.", .{person.display_name});
}

fn isNotableChange(change_summary: []const u8) bool {
    const change = std.mem.trim(u8, change_summary, " \t\r\n.!");
    if (change.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(change, "no change")) return false;
    if (std.ascii.eqlIgnoreCase(change, "unchanged")) return false;
    if (std.ascii.startsWithIgnoreCase(change, "no change ")) return false;
    if (std.ascii.startsWithIgnoreCase(change, "no visible change")) return false;
    if (std.ascii.startsWithIgnoreCase(change, "nothing changed")) return false;
    return true;
}

test "known greeting omits absence of appearance change" {
    const text = try knownGreeting(std.testing.allocator, .{
        .person_id = "person_001",
        .display_name = "Zelda",
        .relationship_status = .friend,
        .created_at = "0",
        .last_seen_at = "0",
        .sighting_count = 1,
        .greeting_style = .warm,
        .stable_notes = &.{},
        .recent_notes = &.{},
        .embeddings = &.{},
    }, "No change in appearance details from prior notes.", 1);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Welcome back, Zelda.", text);
}
