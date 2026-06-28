const std = @import("std");
const brain_mod = @import("brain.zig");
const memory_actors = @import("actors/memory/mod.zig");
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
const error_descriptions = @import("error_descriptions.zig");
const context_composition = @import("context_composition.zig");
const brain_context_stats = @import("brain_context_stats.zig");
const random_provider_client = @import("../api/random_provider_client.zig");

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
pub fn setSendEnabled(self: *Brain, enabled: bool) !void {
    if (self.deps.event_log) |log| try log.setSendEnabled(enabled);
}

pub fn logUserUtterance(self: *Brain, title: []const u8, text: []const u8) !void {
    try appendEventLog(self, "user", title, text);
}

pub fn logCapabilityRequested(self: *Brain, proposal: chat_mod.ActionProposal) !void {
    const body = try formatActionPressure(self, proposal);
    try recordExperienceLogEvent(self, .{
        .kind = .capability_requested,
        .title = @tagName(proposal.action),
        .body = body,
        .action = @tagName(proposal.action),
        .raw = body,
        .developer_log_kind = "sent",
        .developer_log_title = @tagName(proposal.action),
        .developer_log_body = body,
        .tags = @constCast(&[_][]const u8{ "capability", @tagName(proposal.action) }),
    });
}

pub fn logCapabilityResult(self: *Brain, proposal: chat_mod.ActionProposal, result: []const u8) !void {
    const formatted_action_pressure = try formatActionPressure(self, proposal);
    try recordExperienceLogEvent(self, .{
        .kind = .capability_result,
        .title = @tagName(proposal.action),
        .body = result,
        .action = @tagName(proposal.action),
        .subject = @tagName(proposal.action),
        .raw = formatted_action_pressure,
        .interpretation = result,
        .developer_log_kind = "result",
        .developer_log_title = @tagName(proposal.action),
        .developer_log_body = result,
        .tags = @constCast(&[_][]const u8{ "capability", @tagName(proposal.action) }),
    });
    const event_text = try std.fmt.allocPrint(self.allocator, "action={s}\nresult:\n{s}", .{ @tagName(proposal.action), result });
    _ = try self.detectWantAchievements(event_text);
}

pub fn logMaintenanceCapabilityRequested(self: *Brain, command: []const u8) !void {
    try recordExperienceLogEvent(self, .{
        .kind = .capability_requested,
        .source = "maintenance",
        .title = "maintenance",
        .body = command,
        .action = command,
        .raw = command,
        .developer_log_kind = "sent",
        .developer_log_title = "maintenance",
        .developer_log_body = command,
        .tags = @constCast(&[_][]const u8{"maintenance"}),
    });
}

pub fn logMaintenanceCapabilityResult(self: *Brain, command: []const u8, result: []const u8) !void {
    const body = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ command, result });
    try recordExperienceLogEvent(self, .{
        .kind = .capability_result,
        .source = "maintenance",
        .title = "maintenance",
        .body = body,
        .action = command,
        .subject = command,
        .raw = command,
        .interpretation = result,
        .developer_log_kind = "result",
        .developer_log_title = "maintenance",
        .developer_log_body = body,
        .tags = @constCast(&[_][]const u8{"maintenance"}),
    });
}

pub fn logState(self: *Brain, state: state_mod.BrainState) !void {
    self.outputFmt("\nBRAIN STATE: {s}\n", .{@tagName(state)});
    const body = try std.fmt.allocPrint(self.allocator, "BRAIN STATE: {s}", .{@tagName(state)});
    try appendEventLog(self, "state", @tagName(state), body);
}

pub fn trace(self: *Brain, stage: []const u8) void {
    self.last_trace_stage = stage;
    self.outputFmt("TRACE now={d} dispatch_id={s} stage={s}\n", .{ self.now_seconds, dispatchIdLabel(self), stage });
}

