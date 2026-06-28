const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const facts = @import("facts.zig");
const greeting = @import("greeting_policy.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const state_mod = @import("state.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const store_mod = ports.store;
const graph_store = ports.graph_store;
const intent_mod = ports.intent;
const openai = ports.openai;
const greeting_client = ports.greeting;
const speech_mod = ports.speech;
const chat_mod = ports.chat;
const skills_mod = ports.skills;
const email_mod = ports.email;
const autonomy_mod = ports.autonomy;
const psyche_client = ports.psyche;
const want_achievement_mod = ports.want_achievement;
const image_mod = ports.image;
const audio_mod = ports.audio;
const camera_mod = ports.camera;
const speaker_mod = ports.speaker;
const input_mod = ports.input;
const button_mod = ports.button;
const event_log_mod = ports.event_log;
const facial_expression = ports.facial_expression;
const system_senses_mod = ports.system_senses;
const time_mod = @import("time.zig");
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const seed_mod = @import("seed.zig");
const vector_index = @import("vector_index.zig");
const emotion = @import("emotion.zig");
const process = ports.process;
const helpers = @import("brain_helpers.zig");
const subsystems = @import("subsystems.zig");
const memory_selection_mod = @import("memory_selection.zig");
const read_models = @import("read_models.zig");
const experience_kinds = @import("experience_kinds.zig");
const recognition_composite = @import("recognition_composite.zig");
const belief_updates = @import("belief_updates.zig");
const experiential_observations = @import("experiential_observations.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const brain_context_stats = @import("brain_context_stats.zig");
const brain_process = @import("brain_process.zig");
const process_goal_resolver = @import("process_goal_resolver.zig");
const actor_payloads = @import("actors/payloads.zig");
const runtime_bridge = @import("brain_runtime_bridge.zig");
const cognitive_capacity = @import("cognitive_capacity.zig");
const context_composition = @import("context_composition.zig");
const activity_mod = @import("activity.zig");
const stimulus_mod = @import("stimulus.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
const ActionPressureBatchResult = brain_mod.ActionPressureBatchResult;
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
    const initial_now = if (deps.clock) |clock|
        if (deps.io) |io| clock.nowSeconds(io) catch 0 else 0
    else
        0;
    const brain: Brain = .{
        .allocator = allocator,
        .cfg = cfg,
        .deps = deps,
        .runtime = brain_mod.BrainRuntime.init(allocator, .{}),
        .now_seconds = initial_now,
        .context_stats = brain_context_stats.State.init(allocator),
    };
    return brain;
}

pub fn clearChatParseFailure(self: *Brain) void {
    if (self.chat_parse_failure_body) |body| {
        self.allocator.free(body);
        self.chat_parse_failure_body = null;
    }
}

pub fn rememberChatParseFailure(self: *Brain, body: []const u8) !void {
    self.clearChatParseFailure();
    self.chat_parse_failure_body = try self.allocator.dupe(u8, body);
}

pub fn chatParseFailureBody(self: *Brain) ?[]const u8 {
    return self.chat_parse_failure_body;
}

pub fn executeRuntimeProposalBatch(self: *Brain, proposals: []chat_mod.ActionProposal, observations: *std.ArrayList(u8)) !ActionPressureBatchResult {
    return runtime_bridge.executeProposalBatch(self, proposals, observations);
}

pub fn executeRuntimeAutonomyBatch(self: *Brain, proposals: []chat_mod.ActionProposal, observations: *std.ArrayList(u8)) !ActionPressureBatchResult {
    return runtime_bridge.executeAutonomyBatch(self, proposals, observations);
}

pub fn publishRuntimeMemoryCandidate(self: *Brain, payload_json: []const u8, source_actor: []const u8) !void {
    try runtime_bridge.publishMemoryCandidate(self, payload_json, source_actor);
}

pub fn publishRuntimeMemoryConsolidation(self: *Brain, payload_json: []const u8, source_actor: []const u8) !void {
    try runtime_bridge.publishMemoryConsolidation(self, payload_json, source_actor);
}

pub fn publishRuntimeLearningCapabilityRecorded(
    self: *Brain,
    payload: actor_payloads.LearningCapabilityRecordedPayload,
    source_actor: []const u8,
) !void {
    try runtime_bridge.publishLearningCapabilityRecorded(self, payload, source_actor);
}

pub fn publishRuntimeLearningCorrectionRecorded(
    self: *Brain,
    payload: actor_payloads.LearningCorrectionRecordedPayload,
    source_actor: []const u8,
) !void {
    try runtime_bridge.publishLearningCorrectionRecorded(self, payload, source_actor);
}

pub fn queryRuntimeMemoryAudit(self: *Brain, belief_id: []const u8) ![]const u8 {
    return runtime_bridge.queryMemoryAuditFormatted(self, belief_id);
}

pub fn seedFromFile(self: *Brain, io: std.Io, path: []const u8) !void {
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const doc = try seed_mod.readSeedFile(self.allocator, fs, io, path);
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

pub fn handleFaceMemoryActivation(self: *Brain) !?ConversationTurnResult {
    return try handleTouchStimulus(self, "short_touch");
}

pub fn handleLongTouchActivation(self: *Brain) !?ConversationTurnResult {
    return try handleTouchStimulus(self, "long_touch");
}

pub fn handleTouchStimulus(self: *Brain, touch_kind: []const u8) !?ConversationTurnResult {
    const assignment = try self.assignTouchStimulus(touch_kind);
    try self.refreshFocus();
    try self.logSimple(.Idle, null, null, null, assignment.stimulus_context);
    return try self.reactToSalientSense(assignment.packet);
}

pub fn forgetByNameOrId(self: *Brain, name_or_id: []const u8) !bool {
    try self.logState(.ForgetPerson);
    const forgotten = try self.deps.store.forgetPerson(name_or_id);
    try self.logSimple(.ForgetPerson, null, null, null, if (forgotten) "profile_forgotten" else "profile_not_found");
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
    _ = try handleConversationText(self, heard_speech, .{});
}

pub fn handleButtonAction(self: *Brain, action: button_mod.ButtonAction) !void {
    switch (action) {
        .short_touch => _ = try handleFaceMemoryActivation(self),
        .held_input => try handleHoldActivation(self),
        .text_input => try handleConversationTurn(self),
    }
}

pub fn handleTouchStimulusError(self: *Brain, err: anyerror) !bool {
    if (err == error.ShortTouchStimulus) {
        _ = try handleFaceMemoryActivation(self);
        return true;
    }
    if (err == error.LongTouchStimulus) {
        _ = try handleLongTouchActivation(self);
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
            _ = try handleFaceMemoryActivation(self);
            return;
        }
        if (err == error.HoldReleasedBeforeRecordingStarted) {
            self.trace("hold.input.released_before_recording.long_touch");
            _ = try handleLongTouchActivation(self);
            return;
        }
        if (err == error.LongTouchStimulus) {
            self.trace("hold.input.no_speech.long_touch");
            _ = try handleLongTouchActivation(self);
            return;
        }
        return @errorCast(err);
    };
    const user_text = heard_speech.text;
    self.traceText("hold.input.ask.done", user_text);
    if (helpers.isBlankText(user_text)) {
        self.trace("hold.input.blank.long_touch");
        _ = try handleLongTouchActivation(self);
        return;
    }
    self.trace("conversation.start");
    try self.logState(.TransientConversation);
    self.trace("conversation.expire_idle.start");
    try expireConversationIfIdle(self);
    self.trace("conversation.expire_idle.done");
    _ = try handleConversationText(self, heard_speech, .{});
}

/// Tell the language mind whether this turn is the start of a fresh social
/// situation versus a continuation, plus whether it can pull the camera to see
/// who is present. These are facts for the bot to reason over — it decides
/// whether to look, wait, or simply respond; there is no scripted greeting.
pub fn classifyIntent(self: *Brain, context: intent_mod.IntentContext, text: []const u8) !intent_mod.IntentResult {
    try self.traceContextComposition(context_composition.auditIntent(context, text));
    return self.deps.intent_service.classify(self.allocator, context, text);
}

pub fn appendSocialContextObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const timeout: i64 = @intCast(self.cfg.conversation_idle_timeout_seconds);
    const since_turn: i64 = if (self.last_conversation_turn_seconds) |t| @max(0, self.now_seconds - t) else -1;
    const since_visual: i64 = if (self.last_visual_update_seconds) |t| @max(0, self.now_seconds - t) else -1;
    const already_in_conversation = since_turn >= 0 and since_turn <= timeout;
    try out.print(
        self.allocator,
        "social_context:\n- already_in_conversation: {any}\n- seconds_since_last_turn: {d}\n- seconds_since_last_visual: {d}\n- camera_pullable: {any}\n- note: if you were not already in a conversation, someone is now beginning to interact with you. recognize pulls the camera as a non-blocking awaited observation; choose to look, wait for it, or just respond based on what already matters.\n",
        .{ already_in_conversation, since_turn, since_visual, self.deps.capabilities.live_camera },
    );
}

pub fn setWaitingFor(self: *Brain, kind: Brain.WaitingKind, intent: []const u8) !void {
    self.clearWaitingFor();
    self.waiting_for = .{
        .kind = kind,
        .intent = try self.allocator.dupe(u8, intent),
        .since = self.now_seconds,
    };
    try brain_process.syncActivityContextFromBrain(self);
}

pub fn clearWaitingFor(self: *Brain) void {
    const waiting = self.waiting_for orelse return;
    self.allocator.free(waiting.intent);
    self.waiting_for = null;
}

pub fn appendReadModelsObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const snapshot = try read_models.readModelsSnapshot(self, self.allocator);
    const salient_belief = if (snapshot.belief_model.salient) |belief| belief.proposition else "none";
    const self_trust_text = if (snapshot.self_trust_model.strongest) |entry|
        try std.fmt.allocPrint(self.allocator, "{s}={d:.2}", .{ entry.faculty, entry.confidence })
    else
        try self.allocator.dupe(u8, "none");
    defer self.allocator.free(self_trust_text);
    const disposition = if (snapshot.disposition_model.strongest) |entry| entry.action_tendency else "none";
    const focus_text = if (self.current_focus) |focus|
        try std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ focus.text, @tagName(focus.source) })
    else
        try self.allocator.dupe(u8, "none");
    defer self.allocator.free(focus_text);
    const stimulus_text = self.current_stimulus_context orelse "none";
    try out.print(
        self.allocator,
        "read_models_snapshot:\n- brain_mode: {s}\n- salient_belief: {s}\n- strongest_self_trust: {s}\n- winning_disposition: {s}\n- current_focus: {s}\n- current_stimulus: {s}\n- host_capabilities: available={d} unavailable={d} degraded={d}\n",
        .{
            @tagName(snapshot.brain_mode),
            salient_belief,
            self_trust_text,
            disposition,
            focus_text,
            stimulus_text,
            snapshot.host_capability_model.available_count,
            snapshot.host_capability_model.unavailable_count,
            snapshot.host_capability_model.degraded_count,
        },
    );
    try cognitive_capacity.appendCapacityObservation(self.allocator, self.cfg.capacity, snapshot.capacity_model, out);
}

