const std = @import("std");
const files = @import("../platform/common/files.zig");

pub const SessionMetadata = struct {
    active_identity: []const u8 = "",
    continuity_thread: []const u8 = "",
    notes: []const u8 = "",
};

pub fn metadataGet(allocator: std.mem.Allocator, io: std.Io, brain_root: []const u8) ![]u8 {
    const metadata = try readMetadata(allocator, io, brain_root);
    return try metadataResponse(allocator, brain_root, metadata);
}

pub fn metadataSet(allocator: std.mem.Allocator, io: std.Io, brain_root: []const u8, args: std.json.Value) ![]u8 {
    var metadata = try readMetadata(allocator, io, brain_root);
    if (getString(args, "active_identity")) |value| metadata.active_identity = value;
    if (getString(args, "continuity_thread")) |value| metadata.continuity_thread = value;
    if (getString(args, "notes")) |value| metadata.notes = value;

    const path = try metadataPath(allocator, brain_root);
    const json = try std.json.Stringify.valueAlloc(allocator, metadata, .{ .whitespace = .indent_2 });
    try files.writeFilePath(io, path, json);
    return try metadataResponse(allocator, brain_root, metadata);
}

pub fn memoryInspectSafe(allocator: std.mem.Allocator, snapshot_json: []const u8, args: std.json.Value) ![]u8 {
    const include_text = getBool(args, "include_text") orelse false;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, snapshot_json, .{});
    defer parsed.deinit();
    const Summary = struct {
        ok: bool = true,
        privacy: []const u8,
        text_included: bool,
        memory_count: ?i64,
        event_count: ?i64,
        belief_count: ?i64,
        self_trust_count: ?i64,
        disposition_count: ?i64,
        action_pressure_count: ?i64,
        mailbox_count: ?i64,
        capability_count: ?i64,
        brain_mode: ?[]const u8,
    };
    const summary = Summary{
        .privacy = if (include_text)
            "This endpoint found no raw memory text in the compact snapshot; use read_models_snapshot for full detail."
        else
            "Raw memory and conversation text are omitted by default. This endpoint returns counts and state labels only.",
        .text_included = false,
        .memory_count = findInteger(parsed.value, "memory_count"),
        .event_count = findInteger(parsed.value, "event_count"),
        .belief_count = findInteger(parsed.value, "belief_count"),
        .self_trust_count = findInteger(parsed.value, "self_trust_count"),
        .disposition_count = findInteger(parsed.value, "disposition_count"),
        .action_pressure_count = findInteger(parsed.value, "action_pressure_count"),
        .mailbox_count = findInteger(parsed.value, "mailbox_count"),
        .capability_count = findInteger(parsed.value, "capability_count"),
        .brain_mode = findString(parsed.value, "brain_mode"),
    };
    return try std.json.Stringify.valueAlloc(allocator, summary, .{ .whitespace = .indent_2 });
}

fn readMetadata(allocator: std.mem.Allocator, io: std.Io, brain_root: []const u8) !SessionMetadata {
    const path = try metadataPath(allocator, brain_root);
    const bytes = files.readFileAllocPath(io, path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    const parsed = try std.json.parseFromSlice(SessionMetadata, allocator, bytes, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

fn metadataResponse(allocator: std.mem.Allocator, brain_root: []const u8, metadata: SessionMetadata) ![]u8 {
    const Response = struct {
        ok: bool = true,
        path: []const u8,
        metadata: SessionMetadata,
    };
    return try std.json.Stringify.valueAlloc(allocator, Response{
        .path = try metadataPath(allocator, brain_root),
        .metadata = metadata,
    }, .{ .whitespace = .indent_2 });
}

fn metadataPath(allocator: std.mem.Allocator, brain_root: []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, &.{ brain_root, "session_metadata.json" });
}

fn getString(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getBool(args: std.json.Value, key: []const u8) ?bool {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    if (value != .bool) return null;
    return value.bool;
}

fn findInteger(value: std.json.Value, key: []const u8) ?i64 {
    switch (value) {
        .object => |object| {
            if (object.get(key)) |found| {
                return switch (found) {
                    .integer => |int| int,
                    else => null,
                };
            }
            var iter = object.iterator();
            while (iter.next()) |entry| if (findInteger(entry.value_ptr.*, key)) |found| return found;
            return null;
        },
        .array => |array| {
            for (array.items) |item| if (findInteger(item, key)) |found| return found;
            return null;
        },
        else => return null,
    }
}

fn findString(value: std.json.Value, key: []const u8) ?[]const u8 {
    switch (value) {
        .object => |object| {
            if (object.get(key)) |found| {
                return switch (found) {
                    .string => |text| text,
                    else => null,
                };
            }
            var iter = object.iterator();
            while (iter.next()) |entry| if (findString(entry.value_ptr.*, key)) |found| return found;
            return null;
        },
        .array => |array| {
            for (array.items) |item| if (findString(item, key)) |found| return found;
            return null;
        },
        else => return null,
    }
}

test "metadata set and get persists active identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = "data/test/mcp_host_admin_metadata";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try files.ensureDir(std.testing.io, root);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"active_identity\":\"Astra\",\"notes\":\"quiet close\"}", .{});
    defer parsed.deinit();
    const set = try metadataSet(allocator, std.testing.io, root, parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, set, "\"active_identity\": \"Astra\"") != null);
    const got = try metadataGet(allocator, std.testing.io, root);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"notes\": \"quiet close\"") != null);
}

test "safe memory inspection returns counts without text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"ok":true,"read_models":{"brain_mode":"waking","memory_count":7,"event_count":3,"private_text":"secret"}}
    ;
    const response = try memoryInspectSafe(arena.allocator(), json, .null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"memory_count\": 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "secret") == null);
}