pub fn traceError(self: *Brain, stage: []const u8, err: anyerror) void {
    var buffer: [512]u8 = undefined;
    const formatted = error_descriptions.formatTraceError(buffer[0..], err, null) orelse error_descriptions.name(err);
    self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} {s}\n", .{ self.now_seconds, dispatchIdLabel(self), stage, formatted });
}

pub fn traceErrorWithHostDetail(self: *Brain, stage: []const u8, err: anyerror, host_detail: ?[]const u8) void {
    var buffer: [768]u8 = undefined;
    const formatted = error_descriptions.formatTraceError(buffer[0..], err, host_detail) orelse error_descriptions.name(err);
    self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} {s}\n", .{ self.now_seconds, dispatchIdLabel(self), stage, formatted });
}

pub fn traceText(self: *Brain, stage: []const u8, text: []const u8) void {
    if (text.len > 0) {
        self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} bytes={d} preview=\"{s}\"\n", .{ self.now_seconds, dispatchIdLabel(self), stage, text.len, helpers.previewText(text) });
    } else {
        self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} bytes={d}\n", .{ self.now_seconds, dispatchIdLabel(self), stage, text.len });
    }
}

pub fn traceCount(self: *Brain, stage: []const u8, count: usize) void {
    self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} count={d}\n", .{ self.now_seconds, dispatchIdLabel(self), stage, count });
}

pub fn ensureContextStatsLoaded(self: *Brain) !void {
    if (self.context_stats_loaded) return;
    if (self.deps.io) |io| {
        if (self.deps.filesystem) |fs| {
            if (self.cfg.context_stats_path.len > 0) {
                const loaded = try brain_context_stats.load(self.allocator, fs, io, self.cfg.context_stats_path);
                self.context_stats.deinit();
                self.context_stats = loaded;
            }
        }
    }
    self.context_stats_loaded = true;
}

pub fn maybeFlushContextStats(self: *Brain) !void {
    const io = self.deps.io orelse return;
    const fs = self.deps.filesystem orelse return;
    if (self.cfg.context_stats_path.len == 0) return;
    try brain_context_stats.maybeFlush(
        &self.context_stats,
        self.allocator,
        fs,
        io,
        self.cfg.context_stats_path,
    );
}

pub fn flushContextStatsIfDirty(self: *Brain) !void {
    try ensureContextStatsLoaded(self);
    const io = self.deps.io orelse return;
    const fs = self.deps.filesystem orelse return;
    if (self.cfg.context_stats_path.len == 0) return;
    try brain_context_stats.flushIfDirty(
        &self.context_stats,
        self.allocator,
        fs,
        io,
        self.cfg.context_stats_path,
    );
}

pub fn recordContextBudgetExceeded(self: *Brain) !void {
    try ensureContextStatsLoaded(self);
    brain_context_stats.recordBudgetExceeded(&self.context_stats, self.now_seconds);
    try maybeFlushContextStats(self);
}

pub fn recordProcessGoalComposition(
    self: *Brain,
    goal: []const u8,
    mode: []const u8,
    context_bytes: usize,
    step_count: usize,
) !void {
    try ensureContextStatsLoaded(self);
    try brain_context_stats.recordProcessGoalComposition(&self.context_stats, .{
        .goal = goal,
        .mode = mode,
        .context_bytes = context_bytes,
        .step_count = step_count,
    }, self.now_seconds);
    try maybeFlushContextStats(self);
}

pub fn traceContextComposition(self: *Brain, report: context_composition.ContextCompositionReport) !void {
    try ensureContextStatsLoaded(self);
    try brain_context_stats.recordComposition(&self.context_stats, report, self.now_seconds);
    try maybeFlushContextStats(self);
    const brain_ptr: *anyopaque = @ptrCast(self);
    const dispatch_id = self.current_dispatch_request_id orelse "(none)";
    context_composition.traceReportCtx(brain_ptr, self.now_seconds, dispatch_id, report, brainTraceAdapter, noopTraceWrite);
}

