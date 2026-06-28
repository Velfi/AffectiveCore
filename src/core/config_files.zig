const std = @import("std");
const ports = @import("ports.zig");
const files = ports.files;
const FileSystem = files.FileSystem;
const Config = @import("config.zig").Config;
const CapacityConfig = @import("config.zig").CapacityConfig;
const CapacityConfigPartial = @import("config.zig").CapacityConfigPartial;
const cognitive_capacity = @import("cognitive_capacity.zig");
const llm_routing = @import("llm_routing.zig");

const LlmModelEntry = llm_routing.RosterModelEntry;

const llm_providers_template_json = @embedFile("../fixtures/llm_providers.json");

const LlmConfigFile = struct {
    mode: ?[]const u8 = null,
    llm_quality: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    psyche_reasoning_effort: ?[]const u8 = null,
    models: []const LlmModelEntry = &.{},
    psyche_models: []const LlmModelEntry = &.{},
};

pub const LoadedLlmConfig = struct {
    mode: ?[]const u8 = null,
    llm_quality: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    psyche_reasoning_effort: ?[]const u8 = null,
    models: []const u8 = "",
    psyche_models: []const u8 = "",
    conversation_roster: llm_routing.LlmRoster = .{ .entries = &.{} },
    psyche_roster: llm_routing.LlmRoster = .{ .entries = &.{} },
    default_model: ?[]const u8 = null,

    pub fn deinit(self: *LoadedLlmConfig, allocator: std.mem.Allocator) void {
        if (self.mode) |v| allocator.free(v);
        if (self.llm_quality) |v| allocator.free(v);
        if (self.reasoning_effort) |v| allocator.free(v);
        if (self.psyche_reasoning_effort) |v| allocator.free(v);
        allocator.free(self.models);
        allocator.free(self.psyche_models);
        if (self.default_model) |v| allocator.free(v);
        self.conversation_roster.deinit(allocator);
        self.psyche_roster.deinit(allocator);
    }
};

