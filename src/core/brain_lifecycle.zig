const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const facts = @import("facts.zig");
const greeting = @import("greeting_policy.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const state_mod = @import("state.zig");
const schema = @import("../storage/schema.zig");
const store_mod = @import("../storage/store.zig");
const graph_store = @import("../storage/graph_store.zig");
const intent_mod = @import("../api/intent_client.zig");
const openai = @import("../api/openai_client.zig");
const greeting_client = @import("../api/greeting_client.zig");
const speech_mod = @import("../api/speech_client.zig");
const chat_mod = @import("../api/chat_client.zig");
const skills_mod = @import("../api/skills.zig");
const email_mod = @import("../api/email_client.zig");
const autonomy_mod = @import("../api/autonomy_client.zig");
const psyche_client = @import("../api/psyche_client.zig");
const want_achievement_mod = @import("../api/want_achievement_client.zig");
const image_mod = @import("../api/image_client.zig");
const audio_mod = @import("../api/audio_client.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const button_mod = @import("../platform/common/button.zig");
const command_log_mod = @import("../platform/common/command_log.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
const system_senses_mod = @import("../platform/common/system_senses.zig");
const time_mod = @import("time.zig");
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const seed_mod = @import("seed.zig");
const vector_index = @import("vector_index.zig");
const emotion = @import("emotion.zig");
const process = @import("../platform/common/process.zig");
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
const CommandBatchResult = brain_mod.CommandBatchResult;
const ConversationTurnResult = brain_mod.ConversationTurnResult;
const ConversationSpeakerContext = brain_mod.Brain.ConversationSpeakerContext;
const QuietHours = brain_mod.Brain.QuietHours;
const SelfDirectiveKind = brain_mod.Brain.SelfDirectiveKind;
const SpeechArtifactSweepResult = brain_mod.SpeechArtifactSweepResult;
const MediaKind = helpers.MediaKind;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const speech_artifact_prefix = brain_mod.speech_artifact_prefix;
const speech_audio_suffix = brain_mod.speech_audio_suffix;
const speech_transcription_json_suffix = brain_mod.speech_transcription_json_suffix;
pub fn init(allocator: std.mem.Allocator, cfg: config_mod.Config, deps: BrainDeps) Brain {
    return .{ .allocator = allocator, .cfg = cfg, .deps = deps, .now_seconds = time_mod.nowSeconds() };
}

pub fn seedFromFile(self: *Brain, io: std.Io, path: []const u8) !void {
    const doc = try seed_mod.readSeedFile(self.allocator, io, path);
    try seedDocument(self, doc);
}

pub fn seedDocument(self: *Brain, doc: seed_mod.SeedDocument) !void {
    const existing = try self.deps.store.loadMemoryRecords(self.allocator);
    for (doc.entries) |entry| {
        const memory = try self.seedEntryMemory(doc, entry);
        if (helpers.findMemoryById(existing, memory.memory_id) != null) continue;
        if (helpers.seedEntryAlreadyPresent(existing, entry)) continue;
        try self.deps.store.saveMemoryRecord(memory);
    }
}

pub fn handleFaceMemoryActivation(self: *Brain) !void {
    try handleTouchStimulus(self, "short_touch");
}

pub fn performFaceMemoryActivation(self: *Brain) !void {
    try handleTouchActivation(self, "button_activated", "person present but not recognized; touch stimulus made this person salient; curiosity is active; if the person offers a name or identity, remember_person is an available skill", "touch stimulus received; recognition found no known person; curiosity is active; if the person offers a name or identity, remember_person is an available skill");
}

pub fn handleLongTouchActivation(self: *Brain) !void {
    try handleTouchStimulus(self, "long_touch");
}

pub fn handleTouchStimulus(self: *Brain, touch_kind: []const u8) !void {
    const assignment = try self.assignTouchStimulus(touch_kind);
    self.setCurrentStimulusContext(assignment.stimulus_context);
    try self.logSimple(.Idle, null, null, null, assignment.stimulus_context);
    if (!assignment.should_look) {
        try self.appendCommandLog("state", "Touch stimulus", assignment.stimulus_context);
        return;
    }
    if (std.mem.eql(u8, touch_kind, "long_touch")) {
        try handleTouchActivation(self, "long_touch_activated", "person present but not recognized; long touch stimulus made this person salient; no speech words were transcribed; curiosity is active; if the person offers a name or identity, remember_person is an available skill", "long touch stimulus received; no speech words were transcribed; recognition found no known person; curiosity is active; if the person offers a name or identity, remember_person is an available skill");
    } else {
        try performFaceMemoryActivation(self);
    }
}

pub fn handleTouchActivation(self: *Brain, activation_note: []const u8, present_status: []const u8, none_status: []const u8) !void {
    self.conversation_speaker_context = null;
    self.last_conversation_turn_seconds = null;
    try self.logSimple(.Idle, null, null, null, activation_note);
    try self.logState(.Capture);
    var capture = try self.deps.camera.capture(self.allocator);
    self.rememberVisualUpdate(capture.path);
    self.last_visual_observation_uploaded = false;
    std.debug.print("Image: {s}\n", .{capture.path});

    try self.logState(.Identify);
    const result = try self.deps.recognizer.identify(self.allocator, capture.path);
    std.debug.print("Recognition: {s}, confidence={d:.2}", .{ @tagName(result.match_status), result.confidence });
    if (result.candidate_name) |candidate| std.debug.print(", candidate={s}", .{candidate});
    std.debug.print("\n", .{});

    try self.retainCaptureForPersonMemory(&capture);

    switch (result.match_status) {
        .known => try self.handleKnown(capture, result),
        .unknown, .multiple => try self.handleUnknown(capture, result, present_status),
        .uncertain => try self.handleUncertain(capture, result),
        .none => try self.handleUnknown(capture, result, none_status),
    }
}

pub fn forgetByNameOrId(self: *Brain, name_or_id: []const u8) !bool {
    try self.logState(.ForgetPerson);
    const forgotten = try self.deps.store.forgetPerson(name_or_id);
    const text = try self.generateSimpleGreeting(.forget_profile);
    std.debug.print("\nBRAIN:\n{s}\n", .{text});
    try self.say(text);
    try self.logSimple(.ForgetPerson, null, null, text, if (forgotten) "profile_forgotten" else "profile_not_found");
    return forgotten;
}

pub fn handleConversationTurn(self: *Brain) !void {
    self.trace("conversation.start");
    errdefer |err| self.traceError("conversation.error", err);
    try self.logState(.TransientConversation);
    self.trace("conversation.expire_idle.start");
    try expireConversationIfIdle(self);
    self.trace("conversation.expire_idle.done");
    self.trace("conversation.input.ask.start");
    const heard_speech = try self.deps.input.ask(self.allocator, "I'm listening.");
    self.traceText("conversation.input.ask.done", heard_speech.text);
    _ = try handleConversationText(self, heard_speech);
}

pub fn handleButtonAction(self: *Brain, action: button_mod.ButtonAction) !void {
    switch (action) {
        .short_touch => try handleFaceMemoryActivation(self),
        .held_input => try handleHoldActivation(self),
        .text_input => try handleConversationTurn(self),
    }
}

pub fn handleTouchStimulusError(self: *Brain, err: anyerror) !bool {
    if (err == error.ShortTouchStimulus) {
        try handleFaceMemoryActivation(self);
        return true;
    }
    if (err == error.LongTouchStimulus) {
        try handleLongTouchActivation(self);
        return true;
    }
    return false;
}

pub fn handleHoldActivation(self: *Brain) !void {
    self.trace("hold.start");
    errdefer |err| self.traceError("hold.error", err);
    self.trace("hold.input.ask.start");
    const heard_speech = self.deps.input.ask(self.allocator, "I'm listening.") catch |err| {
        if (err == error.ShortTouchStimulus) {
            self.trace("hold.input.short_touch");
            try handleFaceMemoryActivation(self);
            return;
        }
        if (err == error.HoldReleasedBeforeRecordingStarted) {
            self.trace("hold.input.released_before_recording.long_touch");
            try handleLongTouchActivation(self);
            return;
        }
        if (err == error.LongTouchStimulus) {
            self.trace("hold.input.no_speech.long_touch");
            try handleLongTouchActivation(self);
            return;
        }
        return @errorCast(err);
    };
    const user_text = heard_speech.text;
    self.traceText("hold.input.ask.done", user_text);
    if (helpers.isBlankText(user_text)) {
        self.trace("hold.input.blank.long_touch");
        try handleLongTouchActivation(self);
        return;
    }
    self.trace("conversation.start");
    try self.logState(.TransientConversation);
    self.trace("conversation.expire_idle.start");
    try expireConversationIfIdle(self);
    self.trace("conversation.expire_idle.done");
    _ = try handleConversationText(self, heard_speech);
}

pub fn handleConversationText(self: *Brain, heard_speech: input_mod.HeardSpeech) !ConversationTurnResult {
    const user_text = heard_speech.text;
    const stimulus_assignment = try self.assignSpeechStimulus(heard_speech);
    self.setCurrentStimulusContext(stimulus_assignment.stimulus_context);
    var speaker_context = stimulus_assignment.speaker_context;
    const heard_speech_raw = try self.heardSpeechRaw(heard_speech);
    self.trace("conversation.memory.user_experience.start");
    try self.recordMemoryCandidateEvent(.user_utterance, "human", "conversation_turn", user_text, .human, .utterance, .summarize, "conversation_turn", heard_speech_raw, user_text, &.{}, &[_][]const u8{ "conversation", "heard_speech" });
    self.trace("conversation.memory.user_experience.done");
    self.trace("conversation.impression.start");
    const user_impression = try self.createImpression(.user_speech, user_text, &[_][]const u8{"conversation"});
    try self.deps.store.addImpression(user_impression);
    self.trace("conversation.impression.done");
    self.trace("conversation.appraisal.start");
    const user_appraisal = try self.createAppraisal(user_text, user_impression.impression_id, &[_][]const u8{"conversation"});
    try self.deps.store.addAppraisal(user_appraisal);
    try self.recordMemoryCandidateEvent(.observation, "brain", "user_speech_appraisal", user_appraisal.freeform, .brain, .appraisal, .keep_disposition, "user_speech_appraisal", user_text, user_appraisal.freeform, &.{}, user_appraisal.tags);
    _ = try self.detectWantAchievements(user_text);
    self.trace("conversation.appraisal.done");
    self.trace("conversation.intent.identity_claim.start");
    const identity_claim = try self.deps.intent_service.classify(self.allocator, .identity_claim, user_text);
    self.traceIntent("conversation.intent.identity_claim.done", identity_claim.action);
    if (identity_claim.action == .claim_identity and speaker_context == null) {
        self.trace("conversation.speaker_context.identity_claim.start");
        speaker_context = try self.conversationSpeakerContext();
        self.trace("conversation.speaker_context.identity_claim.done");
    }
    if (speaker_context) |context| if (try self.handleIdentityClaim(identity_claim, context)) {
        const label = if (self.conversation_speaker_context) |updated_context| updated_context.chat_label else context.chat_label;
        try self.logUserUtterance(label, user_text);
        self.last_conversation_turn_seconds = self.now_seconds;
        self.trace("conversation.done.identity_claim");
        return .{
            .user_text = user_text,
            .spoken_text = "",
            .user_summary = user_text,
            .brain_summary = "recognized identity claim",
        };
    };
    self.trace("conversation.intent.provide_name.start");
    const immediate = try self.deps.intent_service.classify(self.allocator, .provide_name, user_text);
    self.traceIntent("conversation.intent.provide_name.done", immediate.action);
    if (try self.handleImmediateIntent(immediate)) {
        try self.logUserUtterance(if (speaker_context) |context| context.chat_label else "User", user_text);
        self.trace("conversation.done.immediate_intent");
        return .{
            .user_text = user_text,
            .spoken_text = "",
            .user_summary = user_text,
            .brain_summary = "handled immediate intent",
        };
    }

    self.trace("conversation.observations.start");
    var observations = std.ArrayList(u8).empty;
    try self.appendHeardSpeechObservation(&observations, heard_speech);
    self.traceCount("conversation.observations.heard_speech.done", observations.items.len);
    const uploaded_observation = try self.uploadedMediaObservation(user_text);
    if (uploaded_observation) |line| try observations.appendSlice(self.allocator, line);
    self.traceCount("conversation.observations.uploaded.done", observations.items.len);
    if (speaker_context == null and uploaded_observation == null) self.trace("conversation.speaker_context.deferred");
    try self.logUserUtterance(if (speaker_context) |context| context.chat_label else "User", user_text);
    self.trace("conversation.memory.build.start");
    const memory = try self.buildConversationMemoryWithSpeaker(if (speaker_context) |context| context.memory_line else null);
    self.traceCount("conversation.memory.build.done", memory.len);
    self.trace("conversation.affordances.start");
    try self.appendAffordanceObservation(&observations);
    self.traceCount("conversation.affordances.done", observations.items.len);
    const had_pending_hard_error = self.pending_hard_error != null;
    try self.appendPendingHardErrorObservation(&observations);
    if (had_pending_hard_error) self.pending_hard_error = null;
    var spoken_text: []const u8 = "";
    var final_turn: ?chat_mod.ChatTurn = null;
    var pending_interrupt: ?interrupt_mod.Stimulus = null;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        self.traceTurn("conversation.chat.respond.start", i, observations.items.len);
        const turn = try self.deps.chat_service.respond(self.allocator, memory, user_text, observations.items);
        self.traceTurnCommands("conversation.chat.respond.done", i, turn.commands.len, turn.conversation_done);
        final_turn = turn;
        self.traceTurn("conversation.commands.start", i, observations.items.len);
        const batch = self.executeChatCommands(turn.commands, &observations) catch |err| {
            spoken_text = try self.handleHardCommandError(err);
            final_turn = turn;
            break;
        };
        self.traceCommandBatch("conversation.commands.done", i, batch, observations.items.len);
        if (batch.spoken_text) |text| {
            spoken_text = text;
        }
        if (batch.interrupted_by) |stimulus| {
            pending_interrupt = stimulus;
            break;
        }
        if (turn.conversation_done or batch.ended_with_speech) break;
    }

    if (spoken_text.len == 0 and pending_interrupt == null) {
        spoken_text = "I checked what I could, but I am not sure how to answer yet.";
        std.debug.print("\nBRAIN:\n{s}\n", .{spoken_text});
        self.trace("conversation.fallback_say.start");
        try self.say(spoken_text);
        self.trace("conversation.fallback_say.done");
    }

    self.trace("conversation.summary.timestamp.start");
    const now = try time_mod.nowTimestamp(self.allocator);
    self.trace("conversation.summary.timestamp.done");
    if (final_turn == null) self.trace("conversation.summary.extra_respond.start");
    const summary_turn = final_turn orelse try self.deps.chat_service.respond(self.allocator, memory, user_text, observations.items);
    if (final_turn == null) self.trace("conversation.summary.extra_respond.done");
    self.trace("conversation.summary.store.start");
    try self.deps.store.addConversationSummary(.{
        .summary_id = try std.fmt.allocPrint(self.allocator, "conversation_{d}_{d}", .{ self.now_seconds, self.now_seconds + @as(i64, @intCast(user_text.len)) }),
        .time = now,
        .user_summary = summary_turn.user_summary,
        .brain_summary = summary_turn.brain_summary,
    });
    const summary_text = try Brain.formatConversationSummaryForMemory(self.allocator, summary_turn.user_summary, summary_turn.brain_summary);
    try self.recordMemoryCandidateEvent(.memory_mutation, "memory", "conversation_summary", summary_text, .memory, .summary, .keep_fact, "conversation_summary", user_text, summary_text, &.{}, &[_][]const u8{ "conversation", "summary" });
    self.trace("conversation.summary.store.done");
    self.last_conversation_turn_seconds = self.now_seconds;
    try self.logSimple(.TransientConversation, null, null, spoken_text, "conversation_summary_added");
    if (had_pending_hard_error and self.pending_hard_error == null) {
        try self.appendCommandLog("state", "Hard error recovery", "pending hard error resolved by follow-up conversation");
    }
    self.trace("conversation.done");
    if (pending_interrupt) |stimulus| try self.handleInterruptStimulus(stimulus);
    return .{
        .user_text = user_text,
        .spoken_text = spoken_text,
        .user_summary = summary_turn.user_summary,
        .brain_summary = summary_turn.brain_summary,
        .interrupted_by = pending_interrupt,
    };
}

pub fn reportRemoteThinkingFailure(self: *Brain) !void {
    const text = remote_thinking_failure_message;
    std.debug.print("\nBRAIN:\n{s}\n", .{text});
    try self.appendCommandLog("error", "Brain", text);
}

pub fn dryRunConversationPrompt(self: *Brain, user_text: []const u8) !chat_mod.ChatPrompt {
    if (helpers.isBlankText(user_text)) return error.EmptyDryRunRequest;
    var observations = std.ArrayList(u8).empty;
    const memory = try self.buildConversationMemory();
    try self.appendAffordanceObservation(&observations);
    return chat_mod.buildChatPrompt(self.allocator, memory, user_text, observations.items);
}

pub fn syncClock(self: *Brain, io: std.Io) void {
    self.now_seconds = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
}

pub fn runMaintenance(self: *Brain, io: std.Io) !void {
    try runIdMonitors(self, io);
    const tasks = try maintenance.dueTasks(self.allocator, io, self.cfg.maintenance_schedule_path, self.cfg.maintenance_state_path, self.now_seconds);
    for (tasks) |task| {
        if (try self.runMaintenanceCommand(task.command)) {
            try maintenance.markRun(self.allocator, io, self.cfg.maintenance_state_path, task.task_id, self.now_seconds);
            const text = try std.fmt.allocPrint(self.allocator, "maintenance:{s}", .{task.command});
            try self.logSimple(.Idle, null, null, null, text);
        }
    }
}

pub fn runIdMonitors(self: *Brain, io: std.Io) !void {
    if (!std.mem.eql(u8, self.cfg.id_monitors_mode, "on")) return;
    const interval = @max(@as(u64, 1), self.cfg.id_monitor_interval_seconds);
    if (self.id_monitor_manager.inProcessDue(self.now_seconds, interval)) {
        self.id_monitor_manager.markInProcessPoll(self.now_seconds);
        for (self.deps.id_monitor_sources) |source| {
            const monitor_events = source.poll(self.allocator, .{ .now_seconds = self.now_seconds }) catch |err| {
                try self.recordIdMonitorCrashEvent(source.id, err);
                continue;
            };
            for (monitor_events) |event| try self.recordIdMonitorEvent(event);
        }
    }
    const external_cfg = id_monitor.ExternalConfig{
        .command = self.cfg.id_monitor_external_command,
        .interval_seconds = @max(@as(u64, 1), self.cfg.id_monitor_interval_seconds),
        .restart_cooldown_seconds = @intCast(self.cfg.id_monitor_external_restart_cooldown_seconds),
    };
    if (self.id_monitor_manager.externalDue(self.now_seconds, external_cfg)) {
        self.id_monitor_manager.markExternalPoll(self.now_seconds);
        try self.recordRuntimeEvent(.{
            .kind = .system,
            .source = "id_monitor",
            .title = "id_monitor_external_start",
            .body = self.cfg.id_monitor_external_command,
            .monitor_id = "external",
            .severity = .debug,
            .tags = @constCast(&[_][]const u8{ "id", "monitor", "external", "audit" }),
        });
        const monitor_events = id_monitor.runExternalMonitor(self.allocator, io, "external", self.cfg.id_monitor_external_command) catch |err| {
            self.id_monitor_manager.markExternalCrash(self.now_seconds);
            try self.recordIdMonitorCrashEvent("external", err);
            return;
        };
        for (monitor_events) |event| try self.recordIdMonitorEvent(event);
        try self.recordRuntimeEvent(.{
            .kind = .system,
            .source = "id_monitor",
            .title = "id_monitor_external_stop",
            .body = self.cfg.id_monitor_external_command,
            .monitor_id = "external",
            .severity = .debug,
            .tags = @constCast(&[_][]const u8{ "id", "monitor", "external", "audit" }),
        });
    }
}

pub fn recordPowerSourceChange(self: *Brain, previous_external_power: bool, current_external_power: bool) !void {
    const state_text = if (current_external_power) "plugged_in" else "unplugged";
    const previous_text = if (previous_external_power) "plugged_in" else "unplugged";
    const raw = try std.fmt.allocPrint(
        self.allocator,
        "external_power changed from {s} to {s}",
        .{ previous_text, state_text },
    );
    const interpretation = try std.fmt.allocPrint(
        self.allocator,
        "External power was {s}.",
        .{if (current_external_power) "plugged in" else "removed"},
    );
    try self.recordMemoryCandidateEvent(
        .system,
        "environment",
        "power_source_change",
        interpretation,
        .environment,
        .perception,
        .keep_episode,
        "external_power",
        raw,
        interpretation,
        &.{},
        &[_][]const u8{ "system", "power", "external_power", state_text },
    );
}

pub fn recordCriticalPowerShutdown(self: *Brain, power: system_senses_mod.PowerSnapshot, critical_percent: u8) !void {
    const power_text = try system_senses_mod.formatPower(self.allocator, power);
    const raw = try std.fmt.allocPrint(
        self.allocator,
        "host battery reached critical level at or below {d}% without external power",
        .{critical_percent},
    );
    const interpretation = try std.fmt.allocPrint(
        self.allocator,
        "Host power is critically low. Shutting down gracefully now.\n{s}",
        .{power_text},
    );
    try self.recordMemoryCandidateEvent(
        .system,
        "environment",
        "critical_power_shutdown",
        interpretation,
        .environment,
        .perception,
        .keep_episode,
        "critical_power_shutdown",
        raw,
        interpretation,
        &.{},
        &[_][]const u8{ "system", "power", "battery", "critical", "shutdown" },
    );
    try self.appendCommandLog("error", "Power critical", interpretation);
    std.debug.print("\nBRAIN STATE: Shutdown\nREASON: critical host battery <= {d}% without external power\n{s}\n", .{ critical_percent, power_text });
}

pub fn recordSignalShutdown(self: *Brain, signal_name: []const u8) !void {
    const raw = try std.fmt.allocPrint(
        self.allocator,
        "host process received {s}",
        .{signal_name},
    );
    const interpretation = try std.fmt.allocPrint(
        self.allocator,
        "Host process received {s}. Shutting down gracefully now.",
        .{signal_name},
    );
    try self.recordMemoryCandidateEvent(
        .system,
        "environment",
        "signal_shutdown",
        interpretation,
        .environment,
        .perception,
        .keep_episode,
        "signal_shutdown",
        raw,
        interpretation,
        &.{},
        &[_][]const u8{ "system", "process", "signal", "shutdown" },
    );
    try self.appendCommandLog("result", "Signal shutdown", interpretation);
    std.debug.print("\nBRAIN STATE: Shutdown\nREASON: received {s}\n", .{signal_name});
}

pub fn runAutonomyTick(self: *Brain, io: std.Io) !void {
    if (!self.autonomyEnabled()) return;
    const day_key = try self.localDayKey(io);
    var state = try maintenance.loadAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_daily_energy, day_key);
    if (!try prepareAutonomyPlanning(self, io, &state)) return;
    if (!try autonomyTickDue(self, io, &state)) return;
    try runAutonomyPlannerWithState(self, io, &state);
}

pub fn runStimulusAutonomy(self: *Brain, io: std.Io) !void {
    if (!self.autonomyEnabled()) return;
    const day_key = try self.localDayKey(io);
    var state = try maintenance.loadAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_daily_energy, day_key);
    if (!try prepareAutonomyPlanning(self, io, &state)) return;
    try runAutonomyPlannerWithState(self, io, &state);
}

