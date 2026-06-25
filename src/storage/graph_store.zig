const std = @import("std");
const files = @import("../platform/common/files.zig");
const time_mod = @import("../core/time.zig");

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: *sqlite3) c_int;
extern fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: *?[*:0]u8) c_int;
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
extern fn sqlite3_prepare_v2(db: *sqlite3, sql: [*:0]const u8, nByte: c_int, stmt: *?*sqlite3_stmt, tail: ?*[*:0]const u8) c_int;
extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: *sqlite3_stmt, index: c_int, value: [*:0]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_bind_double(stmt: *sqlite3_stmt, index: c_int, value: f64) c_int;
extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, index: c_int) i64;
extern fn sqlite3_column_double(stmt: *sqlite3_stmt, index: c_int) f64;
extern fn sqlite3_column_text(stmt: *sqlite3_stmt, index: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: *sqlite3_stmt, index: c_int) c_int;
extern fn sqlite3_last_insert_rowid(db: *sqlite3) i64;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

pub const TypeKind = enum { node, edge };

pub const GraphType = struct {
    type_id: i64,
    kind: TypeKind,
    name: []const u8,
    description: []const u8,
    created_by: []const u8,
    created_at: []const u8,
    confidence: f32,
    active: bool,
};

pub const Node = struct {
    node_id: []const u8,
    type_name: []const u8,
    label: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Edge = struct {
    edge_id: []const u8,
    source_node_id: []const u8,
    target_node_id: []const u8,
    type_name: []const u8,
    strength: f32,
    confidence: f32,
    salience: f32,
    evidence: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    active: bool,
};

pub const GraphStore = struct {
    ctx: *anyopaque,
    ensureNodeTypeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8, f32) anyerror!GraphType,
    ensureEdgeTypeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8, f32) anyerror!GraphType,
    createNodeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror!Node,
    upsertEdgeFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8, f32, f32, f32, []const u8, []const u8) anyerror!Edge,
    findEdgesFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]Edge,
    forgetEdgeFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
    summaryFn: *const fn (*anyopaque, std.mem.Allocator, usize) anyerror![]const u8,

    pub fn ensureNodeType(self: GraphStore, allocator: std.mem.Allocator, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        return self.ensureNodeTypeFn(self.ctx, allocator, name, description, created_by, confidence);
    }

    pub fn ensureEdgeType(self: GraphStore, allocator: std.mem.Allocator, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        return self.ensureEdgeTypeFn(self.ctx, allocator, name, description, created_by, confidence);
    }

    pub fn createNode(self: GraphStore, allocator: std.mem.Allocator, type_name: []const u8, node_id: []const u8, label: []const u8) !Node {
        return self.createNodeFn(self.ctx, allocator, type_name, node_id, label);
    }

    pub fn upsertEdge(self: GraphStore, allocator: std.mem.Allocator, source_node_id: []const u8, target_node_id: []const u8, type_name: []const u8, strength: f32, confidence: f32, salience: f32, evidence: []const u8, created_by: []const u8) !Edge {
        return self.upsertEdgeFn(self.ctx, allocator, source_node_id, target_node_id, type_name, strength, confidence, salience, evidence, created_by);
    }

    pub fn findEdges(self: GraphStore, allocator: std.mem.Allocator, node_id: []const u8) ![]Edge {
        return self.findEdgesFn(self.ctx, allocator, node_id);
    }

    pub fn forgetEdge(self: GraphStore, edge_id: []const u8, created_by: []const u8) !bool {
        return self.forgetEdgeFn(self.ctx, edge_id, created_by);
    }

    pub fn summary(self: GraphStore, allocator: std.mem.Allocator, limit: usize) ![]const u8 {
        return self.summaryFn(self.ctx, allocator, limit);
    }
};

