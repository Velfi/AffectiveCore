const std = @import("std");

const database_stats = @import("../platform/common/database_stats.zig");
const senses = @import("../platform/common/system_senses.zig");
const graph_store = @import("graph_store.zig");
const json_store = @import("json_store.zig");
const store_mod = @import("store.zig");

pub const BrainStorage = struct {
    memory_impl: *json_store.JsonMemoryStore,
    graph_impl: *graph_store.SqliteGraphStore,
    memory_path: []const u8,
    graph_path: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        memory_path: []const u8,
        events_path: []const u8,
        graph_path: []const u8,
        captures_dir: []const u8,
    ) !BrainStorage {
        const memory_impl = try allocator.create(json_store.JsonMemoryStore);
        memory_impl.* = if (captures_dir.len > 0)
            json_store.JsonMemoryStore.initWithCaptureDir(allocator, io, memory_path, events_path, captures_dir)
        else
            json_store.JsonMemoryStore.init(allocator, io, memory_path, events_path);

        const graph_impl = try allocator.create(graph_store.SqliteGraphStore);
        graph_impl.* = try graph_store.SqliteGraphStore.init(allocator, io, graph_path);

        return .{
            .memory_impl = memory_impl,
            .graph_impl = graph_impl,
            .memory_path = memory_path,
            .graph_path = graph_path,
        };
    }

    pub fn deinit(self: *BrainStorage, allocator: std.mem.Allocator) void {
        self.graph_impl.deinit();
        allocator.destroy(self.graph_impl);
        allocator.destroy(self.memory_impl);
    }

    pub fn memoryStore(self: BrainStorage) store_mod.MemoryStore {
        return self.memory_impl.store();
    }

    pub fn graphStore(self: BrainStorage) graph_store.GraphStore {
        return self.graph_impl.store();
    }

    pub fn commandMemoryPath(self: BrainStorage) []const u8 {
        return self.memory_path;
    }

    pub fn databaseSnapshot(self: BrainStorage, allocator: std.mem.Allocator) !senses.DatabaseSnapshot {
        return database_stats.readDatabases(allocator, self.memory_path, self.graph_path);
    }

    pub fn databaseSenses(self: *BrainStorage) senses.DatabaseSenses {
        return .{ .ctx = self, .snapshotFn = databaseSnapshotFromContext };
    }

    fn databaseSnapshotFromContext(ctx: *anyopaque, allocator: std.mem.Allocator) !senses.DatabaseSnapshot {
        const self: *BrainStorage = @ptrCast(@alignCast(ctx));
        return self.databaseSnapshot(allocator);
    }
};
