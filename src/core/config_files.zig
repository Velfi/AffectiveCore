const std = @import("std");
const files = @import("../platform/common/files.zig");
const Config = @import("config.zig").Config;

const LlmConfigFile = struct {
    mode: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    psyche_reasoning_effort: ?[]const u8 = null,
    models: []const struct {
        provider: []const u8,
        model: []const u8,
    } = &.{},
    psyche_models: []const struct {
        provider: []const u8,
        model: []const u8,
    } = &.{},
};

pub const LoadedLlmConfig = struct {
    mode: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    psyche_reasoning_effort: ?[]const u8 = null,
    models: []const u8 = "",
    psyche_models: []const u8 = "",
    default_model: ?[]const u8 = null,
};

const EmailConfigFile = struct {
    smtp_url: []const u8,
    from: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
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
    events_path: ?[]const u8 = null,
    captures_dir: ?[]const u8 = null,
    capture_scratch_dir: ?[]const u8 = null,
    audio_input_dir: ?[]const u8 = null,
    audio_output_dir: ?[]const u8 = null,
    recognition_mode: ?[]const u8 = null,
    autonomy_mode: ?[]const u8 = null,
    psyche_mode: ?[]const u8 = null,
    speech_voice: ?[]const u8 = null,
    button_hold_ms: ?u64 = null,
    conversation_idle_timeout_seconds: ?u64 = null,
    known_threshold: ?f32 = null,
    uncertain_threshold: ?f32 = null,
    autonomy_interval_seconds: ?u64 = null,
    autonomy_sleep: ?[]const u8 = null,
    autonomy_quiet_hours: ?[]const u8 = null,
    autonomy_speech_cooldown_minutes: ?u64 = null,
    autonomy_daily_energy: ?u32 = null,
    id_monitors_mode: ?[]const u8 = null,
    id_monitor_interval_seconds: ?u64 = null,
    id_monitor_external_command: ?[]const u8 = null,
    id_monitor_external_restart_cooldown_seconds: ?u64 = null,
    id_monitor_severity_threshold: ?[]const u8 = null,
    psyche_reasoning_effort: ?[]const u8 = null,
    recognition_command: ?[]const u8 = null,
    face_detector_model: ?[]const u8 = null,
    face_recognition_model: ?[]const u8 = null,
    face_embeddings_dir: ?[]const u8 = null,
    maintenance_schedule_path: ?[]const u8 = null,
    maintenance_state_path: ?[]const u8 = null,
};

pub const LoadedEmailConfig = struct {
    smtp_url: []const u8,
    from: []const u8,
    username: []const u8,
    password: []const u8,
};

pub fn loadLlmConfig(allocator: std.mem.Allocator, io: std.Io) !LoadedLlmConfig {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "data/llm_providers.json", allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(LlmConfigFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var out = std.ArrayList(u8).empty;
    var default_model: ?[]const u8 = null;
    for (parsed.value.models, 0..) |entry, i| {
        const provider = std.mem.trim(u8, entry.provider, " \r\n\t");
        const model = std.mem.trim(u8, entry.model, " \r\n\t");
        if (provider.len == 0 or model.len == 0) continue;
        if (out.items.len > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, provider);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, model);
        if (i == 0) default_model = try allocator.dupe(u8, model);
    }
    const psyche_models = try formatProviderModels(allocator, parsed.value.psyche_models);

    return .{
        .mode = if (parsed.value.mode) |mode| try allocator.dupe(u8, mode) else null,
        .reasoning_effort = if (parsed.value.reasoning_effort) |effort| try allocator.dupe(u8, effort) else null,
        .psyche_reasoning_effort = if (parsed.value.psyche_reasoning_effort) |effort| try allocator.dupe(u8, effort) else null,
        .models = try out.toOwnedSlice(allocator),
        .psyche_models = psyche_models,
        .default_model = default_model,
    };
}