fn recordLlmCompletionCallback(ctx: *anyopaque, record: brain_context_stats.LlmCompletionRecord) void {
    const brain: *Brain = @ptrCast(@alignCast(ctx));
    brain.recordLlmCompletion(record) catch |err| {
        brain.traceError("llm_stats.record", err);
    };
}

pub fn llmStatsRecorder(self: *Brain) random_provider_client.LlmStatsRecorder {
    return .{
        .ctx = self,
        .record_fn = recordLlmCompletionCallback,
    };
}

pub fn wireLlmStatsRecorder(self: *Brain, clients: []const *random_provider_client.RandomProviderClient) void {
    const recorder = llmStatsRecorder(self);
    for (clients) |client| {
        client.stats_recorder = recorder;
    }
}

pub fn recordLlmCompletion(self: *Brain, record: brain_context_stats.LlmCompletionRecord) !void {
    try ensureContextStatsLoaded(self);
    try brain_context_stats.recordLlmCompletion(&self.context_stats, record, self.now_seconds);
    try maybeFlushContextStats(self);
}

fn noopTraceWrite(_: i64, _: []const u8) void {}

fn brainTraceAdapter(ctx: ?*anyopaque, _: i64, line: []const u8, _: *const fn (i64, []const u8) void) void {
    const brain: *Brain = @ptrCast(@alignCast(ctx.?));
    brain.outputFmt("{s}", .{line});
}

pub fn traceIntent(self: *Brain, stage: []const u8, action: intent_mod.IntentAction) void {
    self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} action={s}\n", .{ self.now_seconds, dispatchIdLabel(self), stage, @tagName(action) });
}

pub fn traceTurn(self: *Brain, stage: []const u8, turn_index: usize, observation_bytes: usize) void {
    self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} turn={d} observation_bytes={d}\n", .{ self.now_seconds, dispatchIdLabel(self), stage, turn_index, observation_bytes });
}

pub fn traceTurnActionPressures(self: *Brain, stage: []const u8, turn_index: usize, action_pressure_count: usize, turn_complete: bool) void {
    self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} turn={d} action_pressures={d} turn_complete={any}\n", .{ self.now_seconds, dispatchIdLabel(self), stage, turn_index, action_pressure_count, turn_complete });
}

pub fn traceActionPressureBatch(self: *Brain, stage: []const u8, turn_index: usize, batch: ActionPressureBatchResult, observation_bytes: usize) void {
    self.outputFmt(
        "TRACE now={d} dispatch_id={s} stage={s} turn={d} spoken={any} ended_with_speech={any} interrupted={any} observation_bytes={d}\n",
        .{ self.now_seconds, dispatchIdLabel(self), stage, turn_index, batch.spoken_text != null, batch.ended_with_speech, batch.interrupted_by != null, observation_bytes },
    );
}

pub fn traceActionPressure(self: *Brain, stage: []const u8, action_pressure_index: usize, action: chat_mod.ActionProposalType) void {
    self.outputFmt("TRACE now={d} dispatch_id={s} stage={s} action_pressure_index={d} action={s}\n", .{ self.now_seconds, dispatchIdLabel(self), stage, action_pressure_index, @tagName(action) });
}

pub fn traceActionPressureError(self: *Brain, stage: []const u8, action_pressure_index: usize, action: chat_mod.ActionProposalType, err: anyerror) void {
    var buffer: [512]u8 = undefined;
    const formatted = error_descriptions.formatTraceError(buffer[0..], err, null) orelse error_descriptions.name(err);
    self.outputFmt(
        "TRACE now={d} dispatch_id={s} stage={s} action_pressure_index={d} action={s} {s}\n",
        .{ self.now_seconds, dispatchIdLabel(self), stage, action_pressure_index, @tagName(action), formatted },
    );
}

pub fn traceActionPressureDeferred(self: *Brain, stage: []const u8, action_pressure_index: usize, action: chat_mod.ActionProposalType, err: anyerror) void {
    self.outputFmt(
        "TRACE now={d} dispatch_id={s} stage={s} action_pressure_index={d} action={s} signal={s} detail=\"{s}\"\n",
        .{ self.now_seconds, dispatchIdLabel(self), stage, action_pressure_index, @tagName(action), error_descriptions.name(err), error_descriptions.detail(err) },
    );
}