pub fn appendHostCapabilityObservationIfChanged(self: *Brain, out: *std.ArrayList(u8)) !void {
    const statuses = try self.deps.store.loadCapabilityStatuses(self.allocator);
    var digest = std.ArrayList(u8).empty;
    defer digest.deinit(self.allocator);
    for (statuses) |status| {
        const part = try std.fmt.allocPrint(self.allocator, "{s}:{s};", .{ status.capability_id, @tagName(status.availability) });
        defer self.allocator.free(part);
        try digest.appendSlice(self.allocator, part);
    }
    const digest_text = try digest.toOwnedSlice(self.allocator);
    defer self.allocator.free(digest_text);
    if (self.last_host_capability_digest) |previous| {
        if (std.mem.eql(u8, previous, digest_text)) return;
        self.allocator.free(previous);
    }
    self.last_host_capability_digest = try self.allocator.dupe(u8, digest_text);
    try out.print(
        self.allocator,
        "host_capability_summary:\n- binding_changed: true\n- digest: {s}\n",
        .{digest_text},
    );
}

const ConversationPassResult = struct {
    spoken_text: []const u8,
    final_turn: ?chat_mod.ChatTurn,
    pending_interrupt: ?interrupt_mod.Stimulus,
    awaiting_host_sense: bool,
};

