const std = @import("std");
const brain_mod = @import("brain.zig");

const Brain = brain_mod.Brain;

pub const Scene = struct {
    name: []const u8,
    theme_color: ?[]const u8 = null,
};

const name_keys = [_][]const u8{ "display_name", "name", "brain_name" };
const color_keys = [_][]const u8{
    "favorite_color",
    "favoriteColor",
    "favourite_color",
    "favouriteColor",
    "favorite_colour",
    "favoriteColour",
    "theme_color",
    "themeColor",
    "accent_color",
    "accentColor",
};
const fact_name_keys = [_][]const u8{ "name", "display_name", "brain_name" };
const fact_color_keys = [_][]const u8{ "favorite_color", "theme_color", "accent_color" };
const presentation_fact_keys = [_][]const u8{
    "name",
    "display_name",
    "brain_name",
    "theme_color",
    "favorite_color",
    "accent_color",
};
const nested_profile_keys = [_][]const u8{ "profile", "identity", "self", "preferences", "appearance", "theme" };

pub fn isPresentationFactKey(key: []const u8) bool {
    const trimmed = std.mem.trim(u8, key, " \r\n\t");
    for (presentation_fact_keys) |candidate| {
        if (std.ascii.eqlIgnoreCase(trimmed, candidate)) return true;
    }
    return false;
}

pub fn refreshAfterPresentationFactChange(brain: *Brain, fact_key: []const u8) !void {
    if (!isPresentationFactKey(fact_key)) return;
    const output = brain.deps.mise_en_scene_output orelse return;
    const scene = try resolve(brain);
    defer {
        brain.allocator.free(scene.name);
        if (scene.theme_color) |color| brain.allocator.free(color);
    }
    try output.apply(scene.name, scene.theme_color);
}

pub fn resolve(self: *Brain) !Scene {
    const io = self.deps.io orelse return error.IoUnavailable;
    const fs = self.deps.filesystem orelse return error.FilesystemUnavailable;

    var profile_name: ?[]const u8 = null;
    var profile_color: ?[]const u8 = null;
    if (self.cfg.brain_root.len > 0) {
        const profile_path = try std.fmt.allocPrint(self.allocator, "{s}/brain_profile.json", .{self.cfg.brain_root});
        defer self.allocator.free(profile_path);
        const bytes = fs.readFileAllocPath(io, profile_path, self.allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => |e| return e,
        };
        if (bytes) |owned| {
            defer self.allocator.free(owned);
            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, owned, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidBrainProfile;
            profile_name = try firstStringInObject(self.allocator, parsed.value.object, &name_keys);
            profile_color = try firstColorInObject(self.allocator, parsed.value.object);
        }
    }

    const fact_name = try factValueForKeys(self, &fact_name_keys);
    const fact_color = try factValueForKeys(self, &fact_color_keys);
    defer {
        if (fact_name) |value| self.allocator.free(value);
        if (fact_color) |value| self.allocator.free(value);
    }

    const name = if (fact_name) |value|
        try self.allocator.dupe(u8, value)
    else if (profile_name) |value|
        value
    else if (self.cfg.brain_id.len > 0)
        try self.allocator.dupe(u8, self.cfg.brain_id)
    else
        return error.MissingMiseEnSceneName;

    const theme_color = if (fact_color) |value|
        try self.allocator.dupe(u8, value)
    else
        profile_color;

    return .{ .name = name, .theme_color = theme_color };
}

fn factValueForKeys(self: *Brain, keys: []const []const u8) !?[]const u8 {
    const records = try self.deps.store.loadFactRecords(self.allocator);
    for (records) |record| {
        if (!record.active) continue;
        for (keys) |key| {
            if (!std.ascii.eqlIgnoreCase(record.key, key)) continue;
            const trimmed = std.mem.trim(u8, record.value, " \r\n\t");
            if (trimmed.len == 0) continue;
            return try self.allocator.dupe(u8, trimmed);
        }
    }
    return null;
}

