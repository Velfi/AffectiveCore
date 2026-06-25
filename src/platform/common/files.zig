const std = @import("std");

pub fn ensureParentDir(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try ensureDir(io, dir);
    }
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
    try ensureParentDir(io, path);
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .truncate = true } });
    }
    const dirname = std.fs.path.dirname(path) orelse return error.MissingParentDirectory;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    defer dir.close(io);
    return dir.writeFile(io, .{ .sub_path = basename, .data = data, .flags = .{ .truncate = true } });
}

pub fn statFilePath(io: std.Io, path: []const u8) !std.Io.Dir.Stat {
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().statFile(io, path, .{});
    }
    const dirname = std.fs.path.dirname(path) orelse return error.MissingParentDirectory;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, dirname, .{});
    defer dir.close(io);
    return dir.statFile(io, basename, .{});
}

pub fn ensureDir(io: std.Io, path: []const u8) !void {
    if (path.len == 0) return;
    if (!std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.cwd().createDirPath(io, path);
    }

    const existing_parent, const missing_suffix = try nearestExistingParent(io, path);
    if (missing_suffix.len == 0) return;
    var dir = try std.Io.Dir.openDirAbsolute(io, existing_parent, .{});
    defer dir.close(io);
    try dir.createDirPath(io, missing_suffix);
}

fn nearestExistingParent(io: std.Io, path: []const u8) !struct { []const u8, []const u8 } {
    var candidate = trimTrailingSeparators(path);
    if (candidate.len == 0) return .{ "/", "" };

    var last_error: anyerror = error.FileNotFound;
    while (candidate.len > 0) {
        var dir = std.Io.Dir.openDirAbsolute(io, candidate, .{}) catch |err| {
            last_error = err;
            candidate = std.fs.path.dirname(candidate) orelse "";
            continue;
        };
        dir.close(io);

        const suffix = trimLeadingSeparators(path[candidate.len..]);
        return .{ candidate, suffix };
    }

    if (last_error == error.AccessDenied or last_error == error.PermissionDenied) {
        return last_error;
    }
    return .{ "/", trimLeadingSeparators(path) };
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == std.fs.path.sep) {
        end -= 1;
    }
    return path[0..end];
}

fn trimLeadingSeparators(path: []const u8) []const u8 {
    var start: usize = 0;
    while (start < path.len and path[start] == std.fs.path.sep) {
        start += 1;
    }
    return path[start..];
}

test "ensureParentDir supports absolute paths" {
    const io = std.testing.io;
    const dirname = "affective-core-files-test";
    const root = "/tmp/" ++ dirname;
    const path = root ++ "/nested/events.jsonl";
    defer cleanup: {
        var tmp = std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch break :cleanup;
        defer tmp.close(io);
        tmp.deleteTree(io, dirname) catch {};
        break :cleanup;
    }

    try ensureParentDir(io, path);
}

test "writeFilePath supports absolute paths" {
    const io = std.testing.io;
    const dirname = "affective-core-files-write-test";
    const root = "/tmp/" ++ dirname;
    const path = root ++ "/nested/events.jsonl";
    defer cleanup: {
        var tmp = std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch break :cleanup;
        defer tmp.close(io);
        tmp.deleteTree(io, dirname) catch {};
        break :cleanup;
    }

    try writeFilePath(io, path, "ok\n");
    const bytes = try readFileAllocPath(io, path, std.testing.allocator, .limited(16));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("ok\n", bytes);
}
