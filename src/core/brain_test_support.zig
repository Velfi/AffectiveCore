const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const store_mod = ports.store;
const graph_store = ports.graph_store;
const intent_mod = ports.intent;
const openai = ports.openai;
const greeting_client = ports.greeting;
const chat_mod = ports.chat;
const speech_mod = ports.speech;
const audio_mod = ports.audio;
const image_mod = ports.image;
const want_achievement_mod = ports.want_achievement;
const camera_mod = ports.camera;
const input_mod = ports.input;
const speaker_mod = ports.speaker;
const system_senses_mod = ports.system_senses;
const files_mod = ports.files;
const clock_mod = ports.clock;
const command_log_mod = ports.command_log;
const facial_expression = ports.facial_expression;
const process_mod = ports.process;
const id_monitor = @import("id_monitor.zig");
const maintenance = @import("maintenance.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
pub const TestStore = @import("brain_test_store.zig").TestStore;

pub const TestCamera = struct {
    image: []const u8,
    fn camera(self: *TestCamera) camera_mod.Camera {
        return .{ .ctx = self, .captureFn = capture };
    }
    fn capture(ctx: *anyopaque, _: std.mem.Allocator) !events.ImageCapture {
        const self: *TestCamera = @ptrCast(@alignCast(ctx));
        return .{ .path = self.image, .temporary = true };
    }
};

/// Mirrors the real frontend camera: every capture is an awaited pull, signalled
/// by raising FrontendCaptureRequested rather than returning a frame inline.
pub const FrontendPullCamera = struct {
    pub fn camera(self: *FrontendPullCamera) camera_mod.Camera {
        return .{ .ctx = self, .captureFn = capture };
    }
    fn capture(_: *anyopaque, _: std.mem.Allocator) !events.ImageCapture {
        return error.FrontendCaptureRequested;
    }
};

/// Chooses to look (recognize) on the first turn; the awaited host sense should
/// pause the conversation until the observation arrives.
pub const ScriptedRecognizeThenSayChatService = struct {
    calls: usize = 0,

    pub fn service(self: *ScriptedRecognizeThenSayChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedRecognizeThenSayChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            try std.testing.expect(std.mem.indexOf(u8, observations, "social_context:") != null);
            try std.testing.expect(std.mem.indexOf(u8, observations, "camera_pullable: true") != null);
            const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
            commands[0] = .{ .command = .recognize };
            return .{
                .commands = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Chose to look at who is here."),
                .conversation_done = false,
            };
        }
        return error.UnexpectedSecondSensePullTurn;
    }
};

pub const TestRecognitionClient = struct {
    known_threshold: f32 = 0.85,
    uncertain_threshold: f32 = 0.60,

    pub fn recognizer(self: *TestRecognitionClient) identity.IdentityRecognizer {
        return .{ .ctx = self, .identifyFn = identify };
    }

    fn identify(ctx: *anyopaque, _: std.mem.Allocator, path: []const u8) !identity.IdentityResult {
        const self: *TestRecognitionClient = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, path, "empty") != null) {
            return .{ .person_present = false, .match_status = .none, .confidence = 0, .people_count = 0 };
        }
        if (std.mem.indexOf(u8, path, "known_changed") != null) {
            const confidence: f32 = 0.72;
            return .{
                .person_present = true,
                .match_status = identity.statusFromConfidence(true, confidence, self.known_threshold, self.uncertain_threshold),
                .person_id = "person_001",
                .confidence = confidence,
                .candidate_name = "Mara",
                .people_count = 1,
            };
        }
        if (std.mem.indexOf(u8, path, "unknown") != null) {
            return .{ .person_present = true, .match_status = .unknown, .confidence = 0.40, .people_count = 1 };
        }
        if (std.mem.indexOf(u8, path, "known") != null) {
            const confidence: f32 = 0.91;
            return .{
                .person_present = true,
                .match_status = identity.statusFromConfidence(true, confidence, self.known_threshold, self.uncertain_threshold),
                .person_id = "person_001",
                .confidence = confidence,
                .candidate_name = "Mara",
                .people_count = 1,
            };
        }
        if (std.mem.indexOf(u8, path, "multiple") != null) {
            return .{ .person_present = true, .match_status = .multiple, .confidence = 0.66, .people_count = 2 };
        }
        return .{ .person_present = true, .match_status = .unknown, .confidence = 0.40, .people_count = 1 };
    }
};

