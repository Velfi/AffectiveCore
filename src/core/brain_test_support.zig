const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const memory_extraction_mod = ports.memory_extraction;
const store_mod = ports.store;
const graph_store = ports.graph_store;
const openai = ports.openai;
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
const event_log_mod = ports.event_log;
const facial_expression = ports.facial_expression;
const process_mod = ports.process;
const id_monitor = @import("id_monitor.zig");
const maintenance = @import("maintenance.zig");
const embedding_mod = ports.embedding;

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
pub const ScriptedContinuingChatService = struct {
    calls: usize = 0,
    /// When set, `turn_complete` becomes true once this many chat calls have run.
    done_after_call: ?usize = 2,

    pub fn service(self: *ScriptedContinuingChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedContinuingChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const done = if (self.done_after_call) |threshold| self.calls >= threshold else false;
        const action_pressures = try allocator.alloc(chat_mod.ActionProposal, 1);
        action_pressures[0] = .{ .action = .say, .text = try std.fmt.allocPrint(allocator, "Reply {d} to {s}", .{ self.calls, user_text }) };
        return .{
            .action_pressures = action_pressures,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Continuing conversation."),
            .turn_complete = done,
        };
    }
};

pub const ScriptedRecognizeThenSayChatService = struct {
    calls: usize = 0,
    say_text: []const u8 = "Hello there.",

    pub fn service(self: *ScriptedRecognizeThenSayChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedRecognizeThenSayChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            try std.testing.expect(std.mem.indexOf(u8, observations, "social_context:") != null);
            try std.testing.expect(std.mem.indexOf(u8, observations, "camera_pullable: true") != null);
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .recognize };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Greeted back and looked at the speaker."),
                .turn_complete = false,
            };
        }
        if (self.calls == 2) {
            if (std.mem.indexOf(u8, observations, "host_sense_delivered:") != null or
                std.mem.indexOf(u8, observations, "Current speaker recognition:") != null)
            {
                const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
                commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, self.say_text) };
                return .{
                    .action_pressures = commands,
                    .user_summary = try allocator.dupe(u8, user_text),
                    .brain_summary = try allocator.dupe(u8, "Greeted after the awaited visual observation."),
                    .turn_complete = true,
                };
            }
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "I still need the camera.") };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Acknowledged the new user turn while a camera pull is still pending."),
                .turn_complete = true,
            };
        }
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try std.fmt.allocPrint(allocator, "Still here: {s}", .{user_text}) };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Answered deferred speech after the awaited visual observation."),
            .turn_complete = true,
        };
    }
};

pub const ConversationCotextOnNextTurnChatService = struct {
    calls: usize = 0,

    pub fn service(self: *ConversationCotextOnNextTurnChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ConversationCotextOnNextTurnChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (std.mem.indexOf(u8, observations, "salient_sense_during_conversation:") != null) {
            return .{
                .action_pressures = &.{},
                .user_summary = try allocator.dupe(u8, "Ambient visual sense during conversation."),
                .brain_summary = try allocator.dupe(u8, "Noted internally without speaking."),
                .turn_complete = true,
            };
        }
        if (std.mem.eql(u8, user_text, "what did you see?")) {
            try std.testing.expect(std.mem.indexOf(u8, observations, "conversation_cotext:") != null);
            try std.testing.expect(std.mem.indexOf(u8, observations, "uploaded_image:") != null);
        }
        return .{
            .action_pressures = &.{},
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Continued the conversation."),
            .turn_complete = true,
        };
    }
};

pub const SilentSalientSenseDuringConversationChatService = struct {
    calls: usize = 0,

    pub fn service(self: *SilentSalientSenseDuringConversationChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *SilentSalientSenseDuringConversationChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        _ = observations;
        return .{
            .action_pressures = &.{},
            .user_summary = try allocator.dupe(u8, "Ambient visual sense during conversation."),
            .brain_summary = try allocator.dupe(u8, "Noted internally without speaking."),
            .turn_complete = true,
        };
    }
};

