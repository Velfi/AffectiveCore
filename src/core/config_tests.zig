const std = @import("std");
const config = @import("config.zig");
const Config = config.Config;
const effectiveRecognitionMode = config.effectiveRecognitionMode;
const parseEmailConfig = config.parseEmailConfig;
const loadEmailConfig = config.loadEmailConfig;
const parseRuntimeOptionsConfig = config.parseRuntimeOptionsConfig;

test "config parses autonomy flags" {
    const cfg = try Config.fromArgs(&.{
        "--autonomy",
        "on",
        "--autonomy-interval-seconds",
        "60",
        "--autonomy-sleep",
        "on",
        "--autonomy-quiet-hours",
        "21:30-07:15",
        "--autonomy-speech-cooldown-minutes",
        "45",
        "--autonomy-daily-energy",
        "12",
        "--psyche",
        "off",
        "--psyche-models",
        "openai:gpt-4.1-nano",
        "--psyche-reasoning-effort",
        "low",
    });
    try std.testing.expectEqualStrings("on", cfg.autonomy_mode);
    try std.testing.expectEqual(@as(u64, 60), cfg.autonomy_interval_seconds);
    try std.testing.expectEqualStrings("on", cfg.autonomy_sleep);
    try std.testing.expectEqualStrings("21:30-07:15", cfg.autonomy_quiet_hours);
    try std.testing.expectEqual(@as(u64, 45), cfg.autonomy_speech_cooldown_minutes);
    try std.testing.expectEqual(@as(u32, 12), cfg.autonomy_daily_energy);
    try std.testing.expectEqualStrings("off", cfg.psyche_mode);
    try std.testing.expectEqualStrings("openai:gpt-4.1-nano", cfg.psyche_models);
    try std.testing.expectEqualStrings("low", cfg.psyche_reasoning_effort);
}

test "config defaults to auto recognition" {
    const cfg = try Config.fromArgs(&.{});
    try std.testing.expectEqualStrings("auto", cfg.recognition_mode);
    try std.testing.expectEqualStrings("command", effectiveRecognitionMode(cfg, .macos));
    try std.testing.expectEqualStrings("command", effectiveRecognitionMode(.{ .camera_mode = "webcam" }, .macos));
    try std.testing.expectEqualStrings("command", effectiveRecognitionMode(cfg, .radxa));
}

test "brain derives isolated runtime paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try Config.fromArgs(&.{ "--brain", "ada" });
    const cfg = try parsed.withBrainPathsForRoots(allocator, "/Users/test/Library/Application Support/AffectiveCore", "/tmp/affective-core");

    try std.testing.expectEqualStrings("ada", cfg.brain_id);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/AffectiveCore/brains/ada", cfg.brain_root);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/AffectiveCore/brains/ada/memory/people.sqlite", cfg.memory_path);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/AffectiveCore/brains/ada/memory/relationships.sqlite", cfg.graph_path);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/AffectiveCore/brains/ada/events.jsonl", cfg.events_path);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/AffectiveCore/brains/ada/runtime_options.json", cfg.runtime_options_path);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/AffectiveCore/brains/ada/memory/face_embeddings", cfg.face_embeddings_dir);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/AffectiveCore/brains/ada/captures", cfg.captures_dir);
    try std.testing.expectEqualStrings("/tmp/affective-core/brains/ada/captures", cfg.capture_scratch_dir);
    try std.testing.expectEqualStrings("/tmp/affective-core/brains/ada/audio/input", cfg.audio_input_dir);
    try std.testing.expectEqualStrings("/tmp/affective-core/brains/ada/audio/output", cfg.audio_output_dir);
    try std.testing.expectEqualStrings("/Users/test/Library/Application Support/AffectiveCore/brains/ada/generated/images", cfg.image_generation_output_dir);
}

test "legacy profile flag maps to brain id" {
    const cfg = try Config.fromArgs(&.{ "--profile", "ada" });
    try std.testing.expectEqualStrings("ada", cfg.brain_id);
}

test "brain rejects path-like names" {
    const parsed = try Config.fromArgs(&.{ "--brain", "../ada" });
    try std.testing.expectError(error.InvalidBrainId, parsed.withBrainPathsForRoots(std.testing.allocator, "/Users/test/Library/Application Support/AffectiveCore", "/tmp/affective-core"));
}