fn dispatchIdLabel(self: *Brain) []const u8 {
    return self.current_dispatch_request_id orelse "(none)";
}

pub fn output(self: *Brain, text: []const u8) void {
    const sink = self.deps.output orelse return;
    sink.write(text) catch {};
}

pub fn outputFmt(self: *Brain, comptime fmt: []const u8, args: anytype) void {
    const sink = self.deps.output orelse return;
    const text = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
    defer self.allocator.free(text);
    sink.write(text) catch {};
}

pub fn outputBrain(self: *Brain, text: []const u8) void {
    self.outputFmt("\nBRAIN:\n{s}\n", .{text});
}

pub fn outputImageCapture(self: *Brain, capture: events.ImageCapture) void {
    self.outputFmt("Image: {s}\n", .{capture.path});
}

pub fn outputRecognitionResult(self: *Brain, result: identity.IdentityResult) void {
    const status_detail = error_descriptions.recognitionStatusDetail(result.match_status, result.confidence, result.people_count);
    if (result.candidate_name) |candidate| {
        self.outputFmt(
            "Recognition: {s}, confidence={d:.2}, candidate={s}, people_count={d}, meaning=\"{s}\"\n",
            .{ @tagName(result.match_status), result.confidence, candidate, result.people_count, status_detail },
        );
    } else {
        self.outputFmt(
            "Recognition: {s}, confidence={d:.2}, people_count={d}, meaning=\"{s}\"\n",
            .{ @tagName(result.match_status), result.confidence, result.people_count, status_detail },
        );
    }
}

pub fn appendEventLog(self: *Brain, kind: []const u8, title: []const u8, body: []const u8) !void {
    try recordExperienceLogEvent(self, .{
        .kind = .developer_log,
        .title = title,
        .body = body,
        .developer_log_kind = kind,
        .developer_log_title = title,
        .developer_log_body = body,
    });
}

pub fn recordExperienceLogEvent(self: *Brain, event: schema.ExperienceLogEvent) anyerror!void {
    const now = try self.timestampNow();
    const existing_events = self.deps.store.loadExperienceEvents(self.allocator) catch &.{};
    const event_id = try std.fmt.allocPrint(self.allocator, "event_{d}_{d}_{s}_{d}_{d}", .{ self.now_seconds, existing_events.len, @tagName(event.kind), event.title.len, event.body.len });
    const full_event: schema.ExperienceLogEvent = .{
        .event_id = event_id,
        .time = now,
        .kind = event.kind,
        .source = event.source,
        .title = event.title,
        .body = event.body,
        .action = event.action,
        .subject = event.subject,
        .raw = event.raw,
        .interpretation = event.interpretation,
        .developer_log_kind = event.developer_log_kind,
        .developer_log_title = event.developer_log_title,
        .developer_log_body = event.developer_log_body,
        .experience_source = event.experience_source,
        .experience_kind = event.experience_kind,
        .experience_retention = event.experience_retention,
        .derived_memory_ids = event.derived_memory_ids,
        .created_memory_id = event.created_memory_id,
        .forgotten_memory_id = event.forgotten_memory_id,
        .created_fact_id = event.created_fact_id,
        .invalidated_fact_id = event.invalidated_fact_id,
        .severity = event.severity,
        .psyche_role = event.psyche_role,
        .monitor_id = event.monitor_id,
        .pattern_id = event.pattern_id,
        .confidence = event.confidence,
        .dedupe_key = event.dedupe_key,
        .attention_candidate = event.attention_candidate,
        .tags = event.tags,
    };
    try self.recordExperienceLogMirrorEvent(full_event);
    try developerLogReader(self, full_event);
    try maintenanceReader(self, full_event);
    try superegoReader(self, full_event);
    try egoReader(self, full_event);
    try memoryFormationReader(self, full_event);
}