pub fn clearPendingConversationPause(self: *Brain) void {
    brain_process.clearActiveActivity(self);
}

pub const salient_sense_attention_threshold: f32 = 0.55;

fn isOrchestrationAnchor(text: []const u8) bool {
    if (std.mem.startsWith(u8, text, "self-defined want:")) return true;
    if (std.mem.startsWith(u8, text, "self-defined goal:")) return true;
    if (std.mem.startsWith(u8, text, "A salient ")) return true;
    if (std.mem.startsWith(u8, text, "A scheduled wait has ended.")) return true;
    return false;
}

fn appendHostSenseDeliveredObservation(self: *Brain, observations: *std.ArrayList(u8), delivered_line: []const u8) !void {
    try observations.appendSlice(
        self.allocator,
        "host_sense_delivered:\n- note: host fulfilled a pending pull sense; continue the active goal from context.\n",
    );
    try observations.appendSlice(self.allocator, delivered_line);
}

fn shouldFollowUpAfterHostSenseDelivery(self: *Brain) bool {
    const active = self.active_activity orelse return false;
    if (active.status != .active) return false;
    return active.kind == .conversation or isOrchestrationAnchor(active.goal);
}

pub fn runHostSenseFollowUpChat(self: *Brain, delivered_line: []const u8) !?ConversationTurnResult {
    if (!shouldFollowUpAfterHostSenseDelivery(self)) return null;
    if (self.activity_stack.items.len > 0) {
        try brain_process.collapseActivityStack(self, "host sense follow-up collapsed stale stack");
    }
    const anchor = self.active_activity.?.goal;

    const memory = try self.buildConversationMemory();
    defer self.allocator.free(memory);

    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(self.allocator);
    try appendHostSenseDeliveredObservation(self, &observations, delivered_line);
    try self.appendAffordanceObservation(&observations);
    try appendReadModelsObservation(self, &observations);
    try brain_process.appendActivityObservation(self, &observations);
    try experiential_observations.appendRecentExperienceObservation(self, &observations, null);
    try experiential_observations.appendWaitingForObservation(self, &observations);
    try appendHostCapabilityObservationIfChanged(self, &observations);

    self.conversation_user_text = anchor;
    defer self.conversation_user_text = null;

    if (!try chat_mod.chatPromptWithinBudget(self.allocator, memory, anchor, observations.items, self.cfg.capacity.chat_context_tokens_max)) {
        try self.recordContextBudgetExceeded();
        return null;
    }

    const loop_result = try runSingleChatPass(self, memory, &.{}, anchor, &observations);
    const result = try finalizeConversationTurn(
        self,
        anchor,
        memory,
        loop_result.spoken_text,
        loop_result.final_turn,
        observations.items,
        loop_result.pending_interrupt,
        false,
    );
    try finishActivityTurn(self, anchor, loop_result.spoken_text, loop_result.final_turn);
    return try brain_process.attachActivityFields(self, result);
}

fn finishActivityTurn(
    self: *Brain,
    user_text: []const u8,
    spoken_text: []const u8,
    turn: ?chat_mod.ChatTurn,
) !void {
    const turn_complete = if (turn) |chat_turn| chat_turn.turn_complete else false;
    const cont = try brain_process.classifyTurnContinuation(self, user_text, turn_complete);
    try brain_process.applyTurnContinuation(self, cont, user_text, spoken_text, turn, turn_complete);
}

pub fn clearPendingDeferredSpeech(self: *Brain) void {
    const deferred = self.pending_deferred_heard_speech orelse return;
    self.pending_deferred_heard_speech = null;
    freeHeardSpeechFields(self, deferred);
}

fn stashDeferredSpeech(self: *Brain, heard_speech: input_mod.HeardSpeech) !void {
    clearPendingDeferredSpeech(self);
    self.pending_deferred_heard_speech = try cloneHeardSpeech(self, heard_speech);
}

fn takePendingDeferredSpeech(self: *Brain) ?input_mod.HeardSpeech {
    const deferred = self.pending_deferred_heard_speech orelse return null;
    self.pending_deferred_heard_speech = null;
    return deferred;
}

fn drainDeferredConversationSpeech(self: *Brain, result: ConversationTurnResult) !ConversationTurnResult {
    var latest = result;
    while (takePendingDeferredSpeech(self)) |deferred| {
        defer freeHeardSpeechFields(self, deferred);
        latest = try runConversationTurnBody(self, deferred);
    }
    return latest;
}

pub fn drainPendingDeferredConversation(self: *Brain) !?ConversationTurnResult {
    if (self.pending_deferred_heard_speech == null) return null;
    return try drainDeferredConversationSpeech(self, .{
        .user_text = "",
        .spoken_text = "",
        .user_summary = "",
        .brain_summary = "deferred conversation processed",
    });
}