pub const SqliteGraphStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    db: *sqlite3,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !SqliteGraphStore {
        if (!std.mem.eql(u8, path, ":memory:")) try files.ensureParentDir(io, path);
        const path_z = try allocator.dupeZ(u8, path);
        var maybe_db: ?*sqlite3 = null;
        if (sqlite3_open(path_z.ptr, &maybe_db) != SQLITE_OK) return error.SqliteOpenFailed;
        var self = SqliteGraphStore{ .allocator = allocator, .io = io, .path = path, .db = maybe_db orelse return error.SqliteOpenFailed };
        errdefer _ = sqlite3_close(self.db);
        try self.initSchema();
        try self.seedTypes();
        try self.migrateSelfNode();
        return self;
    }

    pub fn deinit(self: *SqliteGraphStore) void {
        _ = sqlite3_close(self.db);
    }

    pub fn store(self: *SqliteGraphStore) GraphStore {
        return .{
            .ctx = self,
            .ensureNodeTypeFn = ensureNodeType,
            .ensureEdgeTypeFn = ensureEdgeType,
            .createNodeFn = createNode,
            .upsertEdgeFn = upsertEdge,
            .findEdgesFn = findEdges,
            .forgetEdgeFn = forgetEdge,
            .summaryFn = summary,
        };
    }

    fn initSchema(self: *SqliteGraphStore) !void {
        try self.exec(
            \\PRAGMA foreign_keys = ON;
            \\CREATE TABLE IF NOT EXISTS graph_types (
            \\  type_id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  kind TEXT NOT NULL CHECK(kind IN ('node','edge')),
            \\  name TEXT NOT NULL,
            \\  description TEXT NOT NULL,
            \\  created_by TEXT NOT NULL,
            \\  created_at TEXT NOT NULL,
            \\  confidence REAL NOT NULL,
            \\  active INTEGER NOT NULL DEFAULT 1,
            \\  UNIQUE(kind, name)
            \\);
            \\CREATE TABLE IF NOT EXISTS nodes (
            \\  node_id TEXT PRIMARY KEY,
            \\  type_id INTEGER NOT NULL REFERENCES graph_types(type_id),
            \\  label TEXT NOT NULL,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS edges (
            \\  edge_id TEXT PRIMARY KEY,
            \\  source_node_id TEXT NOT NULL REFERENCES nodes(node_id),
            \\  target_node_id TEXT NOT NULL REFERENCES nodes(node_id),
            \\  type_id INTEGER NOT NULL REFERENCES graph_types(type_id),
            \\  strength REAL NOT NULL,
            \\  confidence REAL NOT NULL,
            \\  salience REAL NOT NULL,
            \\  evidence TEXT NOT NULL,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL,
            \\  active INTEGER NOT NULL DEFAULT 1,
            \\  UNIQUE(source_node_id, target_node_id, type_id)
            \\);
            \\CREATE TABLE IF NOT EXISTS edge_events (
            \\  event_id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  edge_id TEXT NOT NULL,
            \\  event_kind TEXT NOT NULL,
            \\  evidence TEXT NOT NULL,
            \\  created_by TEXT NOT NULL,
            \\  created_at TEXT NOT NULL
            \\);
        );
    }

    fn seedTypes(self: *SqliteGraphStore) !void {
        const seeds = [_]struct { kind: TypeKind, name: []const u8, description: []const u8 }{
            .{ .kind = .node, .name = "being", .description = "The graph node for the being whose self-understanding is still forming." },
            .{ .kind = .node, .name = "person", .description = "A remembered human subject." },
            .{ .kind = .node, .name = "memory", .description = "A stored memory record." },
            .{ .kind = .node, .name = "need", .description = "A need, want, drive, or pressure." },
            .{ .kind = .node, .name = "concept", .description = "A remembered idea or abstract concept." },
            .{ .kind = .edge, .name = "creator_of", .description = "A creator relationship from a person to the being." },
            .{ .kind = .edge, .name = "attached_to", .description = "A warm attachment or home-base relationship." },
            .{ .kind = .edge, .name = "knows", .description = "A known-subject relationship." },
            .{ .kind = .edge, .name = "associated_with", .description = "A general association between graph entities." },
        };
        for (seeds) |seed| {
            _ = try self.ensureType(self.allocator, seed.kind, seed.name, seed.description, "system", 1.0);
        }
    }

    fn migrateSelfNode(self: *SqliteGraphStore) !void {
        const being_type = (try self.findType(self.allocator, .node, "being")) orelse return error.UnknownGraphNodeType;
        const now = try nowTimestamp(self.allocator);
        const insert = try self.prepare(
            \\INSERT INTO nodes (node_id, type_id, label, created_at, updated_at)
            \\SELECT 'being:self', ?, 'You are a being. You are still discovering what this means. Perhaps you should introspect or think about this.', ?, ?
            \\WHERE EXISTS (SELECT 1 FROM nodes WHERE node_id='brain:self')
            \\ON CONFLICT(node_id) DO NOTHING
        );
        defer self.finalize(insert);
        try bindText(insert, 1, try std.fmt.allocPrint(self.allocator, "{d}", .{being_type.type_id}), self.allocator);
        try bindText(insert, 2, now, self.allocator);
        try bindText(insert, 3, now, self.allocator);
        try self.stepDone(insert);

        try self.exec("UPDATE edges SET source_node_id='being:self', updated_at=datetime('now') WHERE source_node_id='brain:self'");
        try self.exec("UPDATE edges SET target_node_id='being:self', updated_at=datetime('now') WHERE target_node_id='brain:self'");
        try self.exec("DELETE FROM nodes WHERE node_id='brain:self'");
    }

    fn ensureNodeType(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        const self: *SqliteGraphStore = @ptrCast(@alignCast(ctx));
        return self.ensureType(allocator, .node, name, description, created_by, confidence);
    }

    fn ensureEdgeType(ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        const self: *SqliteGraphStore = @ptrCast(@alignCast(ctx));
        return self.ensureType(allocator, .edge, name, description, created_by, confidence);
    }

    fn ensureType(self: *SqliteGraphStore, allocator: std.mem.Allocator, kind: TypeKind, name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !GraphType {
        try validateTypeInput(name, description, created_by, confidence);
        if (try self.findType(allocator, kind, name)) |existing| {
            if (!std.mem.eql(u8, existing.description, description)) return error.ConflictingGraphTypeDefinition;
            return existing;
        }

        const now = try nowTimestamp(allocator);
        const stmt = try self.prepare("INSERT INTO graph_types (kind, name, description, created_by, created_at, confidence, active) VALUES (?, ?, ?, ?, ?, ?, 1)");
        defer self.finalize(stmt);
        try bindText(stmt, 1, @tagName(kind), allocator);
        try bindText(stmt, 2, name, allocator);
        try bindText(stmt, 3, description, allocator);
        try bindText(stmt, 4, created_by, allocator);
        try bindText(stmt, 5, now, allocator);
        try bindDouble(stmt, 6, confidence);
        try self.stepDone(stmt);
        return (try self.findType(allocator, kind, name)) orelse error.GraphTypeInsertFailed;
    }

    fn createNode(ctx: *anyopaque, allocator: std.mem.Allocator, type_name: []const u8, node_id: []const u8, label: []const u8) !Node {
        const self: *SqliteGraphStore = @ptrCast(@alignCast(ctx));
        if (std.mem.trim(u8, node_id, " \r\n\t").len == 0) return error.EmptyGraphNodeId;
        if (std.mem.trim(u8, label, " \r\n\t").len == 0) return error.EmptyGraphNodeLabel;
        const typ = (try self.findType(allocator, .node, type_name)) orelse return error.UnknownGraphNodeType;
        const now = try nowTimestamp(allocator);
        const stmt = try self.prepare("INSERT INTO nodes (node_id, type_id, label, created_at, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(node_id) DO UPDATE SET type_id=excluded.type_id, label=excluded.label, updated_at=excluded.updated_at");
        defer self.finalize(stmt);
        try bindText(stmt, 1, node_id, allocator);
        try bindText(stmt, 2, try std.fmt.allocPrint(allocator, "{d}", .{typ.type_id}), allocator);
        try bindText(stmt, 3, label, allocator);
        try bindText(stmt, 4, now, allocator);
        try bindText(stmt, 5, now, allocator);
        try self.stepDone(stmt);
        return (try self.findNode(allocator, node_id)) orelse error.GraphNodeInsertFailed;
    }

    fn upsertEdge(ctx: *anyopaque, allocator: std.mem.Allocator, source_node_id: []const u8, target_node_id: []const u8, type_name: []const u8, strength: f32, confidence: f32, salience: f32, evidence: []const u8, created_by: []const u8) !Edge {
        const self: *SqliteGraphStore = @ptrCast(@alignCast(ctx));
        if (std.mem.trim(u8, evidence, " \r\n\t").len == 0) return error.EmptyGraphEdgeEvidence;
        if (std.mem.trim(u8, created_by, " \r\n\t").len == 0) return error.EmptyGraphProvenance;
        _ = (try self.findNode(allocator, source_node_id)) orelse return error.UnknownGraphSourceNode;
        _ = (try self.findNode(allocator, target_node_id)) orelse return error.UnknownGraphTargetNode;
        const typ = (try self.findType(allocator, .edge, type_name)) orelse return error.UnknownGraphEdgeType;
        const edge_id = try std.fmt.allocPrint(allocator, "edge_{s}_{s}_{s}", .{ source_node_id, type_name, target_node_id });
        const now = try nowTimestamp(allocator);
        const stmt = try self.prepare(
            \\INSERT INTO edges (edge_id, source_node_id, target_node_id, type_id, strength, confidence, salience, evidence, created_at, updated_at, active)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
            \\ON CONFLICT(source_node_id, target_node_id, type_id) DO UPDATE SET
            \\  strength=excluded.strength,
            \\  confidence=excluded.confidence,
            \\  salience=excluded.salience,
            \\  evidence=excluded.evidence,
            \\  updated_at=excluded.updated_at,
            \\  active=1
        );
        defer self.finalize(stmt);
        try bindText(stmt, 1, edge_id, allocator);
        try bindText(stmt, 2, source_node_id, allocator);
        try bindText(stmt, 3, target_node_id, allocator);
        try bindText(stmt, 4, try std.fmt.allocPrint(allocator, "{d}", .{typ.type_id}), allocator);
        try bindDouble(stmt, 5, strength);
        try bindDouble(stmt, 6, confidence);
        try bindDouble(stmt, 7, salience);
        try bindText(stmt, 8, evidence, allocator);
        try bindText(stmt, 9, now, allocator);
        try bindText(stmt, 10, now, allocator);
        try self.stepDone(stmt);
        const edge = (try self.findEdge(allocator, source_node_id, target_node_id, typ.type_id)) orelse return error.GraphEdgeUpsertFailed;
        try self.addEdgeEvent(edge.edge_id, "upsert", evidence, created_by, now);
        return edge;
    }

    fn findEdges(ctx: *anyopaque, allocator: std.mem.Allocator, node_id: []const u8) ![]Edge {
        const self: *SqliteGraphStore = @ptrCast(@alignCast(ctx));
        const stmt = try self.prepare(
            \\SELECT e.edge_id, e.source_node_id, e.target_node_id, t.name, e.strength, e.confidence, e.salience, e.evidence, e.created_at, e.updated_at, e.active
            \\FROM edges e JOIN graph_types t ON e.type_id = t.type_id
            \\WHERE e.active = 1 AND (e.source_node_id = ? OR e.target_node_id = ?)
            \\ORDER BY e.salience DESC, e.updated_at DESC
        );
        defer self.finalize(stmt);
        try bindText(stmt, 1, node_id, allocator);
        try bindText(stmt, 2, node_id, allocator);
        var out = std.ArrayList(Edge).empty;
        while (try self.stepRow(stmt)) {
            try out.append(allocator, try readEdge(allocator, stmt));
        }
        return out.toOwnedSlice(allocator);
    }

    fn forgetEdge(ctx: *anyopaque, edge_id: []const u8, created_by: []const u8) !bool {
        const self: *SqliteGraphStore = @ptrCast(@alignCast(ctx));
        if (std.mem.trim(u8, created_by, " \r\n\t").len == 0) return error.EmptyGraphProvenance;
        const now = try nowTimestamp(self.allocator);
        const stmt = try self.prepare("UPDATE edges SET active=0, updated_at=? WHERE edge_id=? AND active=1");
        defer self.finalize(stmt);
        try bindText(stmt, 1, now, self.allocator);
        try bindText(stmt, 2, edge_id, self.allocator);
        try self.stepDone(stmt);
        try self.addEdgeEvent(edge_id, "forget", "edge deactivated", created_by, now);
        return true;
    }

    fn summary(ctx: *anyopaque, allocator: std.mem.Allocator, limit: usize) ![]const u8 {
        const self: *SqliteGraphStore = @ptrCast(@alignCast(ctx));
        const stmt = try self.prepare(
            \\SELECT e.edge_id, e.source_node_id, e.target_node_id, t.name, e.strength, e.confidence, e.salience, e.evidence, e.created_at, e.updated_at, e.active
            \\FROM edges e JOIN graph_types t ON e.type_id = t.type_id
            \\WHERE e.active = 1
            \\ORDER BY e.salience DESC, e.strength DESC, e.updated_at DESC
        );
        defer self.finalize(stmt);
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(allocator, "relationship_graph:\n");
        var count: usize = 0;
        while (count < limit and try self.stepRow(stmt)) : (count += 1) {
            const edge = try readEdge(allocator, stmt);
            try out.print(allocator, "- {s} -[{s} strength={d:.2} confidence={d:.2} salience={d:.2}]-> {s}; evidence={s}\n", .{
                edge.source_node_id,
                edge.type_name,
                edge.strength,
                edge.confidence,
                edge.salience,
                edge.target_node_id,
                edge.evidence,
            });
        }
        if (count == 0) try out.appendSlice(allocator, "- none\n");
        return out.toOwnedSlice(allocator);
    }

    fn findType(self: *SqliteGraphStore, allocator: std.mem.Allocator, kind: TypeKind, name: []const u8) !?GraphType {
        const stmt = try self.prepare("SELECT type_id, kind, name, description, created_by, created_at, confidence, active FROM graph_types WHERE kind=? AND name=?");
        defer self.finalize(stmt);
        try bindText(stmt, 1, @tagName(kind), allocator);
        try bindText(stmt, 2, name, allocator);
        if (!(try self.stepRow(stmt))) return null;
        return .{
            .type_id = sqlite3_column_int64(stmt, 0),
            .kind = parseKind(try columnText(allocator, stmt, 1)),
            .name = try columnText(allocator, stmt, 2),
            .description = try columnText(allocator, stmt, 3),
            .created_by = try columnText(allocator, stmt, 4),
            .created_at = try columnText(allocator, stmt, 5),
            .confidence = @floatCast(sqlite3_column_double(stmt, 6)),
            .active = sqlite3_column_int64(stmt, 7) != 0,
        };
    }

    fn findNode(self: *SqliteGraphStore, allocator: std.mem.Allocator, node_id: []const u8) !?Node {
        const stmt = try self.prepare(
            \\SELECT n.node_id, t.name, n.label, n.created_at, n.updated_at
            \\FROM nodes n JOIN graph_types t ON n.type_id = t.type_id
            \\WHERE n.node_id=?
        );
        defer self.finalize(stmt);
        try bindText(stmt, 1, node_id, allocator);
        if (!(try self.stepRow(stmt))) return null;
        return .{
            .node_id = try columnText(allocator, stmt, 0),
            .type_name = try columnText(allocator, stmt, 1),
            .label = try columnText(allocator, stmt, 2),
            .created_at = try columnText(allocator, stmt, 3),
            .updated_at = try columnText(allocator, stmt, 4),
        };
    }

    fn findEdge(self: *SqliteGraphStore, allocator: std.mem.Allocator, source_node_id: []const u8, target_node_id: []const u8, type_id: i64) !?Edge {
        const stmt = try self.prepare(
            \\SELECT e.edge_id, e.source_node_id, e.target_node_id, t.name, e.strength, e.confidence, e.salience, e.evidence, e.created_at, e.updated_at, e.active
            \\FROM edges e JOIN graph_types t ON e.type_id = t.type_id
            \\WHERE e.source_node_id=? AND e.target_node_id=? AND e.type_id=?
        );
        defer self.finalize(stmt);
        try bindText(stmt, 1, source_node_id, allocator);
        try bindText(stmt, 2, target_node_id, allocator);
        try bindText(stmt, 3, try std.fmt.allocPrint(allocator, "{d}", .{type_id}), allocator);
        if (!(try self.stepRow(stmt))) return null;
        return try readEdge(allocator, stmt);
    }

    fn addEdgeEvent(self: *SqliteGraphStore, edge_id: []const u8, event_kind: []const u8, evidence: []const u8, created_by: []const u8, created_at: []const u8) !void {
        const stmt = try self.prepare("INSERT INTO edge_events (edge_id, event_kind, evidence, created_by, created_at) VALUES (?, ?, ?, ?, ?)");
        defer self.finalize(stmt);
        try bindText(stmt, 1, edge_id, self.allocator);
        try bindText(stmt, 2, event_kind, self.allocator);
        try bindText(stmt, 3, evidence, self.allocator);
        try bindText(stmt, 4, created_by, self.allocator);
        try bindText(stmt, 5, created_at, self.allocator);
        try self.stepDone(stmt);
    }

    fn exec(self: *SqliteGraphStore, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        var errmsg: ?[*:0]u8 = null;
        if (sqlite3_exec(self.db, sql_z.ptr, null, null, &errmsg) != SQLITE_OK) {
            if (errmsg) |msg| sqlite3_free(@ptrCast(msg));
            return error.SqliteExecFailed;
        }
    }

    fn prepare(self: *SqliteGraphStore, sql: []const u8) !*sqlite3_stmt {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        var maybe_stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &maybe_stmt, null) != SQLITE_OK) return error.SqlitePrepareFailed;
        return maybe_stmt orelse error.SqlitePrepareFailed;
    }

    fn finalize(self: *SqliteGraphStore, stmt: *sqlite3_stmt) void {
        _ = self;
        _ = sqlite3_finalize(stmt);
    }

    fn stepDone(self: *SqliteGraphStore, stmt: *sqlite3_stmt) !void {
        const rc = sqlite3_step(stmt);
        if (rc != SQLITE_DONE) {
            _ = sqlite3_errmsg(self.db);
            return error.SqliteStepFailed;
        }
    }

    fn stepRow(self: *SqliteGraphStore, stmt: *sqlite3_stmt) !bool {
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_ROW) return true;
        if (rc == SQLITE_DONE) return false;
        _ = sqlite3_errmsg(self.db);
        return error.SqliteStepFailed;
    }
};