test "config parses speech voice flag" {
    const defaults = try Config.fromArgs(&.{});
    try std.testing.expectEqualStrings("Fred", defaults.speech_voice);

    const cfg = try Config.fromArgs(&.{ "--speech-voice", "Samantha" });
    try std.testing.expectEqualStrings("Samantha", cfg.speech_voice);
}

test "client settings isolate frontend and speech IO choices" {
    const cfg = Config{
        .brain_id = "ada",
        .activation_mode = "webview",
        .camera_mode = "webcam",
        .speech_mode = "say",
        .speech_voice = "Samantha",
        .transcription_mode = "voice",
        .transcription_command = "/bin/whisper",
        .transcription_model = "models/base.bin",
        .speaker_command = "afplay",
        .button_line = "22",
        .button_hold_ms = 620,
        .audio_input_dir = "/tmp/audio/in",
        .audio_output_dir = "/tmp/audio/out",
        .capture_scratch_dir = "/tmp/captures",
        .autonomy_mode = "on",
        .conversation_model = "gpt-4.1-mini",
    };

    const client = cfg.clientSettings();
    try std.testing.expectEqualStrings("ada", client.client_id);
    try std.testing.expectEqualStrings("mac_webview", client.frontend_kind);
    try std.testing.expectEqualStrings("webview", client.activation_mode);
    try std.testing.expectEqualStrings("say", client.speech_mode);
    try std.testing.expectEqualStrings("Samantha", client.speech_voice);
    try std.testing.expectEqualStrings("voice", client.transcription_mode);
    try std.testing.expectEqualStrings("/bin/whisper", client.transcription_command);
    try std.testing.expectEqualStrings("afplay", client.speaker_command);
    try std.testing.expectEqual(@as(?u64, 620), client.button_hold_ms);

    const updated = cfg.withClientSettings(.{
        .speech_mode = "none",
        .speech_voice = "Fred",
        .transcription_mode = "terminal",
        .speaker_command = "aplay",
        .button_hold_ms = 900,
    });
    try std.testing.expectEqualStrings("none", updated.speech_mode);
    try std.testing.expectEqualStrings("Fred", updated.speech_voice);
    try std.testing.expectEqualStrings("terminal", updated.transcription_mode);
    try std.testing.expectEqualStrings("aplay", updated.speaker_command);
    try std.testing.expectEqual(@as(u64, 900), updated.button_hold_ms);
    try std.testing.expectEqualStrings("on", updated.autonomy_mode);
    try std.testing.expectEqualStrings("gpt-4.1-mini", updated.conversation_model);
}

test "brain settings isolate central cognition and storage choices" {
    const cfg = Config{
        .brain_id = "otto",
        .speech_mode = "say",
        .speech_voice = "Samantha",
        .transcription_mode = "voice",
        .speaker_command = "afplay",
        .ai_mode = "openai",
        .conversation_model = "gpt-4.1",
        .autonomy_mode = "off",
        .autonomy_interval_seconds = 300,
        .memory_path = "data/otto/memory.sqlite",
        .graph_path = "data/otto/graph.sqlite",
        .email_smtp_url = "smtps://smtp.example.com:465",
        .email_from = "otto@example.com",
        .email_password = "secret",
    };

    const brain = cfg.brainSettings();
    try std.testing.expectEqualStrings("otto", brain.brain_id);
    try std.testing.expectEqualStrings("openai", brain.ai_mode);
    try std.testing.expectEqualStrings("gpt-4.1", brain.conversation_model);
    try std.testing.expectEqualStrings("off", brain.autonomy_mode);
    try std.testing.expectEqual(@as(?u64, 300), brain.autonomy_interval_seconds);
    try std.testing.expectEqualStrings("data/otto/memory.sqlite", brain.memory_path);

    const updated = cfg.withBrainSettings(.{
        .brain_id = "otto",
        .ai_mode = "random",
        .conversation_model = "gpt-4.1-mini",
        .autonomy_mode = "on",
        .autonomy_interval_seconds = 45,
        .memory_path = "data/otto/new-memory.sqlite",
    });
    try std.testing.expectEqualStrings("random", updated.ai_mode);
    try std.testing.expectEqualStrings("gpt-4.1-mini", updated.conversation_model);
    try std.testing.expectEqualStrings("on", updated.autonomy_mode);
    try std.testing.expectEqual(@as(u64, 45), updated.autonomy_interval_seconds);
    try std.testing.expectEqualStrings("smtps://smtp.example.com:465", updated.email_smtp_url);
    try std.testing.expectEqualStrings("secret", updated.email_password);
    try std.testing.expectEqualStrings("data/otto/new-memory.sqlite", updated.memory_path);
    try std.testing.expectEqualStrings("say", updated.speech_mode);
    try std.testing.expectEqualStrings("Samantha", updated.speech_voice);
    try std.testing.expectEqualStrings("voice", updated.transcription_mode);
    try std.testing.expectEqualStrings("afplay", updated.speaker_command);
}

