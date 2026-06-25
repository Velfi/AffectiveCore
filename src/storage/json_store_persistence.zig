const std = @import("std");
const schema = @import("schema.zig");
const files = @import("../platform/common/files.zig");

pub const current_schema_version: u32 = 2;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: *?[*:0]u8) c_int;
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*:0]const u8, nByte: c_int, stmt: *?*sqlite3_stmt, tail: ?*[*:0]const u8) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_int(stmt: *sqlite3_stmt, index: c_int, value: c_int) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, index: c_int, value: [*:0]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_column_int(stmt: *sqlite3_stmt, index: c_int) c_int;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, index: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, index: c_int) c_int;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

pub fn parseSchemaVersion(allocator: std.mem.Allocator, bytes: []const u8) !u32 {
    const Header = struct { schema_version: ?u32 = null };
    const parsed = try std.json.parseFromSlice(Header, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parsed.value.schema_version orelse error.MissingCognitiveSchemaVersion;
}

pub fn validateCognitiveFile(data: schema.CognitiveFile) !void {
    if (data.schema_version != current_schema_version) return error.UnsupportedCognitiveSchemaVersion;
    for (data.traces) |trace| try validateConfidence(trace.confidence);
    for (data.beliefs) |belief| try validateConfidence(belief.confidence);
    for (data.subjects) |subject| {
        if (subject.subject_id.len == 0) return error.EmptySubjectId;
        if (subject.display_name.len == 0) return error.EmptySubjectName;
    }
}

fn validateConfidence(value: f32) !void {
    if (value < 0 or value > 1) return error.InvalidConfidence;
}

pub fn readCognitiveJson(store_allocator: std.mem.Allocator, io: std.Io, path: []const u8, out_allocator: std.mem.Allocator) ![]u8 {
    const db = try openMemoryDb(store_allocator, io, path);
    defer _ = sqlite3_close(db);
    try initMemorySchema(store_allocator, db);
    const stmt = try prepareSql(store_allocator, db, "SELECT schema_version, data_json FROM cognitive_memory WHERE id = 1");
    defer finalizeSql(stmt);
    const rc = sqlite3_step(stmt);
    if (rc == SQLITE_DONE) {
        return std.json.Stringify.valueAlloc(out_allocator, schema.CognitiveFile{ .schema_version = current_schema_version }, .{ .whitespace = .indent_2 });
    }
    if (rc != SQLITE_ROW) return error.SqliteStepFailed;
    const version: u32 = @intCast(sqlite3_column_int(stmt, 0));
    if (version != current_schema_version) return error.UnsupportedCognitiveSchemaVersion;
    return columnText(out_allocator, stmt, 1);
}

pub fn writeCognitiveJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8, json: []const u8) !void {
    const db = try openMemoryDb(allocator, io, path);
    defer _ = sqlite3_close(db);
    try initMemorySchema(allocator, db);
    try writeCognitiveJsonToDb(allocator, db, current_schema_version, json);
}

fn openMemoryDb(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*sqlite3 {
    if (!std.mem.eql(u8, path, ":memory:")) try files.ensureParentDir(io, path);
    const path_z = try allocator.dupeZ(u8, path);
    var maybe_db: ?*sqlite3 = null;
    if (sqlite3_open(path_z.ptr, &maybe_db) != SQLITE_OK) return error.SqliteOpenFailed;
    return maybe_db orelse error.SqliteOpenFailed;
}

fn initMemorySchema(allocator: std.mem.Allocator, db: *sqlite3) !void {
    try execSql(allocator, db,
        \\PRAGMA foreign_keys = ON;
        \\PRAGMA user_version = 2;
        \\CREATE TABLE IF NOT EXISTS cognitive_memory (
        \\  id INTEGER PRIMARY KEY CHECK(id = 1),
        \\  schema_version INTEGER NOT NULL,
        \\  data_json TEXT NOT NULL
        \\);
    );
}

fn writeCognitiveJsonToDb(allocator: std.mem.Allocator, db: *sqlite3, version: u32, json: []const u8) !void {
    const stmt = try prepareSql(allocator, db,
        \\INSERT INTO cognitive_memory (id, schema_version, data_json)
        \\VALUES (1, ?, ?)
        \\ON CONFLICT(id) DO UPDATE SET schema_version=excluded.schema_version, data_json=excluded.data_json
    );
    defer finalizeSql(stmt);
    if (sqlite3_bind_int(stmt, 1, @intCast(version)) != SQLITE_OK) return error.SqliteBindFailed;
    try bindText(stmt, 2, json, allocator);
    try stepDone(stmt);
}

fn execSql(allocator: std.mem.Allocator, db: *sqlite3, sql: []const u8) !void {
    const sql_z = try allocator.dupeZ(u8, sql);
    var errmsg: ?[*:0]u8 = null;
    if (sqlite3_exec(db, sql_z.ptr, null, null, &errmsg) != SQLITE_OK) {
        if (errmsg) |msg| sqlite3_free(@ptrCast(msg));
        return error.SqliteExecFailed;
    }
}

fn prepareSql(allocator: std.mem.Allocator, db: *sqlite3, sql: []const u8) !*sqlite3_stmt {
    const sql_z = try allocator.dupeZ(u8, sql);
    var maybe_stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(db, sql_z.ptr, -1, &maybe_stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
    return maybe_stmt orelse error.SqlitePrepareFailed;
}

fn finalizeSql(stmt: *sqlite3_stmt) void {
    _ = sqlite3_finalize(stmt);
}

fn bindText(stmt: *sqlite3_stmt, index: c_int, value: []const u8, allocator: std.mem.Allocator) !void {
    const value_z = try allocator.dupeZ(u8, value);
    if (sqlite3_bind_text(stmt, index, value_z.ptr, @intCast(value.len), null) != SQLITE_OK) return error.SqliteBindFailed;
}

fn stepDone(stmt: *sqlite3_stmt) !void {
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_DONE) return error.SqliteStepFailed;
}

fn columnText(allocator: std.mem.Allocator, stmt: *sqlite3_stmt, index: c_int) ![]u8 {
    const ptr = sqlite3_column_text(stmt, index) orelse return allocator.dupe(u8, "");
    const len: usize = @intCast(sqlite3_column_bytes(stmt, index));
    return allocator.dupe(u8, ptr[0..len]);
}

fn lifecycle(time: []const u8) schema.CognitiveLifecycle {
    return .{ .created_at = time, .updated_at = time };
}

fn parseTimestamp(text: []const u8) i64 {
    return std.fmt.parseInt(i64, text, 10) catch 0;
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

pub fn writeRawCognitiveJsonForTest(allocator: std.mem.Allocator, io: std.Io, path: []const u8, version: u32, json: []const u8) !void {
    const db = try openMemoryDb(allocator, io, path);
    defer _ = sqlite3_close(db);
    try initMemorySchema(allocator, db);
    try writeCognitiveJsonToDb(allocator, db, version, json);
}