fn freeHeardSpeechFields(self: *Brain, heard_speech: input_mod.HeardSpeech) void {
    self.allocator.free(heard_speech.text);
    if (heard_speech.provider) |provider| self.allocator.free(provider);
    if (heard_speech.model_path) |model_path| self.allocator.free(model_path);
    if (heard_speech.audio_path) |audio_path| self.allocator.free(audio_path);
    if (heard_speech.raw_provider_json_path) |raw_path| self.allocator.free(raw_path);
    if (heard_speech.summary_json) |summary_json| self.allocator.free(summary_json);
}

fn cloneHeardSpeech(self: *Brain, heard_speech: input_mod.HeardSpeech) !input_mod.HeardSpeech {
    return .{
        .text = try self.allocator.dupe(u8, heard_speech.text),
        .source = heard_speech.source,
        .provider = if (heard_speech.provider) |provider| try self.allocator.dupe(u8, provider) else null,
        .model_path = if (heard_speech.model_path) |model_path| try self.allocator.dupe(u8, model_path) else null,
        .audio_path = if (heard_speech.audio_path) |audio_path| try self.allocator.dupe(u8, audio_path) else null,
        .raw_provider_json_path = if (heard_speech.raw_provider_json_path) |raw_path| try self.allocator.dupe(u8, raw_path) else null,
        .summary_json = if (heard_speech.summary_json) |summary_json| try self.allocator.dupe(u8, summary_json) else null,
    };
}

fn visualObservationLine(self: *Brain, path: []const u8, source: []const u8) ![]const u8 {
    if (self.fulfillAwaitedHostRequestIfMatches("camera", "recognize")) {
        return try self.recognizeFromCapturedPath(path);
    }
    if (self.fulfillAwaitedHostRequestIfMatches("camera", "take_picture")) {
        const description = try self.deps.description_service.describePerson(self.allocator, path, "");
        return try std.fmt.allocPrint(self.allocator, "picture: {s}\n", .{description.description});
    }
    if (try self.uploadedImageObservation(path, source)) |line| return line;
    return try std.fmt.allocPrint(
        self.allocator,
        "sensed_image:\n- image: {s}\n- source: {s}\n",
        .{ path, source },
    );
}

pub const HostVisualObservationResult = union(enum) {
    conversation_resume: ConversationTurnResult,
    recognition_only: []const u8,
    salient_reaction: ConversationTurnResult,
    detail_only: []const u8,
};

/// Deliver a host-provided image path into the brain, record the observation,
/// and optionally run a follow-up chat pass when an active conversation is waiting
/// on the delivered pull sense.
pub fn handleHostVisualObservation(
    self: *Brain,
    path: []const u8,
    source: []const u8,
    mime_type: []const u8,
) !HostVisualObservationResult {
    const owned_path = try self.allocator.dupe(u8, path);
    self.rememberVisualUpdate(owned_path);
    self.last_visual_observation_uploaded = false;

    const metadata = try std.fmt.allocPrint(self.allocator, "path={s} mime_type={s} source={s}", .{ owned_path, mime_type, source });
    const packet = try self.observeSenseStimulus(.{
        .kind = .visual,
        .source = "affective_camera",
        .signature = owned_path,
        .raw_magnitude = 0.75,
        .threat = 0,
        .curiosity = 0.50,
        .metadata = metadata,
    });

    const observation_line = try visualObservationLine(self, owned_path, source);

    if (try runHostSenseFollowUpChat(self, observation_line)) |conversation| {
        return .{ .conversation_resume = conversation };
    }

    if (try self.reactToSalientSense(packet)) |conversation| {
        return .{ .salient_reaction = conversation };
    }
    if (std.mem.indexOf(u8, observation_line, "Current speaker recognition:") != null or
        std.mem.indexOf(u8, observation_line, "picture:") != null)
    {
        return .{ .recognition_only = observation_line };
    }
    const detail = try std.fmt.allocPrint(self.allocator, "camera: observed image at {s}", .{owned_path});
    return .{ .detail_only = detail };
}

fn syntheticConversationTurn(
    self: *Brain,
    user_text: []const u8,
    brain_summary: []const u8,
) !chat_mod.ChatTurn {
    return .{
        .action_pressures = &.{},
        .user_summary = try self.allocator.dupe(u8, user_text),
        .brain_summary = try self.allocator.dupe(u8, brain_summary),
        .turn_complete = true,
    };
}

fn recordConversationPassFailure(
    self: *Brain,
    user_text: []const u8,
    err: anyerror,
    pass_result: *ConversationPassResult,
) !void {
    pass_result.spoken_text = try self.handleHardActionError(err);
    pass_result.final_turn = try syntheticConversationTurn(
        self,
        user_text,
        "Runtime failed before chat interpretation finished; surfaced the error to the user.",
    );
}

fn runSingleChatPass(
    self: *Brain,
    memory: []const u8,
    memory_sections: []const context_composition.SectionStat,
    user_text: []const u8,
    observations: *std.ArrayList(u8),
) !ConversationPassResult {
    if (!try chat_mod.chatPromptWithinBudget(self.allocator, memory, user_text, observations.items, self.cfg.capacity.chat_context_tokens_max)) {
        const audit = try chat_mod.auditChatPrompt(self.allocator, memory, user_text, observations.items);
        self.traceCount("conversation.runtime.turn.skipped context_budget", audit.user_prompt_tokens);
        try self.recordContextBudgetExceeded();
        return .{
            .spoken_text = "",
            .final_turn = try syntheticConversationTurn(
                self,
                user_text,
                "Conversation prompt exceeded context budget; skipped chat interpretation.",
            ),
            .pending_interrupt = null,
            .awaiting_host_sense = false,
        };
    }
    self.traceTurn("conversation.runtime.turn.start", 0, observations.items.len);
    const runtime_turn = runtime_bridge.runConversationPass(self, memory, memory_sections, user_text, observations, 0) catch |err| {
        var failure: ConversationPassResult = .{
            .spoken_text = "",
            .final_turn = null,
            .pending_interrupt = null,
            .awaiting_host_sense = false,
        };
        try recordConversationPassFailure(self, user_text, err, &failure);
        return failure;
    };
    const turn = runtime_turn.turn;
    self.traceTurnActionPressures("conversation.runtime.turn.done", 0, turn.action_pressures.len, turn.turn_complete);
    if (runtime_turn.execution_error) |exec_err| {
        return .{
            .spoken_text = try self.handleHardActionError(exec_err),
            .final_turn = turn,
            .pending_interrupt = null,
            .awaiting_host_sense = false,
        };
    }
    const batch = runtime_turn.batch;
    self.traceActionPressureBatch("conversation.action_pressures.done", 0, batch, observations.items.len);
    return .{
        .spoken_text = batch.spoken_text orelse "",
        .final_turn = turn,
        .pending_interrupt = batch.interrupted_by,
        .awaiting_host_sense = false,
    };
}