fn firstStringInObject(allocator: std.mem.Allocator, object: std.json.ObjectMap, keys: []const []const u8) !?[]const u8 {
    for (keys) |key| {
        if (try stringValue(object.get(key))) |value| return try allocator.dupe(u8, value);
    }
    for (nested_profile_keys) |nested_key| {
        const nested_value = object.get(nested_key) orelse continue;
        if (nested_value != .object) continue;
        if (try firstStringInObject(allocator, nested_value.object, keys)) |value| return value;
    }
    return null;
}

fn firstColorInObject(allocator: std.mem.Allocator, object: std.json.ObjectMap) !?[]const u8 {
    for (color_keys) |key| {
        if (try colorValue(allocator, object.get(key))) |value| return value;
    }
    for (nested_profile_keys) |nested_key| {
        const nested_value = object.get(nested_key) orelse continue;
        if (nested_value != .object) continue;
        if (try firstColorInObject(allocator, nested_value.object)) |value| return value;
    }
    return null;
}

fn stringValue(value: ?std.json.Value) !?[]const u8 {
    const actual = value orelse return null;
    if (actual != .string) return error.InvalidBrainProfile;
    const trimmed = std.mem.trim(u8, actual.string, " \r\n\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn colorValue(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const actual = value orelse return null;
    return switch (actual) {
        .string => blk: {
            const trimmed = try stringValue(actual);
            break :blk if (trimmed) |text| try allocator.dupe(u8, text) else null;
        },
        .object => |object| blk: {
            if (try stringValue(object.get("hex"))) |hex| break :blk try allocator.dupe(u8, hex);
            if (try stringValue(object.get("value"))) |value_string| break :blk try allocator.dupe(u8, value_string);
            if (try stringValue(object.get("name"))) |name| break :blk try allocator.dupe(u8, name);
            const red = object.get("red") orelse object.get("r") orelse return error.InvalidBrainProfile;
            const green = object.get("green") orelse object.get("g") orelse return error.InvalidBrainProfile;
            const blue = object.get("blue") orelse object.get("b") orelse return error.InvalidBrainProfile;
            const r = try numericComponent(red);
            const g = try numericComponent(green);
            const b = try numericComponent(blue);
            break :blk try std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{
                @as(u8, @intFromFloat(normalizeComponent(r) * 255)),
                @as(u8, @intFromFloat(normalizeComponent(g) * 255)),
                @as(u8, @intFromFloat(normalizeComponent(b) * 255)),
            });
        },
        .array => |array| blk: {
            if (array.items.len < 3) return error.InvalidBrainProfile;
            const r = try numericComponent(array.items[0]);
            const g = try numericComponent(array.items[1]);
            const b = try numericComponent(array.items[2]);
            break :blk try std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2}", .{
                @as(u8, @intFromFloat(normalizeComponent(r) * 255)),
                @as(u8, @intFromFloat(normalizeComponent(g) * 255)),
                @as(u8, @intFromFloat(normalizeComponent(b) * 255)),
            });
        },
        else => error.InvalidBrainProfile,
    };
}

fn numericComponent(value: std.json.Value) !f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| @floatCast(float),
        .number_string => |number_string| try std.fmt.parseFloat(f64, number_string),
        .string => |string| try std.fmt.parseFloat(f64, std.mem.trim(u8, string, " \r\n\t")),
        else => error.InvalidBrainProfile,
    };
}

fn normalizeComponent(value: f64) f64 {
    const normalized = if (value > 1.0) value / 255.0 else value;
    return @max(0.0, @min(normalized, 1.0));
}

test "mise en scene recognizes presentation fact keys" {
    try std.testing.expect(isPresentationFactKey("name"));
    try std.testing.expect(isPresentationFactKey("  THEME_COLOR "));
    try std.testing.expect(isPresentationFactKey("favorite_color"));
    try std.testing.expect(!isPresentationFactKey("favorite_food"));
}

test "mise en scene profile json parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"display_name\":\"Mara\",\"theme_color\":\"green\"}", .{});
    defer parsed.deinit();
    const name = try firstStringInObject(allocator, parsed.value.object, &name_keys);
    const color = try firstColorInObject(allocator, parsed.value.object);
    try std.testing.expectEqualStrings("Mara", name.?);
    try std.testing.expectEqualStrings("green", color.?);
}