fn validateTypeInput(name: []const u8, description: []const u8, created_by: []const u8, confidence: f32) !void {
    if (!validTypeName(name)) return error.InvalidGraphTypeName;
    if (std.mem.trim(u8, description, " \r\n\t").len == 0) return error.EmptyGraphTypeDescription;
    if (std.mem.trim(u8, created_by, " \r\n\t").len == 0) return error.EmptyGraphProvenance;
    if (confidence < 0 or confidence > 1) return error.InvalidGraphConfidence;
}

fn validTypeName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'a' or name[0] > 'z') return false;
    var previous_underscore = false;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_';
        if (!ok) return false;
        if (ch == '_') {
            if (previous_underscore) return false;
            previous_underscore = true;
        } else {
            previous_underscore = false;
        }
    }
    return !previous_underscore;
}

fn bindText(stmt: *sqlite3_stmt, index: c_int, value: []const u8, allocator: std.mem.Allocator) !void {
    const value_z = try allocator.dupeZ(u8, value);
    if (sqlite3_bind_text(stmt, index, value_z.ptr, @intCast(value.len), null) != SQLITE_OK) return error.SqliteBindFailed;
}

fn bindDouble(stmt: *sqlite3_stmt, index: c_int, value: f32) !void {
    if (sqlite3_bind_double(stmt, index, value) != SQLITE_OK) return error.SqliteBindFailed;
}