fn finalizeConversationTurn(
    self: *Brain,
    user_text: []const u8,
    memory: []const u8,
    spoken_text: []const u8,
    final_turn: ?chat_mod.ChatTurn,
    observations: []const u8,
    pending_interrupt: ?interrupt_mod.Stimulus,
    had_pending_hard_error: bool,
) !ConversationTurnResult {
    _ = memory;
    _ = observations;
    self.trace("conversation.summary.timestamp.start");
    const now = try self.timestampNow();
    self.trace("conversation.summary.timestamp.done");
    const summary_turn = final_turn orelse return error.MissingRuntimeChatTurnSummary;
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
    if (summary_turn.effort_tier) |tier| self.last_conversation_effort_tier = tier;
    try self.logSimple(.TransientConversation, null, null, spoken_text, "conversation_summary_added");
    if (had_pending_hard_error and self.pending_hard_error == null) {
        try self.appendEventLog("state", "Hard error recovery", "pending hard error resolved by follow-up conversation");
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

/// Run a follow-up chat pass after host sense delivery (tests and legacy callers).
pub fn continueConversationAfterAwaitedVisual(self: *Brain, visual_line: []const u8) !ConversationTurnResult {
    _ = self.fulfillAwaitedHostRequestIfMatches("camera", "recognize");
    _ = self.fulfillAwaitedHostRequestIfMatches("camera", "take_picture");
    _ = self.fulfillAwaitedHostRequestIfMatches("orientation", "sample");
    return try runHostSenseFollowUpChat(self, visual_line) orelse error.NoActiveActivity;
}

pub fn handleConversationText(self: *Brain, heard_speech: input_mod.HeardSpeech, dispatch: brain_process.StimulusDispatch) !ConversationTurnResult {
    try beginDispatchScope(self, dispatch, heard_speech.text);
    defer endDispatchScope(self);
    const result = try runConversationTurnBody(self, heard_speech);
    const drained = try drainDeferredConversationSpeech(self, result);
    return try stampDispatchIdOnResult(self, drained);
}

fn beginDispatchScope(self: *Brain, dispatch: brain_process.StimulusDispatch, user_text: []const u8) !void {
    if (self.current_dispatch_request_id != null) return;
    if (dispatch.request_id.len > 0) {
        self.current_dispatch_request_id = try self.allocator.dupe(u8, dispatch.request_id);
    } else {
        self.dispatch_serial += 1;
        self.current_dispatch_request_id = try std.fmt.allocPrint(self.allocator, "dispatch_{d}_{d}", .{ self.now_seconds, self.dispatch_serial });
    }
    self.traceText("dispatch.start", user_text);
}

fn endDispatchScope(self: *Brain) void {
    self.trace("dispatch.done");
    if (self.current_dispatch_request_id) |request_id| self.allocator.free(request_id);
    self.current_dispatch_request_id = null;
}

fn stampDispatchIdOnResult(self: *Brain, result: ConversationTurnResult) !ConversationTurnResult {
    if (result.dispatch_id.len > 0) return result;
    const id = self.current_dispatch_request_id orelse "";
    return .{
        .user_text = result.user_text,
        .spoken_text = result.spoken_text,
        .user_summary = result.user_summary,
        .brain_summary = result.brain_summary,
        .dispatch_id = if (id.len > 0) try self.allocator.dupe(u8, id) else "",
        .interrupted_by = result.interrupted_by,
        .awaiting_host_sense = result.awaiting_host_sense,
        .activity_id = result.activity_id,
        .activity_kind = result.activity_kind,
        .activity_kind_label = result.activity_kind_label,
        .activity_state = result.activity_state,
        .activity_goal = result.activity_goal,
        .activity_awaiting = result.activity_awaiting,
    };
}

fn runConversationTurnBody(self: *Brain, heard_speech: input_mod.HeardSpeech) !ConversationTurnResult {
    const user_text = heard_speech.text;
    self.clearWaitingFor();
    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode == .dreaming or brain_mode == .waking_up or brain_mode == .unavailable or brain_mode == .drowsy) {
        self.trace("conversation.blocked_by_brain_mode");
        _ = try self.recordSimpleExperienceEvent(experience_kinds.conversation_blocked, .system, @tagName(brain_mode));
        return .{
            .user_text = user_text,
            .spoken_text = "",
            .user_summary = user_text,
            .brain_summary = "Brain is unavailable for waking conversation",
        };
    }
    try recoverAutonomyFromUserTurn(self);
    const stimulus_assignment = try self.assignSpeechStimulus(heard_speech);
    self.setCurrentStimulusContext(stimulus_assignment.stimulus_context);
    // Update working memory now that this turn's stimulus is fresh, so the focus
    // block reflects what is happening as the bot composes its reply.
    try self.refreshFocus();
    const request_id = self.current_dispatch_request_id orelse "";
    try brain_process.ensureActiveActivity(self, user_text, request_id, .user_speech);
    const turn_event = try self.recordSimpleExperienceEvent(experience_kinds.user_text_received, .user, user_text);
    self.current_turn_event_id = turn_event.id;
    defer self.current_turn_event_id = null;
    const speaker_context = stimulus_assignment.speaker_context;
    const heard_speech_raw = try self.heardSpeechRaw(heard_speech);
    self.trace("conversation.memory.user_experience.start");
    try self.recordMemoryCandidateEvent(.user_utterance, "human", "user_text", user_text, .human, .utterance, .summarize, "user_text", heard_speech_raw, user_text, &.{}, &[_][]const u8{ "conversation", "heard_speech" });
    self.trace("conversation.memory.user_experience.done");
    self.trace("conversation.impression.start");
    const user_impression = try self.createImpression(.user_speech, user_text, &[_][]const u8{"conversation"});
    try self.deps.store.addImpression(user_impression);
    self.trace("conversation.impression.done");
    self.trace("conversation.appraisal.start");
    const user_appraisal = try self.createAppraisal(user_text, user_impression.impression_id, &[_][]const u8{"conversation"});
    try self.deps.store.addAppraisal(user_appraisal);
    try self.recordMemoryCandidateEvent(.observation, "brain", "user_speech_appraisal", user_appraisal.freeform, .brain, .appraisal, .keep_disposition, "user_speech_appraisal", user_text, user_appraisal.freeform, &.{}, user_appraisal.tags);
    self.trace("conversation.appraisal.done");

    self.trace("conversation.observations.start");
    var observations = std.ArrayList(u8).empty;
    try self.appendHeardSpeechObservation(&observations, heard_speech);
    if (speaker_context) |context| {
        try observations.appendSlice(self.allocator, context.memory_line);
    }
    self.traceCount("conversation.observations.heard_speech.done", observations.items.len);
    const uploaded_observation = try self.uploadedMediaObservation(user_text);
    if (uploaded_observation) |line| try observations.appendSlice(self.allocator, line);
    self.traceCount("conversation.observations.uploaded.done", observations.items.len);
    if (speaker_context == null and uploaded_observation == null) self.trace("conversation.speaker_context.deferred");
    try self.logUserUtterance(if (speaker_context) |context| context.chat_label else "User", user_text);
    self.trace("conversation.memory.selection.start");
    const memory_selection_result = try memory_selection_mod.selectConversationMemories(self, user_text);
    self.traceCount("conversation.memory.selection.done", memory_selection_result.entries.len);
    self.trace("conversation.memory.build.start");
    var memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer memory_sections.deinit(self.allocator);
    const memory = try self.buildConversationMemoryWithSpeaker(
        if (speaker_context) |context| context.memory_line else null,
        &memory_sections,
        memory_selection_result,
    );
    self.traceCount("conversation.memory.build.done", memory.len);
    self.trace("conversation.affordances.start");
    try self.appendAffordanceObservation(&observations);
    try self.appendSocialContextObservation(&observations);
    try appendReadModelsObservation(self, &observations);
    try brain_process.appendActivityObservation(self, &observations);
    try experiential_observations.appendRecentExperienceObservation(self, &observations, turn_event.id);
    try experiential_observations.appendStimulusContinuityObservation(self, &observations, heard_speech);
    try experiential_observations.appendWaitingForObservation(self, &observations);
    try memory_selection_mod.appendMemorySelectionObservation(self.allocator, &observations, memory_selection_result);
    try appendHostCapabilityObservationIfChanged(self, &observations);
    self.traceCount("conversation.affordances.done", observations.items.len);
    self.trace("conversation.subsystems.start");
    try subsystems.appendSubsystemObservations(self, self.allocator, &observations, .{
        .source_event_ids = &[_][]const u8{turn_event.id},
        .focus = if (self.current_focus) |focus| focus.text else null,
    });
    self.trace("conversation.subsystems.done");
    const had_pending_hard_error = self.pending_hard_error != null;
    try self.appendPendingHardErrorObservation(&observations);
    if (had_pending_hard_error) self.pending_hard_error = null;
    self.conversation_user_text = user_text;
    defer self.conversation_user_text = null;
    const loop_result = try runSingleChatPass(self, memory, memory_sections.items, user_text, &observations);
    const result = try finalizeConversationTurn(
        self,
        user_text,
        memory,
        loop_result.spoken_text,
        loop_result.final_turn,
        observations.items,
        loop_result.pending_interrupt,
        had_pending_hard_error,
    );
    const attached = try brain_process.attachActivityFields(self, result);
    try finishActivityTurn(self, user_text, loop_result.spoken_text, loop_result.final_turn);
    return attached;
}

fn recoverAutonomyFromUserTurn(self: *Brain) !void {
    const io = self.deps.io orelse return;
    const fs = self.deps.filesystem orelse return;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    maintenance.recoverOnUserTurn(&state, self.cfg.autonomy_social_engagement_boost, self.now_seconds);
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
}

pub fn reportRemoteThinkingFailure(self: *Brain) !void {
    const text = remote_thinking_failure_message;
    self.outputBrain(text);
    try self.appendEventLog("error", "Brain", text);
}

pub fn dryRunConversationPrompt(self: *Brain, user_text: []const u8) !chat_mod.ChatPrompt {
    if (helpers.isBlankText(user_text)) return error.EmptyDryRunRequest;
    var observations = std.ArrayList(u8).empty;
    const memory = try self.buildConversationMemory();
    try self.appendAffordanceObservation(&observations);
    return chat_mod.buildChatPrompt(self.allocator, memory, user_text, observations.items, self.cfg.capacity.chat_context_tokens_max);
}

pub fn syncClock(self: *Brain, io: std.Io) void {
    const clock = self.deps.clock orelse return;
    self.now_seconds = clock.nowSeconds(io) catch self.now_seconds;
}

pub fn runMaintenance(self: *Brain, io: std.Io) !void {
    try runIdMonitors(self, io);
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const tasks = try maintenance.dueTasks(self.allocator, fs, io, self.cfg.maintenance_schedule_path, self.cfg.maintenance_state_path, self.now_seconds);
    for (tasks) |task| {
        if (brain_dream_memory.maintenanceSpeechText(task.capability_spec)) |intent| {
            _ = try self.reconsiderFromReminder(intent);
            try maintenance.markRun(self.allocator, fs, io, self.cfg.maintenance_state_path, task.task_id, self.now_seconds);
            const text = try std.fmt.allocPrint(self.allocator, "maintenance:{s}", .{task.capability_spec});
            try self.logSimple(.Idle, null, null, null, text);
            continue;
        }
        try self.runMaintenanceCapability(task.capability_spec);
        try maintenance.markRun(self.allocator, fs, io, self.cfg.maintenance_state_path, task.task_id, self.now_seconds);
        const text = try std.fmt.allocPrint(self.allocator, "maintenance:{s}", .{task.capability_spec});
        try self.logSimple(.Idle, null, null, null, text);
    }
    try self.flushContextStatsIfDirty();
}

fn salientSenseWarrantsOrchestration(self: *Brain, packet: stimulus_mod.Packet) bool {
    if (packet.attention_intensity < salient_sense_attention_threshold) return false;
    if (packet.threat >= 0.55) return true;
    if (self.waiting_for != null) return true;
    if (self.active_activity != null) return true;
    if (self.current_focus != null) {
        if (self.currentFocusAttention()) |attention| {
            if (attention >= 0.35) return true;
        }
    }
    const since_turn: i64 = if (self.last_conversation_turn_seconds) |t| @max(0, self.now_seconds - t) else -1;
    const timeout: i64 = @intCast(self.cfg.conversation_idle_timeout_seconds);
    return since_turn >= 0 and since_turn <= timeout;
}

pub fn reactToSalientSense(self: *Brain, packet: stimulus_mod.Packet) !?ConversationTurnResult {
    if (!salientSenseWarrantsOrchestration(self, packet)) return null;

    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode == .dreaming or brain_mode == .waking_up or brain_mode == .unavailable or brain_mode == .drowsy) return null;

    const orchestration_text = try std.fmt.allocPrint(
        self.allocator,
        "A salient {s} sense arrived. Reconsider what to do.",
        .{@tagName(packet.kind)},
    );
    defer self.allocator.free(orchestration_text);

    try self.refreshFocus();
    var observations = std.ArrayList(u8).empty;
    try observations.print(
        self.allocator,
        "salient_sense:\n- kind: {s}\n- attention_intensity: {d:.3}\n- note: this sense is strong enough to warrant reconsideration; choose whether to speak, look, remember, or wait.\n",
        .{ @tagName(packet.kind), packet.attention_intensity },
    );
    var salient_memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer salient_memory_sections.deinit(self.allocator);
    const memory = try self.buildConversationMemoryWithSpeaker(null, &salient_memory_sections, null);
    defer self.allocator.free(memory);
    try self.appendAffordanceObservation(&observations);
    try appendReadModelsObservation(self, &observations);
    try brain_process.appendActivityObservation(self, &observations);
    try experiential_observations.appendRecentExperienceObservation(self, &observations, null);
    try experiential_observations.appendWaitingForObservation(self, &observations);
    try appendHostCapabilityObservationIfChanged(self, &observations);
    self.conversation_user_text = orchestration_text;
    defer self.conversation_user_text = null;

    if (!try chat_mod.chatPromptWithinBudget(self.allocator, memory, orchestration_text, observations.items, self.cfg.capacity.chat_context_tokens_max)) {
        const audit = try chat_mod.auditChatPrompt(self.allocator, memory, orchestration_text, observations.items);
        self.traceCount("salient_sense.orchestration.skipped context_budget", audit.user_prompt_tokens);
        try self.recordContextBudgetExceeded();
        return null;
    }

    const stack_depth_before = self.activity_stack.items.len;
    try brain_process.ensureActiveActivity(self, orchestration_text, "", .salient_sense);
    errdefer if (self.activity_stack.items.len > stack_depth_before) {
        brain_process.abandonOrchestrationSubtask(self, "salient sense orchestration aborted") catch {};
    };
    const loop_result = try runSingleChatPass(self, memory, salient_memory_sections.items, orchestration_text, &observations);
    const result = try finalizeConversationTurn(
        self,
        orchestration_text,
        memory,
        loop_result.spoken_text,
        loop_result.final_turn,
        observations.items,
        loop_result.pending_interrupt,
        false,
    );
    try brain_process.completeSubtaskActivity(self, orchestration_text, result.spoken_text, loop_result.final_turn);
    if (result.spoken_text.len == 0 and !self.awaitedHostRequestActive()) return null;
    return try brain_process.attachActivityFields(self, result);
}