pub const TestInput = struct {
    answers: []const []const u8,
    index: usize = 0,
    active: bool = false,
    fn input(self: *TestInput) input_mod.UserInput {
        return .{ .ctx = self, .askFn = ask, .isActiveFn = isActive };
    }
    fn ask(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) !input_mod.HeardSpeech {
        const self: *TestInput = @ptrCast(@alignCast(ctx));
        if (self.index >= self.answers.len) return input_mod.HeardSpeech.typed(allocator, "");
        const answer = self.answers[self.index];
        self.index += 1;
        return input_mod.HeardSpeech.typed(allocator, answer);
    }
    fn isActive(ctx: *anyopaque, _: std.mem.Allocator) !bool {
        const self: *TestInput = @ptrCast(@alignCast(ctx));
        return self.active;
    }
};

pub const FailingIdentityClaimIntentService = struct {
    calls: usize = 0,

    pub fn service(self: *FailingIdentityClaimIntentService) intent_mod.IntentService {
        return .{ .ctx = self, .classifyFn = classify };
    }

    fn classify(ctx: *anyopaque, _: std.mem.Allocator, context: intent_mod.IntentContext, _: []const u8) !intent_mod.IntentResult {
        const self: *FailingIdentityClaimIntentService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        try std.testing.expectEqual(intent_mod.IntentContext.identity_claim, context);
        return error.SyntaxError;
    }
};

pub const TestInterruptSource = struct {
    stimulus: ?interrupt_mod.Stimulus = null,
    calls: usize = 0,

    pub fn source(self: *TestInterruptSource) interrupt_mod.Source {
        return .{ .ctx = self, .pollFn = poll };
    }

    fn poll(ctx: *anyopaque, _: std.mem.Allocator) !?interrupt_mod.Stimulus {
        const self: *TestInterruptSource = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const stimulus = self.stimulus orelse return null;
        self.stimulus = null;
        return stimulus;
    }
};

pub const TestIdMonitor = struct {
    calls: usize = 0,
    fail: bool = false,
    event: ?schema.RuntimeEvent = null,

    pub fn source(self: *TestIdMonitor) id_monitor.Source {
        return .{
            .id = "test_id_monitor",
            .name = "Test Id Monitor",
            .ctx = self,
            .pollFn = poll,
        };
    }

    fn poll(ctx: *anyopaque, allocator: std.mem.Allocator, _: id_monitor.PollContext) ![]schema.RuntimeEvent {
        const self: *TestIdMonitor = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail) return error.TestIdMonitorFailure;
        const event = self.event orelse return &.{};
        const monitor_events = try allocator.alloc(schema.RuntimeEvent, 1);
        monitor_events[0] = event;
        return monitor_events;
    }
};

pub const TestProcessRunner = struct {
    pub fn runner(self: *TestProcessRunner) process_mod.ProcessRunner {
        return .{
            .ctx = self,
            .runCommandFn = runCommand,
            .runOptionalCommandFn = runOptionalCommand,
            .runCaptureFn = runCapture,
            .runCaptureLargeFn = runCapture,
        };
    }

    fn runCommand(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const []const u8) !void {}

    fn runOptionalCommand(_: *anyopaque, _: std.mem.Allocator, _: std.Io, _: []const []const u8) !void {}

    fn runCapture(_: *anyopaque, allocator: std.mem.Allocator, _: std.Io, argv: []const []const u8) ![]u8 {
        if (argv.len == 2 and std.mem.eql(u8, argv[0], "date") and std.mem.eql(u8, argv[1], "+%F")) {
            return allocator.dupe(u8, "2026-06-23\n");
        }
        if (argv.len == 2 and std.mem.eql(u8, argv[0], "date") and std.mem.eql(u8, argv[1], "+%H:%M")) {
            return allocator.dupe(u8, "12:30\n");
        }
        return error.UnexpectedTestProcessCommand;
    }

    fn runCaptureLarge(ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
        return runCapture(ctx, allocator, io, argv);
    }
};