pub const SpeakingSalientSenseDuringConversationChatService = struct {
    calls: usize = 0,
    say_text: []const u8 = "I see the photo.",

    pub fn service(self: *SpeakingSalientSenseDuringConversationChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *SpeakingSalientSenseDuringConversationChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (std.mem.indexOf(u8, observations, "salient_sense_during_conversation:") != null) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, self.say_text) };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, "User showed a photo mid-conversation."),
                .brain_summary = try allocator.dupe(u8, "Associated the image with the ongoing talk."),
                .turn_complete = true,
            };
        }
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "Hello.") };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, "User greeted."),
            .brain_summary = try allocator.dupe(u8, "Greeted back."),
            .turn_complete = true,
        };
    }
};

pub const OrchestrationResumeObservingChatService = struct {
    calls: usize = 0,

    pub fn service(self: *OrchestrationResumeObservingChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *OrchestrationResumeObservingChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (std.mem.indexOf(u8, observations, "host_sense_delivered:") != null) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "Continuing the activity.") };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, "Resumed orchestration."),
                .brain_summary = try allocator.dupe(u8, "Continued after host sense."),
                .turn_complete = true,
            };
        }
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .recognize };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, "Requested host sense."),
            .brain_summary = try allocator.dupe(u8, "Requested camera for orchestration."),
            .turn_complete = false,
        };
    }
};

/// Models a model that bundles recognize with say on the resumed turn instead of
/// waiting for a follow-up chat pass.
pub const ScriptedRecognizeAndSaySameBatchChatService = struct {
    calls: usize = 0,
    say_text: []const u8 = "Hello Celery.",

    pub fn service(self: *ScriptedRecognizeAndSaySameBatchChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedRecognizeAndSaySameBatchChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .recognize };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Requested recognition."),
                .turn_complete = false,
            };
        }
        try std.testing.expect(std.mem.indexOf(u8, observations, "host_sense_delivered:") != null);
        try std.testing.expect(std.mem.indexOf(u8, observations, "Current speaker recognition:") != null);
        const commands = try allocator.alloc(chat_mod.ActionProposal, 2);
        commands[0] = .{ .action = .recognize };
        commands[1] = .{ .action = .say, .text = try allocator.dupe(u8, self.say_text) };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Greeted after recognition in one batch."),
            .turn_complete = false,
        };
    }
};

/// Expects the interrupt coalesce observation and responds with say.
pub const ScriptedInterruptCoalesceSayChatService = struct {
    pub fn service(_: *ScriptedInterruptCoalesceSayChatService) chat_mod.ChatService {
        return .{ .ctx = undefined, .respondFn = respond };
    }

    fn respond(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        try std.testing.expect(std.mem.indexOf(u8, observations, "user_interrupt_coalesce:") != null);
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "Hello.") };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Greeted after interrupt coalesce."),
            .turn_complete = true,
        };
    }
};

/// First pass returns a non-verbal action; pre-pass nudge on pass 0 should elicit say on the same pass.
pub const ScriptedNonVerbalThenNudgedSayChatService = struct {
    calls: usize = 0,
    say_text: []const u8 = "Hello there.",
    last_nudge_kind: NudgeKind = .none,

    pub const NudgeKind = enum { none, initial, follow_up };

    pub fn service(self: *ScriptedNonVerbalThenNudgedSayChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedNonVerbalThenNudgedSayChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_nudge_kind = classifyHeardSpeechNudge(observations);
        if (self.calls == 1 and self.last_nudge_kind == .none) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .introspect };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Chose to introspect."),
                .turn_complete = true,
            };
        }
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, self.say_text) };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Responded verbally after nudge."),
            .turn_complete = true,
        };
    }

    fn classifyHeardSpeechNudge(observations: []const u8) NudgeKind {
        if (std.mem.indexOf(u8, observations, chat_mod.heard_speech_stimulus_response_nudge_follow_up) != null) return .follow_up;
        if (std.mem.indexOf(u8, observations, chat_mod.heard_speech_stimulus_response_nudge_initial) != null) return .initial;
        return .none;
    }
};

