const std = @import("std");
const files = @import("platform/common/files.zig");
const config_mod = @import("core/config.zig");
const embedded = @import("affective_core_embedded.zig");

const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;
const AffectiveCoreEmbeddedConfig = embedded.AffectiveCoreEmbeddedConfig;

pub fn makeConfig(allocator: std.mem.Allocator, raw: AffectiveCoreEmbeddedConfig) !config_mod.Config {
    var cfg = config_mod.Config{
        .brain_id = try stringOrDefault(allocator, raw.brain_id, "default"),
        .brain_root = try stringOrDefault(allocator, raw.brain_root, ""),
        .conversation_models = try stringOrDefault(allocator, raw.conversation_models, ""),
        .conversation_reasoning_effort = try stringOrDefault(allocator, raw.conversation_reasoning_effort, "auto"),
        .image_generation_model = try stringOrDefault(allocator, raw.image_generation_model, "gemini-3.1-flash-image"),
        .image_generation_output_dir = try stringOrDefault(allocator, raw.image_generation_output_dir, ""),
        .memory_path = try requiredString(allocator, raw.memory_path),
        .graph_path = try requiredString(allocator, raw.graph_path),
        .events_path = try requiredString(allocator, raw.events_path),
        .maintenance_schedule_path = try requiredString(allocator, raw.schedule_path),
        .maintenance_state_path = try requiredString(allocator, raw.maintenance_state_path),
        .face_embeddings_dir = try stringOrDefault(allocator, raw.face_embeddings_dir, ""),
    };
    cfg.runtime_options_path = try std.fs.path.join(allocator, &.{ cfg.brain_root, "runtime_options.json" });
    if (cfg.image_generation_output_dir.len == 0) {
        cfg.image_generation_output_dir = try std.fs.path.join(allocator, &.{ cfg.brain_root, "generated", "images" });
    }
    cfg.ai_mode = "random";
    cfg.intent_mode = "random";
    cfg.speech_mode = "speak-n-spell";
    cfg.autonomy_mode = "off";
    return cfg;
}

pub fn restoreHostControlledPaths(
    allocator: std.mem.Allocator,
    raw: AffectiveCoreEmbeddedConfig,
    runtime_cfg: config_mod.Config,
) !config_mod.Config {
    var cfg = runtime_cfg;
    cfg.brain_id = try stringOrDefault(allocator, raw.brain_id, "default");
    cfg.brain_root = try requiredString(allocator, raw.brain_root);
    cfg.memory_path = try requiredString(allocator, raw.memory_path);
    cfg.graph_path = try requiredString(allocator, raw.graph_path);
    cfg.events_path = try requiredString(allocator, raw.events_path);
    cfg.maintenance_schedule_path = try requiredString(allocator, raw.schedule_path);
    cfg.maintenance_state_path = try requiredString(allocator, raw.maintenance_state_path);
    cfg.runtime_options_path = try std.fs.path.join(allocator, &.{ cfg.brain_root, "runtime_options.json" });
    cfg.face_embeddings_dir = try stringOrDefault(allocator, raw.face_embeddings_dir, "");
    cfg.image_generation_output_dir = try stringOrDefault(allocator, raw.image_generation_output_dir, "");
    if (cfg.image_generation_output_dir.len == 0) {
        cfg.image_generation_output_dir = try std.fs.path.join(allocator, &.{ cfg.brain_root, "generated", "images" });
    }
    return cfg;
}

pub fn seedProviderEnvironment(allocator: std.mem.Allocator, env: *std.process.Environ.Map, raw: AffectiveCoreEmbeddedConfig) !void {
    try trySeedProviderEnvironment(allocator, env, raw);
}

pub fn trySeedProviderEnvironment(allocator: std.mem.Allocator, env: *std.process.Environ.Map, raw: AffectiveCoreEmbeddedConfig) !void {
    try putEnvString(allocator, env, "OPENAI_API_KEY", raw.openai_api_key);
    try putEnvString(allocator, env, "ANTHROPIC_API_KEY", raw.anthropic_api_key);
    try putEnvString(allocator, env, "GEMINI_API_KEY", raw.google_api_key);
    try putEnvString(allocator, env, "GOOGLE_API_KEY", raw.google_api_key);
    try putEnvString(allocator, env, "GOOGLE_AI_API_KEY", raw.google_api_key);
}

pub fn putEnvString(allocator: std.mem.Allocator, env: *std.process.Environ.Map, key: []const u8, value: AffectiveCoreEmbeddedString) !void {
    const raw = stringSlice(value) orelse return;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return;
    try env.put(try allocator.dupe(u8, key), try allocator.dupe(u8, trimmed));
}

pub fn ensureParentDirs(io: std.Io, cfg: config_mod.Config) !void {
    inline for (.{
        cfg.memory_path,
        cfg.graph_path,
        cfg.events_path,
        cfg.maintenance_schedule_path,
        cfg.maintenance_state_path,
    }) |path| {
        try ensureParentDir(io, path);
    }
    if (cfg.face_embeddings_dir.len > 0) try ensureDir(io, cfg.face_embeddings_dir);
}

pub fn ensureParentDir(io: std.Io, path: []const u8) !void {
    return files.ensureParentDir(io, path);
}

pub fn ensureDir(io: std.Io, path: []const u8) !void {
    return files.ensureDir(io, path);
}

pub fn requiredString(allocator: std.mem.Allocator, string: AffectiveCoreEmbeddedString) ![]const u8 {
    const value = stringSlice(string) orelse return error.InvalidEmbeddedString;
    if (value.len == 0) return error.EmptyEmbeddedString;
    return allocator.dupe(u8, value);
}

pub fn stringOrDefault(allocator: std.mem.Allocator, string: AffectiveCoreEmbeddedString, default_value: []const u8) ![]const u8 {
    const value = stringSlice(string) orelse default_value;
    if (value.len == 0) return allocator.dupe(u8, default_value);
    return allocator.dupe(u8, value);
}

pub fn requiredSlice(ptr: ?[*]const u8, len: usize) ![]const u8 {
    if (len == 0) return error.EmptyEmbeddedString;
    const start = ptr orelse return error.InvalidEmbeddedString;
    return start[0..len];
}

pub fn optionalSlice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return "";
    const start = ptr orelse return null;
    return start[0..len];
}

pub fn stringSlice(string: AffectiveCoreEmbeddedString) ?[]const u8 {
    if (string.len == 0) return "";
    const ptr = string.ptr orelse return null;
    return ptr[0..string.len];
}