fn prepareAutonomyPlanning(self: *Brain, io: std.Io, state: *maintenance.AutonomyState) !bool {
    if (state.energy_remaining == 0) {
        state.last_autonomy_tick_at = self.now_seconds;
        state.sleeping = true;
        state.energy_exhausted = true;
        state.last_reason = try self.allocator.dupe(u8, "energy exhausted");
        try maintenance.saveAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, state.*);
        return false;
    }
    if (state.sleeping) return false;
    if (try self.deps.input.isActive(self.allocator)) {
        state.last_reason = try self.allocator.dupe(u8, "autonomy paused: human input active");
        try maintenance.saveAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, state.*);
        return false;
    }
    return true;
}

fn runAutonomyPlannerWithState(self: *Brain, io: std.Io, state: *maintenance.AutonomyState) !void {
    if (state.energy_remaining < Brain.autonomyPlannerCost()) {
        state.sleeping = true;
        state.energy_exhausted = true;
        state.last_autonomy_tick_at = self.now_seconds;
        state.last_reason = try self.allocator.dupe(u8, "insufficient energy for planner");
        try maintenance.saveAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, state.*);
        return;
    }

    const planner = self.deps.autonomy_planner orelse return error.MissingAutonomyPlanner;
    state.energy_remaining -= Brain.autonomyPlannerCost();
    state.last_autonomy_tick_at = self.now_seconds;
    try maintenance.saveAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, state.*);

    const context = try self.buildAutonomyContext(io, state.*);
    const turn = planner.plan(self.allocator, context) catch |err| {
        state.last_error = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
        try maintenance.saveAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, state.*);
        return err;
    };
    try self.executeAutonomyTurn(io, state, turn);
    try maintenance.saveAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, state.*);
}

pub fn autonomyTickDue(self: *Brain, io: std.Io, state: *maintenance.AutonomyState) !bool {
    const last_tick = state.last_autonomy_tick_at orelse {
        state.last_autonomy_tick_at = self.now_seconds;
        state.last_reason = try self.allocator.dupe(u8, "autonomy armed");
        try maintenance.saveAutonomyState(self.allocator, io, self.cfg.maintenance_state_path, state.*);
        return false;
    };
    const interval_seconds: i64 = @intCast(self.cfg.autonomy_interval_seconds);
    return self.now_seconds - last_tick >= interval_seconds;
}

pub fn expireConversationIfIdle(self: *Brain) !void {
    const last = self.last_conversation_turn_seconds orelse return;
    const timeout: i64 = @intCast(self.cfg.conversation_idle_timeout_seconds);
    if (self.now_seconds - last >= timeout) {
        _ = try self.runMaintenanceCommand("end_conversation");
    }
}