/// Non-verbal with turn_complete=false until follow-up nudge, then say.
pub const ScriptedAlwaysNonVerbalChatService = struct {
    calls: usize = 0,
    say_text: []const u8 = "Hello.",

    pub fn service(self: *ScriptedAlwaysNonVerbalChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedAlwaysNonVerbalChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (std.mem.indexOf(u8, observations, chat_mod.heard_speech_stimulus_response_nudge_follow_up) == null) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .introspect };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Chose to introspect."),
                .turn_complete = false,
            };
        }
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, self.say_text) };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Responded verbally after nudge."),
            .turn_complete = true,
        };
    }
};

/// Keeps requesting recognize for the first N chat turns, then says. Exercises
/// resumed conversation turns that must not stack duplicate frontend camera pulls.
pub const ScriptedRepeatedRecognizeThenSayChatService = struct {
    calls: usize = 0,
    recognize_calls: usize = 1,
    say_text: []const u8 = "I see you now.",

    pub fn service(self: *ScriptedRepeatedRecognizeThenSayChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedRepeatedRecognizeThenSayChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls <= self.recognize_calls) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .recognize };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Requested recognition."),
                .turn_complete = false,
            };
        }
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, self.say_text) };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Responded after recognition."),
            .turn_complete = true,
        };
    }
};

/// First pass requests recognize (pause). Resume pass says once host observation is present.
pub const ScriptedRecognizeTwiceThenSayChatService = struct {
    calls: usize = 0,
    say_text: []const u8 = "I could not see a face in the frame.",

    pub fn service(self: *ScriptedRecognizeTwiceThenSayChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedRecognizeTwiceThenSayChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .recognize };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Requested recognition."),
                .turn_complete = false,
            };
        }
        _ = observations;
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, self.say_text) };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Responded after recognition."),
            .turn_complete = true,
        };
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
    event: ?schema.ExperienceLogEvent = null,

    pub fn source(self: *TestIdMonitor) id_monitor.Source {
        return .{
            .id = "test_id_monitor",
            .name = "Test Id Monitor",
            .ctx = self,
            .pollFn = poll,
        };
    }

    fn poll(ctx: *anyopaque, allocator: std.mem.Allocator, _: id_monitor.PollContext) ![]schema.ExperienceLogEvent {
        const self: *TestIdMonitor = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail) return error.TestIdMonitorFailure;
        const event = self.event orelse return &.{};
        const monitor_events = try allocator.alloc(schema.ExperienceLogEvent, 1);
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

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedRecallChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const commands = try allocator.alloc(chat_mod.ActionProposal, 2);
        commands[0] = .{ .action = .think_about, .query = try allocator.dupe(u8, "papa") };
        commands[1] = .{ .action = .say, .text = try allocator.dupe(u8, "I found one: Papa taught me to solder patiently.") };
        return .{
            .action_pressures = commands,
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
            try std.testing.expect(std.mem.indexOf(u8, observations, "remember_person") != null);
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{ .action = .remember_person, .name = try allocator.dupe(u8, self.remembered_name) };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Chose to register the newly salient person."),
                .turn_complete = false,
            };
        }

        try std.testing.expect(std.mem.indexOf(u8, observations, "person_remembered:") != null);
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try std.fmt.allocPrint(allocator, "I will remember you as {s}.", .{self.remembered_name}) };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try std.fmt.allocPrint(allocator, "Registered {s} from the touch-driven encounter.", .{self.remembered_name}),
        };
    }
};

