const std = @import("std");
const files = @import("../platform/common/files.zig");
const config_files = @import("config_files.zig");

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
    image_generation_model: []const u8 = "gemini-3.1-flash-image",
    image_generation_output_dir: []const u8 = "",
    autonomy_mode: []const u8 = "off",
    autonomy_interval_seconds: u64 = 300,
    autonomy_sleep: []const u8 = "off",
    autonomy_quiet_hours: []const u8 = "22:00-08:00",
    autonomy_speech_cooldown_minutes: u64 = 120,
    autonomy_daily_energy: u32 = 20,
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
    recognition_mode: []const u8 = "auto",
    recognition_command: []const u8 = "tools/affective-face-recognizer",
    description_mode: []const u8 = "random",
    identity_comparison_mode: []const u8 = "random",
    identity_comparison_model: []const u8 = "gpt-4.1-nano",
    face_detector_model: []const u8 = "models/face_detection_yunet_2023mar_int8.onnx",
    face_recognition_model: []const u8 = "models/face_recognition_sface_2021dec_int8.onnx",
    face_embeddings_dir: []const u8 = "",
    known_threshold: f32 = 0.85,
    uncertain_threshold: f32 = 0.60,
    memory_path: []const u8 = "",
    graph_path: []const u8 = "",
    seed_path: []const u8 = "data/seeds/default.md",
    events_path: []const u8 = "",
    maintenance_schedule_path: []const u8 = "",
    maintenance_state_path: []const u8 = "",
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

    pub fn fromArgs(args: []const []const u8) !Config {
        var cfg = Config{};
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if ((std.mem.eql(u8, args[i], "--brain") or std.mem.eql(u8, args[i], "--profile")) and i + 1 < args.len) {
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
            } else if (std.mem.eql(u8, args[i], "--image-generation-model") and i + 1 < args.len) {
                i += 1;
                cfg.image_generation_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--image-generation-output-dir") and i + 1 < args.len) {
                i += 1;
                cfg.image_generation_output_dir = args[i];
            } else if (std.mem.eql(u8, args[i], "--autonomy") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--autonomy-interval-seconds") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_interval_seconds = try std.fmt.parseInt(u64, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--autonomy-sleep") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_sleep = args[i];
            } else if (std.mem.eql(u8, args[i], "--autonomy-quiet-hours") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_quiet_hours = args[i];
            } else if (std.mem.eql(u8, args[i], "--autonomy-speech-cooldown-minutes") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_speech_cooldown_minutes = try std.fmt.parseInt(u64, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--autonomy-daily-energy") and i + 1 < args.len) {
                i += 1;
                cfg.autonomy_daily_energy = try std.fmt.parseInt(u32, args[i], 10);
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
            } else if (std.mem.eql(u8, args[i], "--events-path") and i + 1 < args.len) {
                i += 1;
                cfg.events_path = args[i];
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
            } else if (std.mem.eql(u8, args[i], "--recognition") and i + 1 < args.len) {
                i += 1;
                cfg.recognition_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--recognition-command") and i + 1 < args.len) {
                i += 1;
                cfg.recognition_command = args[i];
            } else if (std.mem.eql(u8, args[i], "--description") and i + 1 < args.len) {
                i += 1;
                cfg.description_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--identity-comparison") and i + 1 < args.len) {
                i += 1;
                cfg.identity_comparison_mode = args[i];
            } else if (std.mem.eql(u8, args[i], "--identity-comparison-model") and i + 1 < args.len) {
                i += 1;
                cfg.identity_comparison_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--face-detector-model") and i + 1 < args.len) {
                i += 1;
                cfg.face_detector_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--face-recognition-model") and i + 1 < args.len) {
                i += 1;
                cfg.face_recognition_model = args[i];
            } else if (std.mem.eql(u8, args[i], "--face-embeddings-dir") and i + 1 < args.len) {
                i += 1;
                cfg.face_embeddings_dir = args[i];
            }
        }
        return cfg;
    }

    pub fn withBrainPaths(self: Config, allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !Config {
        const home = env.get("HOME") orelse return error.MissingHome;
        if (home.len == 0) return error.MissingHome;
        const tmp = env.get("TMPDIR") orelse return error.MissingTmpDir;
        if (tmp.len == 0) return error.MissingTmpDir;
        const persistent_root = try std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "AffectiveCore" });
        const tmp_root = try std.fs.path.join(allocator, &.{ tmp, "affective-core" });
        return self.withBrainPathsForRoots(allocator, persistent_root, tmp_root);
    }

    pub fn withBrainPathsForRoots(self: Config, allocator: std.mem.Allocator, persistent_root: []const u8, tmp_root: []const u8) !Config {
        try config_files.validateBrainId(self.brain_id);
        var cfg = self;
        cfg.brain_id = try allocator.dupe(u8, self.brain_id);
        cfg.brain_root = try std.fs.path.join(allocator, &.{ persistent_root, "brains", cfg.brain_id });
        const tmp_brain_root = try std.fs.path.join(allocator, &.{ tmp_root, "brains", cfg.brain_id });
        if (self.memory_path.len == 0) cfg.memory_path = try config_files.brainPath(allocator, cfg.brain_root, "memory/people.sqlite");
        if (self.graph_path.len == 0) cfg.graph_path = try config_files.brainPath(allocator, cfg.brain_root, "memory/relationships.sqlite");
        if (self.events_path.len == 0) cfg.events_path = try config_files.brainPath(allocator, cfg.brain_root, "events.jsonl");
        if (self.maintenance_schedule_path.len == 0) cfg.maintenance_schedule_path = try config_files.brainPath(allocator, cfg.brain_root, "maintenance.md");
        if (self.maintenance_state_path.len == 0) cfg.maintenance_state_path = try config_files.brainPath(allocator, cfg.brain_root, "maintenance_state.json");
        if (self.runtime_options_path.len == 0) cfg.runtime_options_path = try config_files.brainPath(allocator, cfg.brain_root, "runtime_options.json");
        if (self.face_embeddings_dir.len == 0) cfg.face_embeddings_dir = try config_files.brainPath(allocator, cfg.brain_root, "memory/face_embeddings");
        if (self.captures_dir.len == 0) cfg.captures_dir = try config_files.brainPath(allocator, cfg.brain_root, "captures");
        if (self.capture_scratch_dir.len == 0) cfg.capture_scratch_dir = try config_files.brainPath(allocator, tmp_brain_root, "captures");
        if (self.audio_input_dir.len == 0) cfg.audio_input_dir = try config_files.brainPath(allocator, tmp_brain_root, "audio/input");
        if (self.audio_output_dir.len == 0) cfg.audio_output_dir = try config_files.brainPath(allocator, tmp_brain_root, "audio/output");
        if (self.image_generation_output_dir.len == 0) cfg.image_generation_output_dir = try config_files.brainPath(allocator, cfg.brain_root, "generated/images");
        return cfg;
    }

    pub fn withLlmConfig(self: Config, allocator: std.mem.Allocator, io: std.Io) !Config {
        var cfg = self;
        const loaded = try config_files.loadLlmConfig(allocator, io);
        if (loaded.mode) |mode| cfg.ai_mode = mode;
        if (loaded.reasoning_effort) |effort| cfg.conversation_reasoning_effort = effort;
        if (loaded.psyche_reasoning_effort) |effort| cfg.psyche_reasoning_effort = effort;
        if (loaded.models.len > 0) {
            cfg.conversation_models = loaded.models;
            if (loaded.default_model) |model| cfg.conversation_model = model;
        }
        if (loaded.psyche_models.len > 0) cfg.psyche_models = loaded.psyche_models;
        return cfg;
    }

    pub fn withEmailConfig(self: Config, allocator: std.mem.Allocator, io: std.Io) !Config {
        var cfg = self;
        const loaded = try config_files.loadEmailConfig(allocator, io);
        cfg.email_smtp_url = loaded.smtp_url;
        cfg.email_from = loaded.from;
        cfg.email_username = loaded.username;
        cfg.email_password = loaded.password;
        return cfg;
    }

    pub fn withRuntimeOptions(self: Config, allocator: std.mem.Allocator, io: std.Io) !Config {
        const bytes = files.readFileAllocPath(io, self.runtime_options_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
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
            .image_generation_model = self.image_generation_model,
            .image_generation_output_dir = self.image_generation_output_dir,
            .autonomy_mode = self.autonomy_mode,
            .autonomy_interval_seconds = self.autonomy_interval_seconds,
            .autonomy_sleep = self.autonomy_sleep,
            .autonomy_quiet_hours = self.autonomy_quiet_hours,
            .autonomy_speech_cooldown_minutes = self.autonomy_speech_cooldown_minutes,
            .autonomy_daily_energy = self.autonomy_daily_energy,
            .id_monitors_mode = self.id_monitors_mode,
            .id_monitor_interval_seconds = self.id_monitor_interval_seconds,
            .id_monitor_external_command = self.id_monitor_external_command,
            .id_monitor_external_restart_cooldown_seconds = self.id_monitor_external_restart_cooldown_seconds,
            .id_monitor_severity_threshold = self.id_monitor_severity_threshold,
            .psyche_mode = self.psyche_mode,
            .psyche_models = self.psyche_models,
            .psyche_reasoning_effort = self.psyche_reasoning_effort,
            .recognition_mode = self.recognition_mode,
            .recognition_command = self.recognition_command,
            .description_mode = self.description_mode,
            .identity_comparison_mode = self.identity_comparison_mode,
            .identity_comparison_model = self.identity_comparison_model,
            .face_detector_model = self.face_detector_model,
            .face_recognition_model = self.face_recognition_model,
            .face_embeddings_dir = self.face_embeddings_dir,
            .known_threshold = self.known_threshold,
            .uncertain_threshold = self.uncertain_threshold,
            .memory_path = self.memory_path,
            .graph_path = self.graph_path,
            .seed_path = self.seed_path,
            .events_path = self.events_path,
            .maintenance_schedule_path = self.maintenance_schedule_path,
            .maintenance_state_path = self.maintenance_state_path,
            .runtime_options_path = self.runtime_options_path,
            .captures_dir = self.captures_dir,
            .conversation_idle_timeout_seconds = self.conversation_idle_timeout_seconds,
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

    pub fn withBrainSettings(self: Config, settings: BrainSettings) Config {
        var cfg = self;
        if (settings.brain_id.len > 0) cfg.brain_id = settings.brain_id;
        if (settings.brain_root.len > 0) cfg.brain_root = settings.brain_root;
        if (settings.ai_mode.len > 0) cfg.ai_mode = settings.ai_mode;
        if (settings.intent_mode.len > 0) cfg.intent_mode = settings.intent_mode;
        if (settings.intent_model.len > 0) cfg.intent_model = settings.intent_model;
        if (settings.conversation_model.len > 0) cfg.conversation_model = settings.conversation_model;
        if (settings.conversation_models.len > 0) cfg.conversation_models = settings.conversation_models;
        if (settings.conversation_reasoning_effort.len > 0) cfg.conversation_reasoning_effort = settings.conversation_reasoning_effort;
        if (settings.image_generation_model.len > 0) cfg.image_generation_model = settings.image_generation_model;
        if (settings.image_generation_output_dir.len > 0) cfg.image_generation_output_dir = settings.image_generation_output_dir;
        if (settings.autonomy_mode.len > 0) cfg.autonomy_mode = settings.autonomy_mode;
        if (settings.autonomy_interval_seconds) |v| cfg.autonomy_interval_seconds = v;
        if (settings.autonomy_sleep.len > 0) cfg.autonomy_sleep = settings.autonomy_sleep;
        if (settings.autonomy_quiet_hours.len > 0) cfg.autonomy_quiet_hours = settings.autonomy_quiet_hours;
        if (settings.autonomy_speech_cooldown_minutes) |v| cfg.autonomy_speech_cooldown_minutes = v;
        if (settings.autonomy_daily_energy) |v| cfg.autonomy_daily_energy = v;
        if (settings.id_monitors_mode.len > 0) cfg.id_monitors_mode = settings.id_monitors_mode;
        if (settings.id_monitor_interval_seconds) |v| cfg.id_monitor_interval_seconds = v;
        if (settings.id_monitor_external_command.len > 0) cfg.id_monitor_external_command = settings.id_monitor_external_command;
        if (settings.id_monitor_external_restart_cooldown_seconds) |v| cfg.id_monitor_external_restart_cooldown_seconds = v;
        if (settings.id_monitor_severity_threshold.len > 0) cfg.id_monitor_severity_threshold = settings.id_monitor_severity_threshold;
        if (settings.psyche_mode.len > 0) cfg.psyche_mode = settings.psyche_mode;
        if (settings.psyche_models.len > 0) cfg.psyche_models = settings.psyche_models;
        if (settings.psyche_reasoning_effort.len > 0) cfg.psyche_reasoning_effort = settings.psyche_reasoning_effort;
        if (settings.recognition_mode.len > 0) cfg.recognition_mode = settings.recognition_mode;
        if (settings.recognition_command.len > 0) cfg.recognition_command = settings.recognition_command;
        if (settings.description_mode.len > 0) cfg.description_mode = settings.description_mode;
        if (settings.identity_comparison_mode.len > 0) cfg.identity_comparison_mode = settings.identity_comparison_mode;
        if (settings.identity_comparison_model.len > 0) cfg.identity_comparison_model = settings.identity_comparison_model;
        if (settings.face_detector_model.len > 0) cfg.face_detector_model = settings.face_detector_model;
        if (settings.face_recognition_model.len > 0) cfg.face_recognition_model = settings.face_recognition_model;
        if (settings.face_embeddings_dir.len > 0) cfg.face_embeddings_dir = settings.face_embeddings_dir;
        if (settings.known_threshold) |v| cfg.known_threshold = v;
        if (settings.uncertain_threshold) |v| cfg.uncertain_threshold = v;
        if (settings.memory_path.len > 0) cfg.memory_path = settings.memory_path;
        if (settings.graph_path.len > 0) cfg.graph_path = settings.graph_path;
        if (settings.seed_path.len > 0) cfg.seed_path = settings.seed_path;
        if (settings.events_path.len > 0) cfg.events_path = settings.events_path;
        if (settings.maintenance_schedule_path.len > 0) cfg.maintenance_schedule_path = settings.maintenance_schedule_path;
        if (settings.maintenance_state_path.len > 0) cfg.maintenance_state_path = settings.maintenance_state_path;
        if (settings.runtime_options_path.len > 0) cfg.runtime_options_path = settings.runtime_options_path;
        if (settings.captures_dir.len > 0) cfg.captures_dir = settings.captures_dir;
        if (settings.conversation_idle_timeout_seconds) |v| cfg.conversation_idle_timeout_seconds = v;
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
    image_generation_model: []const u8 = "",
    image_generation_output_dir: []const u8 = "",
    autonomy_mode: []const u8 = "",
    autonomy_interval_seconds: ?u64 = null,
    autonomy_sleep: []const u8 = "",
    autonomy_quiet_hours: []const u8 = "",
    autonomy_speech_cooldown_minutes: ?u64 = null,
    autonomy_daily_energy: ?u32 = null,
    id_monitors_mode: []const u8 = "",
    id_monitor_interval_seconds: ?u64 = null,
    id_monitor_external_command: []const u8 = "",
    id_monitor_external_restart_cooldown_seconds: ?u64 = null,
    id_monitor_severity_threshold: []const u8 = "",
    psyche_mode: []const u8 = "",
    psyche_models: []const u8 = "",
    psyche_reasoning_effort: []const u8 = "",
    recognition_mode: []const u8 = "",
    recognition_command: []const u8 = "",
    description_mode: []const u8 = "",
    identity_comparison_mode: []const u8 = "",
    identity_comparison_model: []const u8 = "",
    face_detector_model: []const u8 = "",
    face_recognition_model: []const u8 = "",
    face_embeddings_dir: []const u8 = "",
    known_threshold: ?f32 = null,
    uncertain_threshold: ?f32 = null,
    memory_path: []const u8 = "",
    graph_path: []const u8 = "",
    seed_path: []const u8 = "",
    events_path: []const u8 = "",
    maintenance_schedule_path: []const u8 = "",
    maintenance_state_path: []const u8 = "",
    runtime_options_path: []const u8 = "",
    captures_dir: []const u8 = "",
    conversation_idle_timeout_seconds: ?u64 = null,
};

pub const RecognitionPlatform = enum { macos, radxa };

pub fn effectiveRecognitionMode(cfg: Config, platform: RecognitionPlatform) []const u8 {
    if (!std.mem.eql(u8, cfg.recognition_mode, "auto")) return cfg.recognition_mode;
    return switch (platform) {
        .macos => "command",
        .radxa => "command",
    };
}

pub const LoadedEmailConfig = config_files.LoadedEmailConfig;

pub fn loadEmailConfig(allocator: std.mem.Allocator, io: std.Io) !LoadedEmailConfig {
    return config_files.loadEmailConfig(allocator, io);
}

pub fn parseEmailConfig(allocator: std.mem.Allocator, bytes: []const u8) !LoadedEmailConfig {
    return config_files.parseEmailConfig(allocator, bytes);
}

pub fn parseRuntimeOptionsConfig(allocator: std.mem.Allocator, base: Config, bytes: []const u8) !Config {
    return config_files.parseRuntimeOptionsConfig(allocator, base, bytes);
}

pub fn saveRuntimeOptions(io: std.Io, cfg: Config) !void {
    return config_files.saveRuntimeOptions(io, cfg);
}