pub fn recordIdMonitorEvent(self: *Brain, event: schema.ExperienceLogEvent) !void {
    if (event.monitor_id == null) return error.MissingIdMonitorId;
    if (event.title.len == 0 or event.body.len == 0) return error.InvalidIdMonitorEvent;
    if (!try self.id_monitor_manager.shouldEmit(self.allocator, self.now_seconds, event, @intCast(self.cfg.id_monitor_external_restart_cooldown_seconds))) return;
    try recordExperienceLogEvent(self, event);
}

pub fn recordIdMonitorCrashEvent(self: *Brain, monitor_id: []const u8, err: anyerror) !void {
    const body = try std.fmt.allocPrint(self.allocator, "Id monitor {s} failed: {s}", .{ monitor_id, @errorName(err) });
    try recordExperienceLogEvent(self, .{
        .kind = .system,
        .source = "id_monitor",
        .title = "id_monitor_crash",
        .body = body,
        .monitor_id = monitor_id,
        .severity = .warning,
        .tags = @constCast(&[_][]const u8{ "id", "monitor", "crash", "audit" }),
    });
}

pub fn recordMemoryCandidateEvent(
    self: *Brain,
    event_kind: schema.ExperienceLogKind,
    event_source: []const u8,
    title: []const u8,
    body: []const u8,
    experience_source: schema.MemoryExperienceSource,
    experience_kind: schema.MemoryExperienceKind,
    retention: schema.MemoryExperienceRetention,
    subject: []const u8,
    raw: []const u8,
    interpretation: []const u8,
    derived_memory_ids: []const []const u8,
    tags: []const []const u8,
) !void {
    try recordExperienceLogEvent(self, .{
        .kind = event_kind,
        .source = event_source,
        .title = title,
        .body = body,
        .subject = subject,
        .raw = raw,
        .interpretation = interpretation,
        .experience_source = experience_source,
        .experience_kind = experience_kind,
        .experience_retention = retention,
        .derived_memory_ids = @constCast(derived_memory_ids),
        .tags = @constCast(tags),
    });
}

pub fn developerLogReader(self: *Brain, event: schema.ExperienceLogEvent) !void {
    if (event.developer_log_kind == null and event.monitor_id != null) {
        const severity = event.severity orelse .info;
        if (id_monitor.severityRank(severity) >= id_monitor.severityRank(helpers.idMonitorExperienceLogSeverityThreshold(self.cfg.id_monitor_severity_threshold))) {
            if (self.deps.event_log) |log| try log.append("id", event.title, event.body);
        }
        return;
    }
    const kind = event.developer_log_kind orelse return;
    const title = event.developer_log_title orelse event.title;
    const body = event.developer_log_body orelse event.body;
    if (self.deps.event_log) |log| try log.append(kind, title, body);
}

pub fn psycheEffectiveRank(self: *Brain, role: schema.PsycheRole, projection_title: []const u8, event: schema.ExperienceLogEvent, base_severity: schema.ExperienceLogSeverity) !u8 {
    const subject = if (event.subject.len > 0) event.subject else if (event.pattern_id) |pattern_id| pattern_id else event.title;
    var key_buffer: [256]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buffer, "{s}|{s}|{s}|{s}|{s}", .{
        @tagName(role),
        helpers.psycheKeySlice(projection_title),
        helpers.psycheKeySlice(event.source),
        helpers.psycheKeySlice(event.title),
        helpers.psycheKeySlice(subject),
    });
    const count = self.psyche_habituation.observe(self.now_seconds, key);
    const base_rank = id_monitor.severityRank(base_severity);
    const attenuation: u8 = @intCast(@min(@as(u32, base_rank), count - 1));
    return base_rank - attenuation;
}

