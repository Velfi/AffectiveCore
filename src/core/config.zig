const std = @import("std");
const ports = @import("ports.zig");
const files = ports.files;
const FileSystem = files.FileSystem;
const config_files = @import("config_files.zig");
const llm_routing = @import("llm_routing.zig");
const cognitive_capacity = @import("cognitive_capacity.zig");

pub const CapacityConfig = struct {
    activity_stack_max: usize = 8,
    focus_slots_max: usize = 1,
    memory_selected_max: usize = 5,
    memory_prefilter_max: usize = 50,
    memory_snippet_max_bytes: usize = 200,
    memory_context_bytes_max: usize = 1200,
    candidate_actions_max: usize = 5,
    open_loops_soft_max: usize = 4,
    conversation_summaries_in_context_max: usize = 8,
    chat_context_tokens_max: usize = 120_000,
    dispatch_envelope_bytes_max: usize = 16 * 1024,
    dispatch_event_count_max: usize = 12,
};

pub const CapacityConfigPartial = struct {
    activity_stack_max: ?usize = null,
    focus_slots_max: ?usize = null,
    memory_selected_max: ?usize = null,
    memory_prefilter_max: ?usize = null,
    memory_snippet_max_bytes: ?usize = null,
    memory_context_bytes_max: ?usize = null,
    candidate_actions_max: ?usize = null,
    open_loops_soft_max: ?usize = null,
    conversation_summaries_in_context_max: ?usize = null,
    chat_context_tokens_max: ?usize = null,
    dispatch_envelope_bytes_max: ?usize = null,
    dispatch_event_count_max: ?usize = null,
};

