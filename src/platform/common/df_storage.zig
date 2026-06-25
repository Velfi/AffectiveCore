const std = @import("std");
const process = @import("process.zig");
const senses_mod = @import("system_senses.zig");

pub fn readMount(allocator: std.mem.Allocator, io: std.Io, mount_path: []const u8) !senses_mod.StorageSnapshot {
    const out = try process.runCapture(allocator, io, &.{ "df", "-kP", mount_path });
    defer allocator.free(out);

    const volume = try parseDfKilobytePosix(allocator, out);
    var volumes = try allocator.alloc(senses_mod.StorageVolume, 1);
    volumes[0] = volume;
    return .{ .volumes = volumes };
}

pub fn parseDfKilobytePosix(allocator: std.mem.Allocator, text: []const u8) !senses_mod.StorageVolume {
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \r\n\t"), '\n');
    _ = lines.next() orelse return error.MissingDfHeader;
    const data_line = lines.next() orelse return error.MissingDfData;
    if (lines.next()) |extra| {
        if (std.mem.trim(u8, extra, " \r\n\t").len != 0) return error.UnexpectedDfDataLine;
    }

    var fields = std.mem.tokenizeAny(u8, data_line, " \t");
    const name = fields.next() orelse return error.MissingDfFilesystem;
    const total_kb_text = fields.next() orelse return error.MissingDfBlocks;
    _ = fields.next() orelse return error.MissingDfUsed;
    const available_kb_text = fields.next() orelse return error.MissingDfAvailable;
    const used_percent_text = fields.next() orelse return error.MissingDfCapacity;
    const mount_path = fields.next() orelse return error.MissingDfMountPath;
    if (fields.next() != null) return error.UnexpectedDfField;

    if (!std.mem.endsWith(u8, used_percent_text, "%")) return error.InvalidDfCapacity;
    const used_percent = try std.fmt.parseInt(u8, used_percent_text[0 .. used_percent_text.len - 1], 10);
    if (used_percent > 100) return error.InvalidDfCapacity;

    const total_kb = try std.fmt.parseInt(u64, total_kb_text, 10);
    const available_kb = try std.fmt.parseInt(u64, available_kb_text, 10);
    if (total_kb > std.math.maxInt(u64) / 1024) return error.StorageSizeOverflow;
    if (available_kb > std.math.maxInt(u64) / 1024) return error.StorageSizeOverflow;

    return .{
        .name = try allocator.dupe(u8, name),
        .mount_path = try allocator.dupe(u8, mount_path),
        .total_bytes = total_kb * 1024,
        .available_bytes = available_kb * 1024,
        .used_percent = used_percent,
    };
}

test "parses POSIX df storage output" {
    const text =
        \\Filesystem 1024-blocks Used Available Capacity Mounted on
        \\/dev/disk3s1 1000 750 250 75% /
    ;
    const volume = try parseDfKilobytePosix(std.testing.allocator, text);
    defer std.testing.allocator.free(volume.name);
    defer std.testing.allocator.free(volume.mount_path);
    try std.testing.expectEqualStrings("/dev/disk3s1", volume.name);
    try std.testing.expectEqualStrings("/", volume.mount_path);
    try std.testing.expectEqual(@as(u64, 1_024_000), volume.total_bytes);
    try std.testing.expectEqual(@as(u64, 256_000), volume.available_bytes);
    try std.testing.expectEqual(@as(u8, 75), volume.used_percent);
}