test "config parses recognition command flags" {
    const cfg = try Config.fromArgs(&.{
        "--recognition",
        "command",
        "--recognition-command",
        "/usr/local/bin/affective-face-recognizer",
        "--description",
        "random",
        "--identity-comparison",
        "random",
        "--identity-comparison-model",
        "gpt-4.1-mini",
        "--face-detector-model",
        "models/yunet.onnx",
        "--face-recognition-model",
        "models/sface.onnx",
        "--face-embeddings-dir",
        "data/faces",
    });
    try std.testing.expectEqualStrings("command", cfg.recognition_mode);
    try std.testing.expectEqualStrings("/usr/local/bin/affective-face-recognizer", cfg.recognition_command);
    try std.testing.expectEqualStrings("random", cfg.description_mode);
    try std.testing.expectEqualStrings("random", cfg.identity_comparison_mode);
    try std.testing.expectEqualStrings("gpt-4.1-mini", cfg.identity_comparison_model);
    try std.testing.expectEqualStrings("models/yunet.onnx", cfg.face_detector_model);
    try std.testing.expectEqualStrings("models/sface.onnx", cfg.face_recognition_model);
    try std.testing.expectEqualStrings("data/faces", cfg.face_embeddings_dir);
}

test "email config parses SMTP settings and auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const loaded = try parseEmailConfig(allocator,
        \\{
        \\  "smtp_url": "smtps://smtp.example.com:465",
        \\  "from": "brain@example.com",
        \\  "username": "brain@example.com",
        \\  "password": "secret"
        \\}
    );
    try std.testing.expectEqualStrings("smtps://smtp.example.com:465", loaded.smtp_url);
    try std.testing.expectEqualStrings("brain@example.com", loaded.from);
    try std.testing.expectEqualStrings("brain@example.com", loaded.username);
    try std.testing.expectEqualStrings("secret", loaded.password);
}

test "missing email config disables email without error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const loaded = try loadEmailConfig(allocator, std.testing.io);
    try std.testing.expectEqualStrings("", loaded.smtp_url);
    try std.testing.expectEqualStrings("", loaded.from);
    try std.testing.expectEqualStrings("", loaded.username);
    try std.testing.expectEqualStrings("", loaded.password);
}

test "email config rejects half configured auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.MissingEmailPassword, parseEmailConfig(allocator,
        \\{
        \\  "smtp_url": "smtps://smtp.example.com:465",
        \\  "from": "brain@example.com",
        \\  "username": "brain@example.com"
        \\}
    ));
}

test "runtime options override persisted preferences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cfg = try parseRuntimeOptionsConfig(allocator, .{},
        \\{
        \\  "activation_mode": "webview",
        \\  "transcription_mode": "voice",
        \\  "speech_mode": "say",
        \\  "seed_path": "data/seeds/otto.md",
        \\  "recognition_mode": "descriptive",
        \\  "autonomy_mode": "on",
        \\  "speech_voice": "Samantha",
        \\  "button_hold_ms": 750,
        \\  "known_threshold": 0.9,
        \\  "maintenance_state_path": "data/custom_state.json"
        \\}
    );
    try std.testing.expectEqualStrings("webview", cfg.activation_mode);
    try std.testing.expectEqualStrings("voice", cfg.transcription_mode);
    try std.testing.expectEqualStrings("say", cfg.speech_mode);
    try std.testing.expectEqualStrings("data/seeds/otto.md", cfg.seed_path);
    try std.testing.expectEqualStrings("descriptive", cfg.recognition_mode);
    try std.testing.expectEqualStrings("on", cfg.autonomy_mode);
    try std.testing.expectEqualStrings("Samantha", cfg.speech_voice);
    try std.testing.expectEqual(@as(u64, 750), cfg.button_hold_ms);
    try std.testing.expectEqual(@as(f32, 0.9), cfg.known_threshold);
    try std.testing.expectEqualStrings("data/custom_state.json", cfg.maintenance_state_path);
}