const EmailConfigFile = struct {
    smtp_url: []const u8,
    from: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

const CapacityConfigFile = struct {
    activity_stack_max: ?usize = null,
    focus_slots_max: ?usize = null,
    memory_selected_max: ?usize = null,
    memory_prefilter_max: ?usize = null,
    candidate_actions_max: ?usize = null,
    open_loops_soft_max: ?usize = null,
    conversation_summaries_in_context_max: ?usize = null,
    chat_context_tokens_max: ?usize = null,
    dispatch_envelope_bytes_max: ?usize = null,
    dispatch_event_count_max: ?usize = null,
};

const RuntimeOptionsFile = struct {
    camera_mode: ?[]const u8 = null,
    activation_mode: ?[]const u8 = null,
    ai_mode: ?[]const u8 = null,
    intent_mode: ?[]const u8 = null,
    description_mode: ?[]const u8 = null,
    identity_comparison_mode: ?[]const u8 = null,
    transcription_mode: ?[]const u8 = null,
    speech_mode: ?[]const u8 = null,
    memory_path: ?[]const u8 = null,
    graph_path: ?[]const u8 = null,
    seed_path: ?[]const u8 = null,
    captures_dir: ?[]const u8 = null,
    capture_scratch_dir: ?[]const u8 = null,
    audio_input_dir: ?[]const u8 = null,
    audio_output_dir: ?[]const u8 = null,
    autonomy_mode: ?[]const u8 = null,
    psyche_mode: ?[]const u8 = null,
    llm_quality: ?[]const u8 = null,
    speech_voice: ?[]const u8 = null,
    button_hold_ms: ?u64 = null,
    conversation_idle_timeout_seconds: ?u64 = null,
    known_threshold: ?f32 = null,
    uncertain_threshold: ?f32 = null,
    autonomy_sleep: ?[]const u8 = null,
    autonomy_quiet_hours: ?[]const u8 = null,
    autonomy_limited_max_capacity: ?f32 = null,
    autonomy_full_max_capacity: ?f32 = null,
    autonomy_limited_threshold_bias: ?f32 = null,
    autonomy_full_threshold_bias: ?f32 = null,
    autonomy_social_engagement_boost: ?f32 = null,
    autonomy_limited_replenish_actions_per_minute: ?f32 = null,
    autonomy_full_replenish_actions_per_minute: ?f32 = null,
    autonomy_planner_min_capacity: ?f32 = null,
    autonomy_social_reserve: ?f32 = null,
    autonomy_safety_reserve: ?f32 = null,
    autonomy_opportunity_reserve: ?f32 = null,
    id_monitors_mode: ?[]const u8 = null,
    id_monitor_interval_seconds: ?u64 = null,
    id_monitor_external_command: ?[]const u8 = null,
    id_monitor_external_restart_cooldown_seconds: ?u64 = null,
    id_monitor_severity_threshold: ?[]const u8 = null,
    psyche_reasoning_effort: ?[]const u8 = null,
    face_embeddings_dir: ?[]const u8 = null,
    maintenance_schedule_path: ?[]const u8 = null,
    maintenance_state_path: ?[]const u8 = null,
    capacity: ?CapacityConfigFile = null,
};

pub const LoadedEmailConfig = struct {
    smtp_url: []const u8,
    from: []const u8,
    username: []const u8,
    password: []const u8,
};

pub fn loadLlmConfigFromPath(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, path: []const u8) !LoadedLlmConfig {
    const bytes = try fs.readFileAllocPath(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    return parseLlmConfig(allocator, bytes);
}

pub fn loadLlmConfig(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io) !LoadedLlmConfig {
    return loadLlmConfigFromPath(allocator, fs, io, "data/llm_providers.json");
}

pub fn seedLlmProvidersDefault(fs: FileSystem, io: std.Io, dest_path: []const u8) !void {
    try fs.ensureParentDir(io, dest_path);
    try fs.writeFilePath(io, dest_path, llm_providers_template_json);
}

pub fn seedLlmProvidersFromTemplate(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, dest_path: []const u8, template_path: []const u8) !void {
    const bytes = try fs.readFileAllocPath(io, template_path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    try fs.ensureParentDir(io, dest_path);
    try fs.writeFilePath(io, dest_path, bytes);
}

fn rosterToJsonEntries(allocator: std.mem.Allocator, roster: llm_routing.LlmRoster) ![]LlmModelEntry {
    var out = try allocator.alloc(LlmModelEntry, roster.entries.len);
    for (roster.entries, 0..) |entry, i| {
        out[i] = .{
            .provider = llm_routing.providerName(entry.provider),
            .model = entry.model,
            .tier = @tagName(entry.tier),
        };
    }
    return out;
}

pub fn saveLlmProviders(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, cfg: Config) !void {
    if (cfg.llm_providers_path.len == 0) return error.MissingLlmProvidersPath;
    if (cfg.conversation_roster.entries.len == 0) return error.EmptyConversationRoster;
    const conversation_models = try rosterToJsonEntries(allocator, cfg.conversation_roster);
    defer allocator.free(conversation_models);
    const psyche_models = if (cfg.psyche_roster.entries.len > 0)
        try rosterToJsonEntries(allocator, cfg.psyche_roster)
    else
        @as([]LlmModelEntry, &.{});
    defer if (psyche_models.len > 0) allocator.free(psyche_models);
    const body = try std.json.Stringify.valueAlloc(allocator, struct {
        mode: []const u8,
        reasoning_effort: []const u8,
        psyche_reasoning_effort: []const u8,
        models: []LlmModelEntry,
        psyche_models: []LlmModelEntry,
    }{
        .mode = cfg.ai_mode,
        .reasoning_effort = cfg.conversation_reasoning_effort,
        .psyche_reasoning_effort = cfg.psyche_reasoning_effort,
        .models = conversation_models,
        .psyche_models = psyche_models,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(body);
    try fs.ensureParentDir(io, cfg.llm_providers_path);
    try fs.writeFilePath(io, cfg.llm_providers_path, body);
}

pub fn parseLlmConfig(allocator: std.mem.Allocator, bytes: []const u8) !LoadedLlmConfig {
    const parsed = try std.json.parseFromSlice(LlmConfigFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const conversation_roster = try llm_routing.parseRosterFromJsonEntries(allocator, parsed.value.models);
    const psyche_roster: llm_routing.LlmRoster = if (parsed.value.psyche_models.len == 0)
        .{ .entries = &.{} }
    else
        try llm_routing.parseRosterFromJsonEntries(allocator, parsed.value.psyche_models);
    const models = try conversation_roster.toModelsSpec(allocator);
    const psyche_models: []const u8 = if (psyche_roster.entries.len == 0)
        try allocator.dupe(u8, "")
    else
        try psyche_roster.toModelsSpec(allocator);
    const default_model: ?[]const u8 = if (conversation_roster.entries.len > 0)
        try allocator.dupe(u8, conversation_roster.entries[0].model)
    else
        null;

    return .{
        .mode = if (parsed.value.mode) |mode| try allocator.dupe(u8, mode) else null,
        .llm_quality = if (parsed.value.llm_quality) |quality| try allocator.dupe(u8, quality) else null,
        .reasoning_effort = if (parsed.value.reasoning_effort) |effort| try allocator.dupe(u8, effort) else null,
        .psyche_reasoning_effort = if (parsed.value.psyche_reasoning_effort) |effort| try allocator.dupe(u8, effort) else null,
        .models = models,
        .psyche_models = psyche_models,
        .conversation_roster = conversation_roster,
        .psyche_roster = psyche_roster,
        .default_model = default_model,
    };
}

pub fn loadEmailConfig(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io) !LoadedEmailConfig {
    const bytes = fs.readFileAllocPath(io, "data/email.json", allocator, .limited(16 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{
            .smtp_url = "",
            .from = "",
            .username = "",
            .password = "",
        },
        else => return err,
    };
    defer allocator.free(bytes);
    return parseEmailConfig(allocator, bytes);
}

pub fn parseEmailConfig(allocator: std.mem.Allocator, bytes: []const u8) !LoadedEmailConfig {
    const parsed = try std.json.parseFromSlice(EmailConfigFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const smtp_url = std.mem.trim(u8, parsed.value.smtp_url, " \r\n\t");
    const from = std.mem.trim(u8, parsed.value.from, " \r\n\t");
    if (smtp_url.len == 0) return error.MissingEmailSmtpUrl;
    if (from.len == 0) return error.MissingEmailFrom;

    const username = if (parsed.value.username) |value| std.mem.trim(u8, value, " \r\n\t") else "";
    const password = if (parsed.value.password) |value| std.mem.trim(u8, value, " \r\n\t") else "";
    if (username.len == 0 and password.len > 0) return error.MissingEmailUsername;
    if (username.len > 0 and password.len == 0) return error.MissingEmailPassword;

    return .{
        .smtp_url = try allocator.dupe(u8, smtp_url),
        .from = try allocator.dupe(u8, from),
        .username = try allocator.dupe(u8, username),
        .password = try allocator.dupe(u8, password),
    };
}

pub fn parseRuntimeOptionsConfig(allocator: std.mem.Allocator, base: Config, bytes: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(RuntimeOptionsFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var cfg = base;
    const value = parsed.value;
    if (value.camera_mode) |v| cfg.camera_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.activation_mode) |v| cfg.activation_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.ai_mode) |v| cfg.ai_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.intent_mode) |v| cfg.intent_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.description_mode) |v| cfg.description_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.identity_comparison_mode) |v| cfg.identity_comparison_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.transcription_mode) |v| cfg.transcription_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.speech_mode) |v| cfg.speech_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.memory_path) |v| cfg.memory_path = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.graph_path) |v| cfg.graph_path = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.seed_path) |v| cfg.seed_path = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.captures_dir) |v| cfg.captures_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.capture_scratch_dir) |v| cfg.capture_scratch_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.audio_input_dir) |v| cfg.audio_input_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.audio_output_dir) |v| cfg.audio_output_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.autonomy_mode) |v| cfg.autonomy_mode = try allocator.dupe(u8, normalizeAutonomyMode(std.mem.trim(u8, v, " \r\n\t")));
    if (value.psyche_mode) |v| cfg.psyche_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.llm_quality) |v| cfg.llm_quality = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.speech_voice) |v| cfg.speech_voice = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.button_hold_ms) |v| cfg.button_hold_ms = v;
    if (value.conversation_idle_timeout_seconds) |v| cfg.conversation_idle_timeout_seconds = v;
    if (value.known_threshold) |v| cfg.known_threshold = v;
    if (value.uncertain_threshold) |v| cfg.uncertain_threshold = v;
    if (value.autonomy_sleep) |v| cfg.autonomy_sleep = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.autonomy_quiet_hours) |v| cfg.autonomy_quiet_hours = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.autonomy_limited_max_capacity) |v| cfg.autonomy_limited_max_capacity = v;
    if (value.autonomy_full_max_capacity) |v| cfg.autonomy_full_max_capacity = v;
    if (value.autonomy_limited_threshold_bias) |v| cfg.autonomy_limited_threshold_bias = v;
    if (value.autonomy_full_threshold_bias) |v| cfg.autonomy_full_threshold_bias = v;
    if (value.autonomy_social_engagement_boost) |v| cfg.autonomy_social_engagement_boost = v;
    if (value.autonomy_limited_replenish_actions_per_minute) |v| cfg.autonomy_limited_replenish_actions_per_minute = v;
    if (value.autonomy_full_replenish_actions_per_minute) |v| cfg.autonomy_full_replenish_actions_per_minute = v;
    if (value.autonomy_planner_min_capacity) |v| cfg.autonomy_planner_min_capacity = v;
    if (value.autonomy_social_reserve) |v| cfg.autonomy_social_reserve = v;
    if (value.autonomy_safety_reserve) |v| cfg.autonomy_safety_reserve = v;
    if (value.autonomy_opportunity_reserve) |v| cfg.autonomy_opportunity_reserve = v;
    if (value.id_monitors_mode) |v| cfg.id_monitors_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.id_monitor_interval_seconds) |v| cfg.id_monitor_interval_seconds = v;
    if (value.id_monitor_external_command) |v| cfg.id_monitor_external_command = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.id_monitor_external_restart_cooldown_seconds) |v| cfg.id_monitor_external_restart_cooldown_seconds = v;
    if (value.id_monitor_severity_threshold) |v| cfg.id_monitor_severity_threshold = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.psyche_reasoning_effort) |v| cfg.psyche_reasoning_effort = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.face_embeddings_dir) |v| cfg.face_embeddings_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.maintenance_schedule_path) |v| cfg.maintenance_schedule_path = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.maintenance_state_path) |v| cfg.maintenance_state_path = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.capacity) |cap| {
        cfg.capacity = cognitive_capacity.mergePartial(cfg.capacity, capacityPartialFromFile(cap));
        try cognitive_capacity.validate(cfg.capacity);
    }
    return cfg;
}