pub const Config = struct {
    brain_id: []const u8 = "default",
    brain_root: []const u8 = "",
    camera_mode: []const u8 = "webcam",
    activation_mode: []const u8 = "manual",
    ai_mode: []const u8 = "random",
    intent_mode: []const u8 = "random",
    intent_model: []const u8 = "gpt-4.1-nano",
    conversation_model: []const u8 = "gpt-4.1-nano",
    conversation_models: []const u8 = "",
    conversation_reasoning_effort: []const u8 = "auto",
    llm_quality: []const u8 = "auto",
    conversation_roster: llm_routing.LlmRoster = .{ .entries = &.{} },
    psyche_roster: llm_routing.LlmRoster = .{ .entries = &.{} },
    image_generation_model: []const u8 = "gemini-3.1-flash-image",
    image_generation_output_dir: []const u8 = "",
    autonomy_mode: []const u8 = "off",
    autonomy_sleep: []const u8 = "off",
    autonomy_quiet_hours: []const u8 = "22:00-08:00",
    autonomy_limited_max_capacity: f32 = 25,
    autonomy_full_max_capacity: f32 = 50,
    autonomy_limited_threshold_bias: f32 = 0.20,
    autonomy_full_threshold_bias: f32 = 0.00,
    autonomy_social_engagement_boost: f32 = 3,
    autonomy_limited_replenish_actions_per_minute: f32 = 2,
    autonomy_full_replenish_actions_per_minute: f32 = 8,
    autonomy_social_reserve: f32 = 0.12,
    autonomy_safety_reserve: f32 = 0.20,
    autonomy_opportunity_reserve: f32 = 0.15,
    id_monitors_mode: []const u8 = "on",
    id_monitor_interval_seconds: u64 = 5,
    id_monitor_external_command: []const u8 = "",
    id_monitor_external_restart_cooldown_seconds: u64 = 60,
    id_monitor_severity_threshold: []const u8 = "concern",
    psyche_mode: []const u8 = "on",
    psyche_models: []const u8 = "",
    psyche_reasoning_effort: []const u8 = "low",
    speech_mode: []const u8 = "speak-n-spell",
    speech_voice: []const u8 = "Fred",
    transcription_mode: []const u8 = "terminal",
    transcription_command: []const u8 = "tools/whisper.cpp-v1.9.1-bin/whisper-cli",
    transcription_model: []const u8 = "models/ggml-base.en.bin",
    speaker_command: []const u8 = "aplay",
    description_mode: []const u8 = "random",
    identity_comparison_mode: []const u8 = "random",
    identity_comparison_model: []const u8 = "gpt-4.1-nano",
    face_embeddings_dir: []const u8 = "",
    known_threshold: f32 = 0.85,
    uncertain_threshold: f32 = 0.60,
    memory_path: []const u8 = "",
    graph_path: []const u8 = "",
    seed_path: []const u8 = "data/seeds/default.md",
    maintenance_schedule_path: []const u8 = "",
    maintenance_state_path: []const u8 = "",
    context_stats_path: []const u8 = "",
    runtime_options_path: []const u8 = "",
    captures_dir: []const u8 = "",
    capture_scratch_dir: []const u8 = "",
    audio_input_dir: []const u8 = "",
    audio_output_dir: []const u8 = "",
    email_smtp_url: []const u8 = "",
    email_from: []const u8 = "",
    email_username: []const u8 = "",
    email_password: []const u8 = "",
    button_line: []const u8 = "17",
    button_hold_ms: u64 = 450,
    conversation_idle_timeout_seconds: u64 = 120,
    capacity: CapacityConfig = .{},
    llm_providers_path: []const u8 = "",

    pub fn fromArgs(args: []const []const u8) !Config {
        var cfg = Config{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--brain") and i + 1 < args.len) {
                i += 1;
                cfg.brain_id = args[i];
            } else if (std.mem.eql(u8, args[i], "--camera") and i + 1 < args.len) {
                i += 1;
                cfg.camera_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--activation") and i + 1 < args.len) {
                i += 1;
                cfg.activation_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--ai") and i + 1 < args.len) {
                i += 1;
                cfg.ai_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--intent") and i + 1 < args.len) {
                i += 1;
                cfg.intent_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--intent-model") and i + 1 < args.len) {
                i += 1;
                cfg.intent_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--conversation-model") and i + 1 < args.len) {
                i += 1;
                cfg.conversation_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--conversation-reasoning-effort") and i + 1 < args.len) {
                i += 1;
                cfg.conversation_reasoning_effort = args[i];
            } else if (std.mem.eql(u8, args[i], "--llm-quality") and i + 1 < args.len) {
                i += 1;
                cfg.llm_quality = args[i];
            } else if (std.mem.eql(u8, args[i], "--image-generation-model") and i + 1 < args.len) {
                i += 1;
                cfg.image_generation_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--image-generation-output-dir") and i + 1 < args.len) {
                i += 1;
                cfg.image_generation_output_dir = args[i];
            } else if (std.mem.eql(u8, args[i], "--autonomy") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_mode = try parseAutonomyMode(args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-limited-replenish-actions-per-minute") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_limited_replenish_actions_per_minute = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-full-replenish-actions-per-minute") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_full_replenish_actions_per_minute = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-sleep") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_sleep = args[i];
            } else if (std.mem.eql(u8, args[i], "--autonomy-quiet-hours") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_quiet_hours = args[i];
            } else if (std.mem.eql(u8, args[i], "--autonomy-limited-max-capacity") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_limited_max_capacity = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-full-max-capacity") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_full_max_capacity = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-limited-threshold-bias") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_limited_threshold_bias = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-full-threshold-bias") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_full_threshold_bias = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-social-engagement-boost") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_social_engagement_boost = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-social-reserve") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_social_reserve = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-safety-reserve") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_safety_reserve = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--autonomy-opportunity-reserve") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_opportunity_reserve = try std.fmt.parseFloat(f32, args[i]);
            } else if (std.mem.eql(u8, args[i], "--id-monitors") and i + 1 < args.len) {
                i += 1;
                cfg.id_monitors_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--id-monitor-interval-seconds") and i + 1 < args.len) {
                i += 1;
                cfg.id_monitor_interval_seconds = try std.fmt.parseInt(u64, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--id-monitor-external-command") and i + 1 < args.len) {
                i += 1;
                cfg.id_monitor_external_command = args[i];
            } else if (std.mem.eql(u8, args[i], "--id-monitor-external-restart-cooldown-seconds") and i + 1 < args.len) {
                i += 1;
                cfg.id_monitor_external_restart_cooldown_seconds = try std.fmt.parseInt(u64, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--id-monitor-severity-threshold") and i + 1 < args.len) {
                i += 1;
                cfg.id_monitor_severity_threshold = args[i];
            } else if (std.mem.eql(u8, args[i], "--psyche") and i + 1 < args.len) {
                i += 1;
                cfg.psyche_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--psyche-models") and i + 1 < args.len) {
                i += 1;
                cfg.psyche_models = args[i];
            } else if (std.mem.eql(u8, args[i], "--psyche-reasoning-effort") and i + 1 < args.len) {
                i += 1;
                cfg.psyche_reasoning_effort = args[i];
            } else if (std.mem.eql(u8, args[i], "--speech") and i + 1 < args.len) {
                i += 1;
                cfg.speech_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--speech-voice") and i + 1 < args.len) {
                i += 1;
                cfg.speech_voice = args[i];
            } else if (std.mem.eql(u8, args[i], "--transcription") and i + 1 < args.len) {
                i += 1;
                cfg.transcription_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--transcription-command") and i + 1 < args.len) {
                i += 1;
                cfg.transcription_command = args[i];
            } else if (std.mem.eql(u8, args[i], "--transcription-model") and i + 1 < args.len) {
                i += 1;
                cfg.transcription_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--speaker-command") and i + 1 < args.len) {
                i += 1;
                cfg.speaker_command = args[i];
            } else if (std.mem.eql(u8, args[i], "--memory-path") and i + 1 < args.len) {
                i += 1;
                cfg.memory_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--graph-path") and i + 1 < args.len) {
                i += 1;
                cfg.graph_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--seed") and i + 1 < args.len) {
                i += 1;
                cfg.seed_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--maintenance-schedule") and i + 1 < args.len) {
                i += 1;
                cfg.maintenance_schedule_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--maintenance-state") and i + 1 < args.len) {
                i += 1;
                cfg.maintenance_state_path = args[i];
            } else if (std.mem.eql(u8, args[i], "--button-line") and i + 1 < args.len) {
                i += 1;
                cfg.button_line = args[i];
            } else if (std.mem.eql(u8, args[i], "--button-hold-ms") and i + 1 < args.len) {
                i += 1;
                cfg.button_hold_ms = try std.fmt.parseInt(u64, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--conversation-idle-timeout-seconds") and i + 1 < args.len) {
                i += 1;
                cfg.conversation_idle_timeout_seconds = try std.fmt.parseInt(u64, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--description") and i + 1 < args.len) {
                i += 1;
                cfg.description_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--identity-comparison") and i + 1 < args.len) {
                i += 1;
                cfg.identity_comparison_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--identity-comparison-model") and i + 1 < args.len) {
                i += 1;
                cfg.identity_comparison_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--face-embeddings-dir") and i + 1 < args.len) {
                i += 1;
                cfg.face_embeddings_dir = args[i];
            } else if (std.mem.eql(u8, args[i], "--capacity-activity-stack-max") and i + 1 < args.len) {
                i += 1;
                cfg.capacity.activity_stack_max = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--capacity-memory-selected-max") and i + 1 < args.len) {
                i += 1;
                cfg.capacity.memory_selected_max = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--capacity-chat-context-tokens-max") and i + 1 < args.len) {
                i += 1;
                cfg.capacity.chat_context_tokens_max = try std.fmt.parseInt(usize, args[i], 10);
            } else if (std.mem.startsWith(u8, args[i], "--")) {
                return error.UnknownConfigFlag;
            }
        }
        return cfg;
    }

    pub fn withBrainPathsForRoots(self: Config, allocator: std.mem.Allocator, persistent_root: []const u8, tmp_root: []const u8) !Config {
        try config_files.validateBrainId(self.brain_id);
        var cfg = self;
        cfg.brain_id = try allocator.dupe(u8, self.brain_id);
        cfg.brain_root = try std.fs.path.join(allocator, &.{ persistent_root, "brains", cfg.brain_id });
        const tmp_brain_root = try std.fs.path.join(allocator, &.{ tmp_root, "brains", cfg.brain_id });
        if (self.memory_path.len == 0) cfg.memory_path = try config_files.brainPath(allocator, cfg.brain_root, "memory/people.sqlite");
        if (self.graph_path.len == 0) cfg.graph_path = try config_files.brainPath(allocator, cfg.brain_root, "memory/relationships.sqlite");
        if (self.maintenance_schedule_path.len == 0) cfg.maintenance_schedule_path = try config_files.brainPath(allocator, cfg.brain_root, "maintenance.md");
        if (self.maintenance_state_path.len == 0) cfg.maintenance_state_path = try config_files.brainPath(allocator, cfg.brain_root, "maintenance_state.json");
        if (self.context_stats_path.len == 0) cfg.context_stats_path = try config_files.brainPath(allocator, cfg.brain_root, "context_stats.json");
        if (self.runtime_options_path.len == 0) cfg.runtime_options_path = try config_files.brainPath(allocator, cfg.brain_root, "runtime_options.json");
        if (self.face_embeddings_dir.len == 0) cfg.face_embeddings_dir = try config_files.brainPath(allocator, cfg.brain_root, "memory/face_embeddings");
        if (self.captures_dir.len == 0) cfg.captures_dir = try config_files.brainPath(allocator, cfg.brain_root, "captures");
        if (self.capture_scratch_dir.len == 0) cfg.capture_scratch_dir = try config_files.brainPath(allocator, tmp_brain_root, "captures");
        if (self.audio_input_dir.len == 0) cfg.audio_input_dir = try config_files.brainPath(allocator, tmp_brain_root, "audio/input");
        if (self.audio_output_dir.len == 0) cfg.audio_output_dir = try config_files.brainPath(allocator, tmp_brain_root, "audio/output");
        if (self.image_generation_output_dir.len == 0) cfg.image_generation_output_dir = try config_files.brainPath(allocator, cfg.brain_root, "generated/images");
        if (self.llm_providers_path.len == 0) cfg.llm_providers_path = try config_files.brainPath(allocator, cfg.brain_root, "llm_providers.json");
        return cfg;
    }

    pub fn ensureBrainPaths(self: Config, allocator: std.mem.Allocator) !Config {
        if (self.brain_root.len == 0) return error.MissingBrainRoot;
        var cfg = self;
        if (cfg.runtime_options_path.len == 0) cfg.runtime_options_path = try config_files.brainPath(allocator, cfg.brain_root, "runtime_options.json");
        if (cfg.llm_providers_path.len == 0) cfg.llm_providers_path = try config_files.brainPath(allocator, cfg.brain_root, "llm_providers.json");
        if (cfg.context_stats_path.len == 0) cfg.context_stats_path = try config_files.brainPath(allocator, cfg.brain_root, "context_stats.json");
        return cfg;
    }

    pub fn resolveSeedPath(self: Config, allocator: std.mem.Allocator) !Config {
        var cfg = self;
        if (cfg.brain_root.len == 0) return cfg;
        const brain_seed = try config_files.brainPath(allocator, cfg.brain_root, "seed.md");
        if (cfg.seed_path.len == 0 or
            std.mem.eql(u8, cfg.seed_path, "data/seeds/default.md") or
            std.mem.startsWith(u8, cfg.seed_path, "data/seeds/"))
        {
            cfg.seed_path = brain_seed;
            return cfg;
        }
        if (std.fs.path.isAbsolute(cfg.seed_path)) {
            if (!std.mem.startsWith(u8, cfg.seed_path, cfg.brain_root)) {
                cfg.seed_path = brain_seed;
            }
            return cfg;
        }
        cfg.seed_path = try std.fs.path.join(allocator, &.{ cfg.brain_root, cfg.seed_path });
        return cfg;
    }

    pub fn loadForBrain(self: Config, allocator: std.mem.Allocator, fs: FileSystem, io: std.Io) !Config {
        var cfg = try self.ensureBrainPaths(allocator);
        cfg = try cfg.withLlmConfig(allocator, fs, io);
        cfg = try cfg.withRuntimeOptions(allocator, fs, io);
        cfg = try cfg.resolveSeedPath(allocator);
        try cognitive_capacity.validate(cfg.capacity);
        return cfg;
    }

    pub fn withLlmConfig(self: Config, allocator: std.mem.Allocator, fs: FileSystem, io: std.Io) !Config {
        if (self.llm_providers_path.len == 0) return error.MissingLlmProvidersPath;
        var cfg = self;
        var loaded = try config_files.loadLlmConfigFromPath(allocator, fs, io, self.llm_providers_path);
        defer loaded.deinit(allocator);
        if (loaded.mode) |mode| cfg.ai_mode = try allocator.dupe(u8, mode);
        if (loaded.reasoning_effort) |effort| cfg.conversation_reasoning_effort = try allocator.dupe(u8, effort);
        if (loaded.psyche_reasoning_effort) |effort| cfg.psyche_reasoning_effort = try allocator.dupe(u8, effort);
        if (loaded.models.len > 0) {
            cfg.conversation_models = loaded.models;
            loaded.models = "";
            if (loaded.default_model) |model| cfg.conversation_model = try allocator.dupe(u8, model);
        }
        if (loaded.psyche_models.len > 0) {
            cfg.psyche_models = loaded.psyche_models;
            loaded.psyche_models = "";
        }
        cfg.conversation_roster = loaded.conversation_roster;
        loaded.conversation_roster = .{ .entries = &.{} };
        cfg.psyche_roster = loaded.psyche_roster;
        loaded.psyche_roster = .{ .entries = &.{} };
        try cfg.ensureRostersFromModelSpecs(allocator);
        return cfg;
    }

    pub fn ensureRostersFromModelSpecs(self: *Config, allocator: std.mem.Allocator) !void {
        if (self.conversation_roster.entries.len == 0) {
            const spec = std.mem.trim(u8, self.conversation_models, " \r\n\t");
            if (spec.len > 0) {
                self.conversation_roster = try llm_routing.parseRosterFromModelsSpec(allocator, spec);
            }
        }
        if (self.psyche_roster.entries.len == 0) {
            const spec = std.mem.trim(u8, self.psyche_models, " \r\n\t");
            if (spec.len > 0) {
                self.psyche_roster = try llm_routing.parseRosterFromModelsSpec(allocator, spec);
            }
        }
    }

    pub fn withEmailConfig(self: Config, allocator: std.mem.Allocator, fs: FileSystem, io: std.Io) !Config {
        var cfg = self;
        const loaded = try config_files.loadEmailConfig(allocator, fs, io);
        cfg.email_smtp_url = loaded.smtp_url;
        cfg.email_from = loaded.from;
        cfg.email_username = loaded.username;
        cfg.email_password = loaded.password;
        return cfg;
    }

    pub fn withRuntimeOptions(self: Config, allocator: std.mem.Allocator, fs: FileSystem, io: std.Io) !Config {
        const bytes = fs.readFileAllocPath(io, self.runtime_options_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return err,
        };
        defer allocator.free(bytes);
        return config_files.parseRuntimeOptionsConfig(allocator, self, bytes);
    }

    pub fn clientSettings(self: Config) ClientSettings {
        return .{
            .client_id = self.brain_id,
            .brain_id = self.brain_id,
            .frontend_kind = if (std.mem.eql(u8, self.activation_mode, "webview")) "mac_webview" else "terminal",
            .activation_mode = self.activation_mode,
            .camera_mode = self.camera_mode,
            .speech_mode = self.speech_mode,
            .speech_voice = self.speech_voice,
            .transcription_mode = self.transcription_mode,
            .transcription_command = self.transcription_command,
            .transcription_model = self.transcription_model,
            .speaker_command = self.speaker_command,
            .button_line = self.button_line,
            .button_hold_ms = self.button_hold_ms,
            .audio_input_dir = self.audio_input_dir,
            .audio_output_dir = self.audio_output_dir,
            .capture_scratch_dir = self.capture_scratch_dir,
        };
    }

    pub fn brainSettings(self: Config) BrainSettings {
        return .{
            .brain_id = self.brain_id,
            .brain_root = self.brain_root,
            .ai_mode = self.ai_mode,
            .intent_mode = self.intent_mode,
            .intent_model = self.intent_model,
            .conversation_model = self.conversation_model,
            .conversation_models = self.conversation_models,
            .conversation_reasoning_effort = self.conversation_reasoning_effort,
            .llm_quality = self.llm_quality,
            .image_generation_model = self.image_generation_model,
            .image_generation_output_dir = self.image_generation_output_dir,
            .autonomy_mode = self.autonomy_mode,
            .autonomy_sleep = self.autonomy_sleep,
            .autonomy_quiet_hours = self.autonomy_quiet_hours,
            .autonomy_limited_max_capacity = self.autonomy_limited_max_capacity,
            .autonomy_full_max_capacity = self.autonomy_full_max_capacity,
            .autonomy_limited_threshold_bias = self.autonomy_limited_threshold_bias,
            .autonomy_full_threshold_bias = self.autonomy_full_threshold_bias,
            .autonomy_social_engagement_boost = self.autonomy_social_engagement_boost,
            .autonomy_limited_replenish_actions_per_minute = self.autonomy_limited_replenish_actions_per_minute,
            .autonomy_full_replenish_actions_per_minute = self.autonomy_full_replenish_actions_per_minute,
            .autonomy_social_reserve = self.autonomy_social_reserve,
            .autonomy_safety_reserve = self.autonomy_safety_reserve,
            .autonomy_opportunity_reserve = self.autonomy_opportunity_reserve,
            .id_monitors_mode = self.id_monitors_mode,
            .id_monitor_interval_seconds = self.id_monitor_interval_seconds,
            .id_monitor_external_command = self.id_monitor_external_command,
            .id_monitor_external_restart_cooldown_seconds = self.id_monitor_external_restart_cooldown_seconds,
            .id_monitor_severity_threshold = self.id_monitor_severity_threshold,
            .psyche_mode = self.psyche_mode,
            .psyche_models = self.psyche_models,
            .psyche_reasoning_effort = self.psyche_reasoning_effort,
            .description_mode = self.description_mode,
            .identity_comparison_mode = self.identity_comparison_mode,
            .identity_comparison_model = self.identity_comparison_model,
            .face_embeddings_dir = self.face_embeddings_dir,
            .known_threshold = self.known_threshold,
            .uncertain_threshold = self.uncertain_threshold,
            .memory_path = self.memory_path,
            .graph_path = self.graph_path,
            .seed_path = self.seed_path,
            .maintenance_schedule_path = self.maintenance_schedule_path,
            .maintenance_state_path = self.maintenance_state_path,
            .context_stats_path = self.context_stats_path,
            .runtime_options_path = self.runtime_options_path,
            .llm_providers_path = self.llm_providers_path,
            .captures_dir = self.captures_dir,
            .conversation_idle_timeout_seconds = self.conversation_idle_timeout_seconds,
            .capacity = self.capacity,
        };
    }

    pub fn withClientSettings(self: Config, settings: ClientSettings) Config {
        var cfg = self;
        if (settings.brain_id.len > 0) cfg.brain_id = settings.brain_id;
        if (settings.activation_mode.len > 0) cfg.activation_mode = settings.activation_mode;
        if (settings.camera_mode.len > 0) cfg.camera_mode = settings.camera_mode;
        if (settings.speech_mode.len > 0) cfg.speech_mode = settings.speech_mode;
        if (settings.speech_voice.len > 0) cfg.speech_voice = settings.speech_voice;
        if (settings.transcription_mode.len > 0) cfg.transcription_mode = settings.transcription_mode;
        if (settings.transcription_command.len > 0) cfg.transcription_command = settings.transcription_command;
        if (settings.transcription_model.len > 0) cfg.transcription_model = settings.transcription_model;
        if (settings.speaker_command.len > 0) cfg.speaker_command = settings.speaker_command;
        if (settings.button_line.len > 0) cfg.button_line = settings.button_line;
        if (settings.button_hold_ms) |v| cfg.button_hold_ms = v;
        if (settings.audio_input_dir.len > 0) cfg.audio_input_dir = settings.audio_input_dir;
        if (settings.audio_output_dir.len > 0) cfg.audio_output_dir = settings.audio_output_dir;
        if (settings.capture_scratch_dir.len > 0) cfg.capture_scratch_dir = settings.capture_scratch_dir;
        return cfg;
    }

    pub fn withBrainSettings(self: Config, settings: BrainSettings) !Config {
        var cfg = self;
        if (settings.brain_id.len > 0) cfg.brain_id = settings.brain_id;
        if (settings.brain_root.len > 0) cfg.brain_root = settings.brain_root;
        if (settings.ai_mode.len > 0) cfg.ai_mode = settings.ai_mode;
        if (settings.intent_mode.len > 0) cfg.intent_mode = settings.intent_mode;
        if (settings.intent_model.len > 0) cfg.intent_model = settings.intent_model;
        if (settings.conversation_model.len > 0) cfg.conversation_model = settings.conversation_model;
        if (settings.conversation_models.len > 0) cfg.conversation_models = settings.conversation_models;
        if (settings.conversation_reasoning_effort.len > 0) cfg.conversation_reasoning_effort = settings.conversation_reasoning_effort;
        if (settings.llm_quality.len > 0) cfg.llm_quality = settings.llm_quality;
        if (settings.image_generation_model.len > 0) cfg.image_generation_model = settings.image_generation_model;
        if (settings.image_generation_output_dir.len > 0) cfg.image_generation_output_dir = settings.image_generation_output_dir;
        if (settings.autonomy_mode.len > 0) cfg.autonomy_mode = normalizeAutonomyModeCompat(settings.autonomy_mode);
        if (settings.autonomy_sleep.len > 0) cfg.autonomy_sleep = settings.autonomy_sleep;
        if (settings.autonomy_quiet_hours.len > 0) cfg.autonomy_quiet_hours = settings.autonomy_quiet_hours;
        if (settings.autonomy_limited_max_capacity) |v| cfg.autonomy_limited_max_capacity = v;
        if (settings.autonomy_full_max_capacity) |v| cfg.autonomy_full_max_capacity = v;
        if (settings.autonomy_limited_threshold_bias) |v| cfg.autonomy_limited_threshold_bias = v;
        if (settings.autonomy_full_threshold_bias) |v| cfg.autonomy_full_threshold_bias = v;
        if (settings.autonomy_social_engagement_boost) |v| cfg.autonomy_social_engagement_boost = v;
        if (settings.autonomy_limited_replenish_actions_per_minute) |v| cfg.autonomy_limited_replenish_actions_per_minute = v;
        if (settings.autonomy_full_replenish_actions_per_minute) |v| cfg.autonomy_full_replenish_actions_per_minute = v;
        if (settings.autonomy_social_reserve) |v| cfg.autonomy_social_reserve = v;
        if (settings.autonomy_safety_reserve) |v| cfg.autonomy_safety_reserve = v;
        if (settings.autonomy_opportunity_reserve) |v| cfg.autonomy_opportunity_reserve = v;
        if (settings.id_monitors_mode.len > 0) cfg.id_monitors_mode = settings.id_monitors_mode;
        if (settings.id_monitor_interval_seconds) |v| cfg.id_monitor_interval_seconds = v;
        if (settings.id_monitor_external_command.len > 0) cfg.id_monitor_external_command = settings.id_monitor_external_command;
        if (settings.id_monitor_external_restart_cooldown_seconds) |v| cfg.id_monitor_external_restart_cooldown_seconds = v;
        if (settings.id_monitor_severity_threshold.len > 0) cfg.id_monitor_severity_threshold = settings.id_monitor_severity_threshold;
        if (settings.psyche_mode.len > 0) cfg.psyche_mode = settings.psyche_mode;
        if (settings.psyche_models.len > 0) cfg.psyche_models = settings.psyche_models;
        if (settings.psyche_reasoning_effort.len > 0) cfg.psyche_reasoning_effort = settings.psyche_reasoning_effort;
        if (settings.description_mode.len > 0) cfg.description_mode = settings.description_mode;
        if (settings.identity_comparison_mode.len > 0) cfg.identity_comparison_mode = settings.identity_comparison_mode;
        if (settings.identity_comparison_model.len > 0) cfg.identity_comparison_model = settings.identity_comparison_model;
        if (settings.face_embeddings_dir.len > 0) cfg.face_embeddings_dir = settings.face_embeddings_dir;
        if (settings.known_threshold) |v| cfg.known_threshold = v;
        if (settings.uncertain_threshold) |v| cfg.uncertain_threshold = v;
        if (settings.memory_path.len > 0) cfg.memory_path = settings.memory_path;
        if (settings.graph_path.len > 0) cfg.graph_path = settings.graph_path;
        if (settings.seed_path.len > 0) cfg.seed_path = settings.seed_path;
        if (settings.maintenance_schedule_path.len > 0) cfg.maintenance_schedule_path = settings.maintenance_schedule_path;
        if (settings.maintenance_state_path.len > 0) cfg.maintenance_state_path = settings.maintenance_state_path;
        if (settings.context_stats_path.len > 0) cfg.context_stats_path = settings.context_stats_path;
        if (settings.runtime_options_path.len > 0) cfg.runtime_options_path = settings.runtime_options_path;
        if (settings.captures_dir.len > 0) cfg.captures_dir = settings.captures_dir;
        if (settings.conversation_idle_timeout_seconds) |v| cfg.conversation_idle_timeout_seconds = v;
        if (settings.llm_providers_path.len > 0) cfg.llm_providers_path = settings.llm_providers_path;
        if (settings.capacity) |capacity| cfg.capacity = capacity;
        try cognitive_capacity.validate(cfg.capacity);
        return cfg;
    }
};

pub const ClientSettings = struct {
    client_id: []const u8 = "",
    brain_id: []const u8 = "",
    frontend_kind: []const u8 = "",
    activation_mode: []const u8 = "",
    camera_mode: []const u8 = "",
    speech_mode: []const u8 = "",
    speech_voice: []const u8 = "",
    transcription_mode: []const u8 = "",
    transcription_command: []const u8 = "",
    transcription_model: []const u8 = "",
    speaker_command: []const u8 = "",
    button_line: []const u8 = "",
    button_hold_ms: ?u64 = null,
    audio_input_dir: []const u8 = "",
    audio_output_dir: []const u8 = "",
    capture_scratch_dir: []const u8 = "",
};

pub const BrainSettings = struct {
    brain_id: []const u8 = "",
    brain_root: []const u8 = "",
    ai_mode: []const u8 = "",
    intent_mode: []const u8 = "",
    intent_model: []const u8 = "",
    conversation_model: []const u8 = "",
    conversation_models: []const u8 = "",
    conversation_reasoning_effort: []const u8 = "",
    llm_quality: []const u8 = "",
    image_generation_model: []const u8 = "",
    image_generation_output_dir: []const u8 = "",
    autonomy_mode: []const u8 = "",
    autonomy_sleep: []const u8 = "",
    autonomy_quiet_hours: []const u8 = "",
    autonomy_limited_max_capacity: ?f32 = null,
    autonomy_full_max_capacity: ?f32 = null,
    autonomy_limited_threshold_bias: ?f32 = null,
    autonomy_full_threshold_bias: ?f32 = null,
    autonomy_social_engagement_boost: ?f32 = null,
    autonomy_limited_replenish_actions_per_minute: ?f32 = null,
    autonomy_full_replenish_actions_per_minute: ?f32 = null,
    autonomy_social_reserve: ?f32 = null,
    autonomy_safety_reserve: ?f32 = null,
    autonomy_opportunity_reserve: ?f32 = null,
    id_monitors_mode: []const u8 = "",
    id_monitor_interval_seconds: ?u64 = null,
    id_monitor_external_command: []const u8 = "",
    id_monitor_external_restart_cooldown_seconds: ?u64 = null,
    id_monitor_severity_threshold: []const u8 = "",
    psyche_mode: []const u8 = "",
    psyche_models: []const u8 = "",
    psyche_reasoning_effort: []const u8 = "",
    description_mode: []const u8 = "",
    identity_comparison_mode: []const u8 = "",
    identity_comparison_model: []const u8 = "",
    face_embeddings_dir: []const u8 = "",
    known_threshold: ?f32 = null,
    uncertain_threshold: ?f32 = null,
    memory_path: []const u8 = "",
    graph_path: []const u8 = "",
    seed_path: []const u8 = "",
    maintenance_schedule_path: []const u8 = "",
    maintenance_state_path: []const u8 = "",
    context_stats_path: []const u8 = "",
    runtime_options_path: []const u8 = "",
    llm_providers_path: []const u8 = "",
    captures_dir: []const u8 = "",
    conversation_idle_timeout_seconds: ?u64 = null,
    capacity: ?CapacityConfig = null,
};

fn parseAutonomyMode(mode: []const u8) ![]const u8 {
    if (std.mem.eql(u8, mode, "on")) return "full";
    if (std.mem.eql(u8, mode, "off") or std.mem.eql(u8, mode, "limited") or std.mem.eql(u8, mode, "full")) return mode;
    return error.InvalidAutonomyMode;
}

fn normalizeAutonomyModeCompat(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "on")) return "full";
    return mode;
}

