const std = @import("std");
const transcription = @import("../../api/transcription_client.zig");
const files = @import("files.zig");
const input_mod = @import("input.zig");
const process = @import("process.zig");

pub const RecordingInput = struct {
    pub const Recorder = enum { macos_avfoundation, linux_alsa };
    pub const HoldSignal = struct {
        ctx: *anyopaque,
        isHeldFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!bool,
        releaseKindFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!HoldReleaseKind,

        pub fn isHeld(self: HoldSignal, allocator: std.mem.Allocator) !bool {
            return self.isHeldFn(self.ctx, allocator);
        }

        pub fn releaseKind(self: HoldSignal, allocator: std.mem.Allocator) !HoldReleaseKind {
            return self.releaseKindFn(self.ctx, allocator);
        }
    };
    pub const HoldReleaseKind = enum { short_touch, long_touch };

    io: std.Io,
    transcription_service: transcription.TranscriptionService,
    push_to_talk_stdin: ?*std.Io.Reader,
    recorder: Recorder,
    audio_dir: []const u8 = "data/audio/input",
    seconds: []const u8 = "4",

    pub fn init(io: std.Io, recorder: Recorder, transcription_service: transcription.TranscriptionService, push_to_talk_stdin: ?*std.Io.Reader) RecordingInput {
        return .{ .io = io, .recorder = recorder, .transcription_service = transcription_service, .push_to_talk_stdin = push_to_talk_stdin };
    }

    pub fn input(self: *RecordingInput) input_mod.UserInput {
        return .{ .ctx = self, .askFn = ask, .isActiveFn = isActive };
    }

    pub fn inputWithHold(self: *RecordingInput, hold: HoldSignal) input_mod.UserInput {
        const HeldInput = struct {
            recorder: *RecordingInput,
            hold_signal: HoldSignal,

            fn askHeld(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8) !input_mod.HeardSpeech {
                const held: *@This() = @ptrCast(@alignCast(ctx));
                return held.recorder.askRecordingHeld(allocator, prompt, held.hold_signal);
            }

            fn isActiveHeld(ctx: *anyopaque, allocator: std.mem.Allocator) !bool {
                const held: *@This() = @ptrCast(@alignCast(ctx));
                return held.hold_signal.isHeld(allocator);
            }
        };
        const held = allocatorCreate(HeldInput, .{ .recorder = self, .hold_signal = hold }) catch unreachable;
        return .{ .ctx = held, .askFn = HeldInput.askHeld, .isActiveFn = HeldInput.isActiveHeld };
    }

    fn ask(ctx: *anyopaque, allocator: std.mem.Allocator, prompt: []const u8) !input_mod.HeardSpeech {
        const self: *RecordingInput = @ptrCast(@alignCast(ctx));
        std.debug.print("\nBRAIN:\n{s}\n\nPress to wake, hold to speak; release to send.\n", .{prompt});
        const stamp = std.Io.Clock.real.now(self.io).toMilliseconds();
        const audio_path = try std.fmt.allocPrint(allocator, "{s}/utterance_{d}.wav", .{ self.audio_dir, stamp });
        try files.ensureParentDir(self.io, audio_path);
        try self.recordPushToTalk(allocator, audio_path);
        try self.ensureRecordedAudio(audio_path);
        const result = try self.transcription_service.transcribe(allocator, audio_path);
        std.debug.print("YOU: {s}\n", .{result.text});
        return heardSpeechFromTranscription(result);
    }

    fn isActive(ctx: *anyopaque, allocator: std.mem.Allocator) !bool {
        _ = ctx;
        _ = allocator;
        return false;
    }

    fn askRecordingHeld(self: *RecordingInput, allocator: std.mem.Allocator, prompt: []const u8, hold: HoldSignal) !input_mod.HeardSpeech {
        std.debug.print("\nBRAIN:\n{s}\n\nHold to speak; release to send.\n", .{prompt});
        const stamp = std.Io.Clock.real.now(self.io).toMilliseconds();
        const audio_path = try std.fmt.allocPrint(allocator, "{s}/utterance_{d}.wav", .{ self.audio_dir, stamp });
        try files.ensureParentDir(self.io, audio_path);
        try self.requireActiveHold(allocator, hold);
        const release_kind = try self.recordWhileHeld(allocator, audio_path, hold);
        if (release_kind == .short_touch) return error.ShortTouchStimulus;
        try self.ensureRecordedAudio(audio_path);
        const result = try self.transcription_service.transcribe(allocator, audio_path);
        if (std.mem.trim(u8, result.text, " \r\n\t").len == 0) return error.LongTouchStimulus;
        std.debug.print("YOU: {s}\n", .{result.text});
        return heardSpeechFromTranscription(result);
    }

    fn ensureRecordedAudio(self: *RecordingInput, audio_path: []const u8) !void {
        const stat = files.statFilePath(self.io, audio_path) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Recording failed: expected audio file was not created: {s}\n", .{audio_path});
                return error.RecordingFileMissing;
            },
            else => return err,
        };
        if (stat.size == 0) {
            std.debug.print("Recording failed: audio file is empty: {s}\n", .{audio_path});
            return error.RecordingFileEmpty;
        }
    }

    fn recordPushToTalk(self: *RecordingInput, allocator: std.mem.Allocator, audio_path: []const u8) !void {
        if (self.push_to_talk_stdin) |stdin| {
            std.debug.print("Press Enter to start speaking: ", .{});
            const start = (try stdin.takeDelimiter('\n')) orelse return error.UserQuit;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, start, " \r\n\t"), "quit")) return error.UserQuit;

            var child = try self.spawnRecorder(audio_path);
            std.debug.print("Recording. Press Enter to release/send: ", .{});
            _ = try stdin.takeDelimiter('\n');
            child.kill(self.io);
            return;
        }

        switch (self.recorder) {
            .macos_avfoundation => try process.runCommand(allocator, self.io, &.{
                "ffmpeg",
                "-y",
                "-f",
                "avfoundation",
                "-i",
                ":0",
                "-t",
                self.seconds,
                "-ar",
                "16000",
                "-ac",
                "1",
                audio_path,
            }),
            .linux_alsa => try process.runCommand(allocator, self.io, &.{
                "ffmpeg",
                "-y",
                "-f",
                "alsa",
                "-i",
                "default",
                "-t",
                self.seconds,
                "-ar",
                "16000",
                "-ac",
                "1",
                audio_path,
            }),
        }
    }

    fn recordWhileHeld(self: *RecordingInput, allocator: std.mem.Allocator, audio_path: []const u8, hold: HoldSignal) !HoldReleaseKind {
        var child = try self.spawnRecorder(audio_path);
        while (try hold.isHeld(allocator)) {
            try std.Io.sleep(self.io, .fromMilliseconds(20), .awake);
        }
        child.kill(self.io);
        return try hold.releaseKind(allocator);
    }

    fn requireActiveHold(self: *RecordingInput, allocator: std.mem.Allocator, hold: HoldSignal) !void {
        _ = self;
        if (!try hold.isHeld(allocator)) return error.HoldReleasedBeforeRecordingStarted;
    }

    fn allocatorCreate(comptime T: type, value: T) !*T {
        const ptr = try std.heap.page_allocator.create(T);
        ptr.* = value;
        return ptr;
    }

    fn spawnRecorder(self: *RecordingInput, audio_path: []const u8) !std.process.Child {
        const argv: []const []const u8 = switch (self.recorder) {
            .macos_avfoundation => &[_][]const u8{
                "ffmpeg",
                "-y",
                "-f",
                "avfoundation",
                "-i",
                ":0",
                "-ar",
                "16000",
                "-ac",
                "1",
                audio_path,
            },
            .linux_alsa => &[_][]const u8{
                "ffmpeg",
                "-y",
                "-f",
                "alsa",
                "-i",
                "default",
                "-ar",
                "16000",
                "-ac",
                "1",
                audio_path,
            },
        };
        return std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("Command not found: ffmpeg\n", .{});
                return err;
            },
            else => return err,
        };
    }
};