pub fn superegoReader(self: *Brain, event: schema.ExperienceLogEvent) anyerror!void {
    if (event.forgotten_memory_id) |memory_id| {
        if (try psycheEffectiveRank(self, .superego, "superego_memory_boundary", event, .notice) < id_monitor.severityRank(.notice)) return;
        const body = try std.fmt.allocPrint(self.allocator, "Memory {s} was forgotten. Keep this as audit-only and do not form recallable memory from the forgetting itself.", .{memory_id});
        try recordExperienceLogEvent(self, .{
            .kind = .psyche,
            .source = "superego",
            .title = "superego_memory_boundary",
            .body = body,
            .subject = memory_id,
            .raw = event.body,
            .interpretation = body,
            .severity = .notice,
            .psyche_role = .superego,
            .developer_log_kind = "superego",
            .developer_log_title = "Superego",
            .developer_log_body = body,
            .tags = @constCast(&[_][]const u8{ "psyche", "superego", "memory_boundary", "audit" }),
        });
        return;
    }
    const severity = event.severity orelse return;
    const effective_rank = try psycheEffectiveRank(self, .superego, "superego_concern", event, severity);
    if (effective_rank < id_monitor.severityRank(.warning)) return;
    const body = try std.fmt.allocPrint(
        self.allocator,
        "Superego noticed {s} severity event from {s} with effective significance {d}: {s}. Preserve restraint and do not let this event execute actions directly.",
        .{ @tagName(severity), event.source, effective_rank, event.body },
    );
    try recordExperienceLogEvent(self, .{
        .kind = .psyche,
        .source = "superego",
        .title = "superego_concern",
        .body = body,
        .subject = if (event.subject.len > 0) event.subject else event.title,
        .raw = event.body,
        .interpretation = body,
        .severity = severity,
        .psyche_role = .superego,
        .developer_log_kind = "superego",
        .developer_log_title = "Superego",
        .developer_log_body = body,
        .tags = @constCast(&[_][]const u8{ "psyche", "superego", "constraint", "audit" }),
    });
}

pub fn egoReader(self: *Brain, event: schema.ExperienceLogEvent) anyerror!void {
    const severity = event.severity orelse .info;
    const base_severity: schema.ExperienceLogSeverity = if (event.attention_candidate and id_monitor.severityRank(severity) < id_monitor.severityRank(.warning)) .warning else severity;
    const effective_rank = try psycheEffectiveRank(self, .ego, "ego_attention_candidate", event, base_severity);
    if (effective_rank < id_monitor.severityRank(.warning)) return;
    const body = try std.fmt.allocPrint(
        self.allocator,
        "Ego marked attention candidate from {s} with effective significance {d}: {s}",
        .{ event.source, effective_rank, if (event.interpretation.len > 0) event.interpretation else event.body },
    );
    try recordExperienceLogEvent(self, .{
        .kind = .psyche,
        .source = "ego",
        .title = "ego_attention_candidate",
        .body = body,
        .subject = if (event.subject.len > 0) event.subject else event.title,
        .raw = event.body,
        .interpretation = body,
        .severity = severity,
        .psyche_role = .ego,
        .attention_candidate = true,
        .developer_log_kind = "ego",
        .developer_log_title = "Ego",
        .developer_log_body = body,
        .tags = @constCast(&[_][]const u8{ "psyche", "ego", "attention", "audit" }),
    });
}

pub fn maintenanceReader(self: *Brain, event: schema.ExperienceLogEvent) !void {
    _ = self;
    _ = event;
}

