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
const autonomy_governor = @import("autonomy_governor.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const capability_registry = @import("capability_registry.zig");
const capability_execution = @import("capability_execution.zig");
const scheduler_actor = @import("actors/scheduler_actor.zig");
const actor_payloads = @import("actors/payloads.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const experience_kinds = @import("experience_kinds.zig");
const learning = @import("learning.zig");
const error_descriptions = @import("error_descriptions.zig");
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
pub fn interruptPoint(self: *Brain, observations: *std.ArrayList(u8)) !?interrupt_mod.Stimulus {
    if (try serviceDueMaintenanceInterrupt(self, observations)) return null;
    const source = self.deps.interrupt_source orelse return null;
    const stimulus = (try source.poll(self.allocator)) orelse return null;
    const line = try std.fmt.allocPrint(self.allocator, "interrupt_stimulus: {s}\n", .{@tagName(stimulus.kind)});
    try observations.appendSlice(self.allocator, line);
    try self.recordExperienceLogEvent(.{
        .kind = .autonomy,
        .source = "interrupt",
        .title = "interrupt_stimulus",
        .body = line,
        .subject = @tagName(stimulus.kind),
        .raw = @tagName(stimulus.kind),
        .interpretation = line,
        .developer_log_kind = "state",
        .developer_log_title = "interrupt",
        .developer_log_body = line,
        .tags = @constCast(&[_][]const u8{ "interrupt", @tagName(stimulus.kind), "audit" }),
    });
    return stimulus;
}

pub fn serviceDueMaintenanceInterrupt(self: *Brain, observations: *std.ArrayList(u8)) !bool {
    const io = self.deps.io orelse return false;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const tasks = try maintenance.dueTasks(self.allocator, fs, io, self.cfg.maintenance_schedule_path, self.cfg.maintenance_state_path, self.now_seconds);
    if (tasks.len == 0) return false;
    const task = tasks[0];
    const speech_intent = brain_dream_memory.maintenanceSpeechText(task.capability_spec);
    const line = if (speech_intent) |intent|
        try std.fmt.allocPrint(self.allocator, "timer_fired:\n- intent: {s}\n- note: scheduled wait ended during action batch; reconsider before continuing.\n", .{intent})
    else
        try std.fmt.allocPrint(self.allocator, "interrupt_reminder: {s}\n", .{task.capability_spec});
    try observations.appendSlice(self.allocator, line);
    try self.recordExperienceLogEvent(.{
        .kind = .reminder,
        .source = "maintenance",
        .title = if (speech_intent != null) "timer_fired" else "interrupt_reminder",
        .body = line,
        .action = task.capability_spec,
        .subject = task.task_id,
        .raw = task.capability_spec,
        .interpretation = line,
        .developer_log_kind = "state",
        .developer_log_title = "interrupt",
        .developer_log_body = line,
        .tags = @constCast(&[_][]const u8{ "interrupt", "reminder", "audit" }),
    });
    if (speech_intent == null) {
        try self.runMaintenanceCapability(task.capability_spec);
    }
    try maintenance.markRun(self.allocator, fs, io, self.cfg.maintenance_state_path, task.task_id, self.now_seconds);
    return true;
}

pub fn handleInterruptStimulus(self: *Brain, stimulus: interrupt_mod.Stimulus) anyerror!void {
    switch (stimulus.kind) {
        .face_memory => _ = try self.handleFaceMemoryActivation(),
        .held_input => try self.handleHoldActivation(),
        .conversation => try self.handleConversationTurn(),
    }
}

pub fn executeActionProposals(self: *Brain, proposals: []chat_mod.ActionProposal, observations: *std.ArrayList(u8)) !ActionPressureBatchResult {
    const PressuredProposal = struct {
        index: usize,
        proposal: chat_mod.ActionProposal,
        pressure: schema.ActionPressure,
        policy_suppression: ?[]const u8 = null,
    };

    self.traceCount("action_pressures.batch.start", proposals.len);
    var spoken_text: ?[]const u8 = null;
    if (proposals.len == 0) {
        self.trace("action_pressures.batch.done");
        return .{ .spoken_text = spoken_text, .ended_with_speech = false };
    }
    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode != .waking) {
        const payload = try std.fmt.allocPrint(self.allocator, "mode={s}\nproposal_count={d}", .{ @tagName(brain_mode), proposals.len });
        _ = try self.recordSimpleExperienceEvent(experience_kinds.action_selection_blocked, .system, payload);
        const line = try std.fmt.allocPrint(self.allocator, "action_blocked: brain_mode={s}\n", .{@tagName(brain_mode)});
        try observations.appendSlice(self.allocator, line);
        self.trace("action_pressures.batch.blocked_by_brain_mode");
        return .{ .spoken_text = spoken_text, .ended_with_speech = false };
    }

    var pressured = std.ArrayList(PressuredProposal).empty;
    for (proposals, 0..) |proposal, proposal_index| {
        const capability_input = try self.formatActionPressure(proposal);
        const causal_parents: []const []const u8 = if (self.current_turn_event_id) |turn_id|
            &[_][]const u8{turn_id}
        else
            &.{};
        const action_pressure = try self.proposeActionPressure(
            "LanguageMind",
            @tagName(proposal.action),
            capability_registry.capabilityIdForAction(proposal.action),
            capability_input,
            languageActionPressureStrength(proposal),
            languageActionPressureUrgency(proposal),
            languageActionPressureRisk(proposal),
            causal_parents,
        );
        try pressured.append(self.allocator, .{
            .index = proposal_index,
            .proposal = proposal,
            .pressure = action_pressure,
            .policy_suppression = try shouldSuppressIdentityRiskAction(self, proposal),
        });
    }
    var governor_state = maintenance.AutonomyState{
        .sleeping = false,
        .control_capacity = if (std.mem.eql(u8, self.cfg.autonomy_mode, "limited")) self.cfg.autonomy_limited_max_capacity else self.cfg.autonomy_full_max_capacity,
        .max_capacity = if (std.mem.eql(u8, self.cfg.autonomy_mode, "limited")) self.cfg.autonomy_limited_max_capacity else self.cfg.autonomy_full_max_capacity,
    };
    var persisted_state = false;
    if (self.deps.io != null and self.deps.filesystem != null) {
        governor_state = try maintenance.loadAutonomyState(
            self.allocator,
            self.deps.filesystem.?,
            self.deps.io.?,
            self.cfg.maintenance_state_path,
            self.defaultAutonomySleeping(),
            self.cfg.autonomy_mode,
            .{
                .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
                .full_max_capacity = self.cfg.autonomy_full_max_capacity,
            },
        );
        persisted_state = true;
    }
    const governor_proposals = try self.allocator.alloc(chat_mod.ActionProposal, pressured.items.len);
    const governor_pressures = try self.allocator.alloc(schema.ActionPressure, pressured.items.len);
    defer self.allocator.free(governor_proposals);
    defer self.allocator.free(governor_pressures);
    for (pressured.items, 0..) |item, i| {
        governor_proposals[i] = item.proposal;
        governor_pressures[i] = item.pressure;
    }
    const evaluated = try autonomy_governor.evaluateBatch(self.allocator, governor_proposals, governor_pressures, governor_state, .{
        .autonomy_mode = self.cfg.autonomy_mode,
        .limited_threshold_bias = self.cfg.autonomy_limited_threshold_bias,
        .full_threshold_bias = self.cfg.autonomy_full_threshold_bias,
        .social_reserve = self.cfg.autonomy_social_reserve,
        .safety_reserve = self.cfg.autonomy_safety_reserve,
        .opportunity_reserve = self.cfg.autonomy_opportunity_reserve,
        .quiet_hours_active = if (std.mem.eql(u8, self.cfg.autonomy_mode, "limited") and self.deps.io != null) brain_autonomy.inQuietHours(self, self.deps.io.?) catch false else false,
    });
    defer self.allocator.free(evaluated);

    var selected_primary_action: ?chat_mod.ActionProposalType = null;
    var executed_any = false;
    var ended_with_speech = false;
    for (pressured.items, 0..) |item, index| {
        const verdict = evaluated[index];
        if (item.policy_suppression != null or !verdict.passed) {
            const reason = item.policy_suppression orelse (verdict.suppressed_reason orelse "below governor threshold");
            const line = try std.fmt.allocPrint(self.allocator, "action_suppressed: {s}: {s}\n", .{ skills_mod.name(item.proposal.action), reason });
            try observations.appendSlice(self.allocator, line);
            _ = try self.suppressActionPressure(item.pressure, reason);
            self.traceActionPressure("action_pressures.action.suppressed", item.index, item.proposal.action);
        }
    }

    for (pressured.items, 0..) |item, index| {
        const verdict = evaluated[index];
        if (item.policy_suppression != null or !verdict.passed) continue;
        const proposal = verdict.proposal;
        if (proposal.origin == .autonomy and !maintenance.autonomyBudgetAvailable(governor_state)) {
            const line = try std.fmt.allocPrint(self.allocator, "action_suppressed: {s}: autonomy overdrawn\n", .{skills_mod.name(proposal.action)});
            try observations.appendSlice(self.allocator, line);
            _ = try self.suppressActionPressure(item.pressure, "autonomy overdrawn");
            self.traceActionPressure("action_pressures.action.suppressed", item.index, proposal.action);
            continue;
        }
        if (proposal.delay_ms) |delay| {
            try scheduleProposalDelay(self, observations, proposal, item.pressure, delay);
        }
        if (selected_primary_action == null) selected_primary_action = proposal.action;
        self.traceActionPressure("action_pressures.action.start", item.index, proposal.action);
        _ = try self.selectActionPressure(item.pressure);
        try self.logCapabilityRequested(proposal);
        const capability_input = item.pressure.rationale;
        const capability_request = try self.recordCapabilityRequest(
            capability_registry.capabilityIdForAction(proposal.action),
            capability_input,
            item.pressure.causal_parent_ids,
        );
        var capability_finished = false;
        errdefer |err| {
            if (error_descriptions.isDeferredControlFlow(err)) {
                self.traceActionPressureDeferred("action_pressures.action.awaiting_host_sense", item.index, proposal.action, err);
            } else {
                self.traceActionPressureError("action_pressures.action.error", item.index, proposal.action, err);
                if (!capability_finished) {
                    _ = self.recordCapabilityResult(capability_request, .failed, "", error_descriptions.detail(err)) catch {};
                }
                recordSkillFailure(self, proposal, observations, err) catch {};
                rememberHardActionError(self, proposal, err) catch {};
            }
        }
        if (try self.actionUnavailableReason(proposal.action)) |reason| {
            const hint = skills_mod.failureHint(proposal.action);
            const line = if (hint.len > 0)
                try std.fmt.allocPrint(self.allocator, "skill_failed: {s}: unavailable: {s}\nresolution: {s}\n", .{ skills_mod.name(proposal.action), reason, hint })
            else
                try std.fmt.allocPrint(self.allocator, "skill_failed: {s}: unavailable: {s}\n", .{ skills_mod.name(proposal.action), reason });
            try observations.appendSlice(self.allocator, line);
            try self.logCapabilityResult(proposal, line);
            _ = try self.recordCapabilityResult(capability_request, .unavailable, "", reason);
            capability_finished = true;
            self.traceActionPressure("action_pressures.action.unavailable", item.index, proposal.action);
            if (try interruptPoint(self, observations)) |stimulus| {
                return .{
                    .spoken_text = spoken_text,
                    .ended_with_speech = ended_with_speech,
                    .interrupted_by = stimulus,
                    .selected_primary_action = selected_primary_action,
                };
            }
            continue;
        }
        const observation_start_len = observations.items.len;
        const flow = try capability_execution.executeCapabilityAction(self, proposal, item.index, observations, &spoken_text, interruptPoint);
        switch (flow) {
            .ok, .next_action => {},
            .interrupt => |stimulus| return .{
                .spoken_text = spoken_text,
                .ended_with_speech = ended_with_speech,
                .interrupted_by = stimulus,
                .selected_primary_action = selected_primary_action,
            },
        }
        const capability_output = if (observations.items.len > observation_start_len)
            observations.items[observation_start_len..]
        else if (proposal.text) |text|
            text
        else
            @tagName(proposal.action);
        if (!capability_finished) {
            _ = try self.recordCapabilityResult(capability_request, .completed, capability_output, "");
            capability_finished = true;
        }
        executed_any = true;
        autonomy_governor.applyExecutedProposal(&governor_state, verdict);
        if (proposal.action == .say) ended_with_speech = true;
        if (proposal.action == .facial_expression and proposal.origin == .autonomy) self.last_autonomous_facial_expression_at = self.now_seconds;
        self.traceActionPressure("action_pressures.action.done", item.index, proposal.action);
        if (try interruptPoint(self, observations)) |stimulus| {
            return .{
                .spoken_text = spoken_text,
                .ended_with_speech = ended_with_speech,
                .interrupted_by = stimulus,
                .selected_primary_action = selected_primary_action,
            };
        }
    }

    if (executed_any and persisted_state) {
        if (self.deps.io == null or self.deps.filesystem == null) return error.MissingAutonomyStateDependencies;
        try maintenance.saveAutonomyState(self.allocator, self.deps.filesystem.?, self.deps.io.?, self.cfg.maintenance_state_path, governor_state);
    }

    if (!executed_any) {
        self.trace("action_pressures.batch.done");
        return .{ .spoken_text = spoken_text, .ended_with_speech = false };
    }

    self.trace("action_pressures.batch.done");
    return .{
        .spoken_text = spoken_text,
        .ended_with_speech = ended_with_speech,
        .selected_primary_action = selected_primary_action,
    };
}

/// Legacy direct-call executor retained only for runtime executor actors.
/// Conversation/autonomy orchestration should route through BrainRuntime.
pub fn executeActionProposalsDirect(self: *Brain, proposals: []chat_mod.ActionProposal, observations: *std.ArrayList(u8)) !ActionPressureBatchResult {
    return executeActionProposals(self, proposals, observations);
}

pub fn recordSkillFailure(self: *Brain, proposal: chat_mod.ActionProposal, observations: *std.ArrayList(u8), err: anyerror) !void {
    const hint = skills_mod.failureHint(proposal.action);
    const line = if (hint.len > 0)
        try std.fmt.allocPrint(self.allocator, "skill_failed: {s}: {s}: {s}\nresolution: {s}\n", .{ skills_mod.name(proposal.action), error_descriptions.name(err), error_descriptions.detail(err), hint })
    else
        try std.fmt.allocPrint(self.allocator, "skill_failed: {s}: {s}: {s}\n", .{ skills_mod.name(proposal.action), error_descriptions.name(err), error_descriptions.detail(err) });
    try observations.appendSlice(self.allocator, line);
    try self.logCapabilityResult(proposal, line);
}

pub fn rememberHardActionError(self: *Brain, proposal: chat_mod.ActionProposal, err: anyerror) !void {
    self.pending_hard_error = .{
        .action_pressure = try self.formatActionPressure(proposal),
        .error_name = try self.allocator.dupe(u8, @errorName(err)),
        .recovery_hint = try self.allocator.dupe(u8, skills_mod.failureHint(proposal.action)),
    };
}

pub fn appendPendingHardErrorObservation(self: *Brain, observations: *std.ArrayList(u8)) !void {
    const pending = self.pending_hard_error orelse return;
    const hint_line = if (pending.recovery_hint.len > 0)
        try std.fmt.allocPrint(self.allocator, "- resolution: {s}\n", .{pending.recovery_hint})
    else
        "";
    const line = try std.fmt.allocPrint(
        self.allocator,
        "pending_hard_error:\n- error: {s}\n- failed_action_pressure:\n{s}{s}- recovery_context: Treat this as a surprising, concerning event. The user may say to try again, change course, or nevermind; follow that direction using the normal available skills.\n",
        .{ pending.error_name, pending.action_pressure, hint_line },
    );
    try observations.appendSlice(self.allocator, line);
}

pub fn handleHardActionError(self: *Brain, err: anyerror) ![]const u8 {
    const detail = try error_descriptions.formatFailureDetail(self.allocator, err, self.chatParseFailureBody());
    defer self.allocator.free(detail);
    const text = try std.fmt.allocPrint(
        self.allocator,
        "Something went wrong while I tried that ({s}): {s} That is a hard error, and I do not want to pretend it worked. Tell me if I should try again, change course, or drop it.",
        .{ error_descriptions.name(err), detail },
    );
    self.outputBrain(text);
    try self.say(text);
    try self.appendEventLog("error", "Hard error needs recovery", text);
    return text;
}

fn languageActionPressureStrength(proposal: chat_mod.ActionProposal) f32 {
    return switch (proposal.action) {
        .say => 0.78,
        .recognize, .remember_person, .update_face_picture => 0.72,
        .send_email => 0.60,
        .unknown => 0.20,
        else => 0.64,
    };
}

fn languageActionPressureUrgency(proposal: chat_mod.ActionProposal) f32 {
    return switch (proposal.action) {
        .say => 0.70,
        .take_picture, .request_orientation => 0.62,
        .schedule_reminder, .send_email => 0.55,
        .unknown => 0.10,
        else => 0.45,
    };
}

fn languageActionPressureRisk(proposal: chat_mod.ActionProposal) f32 {
    return switch (proposal.action) {
        .send_email => 0.80,
        .remember_person, .update_face_picture, .recognize => 0.58,
        .take_picture, .request_orientation => 0.52,
        .forget_memory, .forget_person, .invalidate_fact => 0.50,
        .unknown => 0.90,
        else => 0.20,
    };
}

pub fn actionIsCallable(self: *Brain, action: chat_mod.ActionProposalType) !bool {
    return (try self.actionUnavailableReason(action)) == null;
}

pub fn actionProposalsEndWithSpeech(proposals: []const chat_mod.ActionProposal) bool {
    if (proposals.len == 0) return false;
    return proposals[proposals.len - 1].action == .say;
}

fn shouldSuppressIdentityRiskAction(self: *Brain, proposal: chat_mod.ActionProposal) !?[]const u8 {
    const faculty = switch (proposal.action) {
        .recognize => "recognition",
        .remember_person => "recognition",
        .say => if (proposal.name != null or proposal.person_id != null) "recognition" else return null,
        else => return null,
    };
    const trust = try learning.selfTrustForFaculty(self, faculty, "recognition uncertainty or user correction");
    if (trust >= learning.identity_risk_trust_threshold) return null;
    return try std.fmt.allocPrint(
        self.allocator,
        "self-trust for {s} is {d:.2} (below {d:.2}); acting certain would be risky",
        .{ faculty, trust, learning.identity_risk_trust_threshold },
    );
}

fn scheduleProposalDelay(
    self: *Brain,
    observations: *std.ArrayList(u8),
    proposal: chat_mod.ActionProposal,
    pressure: schema.ActionPressure,
    delay_ms: u32,
) !void {
    const EventContext = struct {
        allocator: std.mem.Allocator,
        observations: *std.ArrayList(u8),
    };
    const SleepContext = struct {
        io: std.Io,
    };
    const EventHarness = struct {
        fn emit(ctx: *anyopaque, event_kind: []const u8, payload_json: []const u8) !void {
            const state: *EventContext = @ptrCast(@alignCast(ctx));
            const line = try std.fmt.allocPrint(state.allocator, "event: {s} {s}\n", .{ event_kind, payload_json });
            defer state.allocator.free(line);
            try state.observations.appendSlice(state.allocator, line);
        }
    };
    const SleepHarness = struct {
        fn sleep(ctx: *anyopaque, wait_ms: u32) !void {
            const state: *SleepContext = @ptrCast(@alignCast(ctx));
            try std.Io.sleep(state.io, std.Io.Duration.fromMilliseconds(@intCast(wait_ms)), .awake);
        }
    };

    const io = self.deps.io orelse return error.MissingIoForScheduledAction;
    var event_context = EventContext{
        .allocator = self.allocator,
        .observations = observations,
    };
    var sleep_context = SleepContext{ .io = io };
    const actor = scheduler_actor.SchedulerActor.init(
        self.allocator,
        .{ .ctx = &event_context, .emitFn = EventHarness.emit },
        .{ .ctx = &sleep_context, .sleepMsFn = SleepHarness.sleep },
    );
    const body_text = proposal.text orelse proposal.query orelse proposal.name orelse @tagName(proposal.action);
    try actor.schedule(.{
        .proposal_id = pressure.pressure_id,
        .kind = @tagName(proposal.action),
        .strength = pressure.strength,
        .urgency = pressure.urgency,
        .expected_value = actor_payloads.expectedValue(pressure.strength, pressure.urgency, pressure.risk),
        .risk = pressure.risk,
        .alternatives = .{
            .full = body_text,
            .short = actor_payloads.boundedSlice(body_text, 96),
            .tiny = actor_payloads.boundedSlice(body_text, 32),
            .noop = "noop",
        },
    }, delay_ms);
}
