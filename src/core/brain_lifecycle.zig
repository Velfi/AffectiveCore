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
const openai = ports.openai;
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
const learning = @import("learning.zig");
const memory_selection_mod = @import("memory_selection.zig");
const context_tier = @import("context_tier.zig");
const read_models = @import("read_models.zig");
const stimulus_inbox_mod = @import("stimulus_inbox.zig");
const work_registry_mod = @import("work_registry.zig");
const stimulus_ingest_mod = @import("stimulus_ingest.zig");
const attention_scheduler_mod = @import("attention_scheduler.zig");
const experience_kinds = @import("experience_kinds.zig");
const recognition_composite = @import("recognition_composite.zig");
const belief_updates = @import("belief_updates.zig");
const experiential_observations = @import("experiential_observations.zig");
const present_moment = @import("present_moment.zig");
const awaited_host_request_mod = @import("awaited_host_request.zig");
const conversation_cotext = @import("conversation_cotext.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const brain_context_stats = @import("brain_context_stats.zig");
const brain_process = @import("brain_process.zig");
const host_capability_activation = @import("host_capability_activation.zig");
const process_goal_resolver = @import("process_goal_resolver.zig");
const process_runtime_mod = @import("process_runtime.zig");
const actor_payloads = @import("actors/payloads.zig");
const runtime_bridge = @import("brain_runtime_bridge.zig");
const cognitive_capacity = @import("cognitive_capacity.zig");
const context_composition = @import("context_composition.zig");
const conversation_context = @import("conversation_context.zig");
const brain_observation_append = @import("brain_observation_append.zig");
const activity_mod = @import("activity.zig");
const stimulus_mod = @import("stimulus.zig");
const experience_pipeline = @import("experience_pipeline.zig");

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

fn composeClockMs(self: *Brain) ?i64 {
    const io = self.deps.io orelse return null;
    return std.Io.Clock.real.now(io).toMilliseconds();
}

fn recordComposeStage(self: *Brain, label: []const u8, started_ms: ?i64) !void {
    if (started_ms) |start| try self.recordComposeTimingSpan(label, start);
}

fn recordConversationPromptBudgetFailure(
    self: *Brain,
    memory: []const u8,
    memory_sections: []const context_composition.SectionStat,
    user_text: []const u8,
    observations: []const u8,
    turn_index: ?usize,
    stimulus_kind: chat_mod.StimulusKind,
) !void {
    var audit_arena = std.heap.ArenaAllocator.init(self.allocator);
    defer audit_arena.deinit();
    const composition_report = try context_composition.auditConversationPrompt(
        audit_arena.allocator(),
        memory,
        memory_sections,
        user_text,
        observations,
        turn_index,
    );
    try self.setDispatchContextFromComposition(composition_report, stimulus_kind, true);
    const max_tokens = try chatContextTokenBudgetForPrompt(
        self,
        memory,
        user_text,
        observations,
        stimulus_kind,
    );
    self.traceConversationContextBudgetExceeded(
        composition_report.user_prompt_tokens,
        max_tokens,
    );
    try self.recordContextBudgetExceeded();
}

fn chatContextTokenBudgetForPrompt(
    self: *Brain,
    memory: []const u8,
    user_text: []const u8,
    observations: []const u8,
    stimulus_kind: chat_mod.StimulusKind,
) !usize {
    const audit = try chat_mod.auditChatPrompt(
        self.allocator,
        memory,
        user_text,
        observations,
        stimulus_kind,
    );
    return context_tier.resolveChatContextTokenMax(
        self.cfg.capacity.chat_context_tokens_max,
        self.last_conversation_effort_tier,
        audit.user_prompt_tokens,
    );
}

const PreparedConversationContext = struct {
    memory: []const u8,
    observations: []const u8,
    memory_sections: []context_composition.SectionStat,
    dropped: []const []const u8,

    pub fn deinit(self: PreparedConversationContext, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
        allocator.free(self.observations);
        for (self.memory_sections) |section| allocator.free(section.name);
        allocator.free(self.memory_sections);
        for (self.dropped) |name| allocator.free(name);
        allocator.free(self.dropped);
    }
};

fn traceContextTrim(self: *Brain, dropped: []const []const u8) void {
    for (dropped) |section| self.traceText("context.trim.dropped", section);
}

fn prepareConversationContext(
    self: *Brain,
    memory_blocks: []context_composition.ContextBlock,
    observation_blocks: []context_composition.ContextBlock,
    user_text: []const u8,
    stimulus: chat_mod.StimulusKind,
) !PreparedConversationContext {
    const sorted_memory = try self.allocator.alloc(context_composition.ContextBlock, memory_blocks.len);
    @memcpy(sorted_memory, memory_blocks);
    context_composition.sortBlocks(sorted_memory);

    const sorted_observations = try self.allocator.alloc(context_composition.ContextBlock, observation_blocks.len);
    @memcpy(sorted_observations, observation_blocks);
    context_composition.sortBlocks(sorted_observations);

    const preview_memory = try context_composition.assembleBlocks(self.allocator, sorted_memory);
    defer {
        self.allocator.free(preview_memory.memory);
        self.allocator.free(preview_memory.observations);
        for (preview_memory.memory_sections) |section| self.allocator.free(section.name);
        self.allocator.free(preview_memory.memory_sections);
    }
    const preview_observations = try context_composition.assembleBlocks(self.allocator, sorted_observations);
    defer {
        self.allocator.free(preview_observations.memory);
        self.allocator.free(preview_observations.observations);
        for (preview_observations.memory_sections) |section| self.allocator.free(section.name);
        self.allocator.free(preview_observations.memory_sections);
    }

    const max_tokens = try chatContextTokenBudgetForPrompt(
        self,
        preview_memory.memory,
        user_text,
        preview_observations.observations,
        stimulus,
    );

    const trimmed = try conversation_context.finalizeConversationContext(
        self.allocator,
        memory_blocks,
        observation_blocks,
        user_text,
        stimulus,
        max_tokens,
    );
    traceContextTrim(self, trimmed.dropped);
    self.allocator.free(sorted_memory);
    self.allocator.free(sorted_observations);
    return .{
        .memory = trimmed.memory,
        .observations = trimmed.observations,
        .memory_sections = trimmed.memory_sections,
        .dropped = trimmed.dropped,
    };
}

fn composeAndPrepareConversationContext(
    self: *Brain,
    speaker_context: ?[]const u8,
    selection: ?memory_selection_mod.ResolvedMemorySelection,
    compose_opts: conversation_context.ComposeOptions,
    user_text: []const u8,
) !PreparedConversationContext {
    const memory_blocks = try self.buildConversationMemoryBlocks(speaker_context, selection, compose_opts.stimulus);
    defer conversation_context.freeMemoryBlocks(self.allocator, memory_blocks);
    const observation_blocks = try conversation_context.composeObservations(self, compose_opts);
    defer conversation_context.freeObservationBlocks(self.allocator, observation_blocks);
    return try prepareConversationContext(self, memory_blocks, observation_blocks, user_text, compose_opts.stimulus);
}

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
        .stimulus_inbox = stimulus_inbox_mod.Inbox.init(allocator, cfg.capacity.stimulus_inbox_max),
        .work_registry = work_registry_mod.Registry.init(cfg.capacity.work_registry_max),
    };
    return brain;
}