pub const ScriptedIdentityClaimChatService = struct {
    calls: usize = 0,
    claimed_name: []const u8,
    needs_confirmation: bool = false,

    pub fn service(self: *ScriptedIdentityClaimChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedIdentityClaimChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.needs_confirmation and self.calls == 1) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{
                .action = .say,
                .text = try std.fmt.allocPrint(allocator, "I do not have a stored profile for {s} yet. Would you like me to create one now?", .{self.claimed_name}),
            };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Offered to create a profile after the identity claim."),
                .turn_complete = false,
            };
        }

        const remember_turn = if (self.needs_confirmation) self.calls == 2 else self.calls == 1;
        if (remember_turn) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, if (self.needs_confirmation) 1 else 2);
            commands[0] = .{ .action = .remember_person, .name = try allocator.dupe(u8, self.claimed_name) };
            if (!self.needs_confirmation) {
                commands[1] = .{ .action = .say, .text = try std.fmt.allocPrint(allocator, "Got it, {s}. I linked your profile.", .{self.claimed_name}) };
            }
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try std.fmt.allocPrint(allocator, "Linked the identity claim to {s}.", .{self.claimed_name}),
                .turn_complete = self.needs_confirmation,
            };
        }

        try std.testing.expect(std.mem.indexOf(u8, observations, "person_remembered:") != null);
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try std.fmt.allocPrint(allocator, "Got it, {s}. I created your profile.", .{self.claimed_name}) };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try std.fmt.allocPrint(allocator, "Created profile for {s} after confirmation.", .{self.claimed_name}),
        };
    }
};

pub const ScriptedForgetPersonChatService = struct {
    calls: usize = 0,
    target_name: []const u8,

    pub fn service(self: *ScriptedForgetPersonChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedForgetPersonChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            const commands = try allocator.alloc(chat_mod.ActionProposal, 2);
            commands[0] = .{ .action = .forget_person, .name = try allocator.dupe(u8, self.target_name) };
            commands[1] = .{ .action = .say, .text = try std.fmt.allocPrint(allocator, "I will forget the profile for {s}.", .{self.target_name}) };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try std.fmt.allocPrint(allocator, "Forgot {s} after the user request.", .{self.target_name}),
            };
        }
        _ = observations;
        const commands = try allocator.alloc(chat_mod.ActionProposal, 0);
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Completed forget request."),
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
            const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
            commands[0] = .{
                .action = .send_email,
                .to = try allocator.dupe(u8, "mara@example.com"),
                .subject = try allocator.dupe(u8, "Garden"),
            };
            return .{
                .action_pressures = commands,
                .user_summary = try allocator.dupe(u8, user_text),
                .brain_summary = try allocator.dupe(u8, "Tried to send email but omitted the body."),
            };
        }

        self.followup_observations = try allocator.dupe(u8, observations);
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "Okay, I will drop that failed email attempt.") };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Dropped the failed email attempt after the user said nevermind."),
        };
    }
};

pub const FailingChatService = struct {
    fail_error: anyerror = error.RemoteServiceFailed,

    pub fn service(self: *FailingChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !chat_mod.ChatTurn {
        const self: *FailingChatService = @ptrCast(@alignCast(ctx));
        return self.fail_error;
    }
};

pub const ScriptedEmptyThenFailChatService = struct {
    calls: usize = 0,
    fail_error: anyerror = error.LocalServiceResponseInvalid,

    pub fn service(self: *ScriptedEmptyThenFailChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedEmptyThenFailChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{
            .action_pressures = &.{},
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Returned no outward actions."),
        };
    }
};

pub const ScriptedFailOnCallChatService = struct {
    calls: usize = 0,
    fail_on_call: usize = 1,
    fail_error: anyerror = error.LocalServiceResponseInvalid,

    pub fn service(self: *ScriptedFailOnCallChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedFailOnCallChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == self.fail_on_call) return self.fail_error;
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "Recovered after the chat failure.") };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Answered after a prior chat failure."),
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

        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "I heard the full transcription data.") };
        return .{
            .action_pressures = commands,
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
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "Could you clarify what you want me to add?") };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Asked one clarifying question."),
            .turn_complete = true,
        };
    }
};