pub fn reconsiderFromReminder(self: *Brain, intent_text: []const u8) !ConversationTurnResult {
    self.clearWaitingFor();
    const reconsider_text = try std.fmt.allocPrint(
        self.allocator,
        "A scheduled wait has ended. Reconsider what to do. Intended reminder: {s}",
        .{intent_text},
    );
    defer self.allocator.free(reconsider_text);
    _ = try self.recordSimpleExperienceEvent(experience_kinds.reminder_fired, .system, intent_text);
    try self.refreshFocus();
    try brain_process.ensureActiveActivity(self, reconsider_text, "", .reminder);
    var observations = std.ArrayList(u8).empty;
    try observations.print(
        self.allocator,
        "timer_fired:\n- intent: {s}\n- note: you scheduled this wait; reconsider whether to speak, continue focus, or wait again.\n",
        .{intent_text},
    );
    var reminder_memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer reminder_memory_sections.deinit(self.allocator);
    const memory = try self.buildConversationMemoryWithSpeaker(null, &reminder_memory_sections, null);
    defer self.allocator.free(memory);
    try self.appendAffordanceObservation(&observations);
    try appendReadModelsObservation(self, &observations);
    try brain_process.appendActivityObservation(self, &observations);
    try experiential_observations.appendRecentExperienceObservation(self, &observations, null);
    try experiential_observations.appendWaitingForObservation(self, &observations);
    try appendHostCapabilityObservationIfChanged(self, &observations);
    self.conversation_user_text = reconsider_text;
    defer self.conversation_user_text = null;
    const loop_result = try runSingleChatPass(self, memory, reminder_memory_sections.items, reconsider_text, &observations);
    const result = try finalizeConversationTurn(
        self,
        reconsider_text,
        memory,
        loop_result.spoken_text,
        loop_result.final_turn,
        observations.items,
        loop_result.pending_interrupt,
        false,
    );
    try brain_process.completeSubtaskActivity(self, reconsider_text, loop_result.spoken_text, loop_result.final_turn);
    return try brain_process.attachActivityFields(self, result);
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
        try self.recordExperienceLogEvent(.{
            .kind = .system,
            .source = "id_monitor",
            .title = "id_monitor_external_start",
            .body = self.cfg.id_monitor_external_command,
            .monitor_id = "external",
            .severity = .debug,
            .tags = @constCast(&[_][]const u8{ "id", "monitor", "external", "audit" }),
        });
        const runner = self.deps.process_runner orelse {
            self.id_monitor_manager.markExternalCrash(self.now_seconds);
            try self.recordIdMonitorCrashEvent("external", error.MissingProcessRunner);
            return;
        };
        const monitor_events = id_monitor.runExternalMonitor(self.allocator, io, runner, "external", self.cfg.id_monitor_external_command) catch |err| {
            self.id_monitor_manager.markExternalCrash(self.now_seconds);
            try self.recordIdMonitorCrashEvent("external", err);
            return;
        };
        for (monitor_events) |event| try self.recordIdMonitorEvent(event);
        try self.recordExperienceLogEvent(.{
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
    try self.appendEventLog("error", "Power critical", interpretation);
    self.outputFmt("\nBRAIN STATE: Shutdown\nREASON: critical host battery <= {d}% without external power\n{s}\n", .{ critical_percent, power_text });
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
    try self.appendEventLog("result", "Signal shutdown", interpretation);
    self.outputFmt("\nBRAIN STATE: Shutdown\nREASON: received {s}\n", .{signal_name});
}

pub fn runAutonomyReplenish(self: *Brain, io: std.Io) !void {
    if (!self.autonomyEnabled()) return;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    _ = maintenance.replenishCapacity(
        &state,
        brain_autonomy.autonomyReplenishRatePerSecond(self.cfg),
        self.cfg.autonomy_planner_min_capacity,
        self.now_seconds,
    );
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
}

pub fn runAutonomyReplenishFromPush(self: *Brain, io: std.Io, actions: u32) !u32 {
    if (!self.autonomyEnabled()) return error.AutonomyDisabled;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    const applied_actions = maintenance.replenishWholeActionsFromPush(&state, actions, self.cfg.autonomy_planner_min_capacity, self.now_seconds);
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
    return applied_actions;
}

pub fn runAutonomyTick(self: *Brain, io: std.Io) !void {
    if (!self.autonomyEnabled()) return;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    if (!try prepareAutonomyPlanning(self, io, &state)) return;
    if (!maintenance.autonomyPlannerReady(state)) {
        state.last_reason = try self.allocator.dupe(u8, "autonomy waiting: overdrawn");
        try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
        return;
    }
    try runAutonomyPlannerWithState(self, io, &state);
}

pub fn runStimulusAutonomy(self: *Brain, io: std.Io) !void {
    if (!self.autonomyEnabled()) return;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    if (!try prepareAutonomyPlanning(self, io, &state)) return;
    if (!maintenance.autonomyPlannerReady(state)) return;
    try runAutonomyPlannerWithState(self, io, &state);
}

fn prepareAutonomyPlanning(self: *Brain, io: std.Io, state: *maintenance.AutonomyState) !bool {
    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode == .dreaming or brain_mode == .drowsy or brain_mode == .waking_up) return false;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    if (state.sleeping) return false;
    if (try self.deps.input.isActive(self.allocator)) {
        state.last_reason = try self.allocator.dupe(u8, "autonomy paused: human input active");
        try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state.*);
        return false;
    }
    return true;
}