pub fn pollStimulusInbox(self: *Brain) !void {
    if (self.deps.stimulus_poll) |poll| {
        if (self.deps.stimulus_poll_ctx) |ctx| try poll(ctx);
    }
    try stimulus_ingest_mod.pollInbox(self);
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

pub fn rememberHostHttpErrorDetail(self: *Brain, detail: []const u8) error{OutOfMemory}!void {
    const trimmed = std.mem.trim(u8, detail, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    if (self.last_host_http_error_detail) |prev| self.allocator.free(prev);
    self.last_host_http_error_detail = try self.allocator.dupe(u8, trimmed);
}

pub fn hostHttpErrorDetail(self: *Brain) ?[]const u8 {
    return self.last_host_http_error_detail;
}

pub fn clearHostHttpErrorDetail(self: *Brain) void {
    if (self.last_host_http_error_detail) |prev| {
        self.allocator.free(prev);
        self.last_host_http_error_detail = null;
    }
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
    defer seed_mod.freeSeedDocument(self.allocator, doc);
    try seedDocument(self, doc);
}

pub fn refreshPersonaVoiceFromSeed(self: *Brain) !void {
    if (self.cfg.seed_path.len == 0) return;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const io = self.deps.io orelse return error.MissingIo;
    const voice_lines = try seed_mod.readSeedVoiceLines(self.allocator, fs, io, self.cfg.seed_path);
    defer seed_mod.freeSeedVoiceLines(self.allocator, voice_lines);
    try brain_dream_memory.setPersonaVoiceLines(self, voice_lines);
}

pub fn seedDocument(self: *Brain, doc: seed_mod.SeedDocument) !void {
    try brain_dream_memory.setPersonaVoiceLines(self, doc.voice_lines);
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

pub fn handleUserInterruptFromHost(self: *Brain, ctx: UserInterruptContext) !void {
    const process_model = process_runtime_mod.activeProcessModel(self);

    const activity_goal = if (self.active_activity) |active| active.goal else "none";
    const activity_kind = if (self.active_activity) |active| active.kind_label else "none";
    const activity_status = if (self.active_activity) |active| @tagName(active.status) else "none";
    const activity_awaiting = if (self.active_activity) |active| active.awaiting orelse "none" else "none";

    const awaited_sense = if (self.awaited_host_request) |req| req.sense else "none";
    const awaited_purpose = if (self.awaited_host_request) |req| req.purpose else "none";
    const awaited_request_id = if (self.awaited_host_request) |req| req.request_id else "none";

    const waiting_kind = if (self.waiting_for) |waiting| @tagName(waiting.kind) else "none";
    const waiting_intent = if (self.waiting_for) |waiting| waiting.intent else "none";

    const coalesce = try buildUserInterruptCoalesceObservation(
        self,
        ctx,
        .{
            .activity_goal = activity_goal,
            .activity_kind = activity_kind,
            .activity_status = activity_status,
            .activity_awaiting = activity_awaiting,
            .process_model = process_model,
            .awaited_sense = awaited_sense,
            .awaited_purpose = awaited_purpose,
            .awaited_request_id = awaited_request_id,
            .waiting_kind = waiting_kind,
            .waiting_intent = waiting_intent,
        },
    );
    defer self.allocator.free(coalesce);

    try process_runtime_mod.abortActiveProcessForInterrupt(self, ctx.reason);
    self.clearAwaitedHostRequest();
    self.clearWaitingFor();
    clearPendingDeferredSpeech(self);

    if (self.active_activity) |active| {
        if (brain_process.activityIsInterruptibleWork(active)) {
            try brain_process.collapseActivityStack(self, "user interrupt collapsed stale stack");
            try brain_process.supersedeActiveActivity(self);
        } else {
            try brain_process.dropActiveCheckpointForInterrupt(self);
        }
    }

    try storePendingUserInterruptCoalesce(self, coalesce);

    const stimulus_text = if (ctx.preview_text.len > 0)
        try std.fmt.allocPrint(self.allocator, "user interrupt: {s}", .{ctx.preview_text})
    else
        try std.fmt.allocPrint(self.allocator, "user interrupt: {s}", .{ctx.reason});
    defer self.allocator.free(stimulus_text);
    try self.setOwnedCurrentStimulusContext(stimulus_text);

    try self.refreshFocus();
    _ = try self.recordSimpleExperienceEvent("User.Interrupt", .user, ctx.reason);
}

pub const UserInterruptContext = struct {
    reason: []const u8,
    interrupted_action: []const u8,
    preview_text: []const u8,
    canceled_queued_action_count: i64,
};

const UserInterruptSnapshot = struct {
    activity_goal: []const u8,
    activity_kind: []const u8,
    activity_status: []const u8,
    activity_awaiting: []const u8,
    process_model: process_runtime_mod.ActiveProcessModel,
    awaited_sense: []const u8,
    awaited_purpose: []const u8,
    awaited_request_id: []const u8,
    waiting_kind: []const u8,
    waiting_intent: []const u8,
};

fn clearPendingUserInterruptCoalesce(self: *Brain) void {
    brain_observation_append.clearPendingUserInterruptCoalesce(self);
}

fn storePendingUserInterruptCoalesce(self: *Brain, text: []const u8) !void {
    clearPendingUserInterruptCoalesce(self);
    self.pending_user_interrupt_coalesce = try self.allocator.dupe(u8, text);
}

fn buildUserInterruptCoalesceObservation(
    self: *Brain,
    ctx: UserInterruptContext,
    snapshot: UserInterruptSnapshot,
) ![]const u8 {
    const active_process = snapshot.process_model;
    const process_goal = active_process.goal orelse "none";
    const process_state = active_process.state orelse "none";
    const process_step_kind = active_process.current_step_kind orelse "none";
    const process_waiting = active_process.waiting_for orelse "none";
    return std.fmt.allocPrint(
        self.allocator,
        "user_interrupt_coalesce:\n" ++
            "- reason: {s}\n" ++
            "- preview_text: {s}\n" ++
            "- interrupted_host_action: {s}\n" ++
            "- canceled_queued_action_count: {d}\n" ++
            "- superseded_activity: goal={s} kind={s} status={s} awaiting={s}\n" ++
            "- superseded_process: goal={s} state={s} step={d}/{d} kind={s} waiting={s}\n" ++
            "- awaited_host_before_interrupt: sense={s} purpose={s} request_id={s}\n" ++
            "- waiting_for_before_interrupt: kind={s} intent={s}\n" ++
            "- note: user cut in; prior work is abandoned. Reconsider from what they said now; continuing old steps is optional, not required.\n",
        .{
            ctx.reason,
            ctx.preview_text,
            ctx.interrupted_action,
            ctx.canceled_queued_action_count,
            snapshot.activity_goal,
            snapshot.activity_kind,
            snapshot.activity_status,
            snapshot.activity_awaiting,
            process_goal,
            process_state,
            active_process.step_index + 1,
            active_process.step_count,
            process_step_kind,
            process_waiting,
            snapshot.awaited_sense,
            snapshot.awaited_purpose,
            snapshot.awaited_request_id,
            snapshot.waiting_kind,
            snapshot.waiting_intent,
        },
    );
}

fn appendPendingUserInterruptCoalesceObservation(self: *Brain, observations: *std.ArrayList(u8)) !void {
    try brain_observation_append.appendPendingUserInterruptCoalesceObservation(self, observations);
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

pub fn appendSocialContextObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    try brain_observation_append.appendSocialContextObservation(self, out);
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
    try brain_observation_append.appendReadModelsObservation(self, out);
}

pub fn appendHostCapabilityObservationIfChanged(self: *Brain, out: *std.ArrayList(u8)) !void {
    try brain_observation_append.appendHostCapabilityObservationIfChanged(self, out);
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
    try brain_observation_append.appendHostSenseDeliveredObservation(self, observations, delivered_line);
}

fn appendPresentMomentObservation(self: *Brain, observations: *std.ArrayList(u8), user_text: ?[]const u8) !void {
    const overlap = if (user_text) |text| present_moment.detectRequestOverlap(self, text) else null;
    try present_moment.appendObservation(self, observations, user_text, overlap);
}

fn integrateHostSenseDeliverySilently(self: *Brain, delivered_line: []const u8) !void {
    _ = try self.recordSimpleExperienceEvent("Host.SenseIntegrated", .sense, delivered_line);
}

fn shouldFollowUpAfterHostSenseDelivery(self: *Brain, delivery_was_awaited: bool) bool {
    if (!delivery_was_awaited) return false;
    const active = self.active_activity orelse return false;
    if (active.status != .active and active.status != .paused) return false;
    return active.kind == .conversation or isOrchestrationAnchor(active.goal);
}

pub fn runHostSenseFollowUpChat(
    self: *Brain,
    delivered_line: []const u8,
    delivery_was_awaited: bool,
    bind: ?awaited_host_request_mod.BoundSnapshot,
) !?ConversationTurnResult {
    if (!shouldFollowUpAfterHostSenseDelivery(self, delivery_was_awaited)) return null;

    if (!delivery_was_awaited and !attention_scheduler_mod.shouldRunFullChatPass(self, .host_sense_delivery)) {
        try integrateHostSenseDeliverySilently(self, delivered_line);
        return null;
    }

    const assessment = present_moment.assessHostDelivery(self, delivered_line, bind);
    if (!present_moment.shouldDeliberateAfterHostDelivery(self, assessment)) {
        try integrateHostSenseDeliverySilently(self, delivered_line);
        return null;
    }

    if (self.activity_stack.items.len > 0) {
        try brain_process.collapseActivityStack(self, "host sense follow-up collapsed stale stack");
    }
    const anchor = blk: {
        if (bind) |b| {
            break :blk b.bound_user_text orelse b.bound_goal orelse self.active_activity.?.goal;
        }
        break :blk self.active_activity.?.goal;
    };

    const delivery_opts = conversation_context.HostDeliveryOpts{
        .delivered_line = delivered_line,
        .assessment = assessment,
        .bind = bind,
    };
    const prepared = composeAndPrepareConversationContext(
        self,
        null,
        null,
        conversation_context.hostDeliveryComposeOptions(assessment.bound_user_text, delivery_opts),
        anchor,
    ) catch |err| switch (err) {
        error.ContextBudgetExceeded => {
            try recordConversationPromptBudgetFailure(self, "", &.{}, anchor, "", null, .host_sense_delivery);
            return null;
        },
        else => return err,
    };
    defer prepared.deinit(self.allocator);
    var memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer memory_sections.deinit(self.allocator);
    try memory_sections.appendSlice(self.allocator, prepared.memory_sections);
    const memory = prepared.memory;
    var observations = std.ArrayList(u8).empty;
    try observations.appendSlice(self.allocator, prepared.observations);

    const previous_stimulus_kind = self.conversation_turn_stimulus_kind;
    self.conversation_turn_stimulus_kind = .host_sense_delivery;
    defer self.conversation_turn_stimulus_kind = previous_stimulus_kind;

    self.conversation_user_text = anchor;
    defer self.conversation_user_text = null;

    if (self.active_process != null) {
        if (try process_runtime_mod.resumeProcess(self, .host_delivery, delivered_line, memory, memory_sections.items, &observations)) |advance| {
            const loop_result = ConversationPassResult{
                .spoken_text = advance.spoken_text,
                .final_turn = advance.final_turn orelse try syntheticConversationTurn(self, anchor, "host sense resumed process"),
                .pending_interrupt = advance.pending_interrupt,
                .awaiting_host_sense = advance.awaiting_host_sense,
            };
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
    }

    const loop_result = try runSingleChatPass(self, memory, memory_sections.items, anchor, &observations);
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

pub fn stashDeferredSpeech(self: *Brain, heard_speech: input_mod.HeardSpeech) !void {
    // Fragments arriving while a turn is in flight coalesce into one deferred
    // utterance, so the follow-up is a single deliberation over the burst.
    if (self.pending_deferred_heard_speech) |existing| {
        const joined = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ existing.text, heard_speech.text });
        defer self.allocator.free(joined);
        const merged = try cloneHeardSpeech(self, .{
            .text = joined,
            .source = heard_speech.source,
            .provider = heard_speech.provider,
            .model_path = heard_speech.model_path,
            .audio_path = heard_speech.audio_path,
            .raw_provider_json_path = heard_speech.raw_provider_json_path,
            .summary_json = heard_speech.summary_json,
        });
        clearPendingDeferredSpeech(self);
        self.pending_deferred_heard_speech = merged;
        return;
    }
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
    if (self.fulfillAwaitedHostRequestIfMatches("camera", "describe_image")) {
        return try self.describeImageForObservation("");
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
    const stimulus = try self.observeSenseStimulus(.{
        .kind = .visual,
        .source = "affective_camera",
        .signature = owned_path,
        .raw_magnitude = 0.75,
        .threat = 0,
        .curiosity = 0.50,
        .metadata = metadata,
    });

    const delivery_was_awaited = self.awaitedHostRequestActive();
    const bind = try awaited_host_request_mod.BoundSnapshot.capture(self);
    defer if (bind) |snapshot| snapshot.deinit(self.allocator);

    const observation_line = try visualObservationLine(self, owned_path, source);

    if (delivery_was_awaited) {
        if (try brain_autonomy.resumeAutonomyProcessFromHostDelivery(self, observation_line)) {
            return .{ .detail_only = try std.fmt.allocPrint(self.allocator, "autonomy process resumed after host sense delivery", .{}) };
        }
        if (try runHostSenseFollowUpChat(self, observation_line, true, bind)) |conversation| {
            return .{ .conversation_resume = conversation };
        }
        if (shouldFollowUpAfterHostSenseDelivery(self, true)) {
            if (std.mem.indexOf(u8, observation_line, "Current speaker recognition:") != null or
                std.mem.indexOf(u8, observation_line, "picture:") != null)
            {
                return .{ .recognition_only = observation_line };
            }
            const detail = try std.fmt.allocPrint(self.allocator, "camera: observed image at {s}", .{owned_path});
            return .{ .detail_only = detail };
        }
    }

    if (brain_process.activeConversationPresent(self)) {
        try brain_process.recordSenseDuringConversation(self, @tagName(stimulus.packet.kind), observation_line, stimulus.event_id);
        if (try reconsiderSalientSenseDuringConversation(self, stimulus.packet, observation_line)) |conversation| {
            return .{ .salient_reaction = conversation };
        }
    } else if (try self.reactToSalientSense(stimulus.packet)) |conversation| {
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

fn runProcessDrivenPass(
    self: *Brain,
    memory: []const u8,
    memory_sections: []const context_composition.SectionStat,
    user_text: []const u8,
    observations: *std.ArrayList(u8),
) !ConversationPassResult {
    const advance = process_runtime_mod.advanceProcess(self, memory, memory_sections, user_text, observations) catch |err| switch (err) {
        error.ProcessStepFailed => return .{
            .spoken_text = "I couldn't finish what I was trying to do.",
            .final_turn = try syntheticConversationTurn(self, user_text, "process step failed"),
            .pending_interrupt = null,
            .awaiting_host_sense = false,
        },
        else => return err,
    };
    return .{
        .spoken_text = advance.spoken_text,
        .final_turn = advance.final_turn orelse try syntheticConversationTurn(self, user_text, "process advanced"),
        .pending_interrupt = advance.pending_interrupt,
        .awaiting_host_sense = advance.awaiting_host_sense,
    };
}

fn proposalsAreNonVerbalOnly(proposals: []const chat_mod.ActionProposal) bool {
    if (proposals.len == 0) return false;
    for (proposals) |proposal| {
        switch (proposal.action) {
            .say, .emote => return false,
            else => {},
        }
    }
    return true;
}

fn runSingleChatPass(
    self: *Brain,
    memory: []const u8,
    memory_sections: []const context_composition.SectionStat,
    user_text: []const u8,
    observations: *std.ArrayList(u8),
) !ConversationPassResult {
    if (!try chat_mod.chatPromptWithinBudget(self.allocator, memory, user_text, observations.items, try chatContextTokenBudgetForPrompt(self, memory, user_text, observations.items, self.conversation_turn_stimulus_kind), self.conversation_turn_stimulus_kind)) {
        try recordConversationPromptBudgetFailure(
            self,
            memory,
            memory_sections,
            user_text,
            observations.items,
            null,
            self.conversation_turn_stimulus_kind,
        );
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

    if (self.active_process) |active| {
        if (active.state == .running) {
            return try runProcessDrivenPass(self, memory, memory_sections, user_text, observations);
        }
    }

    var turn_index: usize = 0;
    var latest: ConversationPassResult = .{
        .spoken_text = "",
        .final_turn = null,
        .pending_interrupt = null,
        .awaiting_host_sense = false,
    };

    while (true) : (turn_index += 1) {
        const observations_before = observations.items.len;
        self.traceTurn("conversation.runtime.turn.start", turn_index, observations.items.len);
        const runtime_turn = runtime_bridge.runConversationPass(self, memory, memory_sections, user_text, observations, turn_index) catch |err| {
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
        self.traceTurnActionPressures("conversation.runtime.turn.done", turn_index, turn.action_pressures.len, turn.turn_complete);
        if (runtime_turn.execution_error) |exec_err| {
            const batch = runtime_turn.batch;
            if (batch.spoken_text) |already_spoken| {
                if (already_spoken.len > 0) {
                    return .{
                        .spoken_text = already_spoken,
                        .final_turn = turn,
                        .pending_interrupt = null,
                        .awaiting_host_sense = false,
                    };
                }
            }
            return .{
                .spoken_text = try self.handleHardActionError(exec_err),
                .final_turn = turn,
                .pending_interrupt = null,
                .awaiting_host_sense = false,
            };
        }
        const batch = runtime_turn.batch;
        latest = .{
            .spoken_text = batch.spoken_text orelse "",
            .final_turn = turn,
            .pending_interrupt = batch.interrupted_by,
            .awaiting_host_sense = self.awaitedHostRequestActive(),
        };
        self.traceActionPressureBatch("conversation.action_pressures.done", turn_index, batch, observations.items.len);

        if (self.active_process != null) {
            return try runProcessDrivenPass(self, memory, memory_sections, user_text, observations);
        }

        if (batch.interrupted_by != null) return latest;
        if (latest.awaiting_host_sense) return latest;
        if (latest.spoken_text.len > 0) return latest;
        if (turn.action_pressures.len == 0) return latest;
        if (turn.turn_complete) return latest;
        if (self.conversation_turn_stimulus_kind == .heard_speech and proposalsAreNonVerbalOnly(turn.action_pressures)) {
            try observations.appendSlice(self.allocator, chat_mod.heard_speech_stimulus_response_nudge_follow_up);
            continue;
        }
        if ((self.conversation_turn_stimulus_kind == .orchestration or self.conversation_turn_stimulus_kind == .host_sense_delivery) and
            proposalsAreNonVerbalOnly(turn.action_pressures))
        {
            try observations.appendSlice(
                self.allocator,
                "orchestration_nudge: Salient sense in present_moment — acknowledge it; introspect can follow if you still need detail.\n",
            );
            continue;
        }
        if (observations.items.len <= observations_before) return latest;
    }

    return latest;
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
    const summary_text = try Brain.formatTurnSummaryForMemory(
        self.allocator,
        self.conversation_turn_stimulus_kind,
        summary_turn.user_summary,
        summary_turn.brain_summary,
    );
    try self.recordMemoryCandidateEvent(.memory_mutation, "memory", "conversation_summary", summary_text, .memory, .summary, .keep_fact, "conversation_summary", user_text, summary_text, &.{}, &[_][]const u8{ "conversation", "summary" });
    self.trace("conversation.summary.store.done");
    self.last_conversation_turn_seconds = self.now_seconds;
    if (summary_turn.effort_tier) |tier| self.last_conversation_effort_tier = tier;
    try self.logSimple(.TransientConversation, null, null, spoken_text, "conversation_summary_added");
    if (had_pending_hard_error and self.pending_hard_error == null) {
        try self.appendEventLog("state", "Hard error recovery", "pending hard error resolved by follow-up conversation");
    }
    self.trace("conversation.done");
    if (self.conversation_turn_stimulus_kind == .heard_speech and spoken_text.len > 0) {
        try learning.recordConversationSpeechLearning(self, user_text, spoken_text);
    }
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
    const delivery_was_awaited = self.awaitedHostRequestActive();
    const bind = try awaited_host_request_mod.BoundSnapshot.capture(self);
    defer if (bind) |snapshot| snapshot.deinit(self.allocator);
    _ = self.fulfillAwaitedHostRequestIfMatches("camera", "recognize");
    _ = self.fulfillAwaitedHostRequestIfMatches("camera", "take_picture");
    _ = self.fulfillAwaitedHostRequestIfMatches("camera", "describe_image");
    _ = self.fulfillAwaitedHostRequestIfMatches("orientation", "sample");
    return try runHostSenseFollowUpChat(self, visual_line, delivery_was_awaited, bind) orelse error.NoActiveActivity;
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
        .awaited_host_sense = result.awaited_host_sense,
        .awaited_host_purpose = result.awaited_host_purpose,
        .awaited_host_timeout_ms = result.awaited_host_timeout_ms,
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
    const obs_heard_start = composeClockMs(self);
    if (speaker_context == null and (try self.uploadedMediaObservation(user_text)) == null) self.trace("conversation.speaker_context.deferred");
    try self.logUserUtterance(if (speaker_context) |context| context.chat_label else "User", user_text);
    try recordComposeStage(self, "obs.heard_speech", obs_heard_start);
    self.trace("conversation.memory.selection.start");
    const memory_selection_result = try memory_selection_mod.selectConversationMemories(self, user_text);
    self.traceCount("conversation.memory.selection.done", memory_selection_result.entries.len);
    self.trace("conversation.memory.build.start");
    const memory_build_start = composeClockMs(self);
    const overlap_nudge = blk: {
        if (present_moment.detectRequestOverlap(self, user_text)) |overlap| {
            break :blk overlap.confidence >= 0.75 and self.awaitedHostRequestActive();
        }
        break :blk false;
    };
    const had_pending_hard_error = self.pending_hard_error != null;
    const memory_blocks = try self.buildConversationMemoryBlocks(
        if (speaker_context) |context| context.memory_line else null,
        memory_selection_result,
        .heard_speech,
    );
    defer conversation_context.freeMemoryBlocks(self.allocator, memory_blocks);
    try recordComposeStage(self, "memory.build", memory_build_start);
    self.traceCount("conversation.memory.build.done", memory_blocks.len);
    const observation_blocks = try conversation_context.composeObservations(self, conversation_context.heardSpeechComposeOptions(
        self,
        heard_speech,
        if (speaker_context) |context| context.memory_line else null,
        memory_selection_result,
        overlap_nudge,
        had_pending_hard_error,
    ));
    defer conversation_context.freeObservationBlocks(self.allocator, observation_blocks);
    if (had_pending_hard_error) self.pending_hard_error = null;
    self.trace("conversation.affordances.done");
    self.trace("conversation.subsystems.done");
    const prepared = prepareConversationContext(self, memory_blocks, observation_blocks, user_text, .heard_speech) catch |err| switch (err) {
        error.ContextBudgetExceeded => {
            try recordConversationPromptBudgetFailure(self, "", &.{}, user_text, "", null, .heard_speech);
            return .{
                .user_text = user_text,
                .spoken_text = "",
                .user_summary = user_text,
                .brain_summary = "Conversation prompt exceeded context budget; skipped chat interpretation.",
            };
        },
        else => return err,
    };
    defer prepared.deinit(self.allocator);
    var memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer memory_sections.deinit(self.allocator);
    try memory_sections.appendSlice(self.allocator, prepared.memory_sections);
    const memory = prepared.memory;
    var observations = std.ArrayList(u8).empty;
    try observations.appendSlice(self.allocator, prepared.observations);
    self.conversation_turn_stimulus_kind = .heard_speech;
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
    const prepared = try composeAndPrepareConversationContext(self, null, null, conversation_context.dryRunComposeOptions(user_text), user_text);
    defer prepared.deinit(self.allocator);
    const max_tokens = try chatContextTokenBudgetForPrompt(self, prepared.memory, user_text, prepared.observations, .heard_speech);
    return chat_mod.buildChatPrompt(self.allocator, prepared.memory, user_text, prepared.observations, max_tokens, .heard_speech);
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

fn reconsiderSalientSenseDuringConversation(
    self: *Brain,
    packet: stimulus_mod.Packet,
    observation_line: []const u8,
) !?ConversationTurnResult {
    if (!brain_process.activeConversationPresent(self)) return null;

    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode == .dreaming or brain_mode == .waking_up or brain_mode == .unavailable or brain_mode == .drowsy) return null;

    const anchor = self.active_activity.?.goal;
    try self.refreshFocus();

    const combined_preamble = try std.fmt.allocPrint(
        self.allocator,
        "{s}\nsalient_sense_during_conversation:\n- kind: {s}\n- attention_intensity: {d:.3}\n- note: this sense arrived during an active conversation; associate with the current goal; speaking is optional.\n",
        .{ observation_line, @tagName(packet.kind), packet.attention_intensity },
    );
    defer self.allocator.free(combined_preamble);

    const prepared = composeAndPrepareConversationContext(
        self,
        null,
        null,
        conversation_context.reconsiderComposeOptions(anchor, combined_preamble, true),
        anchor,
    ) catch |err| switch (err) {
        error.ContextBudgetExceeded => {
            try recordConversationPromptBudgetFailure(self, "", &.{}, anchor, "", null, .reconsideration);
            return null;
        },
        else => return err,
    };
    defer prepared.deinit(self.allocator);
    var memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer memory_sections.deinit(self.allocator);
    try memory_sections.appendSlice(self.allocator, prepared.memory_sections);
    const memory = prepared.memory;
    var observations = std.ArrayList(u8).empty;
    try observations.appendSlice(self.allocator, prepared.observations);

    const previous_stimulus_kind = self.conversation_turn_stimulus_kind;
    self.conversation_turn_stimulus_kind = .reconsideration;
    defer self.conversation_turn_stimulus_kind = previous_stimulus_kind;

    self.conversation_user_text = anchor;
    defer self.conversation_user_text = null;

    const loop_result = try runSingleChatPass(self, memory, memory_sections.items, anchor, &observations);
    if (loop_result.spoken_text.len == 0) {
        if (loop_result.final_turn) |turn| {
            try brain_process.appendTurnEventsWithKind(self, .sense_reconsideration, anchor, "", turn);
        }
        if (!self.awaitedHostRequestActive()) return null;
    }

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
    if (result.spoken_text.len == 0 and !self.awaitedHostRequestActive()) return null;
    return try brain_process.attachActivityFields(self, result);
}

pub fn reactToSalientSense(self: *Brain, packet: stimulus_mod.Packet) !?ConversationTurnResult {
    if (!salientSenseWarrantsOrchestration(self, packet)) return null;

    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode == .dreaming or brain_mode == .waking_up or brain_mode == .unavailable or brain_mode == .drowsy) return null;

    try brain_autonomy.maybeWakeFromSalientSense(self, @tagName(packet.kind), packet.attention_intensity);

    if (brain_process.activeConversationPresent(self)) {
        const observation_line = try std.fmt.allocPrint(
            self.allocator,
            "salient_sense:\n- kind: {s}\n- attention_intensity: {d:.3}\n- metadata: {s}\n",
            .{ @tagName(packet.kind), packet.attention_intensity, packet.metadata },
        );
        defer self.allocator.free(observation_line);
        return try reconsiderSalientSenseDuringConversation(self, packet, observation_line);
    }

    const orchestration_text = try std.fmt.allocPrint(
        self.allocator,
        "A salient {s} sense arrived. Reconsider what to do.",
        .{@tagName(packet.kind)},
    );
    defer self.allocator.free(orchestration_text);

    try self.refreshFocus();
    const pending_speech = try stimulus_ingest_mod.pendingHeardSpeechCoalesced(self);
    defer if (pending_speech) |text| self.allocator.free(text);
    if (pending_speech != null) stimulus_ingest_mod.markPendingHeardSpeechHandled(self);
    const orchestration_preamble = if (pending_speech) |speech_text|
        try std.fmt.allocPrint(
            self.allocator,
            "salient_sense:\n- kind: {s}\n- attention_intensity: {d:.3}\n- note: this sense is strong enough to warrant reconsideration; choose whether to speak, look, remember, or wait.\npending_user_speech (unanswered, arrived before this sense — address it, do not ignore it):\n{s}\n",
            .{ @tagName(packet.kind), packet.attention_intensity, speech_text },
        )
    else
        try std.fmt.allocPrint(
            self.allocator,
            "salient_sense:\n- kind: {s}\n- attention_intensity: {d:.3}\n- note: this sense is strong enough to warrant reconsideration; choose whether to speak, look, remember, or wait.\n",
            .{ @tagName(packet.kind), packet.attention_intensity },
        );
    defer self.allocator.free(orchestration_preamble);

    const prepared = composeAndPrepareConversationContext(
        self,
        null,
        null,
        conversation_context.orchestrationComposeOptions(orchestration_preamble, orchestration_text),
        orchestration_text,
    ) catch |err| switch (err) {
        error.ContextBudgetExceeded => {
            try recordConversationPromptBudgetFailure(self, "", &.{}, orchestration_text, "", null, .orchestration);
            return null;
        },
        else => return err,
    };
    defer prepared.deinit(self.allocator);
    var salient_memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer salient_memory_sections.deinit(self.allocator);
    try salient_memory_sections.appendSlice(self.allocator, prepared.memory_sections);
    const memory = prepared.memory;
    var observations = std.ArrayList(u8).empty;
    try observations.appendSlice(self.allocator, prepared.observations);

    const previous_stimulus_kind = self.conversation_turn_stimulus_kind;
    self.conversation_turn_stimulus_kind = .orchestration;
    defer self.conversation_turn_stimulus_kind = previous_stimulus_kind;

    self.conversation_user_text = orchestration_text;
    defer self.conversation_user_text = null;

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

pub const EmojiReactionContext = struct {
    emoji: []const u8,
    utterance_text: []const u8,
    speaker_label: []const u8 = "",
    utterance_event_id: []const u8 = "",
};

fn emojiReactionValence(emoji: []const u8) f32 {
    if (std.mem.eql(u8, emoji, "👍") or std.mem.eql(u8, emoji, "❤️") or std.mem.eql(u8, emoji, "😂")) return 0.35;
    if (std.mem.eql(u8, emoji, "👎")) return -0.35;
    return 0.0;
}

fn emojiReactionPersonLabel(self: *Brain, speaker_label: []const u8) []const u8 {
    if (speaker_label.len > 0) return speaker_label;
    if (self.conversation_speaker_context) |context| return context.chat_label;
    return "You";
}

fn emptyEmojiReactionTurnResult() ConversationTurnResult {
    return .{
        .user_text = "",
        .spoken_text = "",
        .user_summary = "",
        .brain_summary = "",
    };
}

fn reconsiderEmojiReactionDuringConversation(
    self: *Brain,
    packet: stimulus_mod.Packet,
    stimulus_line: []const u8,
) !?ConversationTurnResult {
    if (!brain_process.activeConversationPresent(self)) return null;

    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode == .dreaming or brain_mode == .waking_up or brain_mode == .unavailable or brain_mode == .drowsy) return null;

    const anchor = self.active_activity.?.goal;
    try self.refreshFocus();

    const emoji_preamble = try std.fmt.allocPrint(
        self.allocator,
        "emoji_reaction:\n- {s}\n- note: the user reacted to something you said; acknowledge briefly if appropriate; do not over-explain.\n",
        .{stimulus_line},
    );
    defer self.allocator.free(emoji_preamble);
    const emoji_extra = try std.fmt.allocPrint(
        self.allocator,
        "emoji_reaction_during_conversation:\n- kind: {s}\n- attention_intensity: {d:.3}\n",
        .{ @tagName(packet.kind), packet.attention_intensity },
    );
    defer self.allocator.free(emoji_extra);
    var emoji_opts = conversation_context.reconsiderComposeOptions(anchor, emoji_preamble, true);
    emoji_opts.extra_preamble = emoji_extra;

    const prepared = composeAndPrepareConversationContext(self, null, null, emoji_opts, anchor) catch |err| switch (err) {
        error.ContextBudgetExceeded => {
            try recordConversationPromptBudgetFailure(self, "", &.{}, anchor, "", null, .reconsideration);
            return null;
        },
        else => return err,
    };
    defer prepared.deinit(self.allocator);
    var memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer memory_sections.deinit(self.allocator);
    try memory_sections.appendSlice(self.allocator, prepared.memory_sections);
    const memory = prepared.memory;
    var observations = std.ArrayList(u8).empty;
    try observations.appendSlice(self.allocator, prepared.observations);

    const previous_stimulus_kind = self.conversation_turn_stimulus_kind;
    self.conversation_turn_stimulus_kind = .reconsideration;
    defer self.conversation_turn_stimulus_kind = previous_stimulus_kind;

    self.conversation_user_text = anchor;
    defer self.conversation_user_text = null;

    const loop_result = try runSingleChatPass(self, memory, memory_sections.items, anchor, &observations);
    if (loop_result.spoken_text.len == 0) {
        if (loop_result.final_turn) |turn| {
            try brain_process.appendTurnEventsWithKind(self, .emoji_reaction, anchor, "", turn);
        }
        if (!self.awaitedHostRequestActive()) return null;
    }

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
    if (result.spoken_text.len == 0 and !self.awaitedHostRequestActive()) return null;
    return try brain_process.attachActivityFields(self, result);
}

pub fn handleEmojiReaction(self: *Brain, ctx: EmojiReactionContext) !ConversationTurnResult {
    if (ctx.emoji.len == 0 or ctx.utterance_text.len == 0) return error.InvalidEmojiReaction;

    const person_label = emojiReactionPersonLabel(self, ctx.speaker_label);
    const stimulus_line = try std.fmt.allocPrint(
        self.allocator,
        "{s} reacted {s} to your utterance {s}",
        .{ person_label, ctx.emoji, ctx.utterance_text },
    );
    defer self.allocator.free(stimulus_line);

    const parents: []const []const u8 = if (ctx.utterance_event_id.len > 0)
        &[_][]const u8{ctx.utterance_event_id}
    else
        &.{};
    var event = try experience_pipeline.makeEvent(self, experience_kinds.user_emoji_reaction, .user, stimulus_line, parents);
    event.payload = try self.allocator.dupe(u8, stimulus_line);
    event.salience = 0.55;
    event.valence = emojiReactionValence(ctx.emoji);
    try self.recordExperienceEvent(event);

    const stimulus = try self.observeSenseStimulus(.{
        .kind = .reaction,
        .source = "affective_host",
        .signature = ctx.emoji,
        .raw_magnitude = 0.55,
        .threat = 0,
        .curiosity = 0.20,
        .metadata = stimulus_line,
    });

    if (brain_process.activeConversationPresent(self)) {
        try brain_process.recordSenseDuringConversation(self, "reaction", stimulus_line, stimulus.event_id);
        if (try reconsiderEmojiReactionDuringConversation(self, stimulus.packet, stimulus_line)) |conversation| {
            return conversation;
        }
    }

    return emptyEmojiReactionTurnResult();
}

pub fn reconsiderFromReminder(self: *Brain, intent_text: []const u8) !ConversationTurnResult {
    if (try brain_autonomy.resumeAutonomyProcessFromTimer(self, intent_text)) {
        return .{
            .user_text = "",
            .spoken_text = "",
            .user_summary = "",
            .brain_summary = "autonomy process resumed from timer",
        };
    }
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
    const reminder_opts = conversation_context.reminderComposeOptions(intent_text, reconsider_text);
    const prepared = try composeAndPrepareConversationContext(self, null, null, reminder_opts, reconsider_text);
    defer prepared.deinit(self.allocator);
    var reminder_memory_sections = std.ArrayList(context_composition.SectionStat).empty;
    defer reminder_memory_sections.deinit(self.allocator);
    try reminder_memory_sections.appendSlice(self.allocator, prepared.memory_sections);
    const memory = prepared.memory;
    var observations = std.ArrayList(u8).empty;
    try observations.appendSlice(self.allocator, prepared.observations);

    const previous_stimulus_kind = self.conversation_turn_stimulus_kind;
    self.conversation_turn_stimulus_kind = .reconsideration;
    defer self.conversation_turn_stimulus_kind = previous_stimulus_kind;

    self.conversation_user_text = reconsider_text;
    defer self.conversation_user_text = null;

    if (self.active_process != null) {
        if (try process_runtime_mod.resumeProcess(self, .timer_fired, intent_text, memory, reminder_memory_sections.items, &observations)) |advance| {
            const loop_result = ConversationPassResult{
                .spoken_text = advance.spoken_text,
                .final_turn = advance.final_turn orelse try syntheticConversationTurn(self, reconsider_text, "timer resumed process"),
                .pending_interrupt = advance.pending_interrupt,
                .awaiting_host_sense = advance.awaiting_host_sense,
            };
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
            try brain_process.completeSubtaskActivity(self, reconsider_text, result.spoken_text, loop_result.final_turn);
            return try brain_process.attachActivityFields(self, result);
        }
    }

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
        _ = try self.recordExperienceLogEvent(.{
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
        _ = try self.recordExperienceLogEvent(.{
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
    maintenance.replenishCapacity(
        &state,
        brain_autonomy.autonomyReplenishRatePerSecond(self.cfg),
        self.now_seconds,
    );
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
}

pub fn runAutonomyReplenishFromPush(self: *Brain, io: std.Io, points: u32) !f32 {
    if (!self.autonomyEnabled()) return error.AutonomyDisabled;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    const applied_points = maintenance.replenishPointsFromPush(&state, @floatFromInt(points), self.now_seconds);
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
    return applied_points;
}

pub fn runAutonomyTick(self: *Brain, io: std.Io) !void {
    if (!self.attentionLoopEnabled()) return;
    self.syncClock(io);
    if (self.stimulus_inbox.pendingCount() > 0) {
        try self.runStimulusAutonomy(io);
        return;
    }
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    if (!try prepareAutonomyPlanning(self, io, &state)) return;
    switch (try brain_autonomy.tickActiveAutonomyProcess(self)) {
        .waiting => {
            const reason = "autonomy process waiting";
            state.last_reason = try self.allocator.dupe(u8, reason);
            try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
            try self.logAutonomyStatus("autonomy process", reason);
            return;
        },
        .advanced => {
            const reason = "autonomy process advanced";
            state.last_reason = try self.allocator.dupe(u8, reason);
            try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
            try self.logAutonomyStatus("autonomy process", reason);
            return;
        },
        .idle => {},
    }
    if (!maintenance.autonomyActionsAvailable(state)) {
        const reason = try brain_autonomy.autonomyBlockedReason(self, io, state);
        state.last_reason = try self.allocator.dupe(u8, reason);
        try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
        try self.logAutonomyStatus("autonomy blocked", reason);
        return;
    }
    try runAutonomyPlannerWithState(self, io, &state);
}

pub fn runStimulusAutonomy(self: *Brain, io: std.Io) !void {
    if (!self.attentionLoopEnabled()) return;
    self.syncClock(io);
    switch (attention_scheduler_mod.chooseNextWork(self)) {
        .hold => {
            try self.logAutonomyStatus("attention hold", "pending stimulus did not need deliberation");
            try self.pollStimulusInbox();
            return;
        },
        .coalesce_hold => {
            // Leave the inbox pending: the user is still composing, and the
            // fragments will be answered together once typing goes quiet.
            try self.logAutonomyStatus("attention coalescing", "stimulus burst in progress; holding for one deliberation");
            return;
        },
        .cotext_integrate => {
            try self.logAutonomyStatus("attention integrated", "stimulus updated attention without choosing speech");
            try self.pollStimulusInbox();
            return;
        },
        .foreground_chat, .host_follow_up, .process_advance => {},
    }
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    if (state.sleeping) try brain_autonomy.wakeFromForegroundStimulus(self, io, &state);
    if (!try prepareAutonomyPlanning(self, io, &state)) return;
    switch (try brain_autonomy.tickActiveAutonomyProcess(self)) {
        .waiting, .advanced => return,
        .idle => {},
    }
    if (!maintenance.autonomyActionsAvailable(state)) return;
    try runAutonomyPlannerWithState(self, io, &state);
}

fn prepareAutonomyPlanning(self: *Brain, io: std.Io, state: *maintenance.AutonomyState) !bool {
    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode == .dreaming or brain_mode == .drowsy or brain_mode == .waking_up) {
        const reason = try std.fmt.allocPrint(self.allocator, "autonomy blocked: brain_mode={s}", .{@tagName(brain_mode)});
        defer self.allocator.free(reason);
        try self.logAutonomyStatus("autonomy blocked", reason);
        return false;
    }
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    if (state.sleeping) {
        // Persisted sleep only holds while the owner keeps rest on or quiet
        // hours are active; otherwise the schedule ends the sleep.
        const in_quiet_hours = brain_autonomy.inQuietHours(self, io) catch true;
        if (!self.defaultAutonomySleeping() and !in_quiet_hours) {
            try brain_autonomy.wakeAutonomyFromStimulus(self, io, state, "woke: outside quiet hours");
        } else {
            try self.logAutonomyStatus("autonomy blocked", "autonomy sleeping");
            return false;
        }
    }
    if (try self.deps.input.isActive(self.allocator)) {
        const reason = "autonomy paused: human input active";
        state.last_reason = try self.allocator.dupe(u8, reason);
        try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state.*);
        try self.logAutonomyStatus("autonomy blocked", reason);
        return false;
    }
    return true;
}

fn runAutonomyPlannerWithState(self: *Brain, io: std.Io, state: *maintenance.AutonomyState) !void {
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    if (!maintenance.autonomyActionsAvailable(state.*)) {
        const reason = try brain_autonomy.autonomyBlockedReason(self, io, state.*);
        state.last_reason = try self.allocator.dupe(u8, reason);
        try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state.*);
        try self.logAutonomyStatus("autonomy blocked", reason);
        return;
    }
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
    // The plan deliberated over the coalesced pending speech in its context;
    // consume those fragments so mid-turn polls do not re-stash them.
    stimulus_ingest_mod.markPendingHeardSpeechHandled(self);
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