pub const TestClock = struct {
    now_seconds: i64 = 1_781_222_400,

    pub fn clock(self: *TestClock) clock_mod.Clock {
        return .{ .ctx = self, .nowSecondsFn = nowSeconds };
    }

    fn nowSeconds(ctx: *anyopaque, _: std.Io) !i64 {
        const self: *TestClock = @ptrCast(@alignCast(ctx));
        return self.now_seconds;
    }
};

pub fn localFileSystem(allocator: std.mem.Allocator) files_mod.FileSystem {
    var filesystem = allocator.create(files_mod.TestFileSystem) catch unreachable;
    filesystem.* = .{ .allocator = allocator };
    return filesystem.filesystem();
}

pub const ScriptedRecallChatService = struct {
    calls: usize = 0,

    pub fn service(self: *ScriptedRecallChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedRecallChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            const commands = try allocator.alloc(chat_mod.ChatCommand, 2);
            commands[0] = .{ .command = .say, .text = "I'm checking my memories for 'papa' right now." };
            commands[1] = .{ .command = .recall_memory, .query = "papa" };
            return .{
                .commands = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Started checking memory for papa."),
                .conversation_done = false,
            };
        }

        try std.testing.expect(std.mem.indexOf(u8, observations, "memory_recall:") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "Papa taught me to solder") != null);
        const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
        commands[0] = .{ .command = .say, .text = "I found one: Papa taught me to solder patiently." };
        return .{
            .commands = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Answered with the recalled papa memory."),
        };
    }
};

pub const ScriptedRememberPersonChatService = struct {
    calls: usize = 0,
    remembered_name: []const u8,

    pub fn service(self: *ScriptedRememberPersonChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedRememberPersonChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            try std.testing.expect(std.mem.indexOf(u8, observations, "person present but not recognized") != null);
            try std.testing.expect(std.mem.indexOf(u8, observations, "curiosity is active") != null);
            const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
            commands[0] = .{ .command = .remember_person, .name = self.remembered_name };
            return .{
                .commands = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Chose to register the newly salient person."),
                .conversation_done = false,
            };
        }

        try std.testing.expect(std.mem.indexOf(u8, observations, "person_remembered:") != null);
        const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
        commands[0] = .{ .command = .say, .text = try std.fmt.allocPrint(allocator, "I will remember you as {s}.", .{self.remembered_name}) };
        return .{
            .commands = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try std.fmt.allocPrint(allocator, "Registered {s} from the touch-driven encounter.", .{self.remembered_name}),
        };
    }
};

pub const ScriptedDreamChatService = struct {
    calls: usize = 0,

    pub fn service(self: *ScriptedDreamChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedDreamChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            try std.testing.expect(std.mem.indexOf(u8, observations, "- dream:") != null);
            const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
            commands[0] = .{
                .command = .dream,
                .text = "Connect today's room note with older plant memories.",
                .heat_bias = "mixed",
                .tags = &[_][]const u8{ "dream", "e2e" },
            };
            return .{
                .commands = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Started the dream skill."),
                .conversation_done = false,
            };
        }

        try std.testing.expect(std.mem.indexOf(u8, observations, "dream:\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "image_path: data/test/e2e_dream.png") != null);
        const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
        commands[0] = .{ .command = .say, .text = "I dreamed that through." };
        return .{
            .commands = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Completed the dream skill and reported back."),
        };
    }
};

pub const ScriptedHardErrorRecoveryChatService = struct {
    calls: usize = 0,
    followup_observations: []const u8 = "",

    pub fn service(self: *ScriptedHardErrorRecoveryChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedHardErrorRecoveryChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
            commands[0] = .{ .command = .send_email, .to = "mara@example.com", .subject = "Garden" };
            return .{
                .commands = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Tried to send email but omitted the body."),
            };
        }

        self.followup_observations = try allocator.dupe(u8, observations);
        const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
        commands[0] = .{ .command = .say, .text = "Okay, I will drop that failed email attempt." };
        return .{
            .commands = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Dropped the failed email attempt after the user said nevermind."),
        };
    }
};

