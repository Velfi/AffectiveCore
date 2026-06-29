const std = @import("std");
const process = @import("process.zig");
const senses_mod = @import("system_senses.zig");

pub fn readPowerSnapshot(allocator: std.mem.Allocator, io: std.Io) !senses_mod.PowerSnapshot {
    const out = try process.runCapture(allocator, io, &.{ "/usr/bin/pmset", "-g", "batt" });
    defer allocator.free(out);
    return parsePmsetBatteryOutput(allocator, out);
}

pub fn parsePmsetBatteryOutput(allocator: std.mem.Allocator, text: []const u8) !senses_mod.PowerSnapshot {
    var supplies = std.ArrayList(senses_mod.PowerSupply).empty;
    var external_online = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\n\t");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "Now drawing from")) {
            external_online = std.mem.indexOf(u8, line, "'AC Power'") != null;
            continue;
        }

        const battery_line = blk: {
            var start: usize = 0;
            while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
            break :blk line[start..];
        };
        if (!std.mem.startsWith(u8, battery_line, "-InternalBattery") and
            !std.mem.startsWith(u8, battery_line, "InternalBattery"))
        {
            continue;
        }

        const normalized = if (std.mem.startsWith(u8, battery_line, "-"))
            battery_line[1..]
        else
            battery_line;
        const battery = try parseBatteryLine(allocator, normalized);
        try supplies.append(allocator, battery);
    }

    try supplies.append(allocator, .{
        .name = try allocator.dupe(u8, "AC"),
        .kind = try allocator.dupe(u8, "Mains"),
        .online = external_online,
    });

    return .{ .supplies = try supplies.toOwnedSlice(allocator) };
}

fn parseBatteryLine(allocator: std.mem.Allocator, line: []const u8) !senses_mod.PowerSupply {
    var tab_parts = std.mem.splitScalar(u8, line, '\t');
    const left = tab_parts.next() orelse return error.InvalidPmsetBatteryLine;
    const right = tab_parts.next() orelse return error.InvalidPmsetBatteryLine;
    if (tab_parts.next() != null) return error.InvalidPmsetBatteryLine;

    const id_start = std.mem.indexOf(u8, left, " (id=") orelse return error.InvalidPmsetBatteryLine;
    const name = try allocator.dupe(u8, left[0..id_start]);

    const percent_end = std.mem.indexOf(u8, right, "%") orelse return error.InvalidPmsetBatteryLine;
    var percent_start = percent_end;
    while (percent_start > 0 and right[percent_start - 1] >= '0' and right[percent_start - 1] <= '9') : (percent_start -= 1) {}
    const capacity = try std.fmt.parseInt(u8, right[percent_start..percent_end], 10);
    if (capacity > 100) return error.InvalidPmsetBatteryCapacity;

    const status_start = percent_end + 2;
    if (status_start > right.len) return error.InvalidPmsetBatteryLine;
    const status_end = std.mem.indexOfScalar(u8, right[status_start..], ';') orelse right.len;
    const status = try allocator.dupe(u8, std.mem.trim(u8, right[status_start .. status_start + status_end], " \t"));

    return .{
        .name = name,
        .kind = try allocator.dupe(u8, "Battery"),
        .capacity_percent = capacity,
        .status = status,
    };
}

test "parses pmset battery output on battery power" {
    const text = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=22478947)\t86%; discharging; 4:04 remaining present: true\n";
    const snapshot = try parsePmsetBatteryOutput(std.testing.allocator, text);
    defer freeSnapshot(std.testing.allocator, snapshot);

    try std.testing.expectEqual(@as(usize, 2), snapshot.supplies.len);
    try std.testing.expectEqualStrings("InternalBattery-0", snapshot.supplies[0].name);
    try std.testing.expectEqualStrings("Battery", snapshot.supplies[0].kind);
    try std.testing.expectEqual(@as(?u8, 86), snapshot.supplies[0].capacity_percent);
    try std.testing.expectEqualStrings("discharging", snapshot.supplies[0].status.?);
    try std.testing.expectEqualStrings("AC", snapshot.supplies[1].name);
    try std.testing.expectEqual(@as(?bool, false), snapshot.supplies[1].online);
}

test "parses pmset battery output on ac power" {
    const text = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=22478947)\t100%; AC attached; (no estimate) present: true\n";
    const snapshot = try parsePmsetBatteryOutput(std.testing.allocator, text);
    defer freeSnapshot(std.testing.allocator, snapshot);

    try std.testing.expectEqual(@as(?u8, 100), snapshot.supplies[0].capacity_percent);
    try std.testing.expectEqualStrings("AC attached", snapshot.supplies[0].status.?);
    try std.testing.expectEqual(@as(?bool, true), snapshot.supplies[1].online);
}

test "parses pmset output with no internal battery" {
    const text = "Now drawing from 'AC Power'\n";
    const snapshot = try parsePmsetBatteryOutput(std.testing.allocator, text);
    defer freeSnapshot(std.testing.allocator, snapshot);

    try std.testing.expectEqual(@as(usize, 1), snapshot.supplies.len);
    try std.testing.expectEqual(@as(?bool, true), snapshot.supplies[0].online);
}

fn freeSnapshot(allocator: std.mem.Allocator, snapshot: senses_mod.PowerSnapshot) void {
    for (snapshot.supplies) |supply| {
        allocator.free(supply.name);
        allocator.free(supply.kind);
        if (supply.status) |status| allocator.free(status);
    }
    allocator.free(snapshot.supplies);
}
