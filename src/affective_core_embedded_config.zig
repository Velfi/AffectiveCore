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

pub fn configureHostProviderRouting(allocator: std.mem.Allocator, env: *std.process.Environ.Map, raw: AffectiveCoreEmbeddedConfig) !void {
    try tryConfigureHostProviderRouting(allocator, env, raw);
}

pub fn tryConfigureHostProviderRouting(allocator: std.mem.Allocator, env: *std.process.Environ.Map, raw: AffectiveCoreEmbeddedConfig) !void {
    if (try hostProviderRoutingAvailable(allocator, raw.host_manifest_json)) {
        try env.put(try allocator.dupe(u8, "AFFECTIVE_HOST_PROVIDER_ROUTING"), try allocator.dupe(u8, "1"));
    }
}

pub fn putEnvString(allocator: std.mem.Allocator, env: *std.process.Environ.Map, key: []const u8, value: AffectiveCoreEmbeddedString) !void {
    const raw = stringSlice(value) orelse return;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return;
    try env.put(try allocator.dupe(u8, key), try allocator.dupe(u8, trimmed));
}

fn hostProviderRoutingAvailable(allocator: std.mem.Allocator, manifest_json: AffectiveCoreEmbeddedString) !bool {
    const raw = stringSlice(manifest_json) orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return false;
    const Manifest = struct {
        capability_status: ?struct {
            provider_routing: []const u8 = "",
        } = null,
        host_provider_routing: ?struct {
            configured_providers: []const []const u8 = &.{},
        } = null,
    };
    const parsed = std.json.parseFromSlice(Manifest, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    if (parsed.value.capability_status) |status| {
        if (std.mem.eql(u8, status.provider_routing, "available")) return true;
    }
    if (parsed.value.host_provider_routing) |routing| {
        return routing.configured_providers.len > 0;
    }
    return false;
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

test "embedded provider routing is configured from host manifest without credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env = std.process.Environ.Map.init(allocator);
    const manifest =
        \\{"capability_status":{"provider_routing":"available"},"host_provider_routing":{"configured_providers":["OpenAI"]}}
    ;
    var raw = AffectiveCoreEmbeddedConfig{};
    raw.host_manifest_json = .{ .ptr = manifest.ptr, .len = manifest.len };

    try tryConfigureHostProviderRouting(allocator, &env, raw);

    try std.testing.expectEqualStrings("1", env.get("AFFECTIVE_HOST_PROVIDER_ROUTING") orelse "");
    try std.testing.expect(env.get("OPENAI_API_KEY") == null);
    try std.testing.expect(env.get("ANTHROPIC_API_KEY") == null);
    try std.testing.expect(env.get("GEMINI_API_KEY") == null);
}