pub const HeardSpeechObservationChatService = struct {
    calls: usize = 0,

    pub fn service(self: *HeardSpeechObservationChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *HeardSpeechObservationChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        try std.testing.expectEqualStrings("please remember the lamp", user_text);
        try std.testing.expect(std.mem.indexOf(u8, observations, "heard_speech sense:") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "provider: whisper.cpp/whisper-cli") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "audio_path: data/audio/input/utterance_test.wav") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "raw_provider_json_path: data/audio/input/utterance_test.wav.transcription.json") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "speaker_continuity: sense_stimulus") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "metadata=\"speech_stimulus") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "continuity_score=") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "visual_status=not_checked") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "\"avg_token_p\":0.420") != null);

        const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
        commands[0] = .{ .command = .say, .text = "I heard the full transcription data." };
        return .{
            .commands = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Acknowledged full heard-speech metadata."),
        };
    }
};

pub const ScriptedClarificationChatService = struct {
    calls: usize = 0,

    pub fn service(self: *ScriptedClarificationChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedClarificationChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const commands = try allocator.alloc(chat_mod.ChatCommand, 1);
        commands[0] = .{ .command = .say, .text = "Could you clarify what you want me to add?" };
        return .{
            .commands = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Asked one clarifying question."),
            .conversation_done = false,
        };
    }
};

pub const TestCommandLog = struct {
    kind: ?[]const u8 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    brain_body: ?[]const u8 = null,

    pub fn log(self: *TestCommandLog) command_log_mod.CommandLog {
        return .{ .ctx = self, .appendFn = append };
    }

    fn append(ctx: *anyopaque, kind: []const u8, title: []const u8, body: []const u8) !void {
        const self: *TestCommandLog = @ptrCast(@alignCast(ctx));
        self.kind = kind;
        self.title = title;
        self.body = body;
        if (std.mem.eql(u8, kind, "brain")) self.brain_body = body;
    }
};

pub const TestFacialExpressionOutput = struct {
    calls: usize = 0,
    eyes: ?[]const u8 = null,
    mouth: ?[]const u8 = null,
    duration_ms: u32 = 0,

    pub fn output(self: *TestFacialExpressionOutput) facial_expression.Output {
        return .{ .ctx = self, .showFn = show };
    }

    fn show(ctx: *anyopaque, expression: facial_expression.Expression) !void {
        const self: *TestFacialExpressionOutput = @ptrCast(@alignCast(ctx));
        try facial_expression.validate(expression);
        self.calls += 1;
        self.eyes = expression.eyes;
        self.mouth = expression.mouth;
        self.duration_ms = expression.duration_ms;
    }
};