pub fn loadEmailConfig(allocator: std.mem.Allocator, io: std.Io) !LoadedEmailConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "data/email.json", allocator, .limited(16 * 1024)) catch |err| switch (err) {
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
    if (value.events_path) |v| cfg.events_path = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.captures_dir) |v| cfg.captures_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.capture_scratch_dir) |v| cfg.capture_scratch_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.audio_input_dir) |v| cfg.audio_input_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.audio_output_dir) |v| cfg.audio_output_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.recognition_mode) |v| cfg.recognition_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.autonomy_mode) |v| cfg.autonomy_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.psyche_mode) |v| cfg.psyche_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.speech_voice) |v| cfg.speech_voice = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.button_hold_ms) |v| cfg.button_hold_ms = v;
    if (value.conversation_idle_timeout_seconds) |v| cfg.conversation_idle_timeout_seconds = v;
    if (value.known_threshold) |v| cfg.known_threshold = v;
    if (value.uncertain_threshold) |v| cfg.uncertain_threshold = v;
    if (value.autonomy_interval_seconds) |v| cfg.autonomy_interval_seconds = v;
    if (value.autonomy_sleep) |v| cfg.autonomy_sleep = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.autonomy_quiet_hours) |v| cfg.autonomy_quiet_hours = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.autonomy_speech_cooldown_minutes) |v| cfg.autonomy_speech_cooldown_minutes = v;
    if (value.autonomy_daily_energy) |v| cfg.autonomy_daily_energy = v;
    if (value.id_monitors_mode) |v| cfg.id_monitors_mode = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.id_monitor_interval_seconds) |v| cfg.id_monitor_interval_seconds = v;
    if (value.id_monitor_external_command) |v| cfg.id_monitor_external_command = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.id_monitor_external_restart_cooldown_seconds) |v| cfg.id_monitor_external_restart_cooldown_seconds = v;
    if (value.id_monitor_severity_threshold) |v| cfg.id_monitor_severity_threshold = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.psyche_reasoning_effort) |v| cfg.psyche_reasoning_effort = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.recognition_command) |v| cfg.recognition_command = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.face_detector_model) |v| cfg.face_detector_model = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.face_recognition_model) |v| cfg.face_recognition_model = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.face_embeddings_dir) |v| cfg.face_embeddings_dir = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.maintenance_schedule_path) |v| cfg.maintenance_schedule_path = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    if (value.maintenance_state_path) |v| cfg.maintenance_state_path = try allocator.dupe(u8, std.mem.trim(u8, v, " \r\n\t"));
    return cfg;
}

pub fn saveRuntimeOptions(io: std.Io, cfg: Config) !void {
    var buffer: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    try stream.print("{f}\n", .{std.json.fmt(.{
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
        .events_path = cfg.events_path,
        .captures_dir = cfg.captures_dir,
        .capture_scratch_dir = cfg.capture_scratch_dir,
        .audio_input_dir = cfg.audio_input_dir,
        .audio_output_dir = cfg.audio_output_dir,
        .recognition_mode = cfg.recognition_mode,
        .autonomy_mode = cfg.autonomy_mode,
        .psyche_mode = cfg.psyche_mode,
        .speech_voice = cfg.speech_voice,
        .button_hold_ms = cfg.button_hold_ms,
        .conversation_idle_timeout_seconds = cfg.conversation_idle_timeout_seconds,
        .known_threshold = cfg.known_threshold,
        .uncertain_threshold = cfg.uncertain_threshold,
        .autonomy_interval_seconds = cfg.autonomy_interval_seconds,
        .autonomy_sleep = cfg.autonomy_sleep,
        .autonomy_quiet_hours = cfg.autonomy_quiet_hours,
        .autonomy_speech_cooldown_minutes = cfg.autonomy_speech_cooldown_minutes,
        .autonomy_daily_energy = cfg.autonomy_daily_energy,
        .id_monitors_mode = cfg.id_monitors_mode,
        .id_monitor_interval_seconds = cfg.id_monitor_interval_seconds,
        .id_monitor_external_command = cfg.id_monitor_external_command,
        .id_monitor_external_restart_cooldown_seconds = cfg.id_monitor_external_restart_cooldown_seconds,
        .id_monitor_severity_threshold = cfg.id_monitor_severity_threshold,
        .psyche_reasoning_effort = cfg.psyche_reasoning_effort,
        .recognition_command = cfg.recognition_command,
        .face_detector_model = cfg.face_detector_model,
        .face_recognition_model = cfg.face_recognition_model,
        .face_embeddings_dir = cfg.face_embeddings_dir,
        .maintenance_schedule_path = cfg.maintenance_schedule_path,
        .maintenance_state_path = cfg.maintenance_state_path,
    }, .{})});
    try writeFilePath(io, cfg.runtime_options_path, stream.buffered());
}

fn formatProviderModels(allocator: std.mem.Allocator, models: anytype) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (models) |entry| {
        const provider = std.mem.trim(u8, entry.provider, " \r\n\t");
        const model = std.mem.trim(u8, entry.model, " \r\n\t");
        if (provider.len == 0 or model.len == 0) continue;
        if (out.items.len > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, provider);
        try out.append(allocator, ':');
        try out.appendSlice(allocator, model);
    }
    return out.toOwnedSlice(allocator);
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

fn writeFilePath(io: std.Io, path: []const u8, data: []const u8) !void {
    return files.writeFilePath(io, path, data);
}

fn readFileAllocPath(io: std.Io, path: []const u8, allocator: std.mem.Allocator, limit: std.Io.Limit) ![]u8 {
    return files.readFileAllocPath(io, path, allocator, limit);
}
