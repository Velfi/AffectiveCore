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
        .maintenance_schedule_path = try requiredString(allocator, raw.schedule_path),
        .maintenance_state_path = try requiredString(allocator, raw.maintenance_state_path),
        .face_embeddings_dir = try stringOrDefault(allocator, raw.face_embeddings_dir, ""),
    };
    cfg.runtime_options_path = try std.fs.path.join(allocator, &.{ cfg.brain_root, "runtime_options.json" });
    cfg.llm_providers_path = try std.fs.path.join(allocator, &.{ cfg.brain_root, "llm_providers.json" });
    if (cfg.image_generation_output_dir.len == 0) {
        cfg.image_generation_output_dir = try std.fs.path.join(allocator, &.{ cfg.brain_root, "generated", "images" });
    }
    cfg.ai_mode = "random";
    cfg.intent_mode = "random";
    cfg.speech_mode = "speak-n-spell";
    cfg.autonomy_mode = "off";
    try inheritPsycheModelsFromConversation(allocator, &cfg);
    try cfg.ensureRostersFromModelSpecs(allocator);
    return cfg;
}

fn inheritPsycheModelsFromConversation(allocator: std.mem.Allocator, cfg: *config_mod.Config) !void {
    if (std.mem.trim(u8, cfg.psyche_models, " \r\n\t").len > 0) return;
    const conversation_models = std.mem.trim(u8, cfg.conversation_models, " \r\n\t");
    if (conversation_models.len == 0) return;
    cfg.psyche_models = try allocator.dupe(u8, conversation_models);
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
    cfg.maintenance_schedule_path = try requiredString(allocator, raw.schedule_path);
    cfg.maintenance_state_path = try requiredString(allocator, raw.maintenance_state_path);
    cfg.runtime_options_path = try std.fs.path.join(allocator, &.{ cfg.brain_root, "runtime_options.json" });
    cfg.llm_providers_path = try std.fs.path.join(allocator, &.{ cfg.brain_root, "llm_providers.json" });
    cfg.face_embeddings_dir = try stringOrDefault(allocator, raw.face_embeddings_dir, "");
    cfg.image_generation_output_dir = try stringOrDefault(allocator, raw.image_generation_output_dir, "");
    if (cfg.image_generation_output_dir.len == 0) {
        cfg.image_generation_output_dir = try std.fs.path.join(allocator, &.{ cfg.brain_root, "generated", "images" });
    }
    return cfg;
}

fn replacePathPrefix(allocator: std.mem.Allocator, path: []const u8, old_prefix: []const u8, new_prefix: []const u8) ![]const u8 {
    if (path.len == 0) return allocator.dupe(u8, "");
    if (old_prefix.len > 0 and std.mem.startsWith(u8, path, old_prefix)) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ new_prefix, path[old_prefix.len..] });
    }
    return allocator.dupe(u8, path);
}

pub fn rebindConfigBrainRoot(
    allocator: std.mem.Allocator,
    cfg: config_mod.Config,
    new_brain_id: []const u8,
    new_brain_root: []const u8,
) !config_mod.Config {
    const old_root = cfg.brain_root;
    var next = cfg;
    next.brain_id = try allocator.dupe(u8, new_brain_id);
    next.brain_root = try allocator.dupe(u8, new_brain_root);
    next.memory_path = try replacePathPrefix(allocator, cfg.memory_path, old_root, new_brain_root);
    next.graph_path = try replacePathPrefix(allocator, cfg.graph_path, old_root, new_brain_root);
    next.seed_path = try replacePathPrefix(allocator, cfg.seed_path, old_root, new_brain_root);
    next.maintenance_schedule_path = try replacePathPrefix(allocator, cfg.maintenance_schedule_path, old_root, new_brain_root);
    next.maintenance_state_path = try replacePathPrefix(allocator, cfg.maintenance_state_path, old_root, new_brain_root);
    next.runtime_options_path = try replacePathPrefix(allocator, cfg.runtime_options_path, old_root, new_brain_root);
    next.llm_providers_path = try replacePathPrefix(allocator, cfg.llm_providers_path, old_root, new_brain_root);
    next.captures_dir = try replacePathPrefix(allocator, cfg.captures_dir, old_root, new_brain_root);
    next.capture_scratch_dir = try replacePathPrefix(allocator, cfg.capture_scratch_dir, old_root, new_brain_root);
    next.audio_input_dir = try replacePathPrefix(allocator, cfg.audio_input_dir, old_root, new_brain_root);
    next.audio_output_dir = try replacePathPrefix(allocator, cfg.audio_output_dir, old_root, new_brain_root);
    next.face_embeddings_dir = try replacePathPrefix(allocator, cfg.face_embeddings_dir, old_root, new_brain_root);
    next.image_generation_output_dir = try replacePathPrefix(allocator, cfg.image_generation_output_dir, old_root, new_brain_root);
    return next;
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

test "embedded makeConfig inherits psyche_models from conversation_models" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var raw = AffectiveCoreEmbeddedConfig{};
    raw.brain_root = .{ .ptr = "data/test/embedded_psyche_models".ptr, .len = "data/test/embedded_psyche_models".len };
    raw.memory_path = .{ .ptr = "data/test/embedded_psyche_models/memory/people.sqlite".ptr, .len = "data/test/embedded_psyche_models/memory/people.sqlite".len };
    raw.graph_path = .{ .ptr = "data/test/embedded_psyche_models/memory/relationships.sqlite".ptr, .len = "data/test/embedded_psyche_models/memory/relationships.sqlite".len };
    raw.schedule_path = .{ .ptr = "data/test/embedded_psyche_models/maintenance.md".ptr, .len = "data/test/embedded_psyche_models/maintenance.md".len };
    raw.maintenance_state_path = .{ .ptr = "data/test/embedded_psyche_models/maintenance_state.json".ptr, .len = "data/test/embedded_psyche_models/maintenance_state.json".len };
    raw.conversation_models = .{ .ptr = "openai:gpt-4.1-nano".ptr, .len = "openai:gpt-4.1-nano".len };

    const cfg = try makeConfig(allocator, raw);

    try std.testing.expectEqualStrings("openai:gpt-4.1-nano", cfg.conversation_models);
    try std.testing.expectEqualStrings("openai:gpt-4.1-nano", cfg.psyche_models);
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