pub fn memoryFormationReader(self: *Brain, event: schema.ExperienceLogEvent) !void {
    const parents: []const []const u8 = if (event.event_id.len > 0) &[_][]const u8{event.event_id} else &.{};
    if (event.experience_source) |source| {
        const kind = event.experience_kind orelse return;
        const retention = event.experience_retention orelse .raw_ephemeral;
        _ = try self.recordMemoryExperience(source, kind, event.subject, event.raw, event.interpretation, retention, event.derived_memory_ids, event.tags, parents);
        try maybeRecordMemoryCandidate(self, event, parents);
        return;
    }
    if (event.kind != .capability_result) return;
    if (std.mem.startsWith(u8, event.body, "skill_failed:")) return;
    if (std.mem.eql(u8, event.source, "maintenance")) {
        _ = try self.recordMemoryExperience(.maintenance, .capability_result, event.subject, event.raw, event.interpretation, .summarize, &.{}, event.tags, parents);
        try maybeRecordMemoryCandidate(self, event, parents);
        return;
    }
    const action = helpers.actionTypeFromName(event.action orelse return) orelse return;
    const policy = helpers.actionMemoryPolicy(action) orelse return;
    _ = try self.recordMemoryExperience(policy.source, policy.kind, event.subject, event.raw, event.interpretation, policy.retention, &.{}, event.tags, parents);
    try maybeRecordMemoryCandidate(self, event, parents);
}

fn maybeRecordMemoryCandidate(
    self: *Brain,
    event: schema.ExperienceLogEvent,
    parents: []const []const u8,
) !void {
    var actor_context: memory_actors.context.ActorContext = .{
        .allocator = self.allocator,
        .store = self.deps.store,
        .now_seconds = self.now_seconds,
        .brain_id = self.cfg.brain_id,
        .host_id = self.currentHostId(),
    };
    const candidate = (try memory_actors.MemoryCandidateActor.candidateFromExperienceLog(&actor_context, event, parents)) orelse return;
    const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
        .candidate_id = candidate.candidate_id,
        .key = candidate.key,
        .proposition = candidate.proposition,
        .evidence = candidate.evidence,
        .kind = @tagName(candidate.kind),
        .confidence = candidate.confidence,
        .salience = candidate.salience,
        .tags = candidate.tags,
    }, .{ .whitespace = .minified });
    _ = try actor_context.makeExperienceEvent(.memory, "memory.candidate", payload, parents, .episode);
    try self.publishRuntimeMemoryCandidate(payload, "memory_formation_reader");
}

pub fn formatActionPressure(self: *Brain, proposal: chat_mod.ActionProposal) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "action=");
    try out.appendSlice(self.allocator, @tagName(proposal.action));
    try out.appendSlice(self.allocator, "\n");
    try appendOptionalActionField(self, &out, "text", proposal.text);
    try appendOptionalActionField(self, &out, "query", proposal.query);
    try appendOptionalActionField(self, &out, "memory_id", proposal.memory_id);
    try appendOptionalActionField(self, &out, "person_id", proposal.person_id);
    try appendOptionalActionField(self, &out, "name", proposal.name);
    try appendOptionalActionField(self, &out, "image_path", proposal.image_path);
    try appendOptionalActionField(self, &out, "schedule", proposal.schedule);
    try appendOptionalActionField(self, &out, "to", proposal.to);
    try appendOptionalActionField(self, &out, "subject", proposal.subject);
    try appendOptionalActionField(self, &out, "heat_bias", proposal.heat_bias);
    try appendOptionalActionField(self, &out, "eyes", proposal.eyes);
    try appendOptionalActionField(self, &out, "mouth", proposal.mouth);
    if (proposal.duration_ms) |duration_ms| try out.print(self.allocator, "duration_ms={d}\n", .{duration_ms});
    if (proposal.keep_existing) try out.appendSlice(self.allocator, "keep_existing=true\n");
    if (proposal.tags.len > 0) {
        try out.appendSlice(self.allocator, "tags=");
        for (proposal.tags, 0..) |tag, i| {
            if (i > 0) try out.appendSlice(self.allocator, ", ");
            try out.appendSlice(self.allocator, tag);
        }
        try out.appendSlice(self.allocator, "\n");
    }
    return out.toOwnedSlice(self.allocator);
}

pub fn appendOptionalActionField(self: *Brain, out: *std.ArrayList(u8), name: []const u8, value: ?[]const u8) !void {
    const text = value orelse return;
    try out.appendSlice(self.allocator, name);
    try out.appendSlice(self.allocator, "=");
    try out.appendSlice(self.allocator, text);
    try out.appendSlice(self.allocator, "\n");
}