fn heardSpeechFromTranscription(result: transcription.TranscriptionResult) input_mod.HeardSpeech {
    return .{
        .text = result.text,
        .source = .speech_transcription,
        .provider = result.provider,
        .model_path = result.model_path,
        .audio_path = result.audio_path,
        .raw_provider_json_path = result.raw_provider_json_path,
        .summary_json = result.summary_json,
    };
}

test "recording validation rejects missing audio file" {
    var transcriber = transcription.TestTranscriptionService{};
    var recorder = RecordingInput.init(std.testing.io, .macos_avfoundation, transcriber.service(), null);
    const path = "data/test/missing_voice_input_recording.wav";
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try std.testing.expectError(error.RecordingFileMissing, recorder.ensureRecordedAudio(path));
}

test "recording validation rejects empty audio file" {
    var transcriber = transcription.TestTranscriptionService{};
    var recorder = RecordingInput.init(std.testing.io, .macos_avfoundation, transcriber.service(), null);
    const path = "data/test/empty_voice_input_recording.wav";

    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "", .flags = .{ .truncate = true } });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try std.testing.expectError(error.RecordingFileEmpty, recorder.ensureRecordedAudio(path));
}

test "held recording fails when hold was released before recording starts" {
    const ReleasedHold = struct {
        fn isHeld(_: *anyopaque, _: std.mem.Allocator) !bool {
            return false;
        }

        fn releaseKind(_: *anyopaque, _: std.mem.Allocator) !RecordingInput.HoldReleaseKind {
            return .short_touch;
        }
    };
    var transcriber = transcription.TestTranscriptionService{};
    var recorder = RecordingInput.init(std.testing.io, .macos_avfoundation, transcriber.service(), null);
    var ctx: u8 = 0;
    try std.testing.expectError(error.HoldReleasedBeforeRecordingStarted, recorder.requireActiveHold(std.testing.allocator, .{
        .ctx = &ctx,
        .isHeldFn = ReleasedHold.isHeld,
        .releaseKindFn = ReleasedHold.releaseKind,
    }));
}
