const std = @import("std");
const senses_mod = @import("system_senses.zig");

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: *?[*:0]u8) c_int;
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*:0]const u8, nByte: c_int, stmt: *?*sqlite3_stmt, tail: ?*[*:0]const u8) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, index: c_int) i64;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;

pub fn readDatabases(allocator: std.mem.Allocator, memory_path: []const u8, graph_path: []const u8) !senses_mod.DatabaseSnapshot {
    var databases = try allocator.alloc(senses_mod.DatabaseFileStats, 2);
    databases[0] = try readDatabase(allocator, "memory", memory_path);
    databases[1] = try readDatabase(allocator, "relationship_graph", graph_path);
    return .{ .databases = databases };
}

pub fn readDatabase(allocator: std.mem.Allocator, label: []const u8, path: []const u8) !senses_mod.DatabaseFileStats {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var maybe_db: ?*sqlite3 = null;
    if (sqlite3_open(path_z.ptr, &maybe_db) != SQLITE_OK) return error.SqliteOpenFailed;
    const db = maybe_db orelse return error.SqliteOpenFailed;
    defer _ = sqlite3_close(db);

    const page_count = try queryInt(allocator, db, "PRAGMA page_count");
    const page_size = try queryInt(allocator, db, "PRAGMA page_size");
    const freelist_count = try queryInt(allocator, db, "PRAGMA freelist_count");
    const table_count = try queryInt(allocator, db, "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'");
    if (page_count < 0 or page_size < 0 or freelist_count < 0 or table_count < 0) return error.InvalidDatabaseStat;
    return .{
        .label = try allocator.dupe(u8, label),
        .path = try allocator.dupe(u8, path),
        .page_count = @intCast(page_count),
        .page_size = @intCast(page_size),
        .freelist_count = @intCast(freelist_count),
        .total_bytes = @as(u64, @intCast(page_count)) * @as(u64, @intCast(page_size)),
        .table_count = @intCast(table_count),
    };
}

fn queryInt(allocator: std.mem.Allocator, db: *sqlite3, sql: []const u8) !i64 {
    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);
    var maybe_stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql_z.ptr, -1, &maybe_stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
    const stmt = maybe_stmt orelse return error.SqlitePrepareFailed;
    defer _ = sqlite3_finalize(stmt);
    if (sqlite3_step(stmt) != SQLITE_ROW) return error.SqliteStepFailed;
    return sqlite3_column_int64(stmt, 0);
}

test "reads sqlite database page stats" {
    const path = "data/test/database_stats.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    {
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(path_z);
        var maybe_db: ?*sqlite3 = null;
        if (sqlite3_open(path_z.ptr, &maybe_db) != SQLITE_OK) return error.SqliteOpenFailed;
        const db = maybe_db orelse return error.SqliteOpenFailed;
        defer _ = sqlite3_close(db);
        const sql = try std.testing.allocator.dupeZ(u8, "CREATE TABLE sample (id INTEGER PRIMARY KEY)");
        defer std.testing.allocator.free(sql);
        var errmsg: ?[*:0]u8 = null;
        if (sqlite3_exec(db, sql.ptr, null, null, &errmsg) != SQLITE_OK) {
            if (errmsg) |msg| sqlite3_free(@ptrCast(msg));
            return error.SqliteExecFailed;
        }
    }

    const stats = try readDatabase(std.testing.allocator, "test", path);
    defer {
        std.testing.allocator.free(stats.label);
        std.testing.allocator.free(stats.path);
    }
    try std.testing.expectEqualStrings("test", stats.label);
    try std.testing.expect(stats.page_size > 0);
    try std.testing.expect(stats.total_bytes > 0);
}