pub fn makeBrain(allocator: std.mem.Allocator, image: []const u8, answers: []const []const u8, store: *TestStore, desc: *openai.TestDescriptionService) Brain {
    var camera = allocator.create(TestCamera) catch unreachable;
    camera.* = .{ .image = image };
    var input = allocator.create(TestInput) catch unreachable;
    input.* = .{ .answers = answers };
    var recog = allocator.create(TestRecognitionClient) catch unreachable;
    recog.* = .{};
    var intent = allocator.create(intent_mod.TestIntentService) catch unreachable;
    intent.* = .{};
    var greeting_model = allocator.create(greeting_client.TestGreetingService) catch unreachable;
    greeting_model.* = .{};
    var chat = allocator.create(chat_mod.TestChatService) catch unreachable;
    chat.* = .{};
    var image_gen = allocator.create(image_mod.TestImageGenerationService) catch unreachable;
    image_gen.* = .{};
    var audio_inspector = allocator.create(audio_mod.TestAudioInspectionService) catch unreachable;
    audio_inspector.* = .{};
    var speech = allocator.create(speech_mod.TestSpeechService) catch unreachable;
    speech.* = .{};
    var speaker = allocator.create(speaker_mod.TestSpeaker) catch unreachable;
    speaker.* = .{};
    var process_runner = allocator.create(TestProcessRunner) catch unreachable;
    process_runner.* = .{};
    var clock = allocator.create(TestClock) catch unreachable;
    clock.* = .{};
    var senses = allocator.create(system_senses_mod.StaticSystemSenses) catch unreachable;
    senses.* = .{ .snapshot_value = .{
        .datetime = .{
            .datetime = "2026-06-23T12:30:00-05:00",
            .unix_seconds = 1_781_222_400,
        },
        .power = .{ .supplies = &[_]system_senses_mod.PowerSupply{
            .{ .name = "BAT0", .kind = "Battery", .capacity_percent = 42, .status = "Discharging" },
            .{ .name = "AC", .kind = "Mains", .online = true },
        } },
        .storage = .{ .volumes = &[_]system_senses_mod.StorageVolume{
            .{ .name = "/dev/disk3s1", .mount_path = "/", .total_bytes = 1000, .available_bytes = 250, .used_percent = 75 },
        } },
        .database = .{ .databases = &[_]system_senses_mod.DatabaseFileStats{
            .{ .label = "memory", .path = "data/memory/people.sqlite", .page_count = 10, .page_size = 4096, .freelist_count = 1, .total_bytes = 40960, .table_count = 1 },
            .{ .label = "relationship_graph", .path = "data/memory/relationships.sqlite", .page_count = 12, .page_size = 4096, .freelist_count = 0, .total_bytes = 49152, .table_count = 4 },
        } },
    } };
    var graph_impl = allocator.create(graph_store.TestGraphStore) catch unreachable;
    graph_impl.* = .{};

    return Brain.init(allocator, .{}, .{
        .io = null,
        .capabilities = chat_mod.CapabilitySet.all(),
        .camera = camera.camera(),
        .recognizer = recog.recognizer(),
        .description_service = desc.service(),
        .greeting_service = greeting_model.service(),
        .intent_service = intent.service(),
        .chat_service = chat.service(),
        .image_generation_service = image_gen.service(),
        .audio_inspection_service = audio_inspector.service(),
        .want_achievement_detector = store.want_detector.detector(),
        .speech_service = speech.service(),
        .speaker = speaker.speaker(),
        .input = input.input(),
        .store = store.store(),
        .graph = graph_impl.store(),
        .system_senses = senses.senses(),
        .clock = clock.clock(),
        .filesystem = localFileSystem(allocator),
        .process_runner = process_runner.runner(),
    });
}

pub fn addMara(store: *TestStore, allocator: std.mem.Allocator, last_seen_at: ?[]const u8) !void {
    try store.people.append(allocator, .{
        .person_id = "person_001",
        .display_name = "Mara",
        .relationship_status = .friend,
        .created_at = "1000",
        .last_seen_at = last_seen_at,
        .sighting_count = 1,
        .greeting_style = .warm,
        .stable_notes = &.{},
        .recent_notes = &.{},
        .embeddings = &.{},
    });
}

pub fn addZelda(store: *TestStore, allocator: std.mem.Allocator, last_seen_at: ?[]const u8) !void {
    try store.people.append(allocator, .{
        .person_id = "person_zelda",
        .display_name = "Zelda",
        .relationship_status = .friend,
        .created_at = "1000",
        .last_seen_at = last_seen_at,
        .sighting_count = 1,
        .greeting_style = .warm,
        .stable_notes = &.{},
        .recent_notes = &.{},
        .embeddings = &.{},
    });
}

pub fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        count += 1;
        index = found + needle.len;
    }
    return count;
}