pub const TestEventLog = struct {
    kind: ?[]const u8 = null,
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    brain_body: ?[]const u8 = null,

    pub fn log(self: *TestEventLog) event_log_mod.EventLog {
        return .{ .ctx = self, .appendFn = append };
    }

    pub fn deinit(self: *TestEventLog) void {
        const allocator = std.testing.allocator;
        if (self.brain_body) |body| allocator.free(body);
        self.* = .{};
    }

    fn append(ctx: *anyopaque, kind: []const u8, title: []const u8, body: []const u8) !void {
        const self: *TestEventLog = @ptrCast(@alignCast(ctx));
        self.kind = kind;
        self.title = title;
        self.body = body;
        if (std.mem.eql(u8, kind, "brain")) {
            const allocator = std.testing.allocator;
            if (self.brain_body) |previous| allocator.free(previous);
            self.brain_body = try allocator.dupe(u8, body);
        }
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

    pub fn deinit(self: *TestFacialExpressionOutput) void {
        const allocator = std.testing.allocator;
        if (self.eyes) |eyes| allocator.free(eyes);
        if (self.mouth) |mouth| allocator.free(mouth);
        self.* = .{};
    }

    fn show(ctx: *anyopaque, expression: facial_expression.Expression) !void {
        const self: *TestFacialExpressionOutput = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const allocator = std.testing.allocator;
        if (self.eyes) |eyes| allocator.free(eyes);
        if (self.mouth) |mouth| allocator.free(mouth);
        self.eyes = try allocator.dupe(u8, expression.eyes);
        self.mouth = try allocator.dupe(u8, expression.mouth);
        self.duration_ms = expression.duration_ms;
    }
};

pub const TestEmoteOutput = struct {
    calls: usize = 0,
    text: ?[]const u8 = null,
    display_text: ?[]const u8 = null,
    duration_ms: u32 = 0,

    pub fn output(self: *TestEmoteOutput) @import("port_emote.zig").Output {
        return .{ .ctx = self, .showFn = show };
    }

    pub fn deinit(self: *TestEmoteOutput) void {
        const allocator = std.testing.allocator;
        if (self.text) |text| allocator.free(text);
        if (self.display_text) |display_text| allocator.free(display_text);
        self.* = .{};
    }

    fn show(ctx: *anyopaque, emote: @import("port_emote.zig").Emote) !void {
        const self: *TestEmoteOutput = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const allocator = std.testing.allocator;
        if (self.text) |text| allocator.free(text);
        if (self.display_text) |display_text| allocator.free(display_text);
        self.text = try allocator.dupe(u8, emote.text);
        self.display_text = try allocator.dupe(u8, emote.display_text);
        self.duration_ms = emote.duration_ms;
    }
};

pub fn writeAndRefreshFacialExpressionCatalog(
    brain: *Brain,
    allocator: std.mem.Allocator,
    io: std.Io,
    brain_root: []const u8,
    avatar_json: []const u8,
) !void {
    brain.deps.io = io;
    brain.cfg.brain_root = try allocator.dupe(u8, brain_root);
    const fs = brain.deps.filesystem orelse return error.MissingFacialExpressionCatalog;
    const avatar_path = try std.fs.path.join(allocator, &.{ brain_root, "avatar.json" });
    defer allocator.free(avatar_path);
    try fs.writeFilePath(io, avatar_path, avatar_json);
    const maintenance_path = try std.fs.path.join(allocator, &.{ brain_root, "maintenance_state.json" });
    defer allocator.free(maintenance_path);
    brain.cfg.maintenance_state_path = try allocator.dupe(u8, maintenance_path);
    try maintenance.saveAutonomyState(allocator, fs, io, maintenance_path, .{
        .sleeping = false,
        .control_capacity = brain.cfg.autonomy_full_max_capacity,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    _ = try brain.refreshFacialExpressionCatalog();
}

pub fn wireTestIo(brain: *Brain) void {
    brain.deps.io = std.testing.io;
    brain.syncClock(std.testing.io);
}

pub fn makeBrain(allocator: std.mem.Allocator, image: []const u8, answers: []const []const u8, store: *TestStore, desc: *openai.TestDescriptionService) Brain {
    var camera = allocator.create(TestCamera) catch unreachable;
    camera.* = .{ .image = image };
    var input = allocator.create(TestInput) catch unreachable;
    input.* = .{ .answers = answers };
    var recog = allocator.create(TestRecognitionClient) catch unreachable;
    recog.* = .{};
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
    var extraction = allocator.create(memory_extraction_mod.ScriptedMemoryExtractionService) catch unreachable;
    extraction.* = .{
        .candidates = &[_]memory_extraction_mod.ExtractionCandidate{
            .{
                .key = "episode.runtime.summary",
                .proposition = "Runtime extracted a durable belief candidate from episode context.",
                .evidence = "episode summary indicated a stable, relevant detail",
                .kind = .belief,
                .confidence = 0.72,
                .salience = 0.61,
                .tags = &[_][]const u8{ "episode", "belief" },
                .source_references = &[_][]const u8{"episode summary indicated a stable, relevant detail"},
            },
        },
    };
    var process_runner = allocator.create(TestProcessRunner) catch unreachable;
    process_runner.* = .{};
    var clock = allocator.create(TestClock) catch unreachable;
    clock.* = .{};
    var senses = allocator.create(system_senses_mod.StaticSystemSenses) catch unreachable;
    senses.* = .{ .snapshot_value = .{
        .datetime = .{
            .datetime = "2026-06-23T12:30:00-05:00",
            .datetime_format = "ISO-8601 local",
            .friendly_datetime = "June 23, 2026 at 12:30 PM",
            .friendly_datetime_format = "local long date and time",
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
    var test_embedding = allocator.create(embedding_mod.TestEmbeddingService) catch unreachable;
    test_embedding.* = .{};

    return Brain.init(allocator, .{ .psyche_mode = "off" }, .{
        .io = null,
        .capabilities = chat_mod.CapabilitySet.all(),
        .camera = camera.camera(),
        .recognizer = recog.recognizer(),
        .description_service = desc.service(),
        .chat_service = chat.service(),
        .embedding_service = test_embedding.service(),
        .memory_extraction_service = extraction.service(),
        .image_generation_service = image_gen.service(),
        .audio_inspection_service = audio_inspector.service(),
        .want_achievement_detector = store.want_detector.detector(),
        .persona_directive_synthesizer = store.persona_synthesizer.synthesizer(),
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

pub fn makeBrainWithMemoryStore(
    allocator: std.mem.Allocator,
    image: []const u8,
    answers: []const []const u8,
    memory_store: store_mod.MemoryStore,
    aux_store: *TestStore,
    desc: *openai.TestDescriptionService,
    io: ?std.Io,
) Brain {
    var camera = allocator.create(TestCamera) catch unreachable;
    camera.* = .{ .image = image };
    var input = allocator.create(TestInput) catch unreachable;
    input.* = .{ .answers = answers };
    var recog = allocator.create(TestRecognitionClient) catch unreachable;
    recog.* = .{};
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
    var extraction = allocator.create(memory_extraction_mod.ScriptedMemoryExtractionService) catch unreachable;
    extraction.* = .{ .candidates = &.{} };
    var process_runner = allocator.create(TestProcessRunner) catch unreachable;
    process_runner.* = .{};
    var clock = allocator.create(TestClock) catch unreachable;
    clock.* = .{};
    var senses = allocator.create(system_senses_mod.StaticSystemSenses) catch unreachable;
    senses.* = .{ .snapshot_value = .{
        .datetime = .{
            .datetime = "2026-06-23T12:30:00-05:00",
            .datetime_format = "ISO-8601 local",
            .friendly_datetime = "June 23, 2026 at 12:30 PM",
            .friendly_datetime_format = "local long date and time",
            .unix_seconds = 1_781_222_400,
        },
        .power = .{ .supplies = &.{} },
        .storage = .{ .volumes = &.{} },
        .database = .{ .databases = &.{} },
    } };
    var graph_impl = allocator.create(graph_store.TestGraphStore) catch unreachable;
    graph_impl.* = .{};
    var test_embedding = allocator.create(embedding_mod.TestEmbeddingService) catch unreachable;
    test_embedding.* = .{};

    return Brain.init(allocator, .{ .psyche_mode = "off" }, .{
        .io = io,
        .capabilities = chat_mod.CapabilitySet.all(),
        .camera = camera.camera(),
        .recognizer = recog.recognizer(),
        .description_service = desc.service(),
        .chat_service = chat.service(),
        .embedding_service = test_embedding.service(),
        .memory_extraction_service = extraction.service(),
        .image_generation_service = image_gen.service(),
        .audio_inspection_service = audio_inspector.service(),
        .want_achievement_detector = aux_store.want_detector.detector(),
        .persona_directive_synthesizer = aux_store.persona_synthesizer.synthesizer(),
        .speech_service = speech.service(),
        .speaker = speaker.speaker(),
        .input = input.input(),
        .store = memory_store,
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

pub fn eventKindSeen(experience_events: []const schema.ExperienceEvent, kind: []const u8) bool {
    for (experience_events) |event| {
        if (std.mem.eql(u8, event.kind, kind)) return true;
    }
    return false;
}

pub fn findExperienceEventByKind(experience_events: []const schema.ExperienceEvent, kind: []const u8) ?schema.ExperienceEvent {
    for (experience_events) |event| {
        if (std.mem.eql(u8, event.kind, kind)) return event;
    }
    return null;
}

pub fn findExperienceEventWithPrefix(experience_events: []const schema.ExperienceEvent, prefix: []const u8) ?schema.ExperienceEvent {
    for (experience_events) |event| {
        if (std.mem.startsWith(u8, event.kind, prefix)) return event;
    }
    return null;
}

pub fn stringSliceContains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn seedDueAutonomyState(allocator: std.mem.Allocator, brain: *Brain, state_path: []const u8, max_capacity: f32) !void {
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = false,
        .control_capacity = max_capacity,
        .max_capacity = max_capacity,
        .last_capacity_replenish_at = brain.now_seconds - 3600,
    });
}

pub const ScriptedProcessGoalChatService = struct {
    pub fn service(self: *ScriptedProcessGoalChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !chat_mod.ChatTurn {
        _ = ctx;
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{
            .action = .unknown,
            .origin = .interaction,
            .process_goal = try allocator.dupe(u8, "investigate_touch"),
        };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "process goal requested"),
        };
    }
};

pub const TouchObservationChatService = struct {
    calls: usize = 0,

    pub fn service(self: *TouchObservationChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *TouchObservationChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        try std.testing.expect(std.mem.indexOf(u8, observations, "sense_stimulus kind=touch") != null);
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "I noticed the touch.") };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Responded about the recent touch."),
        };
    }
};

pub const ReminderReconsiderChatService = struct {
    calls: usize = 0,

    pub fn service(self: *ReminderReconsiderChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !chat_mod.ChatTurn {
        const self: *ReminderReconsiderChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const commands = try allocator.alloc(chat_mod.ActionProposal, 1);
        commands[0] = .{ .action = .say, .text = try allocator.dupe(u8, "Thanks for the reminder.") };
        return .{
            .action_pressures = commands,
            .user_summary = try allocator.dupe(u8, user_text),
            .brain_summary = try allocator.dupe(u8, "Reconsidered the due reminder."),
        };
    }
};