fn runAutonomyPlannerWithState(self: *Brain, io: std.Io, state: *maintenance.AutonomyState) !void {
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const planner = self.deps.autonomy_planner orelse return error.MissingAutonomyPlanner;
    state.last_autonomy_tick_at = self.now_seconds;
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state.*);

    try self.refreshFocus();
    const context = try self.buildAutonomyContext(io, state.*);
    defer self.allocator.free(context);
    const turn = planner.plan(self.allocator, context) catch |err| {
        state.last_error = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
        try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state.*);
        return err;
    };
    defer autonomy_mod.freeAutonomyTurn(self.allocator, turn);
    const composition_context = try process_goal_resolver.buildAutonomyCompositionContext(self.allocator, context, turn.reason);
    defer self.allocator.free(composition_context);
    const expanded_turn = try process_goal_resolver.expandAutonomyTurn(self, turn, composition_context);
    defer {
        chat_mod.freeActionProposals(self.allocator, expanded_turn.action_pressures);
        self.allocator.free(@constCast(expanded_turn.reason));
    }
    try self.executeAutonomyTurn(io, state, expanded_turn);
    var latest_state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    if (state.last_reason) |reason| latest_state.last_reason = reason;
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, latest_state);
}

pub fn expireConversationIfIdle(self: *Brain) !void {
    const last = self.last_conversation_turn_seconds orelse return;
    const timeout: i64 = @intCast(self.cfg.conversation_idle_timeout_seconds);
    if (self.now_seconds - last >= timeout) {
        try brain_process.pauseActiveActivityForIdle(self, "conversation idle timeout");
        try self.runMaintenanceCapability("end_conversation");
    }
}