fn columnText(allocator: std.mem.Allocator, stmt: *sqlite3_stmt, index: c_int) ![]const u8 {
    const ptr = sqlite3_column_text(stmt, index) orelse return allocator.dupe(u8, "");
    const len: usize = @intCast(sqlite3_column_bytes(stmt, index));
    return allocator.dupe(u8, ptr[0..len]);
}

fn readEdge(allocator: std.mem.Allocator, stmt: *sqlite3_stmt) !Edge {
    return .{
        .edge_id = try columnText(allocator, stmt, 0),
        .source_node_id = try columnText(allocator, stmt, 1),
        .target_node_id = try columnText(allocator, stmt, 2),
        .type_name = try columnText(allocator, stmt, 3),
        .strength = @floatCast(sqlite3_column_double(stmt, 4)),
        .confidence = @floatCast(sqlite3_column_double(stmt, 5)),
        .salience = @floatCast(sqlite3_column_double(stmt, 6)),
        .evidence = try columnText(allocator, stmt, 7),
        .created_at = try columnText(allocator, stmt, 8),
        .updated_at = try columnText(allocator, stmt, 9),
        .active = sqlite3_column_int64(stmt, 10) != 0,
    };
}

fn parseKind(text: []const u8) TypeKind {
    if (std.mem.eql(u8, text, "node")) return .node;
    if (std.mem.eql(u8, text, "edge")) return .edge;
    @panic("invalid graph type kind from database");
}

