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
pub fn setSendEnabled(self: *Brain, enabled: bool) !void {
    if (self.deps.command_log) |log| try log.setSendEnabled(enabled);
}

pub fn logUserUtterance(self: *Brain, title: []const u8, text: []const u8) !void {
    try appendCommandLog(self, "user", title, text);
}

pub fn logCommandSent(self: *Brain, command: chat_mod.ChatCommand) !void {
    const body = try formatCommand(self, command);
    try recordRuntimeEvent(self, .{
        .kind = .command_sent,
        .title = @tagName(command.command),
        .body = body,
        .command = @tagName(command.command),
        .raw = body,
        .developer_log_kind = "sent",
        .developer_log_title = @tagName(command.command),
        .developer_log_body = body,
        .tags = @constCast(&[_][]const u8{ "command", @tagName(command.command) }),
    });
}

pub fn logCommandResult(self: *Brain, command: chat_mod.ChatCommand, result: []const u8) !void {
    const formatted_command = try formatCommand(self, command);
    try recordRuntimeEvent(self, .{
        .kind = .command_result,
        .title = @tagName(command.command),
        .body = result,
        .command = @tagName(command.command),
        .subject = @tagName(command.command),
        .raw = formatted_command,
        .interpretation = result,
        .developer_log_kind = "result",
        .developer_log_title = @tagName(command.command),
        .developer_log_body = result,
        .tags = @constCast(&[_][]const u8{ "command", @tagName(command.command) }),
    });
    const event_text = try std.fmt.allocPrint(self.allocator, "command={s}\nresult:\n{s}", .{ @tagName(command.command), result });
    _ = try self.detectWantAchievements(event_text);
}

pub fn logMaintenanceCommandSent(self: *Brain, command: []const u8) !void {
    try recordRuntimeEvent(self, .{
        .kind = .command_sent,
        .source = "maintenance",
        .title = "maintenance",
        .body = command,
        .command = command,
        .raw = command,
        .developer_log_kind = "sent",
        .developer_log_title = "maintenance",
        .developer_log_body = command,
        .tags = @constCast(&[_][]const u8{"maintenance"}),
    });
}