pub const LoadedLlmConfig = config_files.LoadedLlmConfig;

pub fn parseLlmConfig(allocator: std.mem.Allocator, bytes: []const u8) !LoadedLlmConfig {
    return config_files.parseLlmConfig(allocator, bytes);
}

pub fn llmQualityFromConfig(cfg: Config) !llm_routing.LlmQuality {
    return llm_routing.LlmQuality.parse(cfg.llm_quality);
}

pub const LoadedEmailConfig = config_files.LoadedEmailConfig;

pub fn loadEmailConfig(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io) !LoadedEmailConfig {
    return config_files.loadEmailConfig(allocator, fs, io);
}

pub fn parseEmailConfig(allocator: std.mem.Allocator, bytes: []const u8) !LoadedEmailConfig {
    return config_files.parseEmailConfig(allocator, bytes);
}

pub fn parseRuntimeOptionsConfig(allocator: std.mem.Allocator, base: Config, bytes: []const u8) !Config {
    return config_files.parseRuntimeOptionsConfig(allocator, base, bytes);
}

pub fn saveRuntimeOptions(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, cfg: Config) !void {
    return config_files.saveRuntimeOptions(allocator, fs, io, cfg);
}

pub fn provisionBrainConfigFiles(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, cfg: Config) !void {
    return config_files.provisionBrainConfigFiles(allocator, fs, io, cfg);
}

pub fn saveLlmProviders(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, cfg: Config) !void {
    return config_files.saveLlmProviders(allocator, fs, io, cfg);
}

pub fn seedLlmProvidersFromTemplate(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, dest_path: []const u8, template_path: []const u8) !void {
    return config_files.seedLlmProvidersFromTemplate(allocator, fs, io, dest_path, template_path);
}

pub fn validateCapacityConfig(cfg: CapacityConfig) !void {
    return cognitive_capacity.validate(cfg);
}