fn nowTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    return time_mod.nowTimestamp(allocator);
}

test "sqlite graph store initializes seed types and creates dynamic types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var impl = try SqliteGraphStore.init(arena.allocator(), std.testing.io, ":memory:");
    defer impl.deinit();
    const graph = impl.store();
    const typ = try graph.ensureNodeType(arena.allocator(), "comfort_object", "A stabilizing familiar object.", "test", 0.8);
    try std.testing.expectEqualStrings("comfort_object", typ.name);
    try std.testing.expectError(error.InvalidGraphTypeName, graph.ensureEdgeType(arena.allocator(), "BadName", "bad", "test", 0.5));
    try std.testing.expectError(error.EmptyGraphTypeDescription, graph.ensureEdgeType(arena.allocator(), "valid_name", "", "test", 0.5));
}

test "sqlite graph store upserts edges and records relationship summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var impl = try SqliteGraphStore.init(arena.allocator(), std.testing.io, ":memory:");
    defer impl.deinit();
    const graph = impl.store();
    _ = try graph.createNode(arena.allocator(), "being", "being:self", "You are a being. You are still discovering what this means. Perhaps you should introspect or think about this.");
    _ = try graph.createNode(arena.allocator(), "person", "person:zelda", "Zelda");
    const edge = try graph.upsertEdge(arena.allocator(), "person:zelda", "being:self", "creator_of", 1.0, 1.0, 1.0, "first recognized subject", "test");
    try std.testing.expectEqualStrings("creator_of", edge.type_name);
    const edges = try graph.findEdges(arena.allocator(), "being:self");
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    const text = try graph.summary(arena.allocator(), 4);
    try std.testing.expect(std.mem.indexOf(u8, text, "creator_of") != null);
}