pub fn logMaintenanceCommandResult(self: *Brain, command: []const u8, result: []const u8) !void {
    const body = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ command, result });
    try recordRuntimeEvent(self, .{
        .kind = .command_result,
        .source = "maintenance",
        .title = "maintenance",
        .body = body,
        .command = command,
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
    state_mod.printState(state);
    const body = try std.fmt.allocPrint(self.allocator, "BRAIN STATE: {s}", .{@tagName(state)});
    try appendCommandLog(self, "state", @tagName(state), body);
}

pub fn trace(self: *Brain, stage: []const u8) void {
    self.last_trace_stage = stage;
    std.debug.print("TRACE now={d} stage={s}\n", .{ self.now_seconds, stage });
}

pub fn traceError(self: *Brain, stage: []const u8, err: anyerror) void {
    std.debug.print("TRACE now={d} stage={s} error={s}\n", .{ self.now_seconds, stage, @errorName(err) });
}

pub fn traceText(self: *Brain, stage: []const u8, text: []const u8) void {
    std.debug.print("TRACE now={d} stage={s} bytes={d}", .{ self.now_seconds, stage, text.len });
    if (text.len > 0) std.debug.print(" preview=\"{s}\"", .{helpers.previewText(text)});
    std.debug.print("\n", .{});
}

pub fn traceCount(self: *Brain, stage: []const u8, count: usize) void {
    std.debug.print("TRACE now={d} stage={s} count={d}\n", .{ self.now_seconds, stage, count });
}

pub fn traceIntent(self: *Brain, stage: []const u8, action: intent_mod.IntentAction) void {
    std.debug.print("TRACE now={d} stage={s} action={s}\n", .{ self.now_seconds, stage, @tagName(action) });
}

pub fn traceTurn(self: *Brain, stage: []const u8, turn_index: usize, observation_bytes: usize) void {
    std.debug.print("TRACE now={d} stage={s} turn={d} observation_bytes={d}\n", .{ self.now_seconds, stage, turn_index, observation_bytes });
}

pub fn traceTurnCommands(self: *Brain, stage: []const u8, turn_index: usize, command_count: usize, conversation_done: bool) void {
    std.debug.print("TRACE now={d} stage={s} turn={d} commands={d} conversation_done={any}\n", .{ self.now_seconds, stage, turn_index, command_count, conversation_done });
}

pub fn traceCommandBatch(self: *Brain, stage: []const u8, turn_index: usize, batch: CommandBatchResult, observation_bytes: usize) void {
    std.debug.print(
        "TRACE now={d} stage={s} turn={d} spoken={any} ended_with_speech={any} interrupted={any} observation_bytes={d}\n",
        .{ self.now_seconds, stage, turn_index, batch.spoken_text != null, batch.ended_with_speech, batch.interrupted_by != null, observation_bytes },
    );
}

pub fn traceCommand(self: *Brain, stage: []const u8, command_index: usize, command: chat_mod.ChatCommandType) void {
    std.debug.print("TRACE now={d} stage={s} command_index={d} command={s}\n", .{ self.now_seconds, stage, command_index, @tagName(command) });
}

pub fn traceCommandError(self: *Brain, stage: []const u8, command_index: usize, command: chat_mod.ChatCommandType, err: anyerror) void {
    std.debug.print(
        "TRACE now={d} stage={s} command_index={d} command={s} error={s}\n",
        .{ self.now_seconds, stage, command_index, @tagName(command), @errorName(err) },
    );
}

pub fn appendCommandLog(self: *Brain, kind: []const u8, title: []const u8, body: []const u8) !void {
    try recordRuntimeEvent(self, .{
        .kind = .developer_log,
        .title = title,
        .body = body,
        .developer_log_kind = kind,
        .developer_log_title = title,
        .developer_log_body = body,
    });
}

pub fn recordRuntimeEvent(self: *Brain, event: schema.RuntimeEvent) anyerror!void {
    const now = try time_mod.nowTimestamp(self.allocator);
    const event_id = try std.fmt.allocPrint(self.allocator, "event_{d}_{s}_{d}_{d}", .{ self.now_seconds, @tagName(event.kind), event.title.len, event.body.len });
    const full_event: schema.RuntimeEvent = .{
        .event_id = event_id,
        .time = now,
        .kind = event.kind,
        .source = event.source,
        .title = event.title,
        .body = event.body,
        .command = event.command,
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
    const json_line = try std.json.Stringify.valueAlloc(self.allocator, full_event, .{ .whitespace = .minified });
    try self.deps.store.logEvent(json_line);
    try developerLogReader(self, full_event);
    try maintenanceReader(self, full_event);
    try superegoReader(self, full_event);
    try egoReader(self, full_event);
    try memoryFormationReader(self, full_event);
}

pub fn recordIdMonitorEvent(self: *Brain, event: schema.RuntimeEvent) !void {
    if (event.monitor_id == null) return error.MissingIdMonitorId;
    if (event.title.len == 0 or event.body.len == 0) return error.InvalidIdMonitorEvent;
    if (!try self.id_monitor_manager.shouldEmit(self.allocator, self.now_seconds, event, @intCast(self.cfg.id_monitor_external_restart_cooldown_seconds))) return;
    try recordRuntimeEvent(self, event);
}

pub fn recordIdMonitorCrashEvent(self: *Brain, monitor_id: []const u8, err: anyerror) !void {
    const body = try std.fmt.allocPrint(self.allocator, "Id monitor {s} failed: {s}", .{ monitor_id, @errorName(err) });
    try recordRuntimeEvent(self, .{
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
    event_kind: schema.RuntimeEventKind,
    event_source: []const u8,
    title: []const u8,
    body: []const u8,
    experience_source: schema.ExperienceSource,
    experience_kind: schema.ExperienceKind,
    retention: schema.ExperienceRetention,
    subject: []const u8,
    raw: []const u8,
    interpretation: []const u8,
    derived_memory_ids: []const []const u8,
    tags: []const []const u8,
) !void {
    try recordRuntimeEvent(self, .{
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

pub fn developerLogReader(self: *Brain, event: schema.RuntimeEvent) !void {
    if (event.developer_log_kind == null and event.monitor_id != null) {
        const severity = event.severity orelse .info;
        if (id_monitor.severityRank(severity) >= id_monitor.severityRank(helpers.idMonitorSeverityThreshold(self.cfg.id_monitor_severity_threshold))) {
            if (self.deps.command_log) |log| try log.append("id", event.title, event.body);
        }
        return;
    }
    const kind = event.developer_log_kind orelse return;
    const title = event.developer_log_title orelse event.title;
    const body = event.developer_log_body orelse event.body;
    if (self.deps.command_log) |log| try log.append(kind, title, body);
}

pub fn psycheEffectiveRank(self: *Brain, role: schema.RuntimePsycheRole, projection_title: []const u8, event: schema.RuntimeEvent, base_severity: schema.RuntimeEventSeverity) !u8 {
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

pub fn superegoReader(self: *Brain, event: schema.RuntimeEvent) anyerror!void {
    if (event.forgotten_memory_id) |memory_id| {
        if (try psycheEffectiveRank(self, .superego, "superego_memory_boundary", event, .notice) < id_monitor.severityRank(.notice)) return;
        const body = try std.fmt.allocPrint(self.allocator, "Memory {s} was forgotten. Keep this as audit-only and do not form recallable memory from the forgetting itself.", .{memory_id});
        try recordRuntimeEvent(self, .{
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
        "Superego noticed {s} severity event from {s} with effective significance {d}: {s}. Preserve restraint and do not let this event execute commands directly.",
        .{ @tagName(severity), event.source, effective_rank, event.body },
    );
    try recordRuntimeEvent(self, .{
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

pub fn egoReader(self: *Brain, event: schema.RuntimeEvent) anyerror!void {
    const severity = event.severity orelse .info;
    const base_severity: schema.RuntimeEventSeverity = if (event.attention_candidate and id_monitor.severityRank(severity) < id_monitor.severityRank(.warning)) .warning else severity;
    const effective_rank = try psycheEffectiveRank(self, .ego, "ego_attention_candidate", event, base_severity);
    if (effective_rank < id_monitor.severityRank(.warning)) return;
    const body = try std.fmt.allocPrint(
        self.allocator,
        "Ego marked attention candidate from {s} with effective significance {d}: {s}",
        .{ event.source, effective_rank, if (event.interpretation.len > 0) event.interpretation else event.body },
    );
    try recordRuntimeEvent(self, .{
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

pub fn maintenanceReader(self: *Brain, event: schema.RuntimeEvent) !void {
    _ = self;
    _ = event;
}

pub fn memoryFormationReader(self: *Brain, event: schema.RuntimeEvent) !void {
    if (event.experience_source) |source| {
        const kind = event.experience_kind orelse return;
        const retention = event.experience_retention orelse .raw_ephemeral;
        _ = try self.addExperience(source, kind, event.subject, event.raw, event.interpretation, retention, event.derived_memory_ids, event.tags);
        return;
    }
    if (event.kind != .command_result) return;
    if (std.mem.startsWith(u8, event.body, "skill_failed:")) return;
    if (std.mem.eql(u8, event.source, "maintenance")) {
        _ = try self.addExperience(.maintenance, .command_result, event.subject, event.raw, event.interpretation, .summarize, &.{}, event.tags);
        return;
    }
    const command = helpers.commandTypeFromName(event.command orelse return) orelse return;
    const policy = helpers.commandMemoryPolicy(command) orelse return;
    _ = try self.addExperience(policy.source, policy.kind, event.subject, event.raw, event.interpretation, policy.retention, &.{}, event.tags);
}

pub fn formatCommand(self: *Brain, command: chat_mod.ChatCommand) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "command=");
    try out.appendSlice(self.allocator, @tagName(command.command));
    try out.appendSlice(self.allocator, "\n");
    try appendOptionalCommandField(self, &out, "text", command.text);
    try appendOptionalCommandField(self, &out, "query", command.query);
    try appendOptionalCommandField(self, &out, "memory_id", command.memory_id);
    try appendOptionalCommandField(self, &out, "person_id", command.person_id);
    try appendOptionalCommandField(self, &out, "name", command.name);
    try appendOptionalCommandField(self, &out, "image_path", command.image_path);
    try appendOptionalCommandField(self, &out, "schedule", command.schedule);
    try appendOptionalCommandField(self, &out, "to", command.to);
    try appendOptionalCommandField(self, &out, "subject", command.subject);
    try appendOptionalCommandField(self, &out, "heat_bias", command.heat_bias);
    try appendOptionalCommandField(self, &out, "eyes", command.eyes);
    try appendOptionalCommandField(self, &out, "mouth", command.mouth);
    if (command.duration_ms) |duration_ms| try out.print(self.allocator, "duration_ms={d}\n", .{duration_ms});
    if (command.keep_existing) try out.appendSlice(self.allocator, "keep_existing=true\n");
    if (command.tags.len > 0) {
        try out.appendSlice(self.allocator, "tags=");
        for (command.tags, 0..) |tag, i| {
            if (i > 0) try out.appendSlice(self.allocator, ", ");
            try out.appendSlice(self.allocator, tag);
        }
        try out.appendSlice(self.allocator, "\n");
    }
    return out.toOwnedSlice(self.allocator);
}

pub fn appendOptionalCommandField(self: *Brain, out: *std.ArrayList(u8), name: []const u8, value: ?[]const u8) !void {
    const text = value orelse return;
    try out.appendSlice(self.allocator, name);
    try out.appendSlice(self.allocator, "=");
    try out.appendSlice(self.allocator, text);
    try out.appendSlice(self.allocator, "\n");
}