fn capacityPartialFromFile(file: CapacityConfigFile) CapacityConfigPartial {
    return .{
        .activity_stack_max = file.activity_stack_max,
        .focus_slots_max = file.focus_slots_max,
        .memory_selected_max = file.memory_selected_max,
        .memory_prefilter_max = file.memory_prefilter_max,
        .candidate_actions_max = file.candidate_actions_max,
        .open_loops_soft_max = file.open_loops_soft_max,
        .conversation_summaries_in_context_max = file.conversation_summaries_in_context_max,
        .chat_context_tokens_max = file.chat_context_tokens_max,
        .dispatch_envelope_bytes_max = file.dispatch_envelope_bytes_max,
        .dispatch_event_count_max = file.dispatch_event_count_max,
    };
}

pub fn provisionBrainConfigFiles(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, cfg: Config) !void {
    if (cfg.llm_providers_path.len == 0) return error.MissingLlmProvidersPath;
    const bytes = fs.readFileAllocPath(io, cfg.llm_providers_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            try seedLlmProvidersDefault(fs, io, cfg.llm_providers_path);
            return;
        },
        else => return err,
    };
    defer allocator.free(bytes);
}

pub fn saveRuntimeOptions(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, cfg: Config) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .camera_mode = cfg.camera_mode,
        .activation_mode = cfg.activation_mode,
        .ai_mode = cfg.ai_mode,
        .intent_mode = cfg.intent_mode,
        .description_mode = cfg.description_mode,
        .identity_comparison_mode = cfg.identity_comparison_mode,
        .speech_mode = cfg.speech_mode,
        .memory_path = cfg.memory_path,
        .graph_path = cfg.graph_path,
        .seed_path = cfg.seed_path,
        .captures_dir = cfg.captures_dir,
        .capture_scratch_dir = cfg.capture_scratch_dir,
        .audio_input_dir = cfg.audio_input_dir,
        .audio_output_dir = cfg.audio_output_dir,
        .autonomy_mode = cfg.autonomy_mode,
        .psyche_mode = cfg.psyche_mode,
        .llm_quality = cfg.llm_quality,
        .speech_voice = cfg.speech_voice,
        .button_hold_ms = cfg.button_hold_ms,
        .conversation_idle_timeout_seconds = cfg.conversation_idle_timeout_seconds,
        .known_threshold = cfg.known_threshold,
        .uncertain_threshold = cfg.uncertain_threshold,
        .autonomy_sleep = cfg.autonomy_sleep,
        .autonomy_quiet_hours = cfg.autonomy_quiet_hours,
        .autonomy_limited_max_capacity = cfg.autonomy_limited_max_capacity,
        .autonomy_full_max_capacity = cfg.autonomy_full_max_capacity,
        .autonomy_limited_threshold_bias = cfg.autonomy_limited_threshold_bias,
        .autonomy_full_threshold_bias = cfg.autonomy_full_threshold_bias,
        .autonomy_social_engagement_boost = cfg.autonomy_social_engagement_boost,
        .autonomy_limited_replenish_actions_per_minute = cfg.autonomy_limited_replenish_actions_per_minute,
        .autonomy_full_replenish_actions_per_minute = cfg.autonomy_full_replenish_actions_per_minute,
        .autonomy_planner_min_capacity = cfg.autonomy_planner_min_capacity,
        .autonomy_social_reserve = cfg.autonomy_social_reserve,
        .autonomy_safety_reserve = cfg.autonomy_safety_reserve,
        .autonomy_opportunity_reserve = cfg.autonomy_opportunity_reserve,
        .id_monitors_mode = cfg.id_monitors_mode,
        .id_monitor_interval_seconds = cfg.id_monitor_interval_seconds,
        .id_monitor_external_command = cfg.id_monitor_external_command,
        .id_monitor_external_restart_cooldown_seconds = cfg.id_monitor_external_restart_cooldown_seconds,
        .id_monitor_severity_threshold = cfg.id_monitor_severity_threshold,
        .psyche_reasoning_effort = cfg.psyche_reasoning_effort,
        .face_embeddings_dir = cfg.face_embeddings_dir,
        .maintenance_schedule_path = cfg.maintenance_schedule_path,
        .maintenance_state_path = cfg.maintenance_state_path,
        .capacity = cfg.capacity,
    }, .{ .whitespace = .indent_2 });
    defer allocator.free(body);
    try fs.ensureParentDir(io, cfg.runtime_options_path);
    try fs.writeFilePath(io, cfg.runtime_options_path, body);
}

fn normalizeAutonomyMode(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "on")) return "full";
    return mode;
}

pub fn brainPath(allocator: std.mem.Allocator, root: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, suffix });
}

pub fn validateBrainId(brain_id: []const u8) !void {
    if (brain_id.len == 0) return error.EmptyBrainId;
    for (brain_id) |c| {
        const valid = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!valid) return error.InvalidBrainId;
    }
}
