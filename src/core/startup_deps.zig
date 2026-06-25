const std = @import("std");
const config_mod = @import("config.zig");

pub fn checkMacos(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cfg: config_mod.Config) !void {
    if (std.mem.eql(u8, cfg.activation_mode, "webview")) {
        try requireCommand(allocator, io, env, cfg.transcription_command, "voice transcription");
        try requireFile(io, cfg.transcription_model, "voice transcription model");
    }

    if (isMacosSaySpeechMode(cfg.speech_mode)) {
        try requireCommand(allocator, io, env, "say", "speech synthesis");
        try requireCommand(allocator, io, env, "afplay", "speech playback");
    }

    if (std.mem.eql(u8, config_mod.effectiveRecognitionMode(cfg, .macos), "command")) {
        try requireCommand(allocator, io, env, cfg.recognition_command, "face recognition");
        try requireFile(io, cfg.face_detector_model, "face detection model");
        try requireFile(io, cfg.face_recognition_model, "face recognition model");
    }

    if (cfg.email_smtp_url.len > 0) {
        try requireCommand(allocator, io, env, "curl", "email delivery");
    }
}

pub fn checkRadxa(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, cfg: config_mod.Config) !void {
    try requireCommand(allocator, io, env, "rpicam-still", "camera capture");
    try requireCommand(allocator, io, env, "gpioget", "button input");

    if (!std.mem.eql(u8, cfg.transcription_mode, "terminal")) {
        try requireCommand(allocator, io, env, cfg.transcription_command, "voice transcription");
        try requireFile(io, cfg.transcription_model, "voice transcription model");
    }

    try requireCommand(allocator, io, env, "say", "speech synthesis");
    try requireCommand(allocator, io, env, cfg.speaker_command, "speech playback");

    if (std.mem.eql(u8, config_mod.effectiveRecognitionMode(cfg, .radxa), "command")) {
        try requireCommand(allocator, io, env, cfg.recognition_command, "face recognition");
        try requireFile(io, cfg.face_detector_model, "face detection model");
        try requireFile(io, cfg.face_recognition_model, "face recognition model");
    }

    if (cfg.email_smtp_url.len > 0) {
        try requireCommand(allocator, io, env, "curl", "email delivery");
    }
}

fn requireCommand(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, command: []const u8, purpose: []const u8) !void {
    if (commandAvailable(allocator, io, env, command)) return;
    std.debug.print("STARTUP ERROR: missing command `{s}` for {s}.\n", .{ command, purpose });
    return error.MissingStartupCommand;
}

fn requireFile(io: std.Io, path: []const u8, purpose: []const u8) !void {
    if (fileAvailable(io, path)) return;
    std.debug.print("STARTUP ERROR: missing file `{s}` for {s}.\n", .{ path, purpose });
    return error.MissingStartupFile;
}

fn commandAvailable(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, command: []const u8) bool {
    if (std.mem.indexOfScalar(u8, command, '/') != null) return fileAvailable(io, command);

    const path = env.get("PATH") orelse return false;
    var parts = std.mem.splitScalar(u8, path, ':');
    while (parts.next()) |dir| {
        const base = if (dir.len == 0) "." else dir;
        const candidate = std.fs.path.join(allocator, &.{ base, command }) catch continue;
        defer allocator.free(candidate);
        if (fileAvailable(io, candidate)) return true;
    }
    return false;
}

fn fileAvailable(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn isMacosSaySpeechMode(mode: []const u8) bool {
    return std.mem.eql(u8, mode, "speak-n-spell") or std.mem.eql(u8, mode, "say");
}
