const std = @import("std");
const config_mod = @import("../core/config.zig");

pub fn withBrainPathsFromEnv(base: config_mod.Config, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !config_mod.Config {
    const home = env.get("HOME") orelse return error.MissingHome;
    if (home.len == 0) return error.MissingHome;
    const tmp = env.get("TMPDIR") orelse return error.MissingTmpDir;
    if (tmp.len == 0) return error.MissingTmpDir;
    const persistent_root = try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "AffectiveCore" });
    const tmp_root = try std.fs.path.join(allocator, &.{ tmp, "affective-core" });
    return base.withBrainPathsForRoots(allocator, persistent_root, tmp_root);
}
