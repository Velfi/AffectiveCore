const std = @import("std");
const brain_config = @import("core/config.zig");

pub const Config = struct {
    brain_id: []const u8 = "default",
    brain_root: []const u8 = "data/brains/default",
    memory_path: []const u8 = "data/brains/default/memory/people.sqlite",
    graph_path: []const u8 = "data/brains/default/memory/relationships.sqlite",
    schedule_path: []const u8 = "data/brains/default/maintenance.md",
    face_embeddings_dir: []const u8 = "data/brains/default/memory/face_embeddings",

    pub fn toBrainConfig(self: Config) !brain_config.Config {
        return .{
            .brain_id = self.brain_id,
            .brain_root = self.brain_root,
            .memory_path = self.memory_path,
            .graph_path = self.graph_path,
            .maintenance_schedule_path = self.schedule_path,
            .face_embeddings_dir = self.face_embeddings_dir,
        };
    }
};

pub fn parseArgs(args: *std.process.Args.Iterator) !Config {
    var config = Config{};
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--brain")) {
            config.brain_id = args.next() orelse return error.MissingBrainId;
        } else if (std.mem.eql(u8, arg, "--brain-root")) {
            config.brain_root = args.next() orelse return error.MissingBrainRoot;
        } else if (std.mem.eql(u8, arg, "--memory-path")) {
            config.memory_path = args.next() orelse return error.MissingMemoryPath;
        } else if (std.mem.eql(u8, arg, "--graph-path")) {
            config.graph_path = args.next() orelse return error.MissingGraphPath;
        } else if (std.mem.eql(u8, arg, "--schedule-path")) {
            config.schedule_path = args.next() orelse return error.MissingSchedulePath;
        } else if (std.mem.eql(u8, arg, "--face-embeddings-dir")) {
            config.face_embeddings_dir = args.next() orelse return error.MissingFaceEmbeddingsDir;
        } else {
            return error.UnknownArgument;
        }
    }
    return config;
}
