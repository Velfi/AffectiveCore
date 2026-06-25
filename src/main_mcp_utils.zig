const std = @import("std");
const schema = @import("storage/schema.zig");
const time_mod = @import("core/time.zig");

pub fn requireString(args: std.json.Value, key: []const u8) ![]const u8 {
    return getString(args, key) orelse error.MissingRequiredString;
}

pub fn getString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

pub fn getNumber(args: std.json.Value, key: []const u8) ?f64 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return switch (value) {
        .float => value.float,
        .integer => @floatFromInt(value.integer),
        else => null,
    };
}

pub fn getBool(args: std.json.Value, key: []const u8) ?bool {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

pub fn getStringArray(allocator: std.mem.Allocator, args: std.json.Value, key: []const u8) ![]const []const u8 {
    if (args != .object) return &.{};
    const value = args.object.get(key) orelse return &.{};
    if (value != .array) return error.ExpectedStringArray;
    const out = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.ExpectedStringArray;
        out[i] = item.string;
    }
    return out;
}

pub fn cloneConstStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, i| out[i] = try allocator.dupe(u8, value);
    return out;
}

pub fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, limit);
    }
    const dirname = std.fs.path.dirname(path) orelse return error.MissingParentDirectory;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, basename, allocator, limit);
}

pub fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .truncate = true } });
    }
    const dirname = std.fs.path.dirname(path) orelse return error.MissingParentDirectory;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    defer dir.close(io);
    return dir.writeFile(io, .{ .sub_path = basename, .data = data, .flags = .{ .truncate = true } });
}

pub fn appendRevision(allocator: std.mem.Allocator, revisions: []const schema.MemoryRevision, revision: schema.MemoryRevision) ![]schema.MemoryRevision {
    const out = try allocator.alloc(schema.MemoryRevision, revisions.len + 1);
    @memcpy(out[0..revisions.len], revisions);
    out[revisions.len] = revision;
    return out;
}

pub fn nowTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    return time_mod.nowTimestamp(allocator);
}

pub fn tagInSlice(tags: []const []const u8, candidate: []const u8) bool {
    for (tags) |tag| if (std.ascii.eqlIgnoreCase(tag, candidate)) return true;
    return false;
}

pub fn memoryInterpretation(memory: schema.MemoryRecord) []const u8 {
    if (memory.interpretation.len > 0) return memory.interpretation;
    return memory.text;
}

pub fn rollDreamHeat(random: std.Random, heat_bias: ?[]const u8) f32 {
    const raw = random.float(f32);
    if (heat_bias) |bias| {
        if (std.ascii.eqlIgnoreCase(bias, "low")) return raw * 0.34;
        if (std.ascii.eqlIgnoreCase(bias, "high")) return 0.67 + raw * 0.33;
        if (std.ascii.eqlIgnoreCase(bias, "grounded")) return raw * 0.34;
        if (std.ascii.eqlIgnoreCase(bias, "surreal")) return 0.67 + raw * 0.33;
    }
    return raw;
}

pub fn dreamStyle(heat: f32) []const u8 {
    if (heat < 0.34) return "grounded_replay";
    if (heat < 0.67) return "associative_synthesis";
    return "surreal_symbolic";
}
