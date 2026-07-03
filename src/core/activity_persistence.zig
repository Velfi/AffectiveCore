const std = @import("std");
const activity_mod = @import("activity.zig");
const schema = @import("port_schema.zig");
const input_mod = @import("port_input.zig");
const brain_mod = @import("brain.zig");
const host_capability_activation = @import("host_capability_activation.zig");

const Brain = brain_mod.Brain;
const Active = activity_mod.Active;

pub const PersistContext = struct {
    awaited_host_request_id: ?[]const u8 = null,
    awaited_host_sense: ?[]const u8 = null,
    awaited_host_purpose: ?[]const u8 = null,
    deferred_heard_speech_text: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
};

pub fn toRecord(allocator: std.mem.Allocator, active: Active, ctx: PersistContext) !schema.ActivityRecord {
    var timeline = try allocator.alloc(schema.ActivityTimelineEvent, active.timeline.len);
    for (active.timeline, 0..) |event, i| {
        timeline[i] = .{
            .at_ms = event.at_seconds * 1000,
            .kind = try allocator.dupe(u8, @tagName(event.kind)),
            .title = try allocator.dupe(u8, event.title),
            .body = try allocator.dupe(u8, event.body),
            .source_event_id = if (event.source_event_id) |id| try allocator.dupe(u8, id) else null,
        };
    }
    var candidates = try allocator.alloc(schema.ActivityCandidateAction, active.recent_candidate_actions.len);
    for (active.recent_candidate_actions, 0..) |candidate, i| {
        candidates[i] = .{
            .action = try allocator.dupe(u8, candidate.action),
            .rationale = try allocator.dupe(u8, candidate.rationale),
            .strength = candidate.strength,
        };
    }
    const checkpoint = if (active.checkpoint) |cp| blk: {
        break :blk schema.ActivityCheckpoint{
            .anchor_text = try allocator.dupe(u8, cp.anchor_text),
            .heard_speech_text = try allocator.dupe(u8, cp.heard_speech.text),
            .heard_speech_source = try allocator.dupe(u8, @tagName(cp.heard_speech.source)),
            .observations = try allocator.dupe(u8, cp.observations),
            .memory = try allocator.dupe(u8, cp.memory),
            .spoken_text = try allocator.dupe(u8, cp.spoken_text),
            .paused_at_ms = cp.paused_at_seconds * 1000,
        };
    } else null;
    return .{
        .id = try allocator.dupe(u8, active.id),
        .parent_id = if (active.parent_id) |parent| try allocator.dupe(u8, parent) else null,
        .kind = mapKindToSchema(active.kind),
        .kind_label = try allocator.dupe(u8, active.kind_label),
        .status = mapStatusToSchema(active.status),
        .goal = try allocator.dupe(u8, active.goal),
        .summary = try allocator.dupe(u8, active.summary),
        .started_at_ms = active.started_at_seconds * 1000,
        .updated_at_ms = active.updated_at_seconds * 1000,
        .paused_at_ms = if (active.paused_at_seconds) |seconds| seconds * 1000 else null,
        .completed_at_ms = if (active.completed_at_seconds) |seconds| seconds * 1000 else null,
        .originating_request_id = try allocator.dupe(u8, active.originating_request_id),
        .interpretation = try allocator.dupe(u8, active.state.interpretation),
        .focus_text = if (active.state.focus_text) |text| try allocator.dupe(u8, text) else null,
        .stimulus_text = if (active.state.stimulus_text) |text| try allocator.dupe(u8, text) else null,
        .last_spoken_text = if (active.state.last_spoken_text) |text| try allocator.dupe(u8, text) else null,
        .waiting_kind = if (active.state.waiting_kind) |kind| try allocator.dupe(u8, @tagName(kind)) else null,
        .waiting_intent = if (active.state.waiting_intent) |text| try allocator.dupe(u8, text) else null,
        .waiting_since_ms = if (active.state.waiting_since_seconds) |seconds| seconds * 1000 else null,
        .awaiting = if (active.awaiting) |awaiting| try allocator.dupe(u8, awaiting) else null,
        .timeline = timeline,
        .candidate_actions = candidates,
        .checkpoint = checkpoint,
        .awaited_host_request_id = if (ctx.awaited_host_request_id) |id| try allocator.dupe(u8, id) else null,
        .awaited_host_sense = if (ctx.awaited_host_sense) |sense| try allocator.dupe(u8, sense) else null,
        .awaited_host_purpose = if (ctx.awaited_host_purpose) |purpose| try allocator.dupe(u8, purpose) else null,
        .deferred_heard_speech_text = if (ctx.deferred_heard_speech_text) |text| try allocator.dupe(u8, text) else null,
        .close_reason = if (ctx.close_reason) |reason| try allocator.dupe(u8, reason) else null,
    };
}

pub fn fromRecord(allocator: std.mem.Allocator, record: schema.ActivityRecord) !Active {
    var timeline = try allocator.alloc(activity_mod.TimelineEvent, record.timeline.len);
    for (record.timeline, 0..) |event, i| {
        timeline[i] = .{
            .at_seconds = @divFloor(event.at_ms, 1000),
            .kind = parseTimelineKind(event.kind),
            .title = try allocator.dupe(u8, event.title),
            .body = try allocator.dupe(u8, event.body),
            .source_event_id = if (event.source_event_id) |id| try allocator.dupe(u8, id) else null,
        };
    }
    var candidates = try allocator.alloc(activity_mod.CandidateAction, record.candidate_actions.len);
    for (record.candidate_actions, 0..) |candidate, i| {
        candidates[i] = .{
            .action = try allocator.dupe(u8, candidate.action),
            .rationale = try allocator.dupe(u8, candidate.rationale),
            .strength = candidate.strength,
        };
    }
    const checkpoint = if (record.checkpoint) |cp| blk: {
        break :blk activity_mod.Checkpoint{
            .anchor_text = try allocator.dupe(u8, cp.anchor_text),
            .heard_speech = .{
                .text = try allocator.dupe(u8, cp.heard_speech_text),
                .source = parseHeardSpeechSource(cp.heard_speech_source),
            },
            .observations = try allocator.dupe(u8, cp.observations),
            .memory = try allocator.dupe(u8, cp.memory),
            .spoken_text = try allocator.dupe(u8, cp.spoken_text),
            .paused_at_seconds = @divFloor(cp.paused_at_ms, 1000),
        };
    } else null;
    return .{
        .id = try allocator.dupe(u8, record.id),
        .parent_id = if (record.parent_id) |parent| try allocator.dupe(u8, parent) else null,
        .kind = mapKindFromSchema(record.kind),
        .kind_label = try allocator.dupe(u8, record.kind_label),
        .status = mapStatusFromSchema(record.status),
        .goal = try allocator.dupe(u8, record.goal),
        .summary = try allocator.dupe(u8, record.summary),
        .started_at_seconds = @divFloor(record.started_at_ms, 1000),
        .updated_at_seconds = @divFloor(record.updated_at_ms, 1000),
        .paused_at_seconds = if (record.paused_at_ms) |ms| @divFloor(ms, 1000) else null,
        .completed_at_seconds = if (record.completed_at_ms) |ms| @divFloor(ms, 1000) else null,
        .originating_request_id = try allocator.dupe(u8, record.originating_request_id),
        .timeline = timeline,
        .state = .{
            .interpretation = try allocator.dupe(u8, record.interpretation),
            .focus_text = if (record.focus_text) |text| try allocator.dupe(u8, text) else null,
            .stimulus_text = if (record.stimulus_text) |text| try allocator.dupe(u8, text) else null,
            .last_spoken_text = if (record.last_spoken_text) |text| try allocator.dupe(u8, text) else null,
            .waiting_kind = if (record.waiting_kind) |kind| parseOpenLoopKind(kind) else null,
            .waiting_intent = if (record.waiting_intent) |text| try allocator.dupe(u8, text) else null,
            .waiting_since_seconds = if (record.waiting_since_ms) |ms| @divFloor(ms, 1000) else null,
        },
        .recent_candidate_actions = candidates,
        .awaiting = if (record.awaiting) |awaiting| try allocator.dupe(u8, awaiting) else null,
        .checkpoint = checkpoint,
    };
}

pub fn applyRecordContext(self: *Brain, record: schema.ActivityRecord) !void {
    if (record.focus_text) |focus_text| {
        self.current_focus = .{
            .text = try self.allocator.dupe(u8, focus_text),
            .source = .derived,
            .set_at = self.now_seconds,
            .base_attention = 0.55,
        };
    }
    if (record.stimulus_text) |stimulus_text| {
        try self.setOwnedCurrentStimulusContext(stimulus_text);
    }
    if (record.waiting_kind != null and record.waiting_intent != null and record.waiting_since_ms != null) {
        const kind = parseWaitingKind(record.waiting_kind.?);
        const since = @divFloor(record.waiting_since_ms.?, 1000);
        self.clearWaitingFor();
        self.waiting_for = .{
            .kind = kind,
            .intent = try self.allocator.dupe(u8, record.waiting_intent.?),
            .since = since,
        };
    }
    if (record.awaited_host_request_id) |request_id| {
        const sense = record.awaited_host_sense orelse return error.MissingAwaitedHostSense;
        const purpose = record.awaited_host_purpose orelse return error.MissingAwaitedHostPurpose;
        self.clearAwaitedHostRequest();
        if (host_capability_activation.hostSenseReportedUnavailable(self, sense)) {
            return restoreDeferredSpeech(self, record);
        }
        var bound_activity_id: ?[]const u8 = null;
        var bound_user_text: ?[]const u8 = null;
        var bound_goal: ?[]const u8 = null;
        if (self.active_activity) |activity| {
            bound_activity_id = try self.allocator.dupe(u8, activity.id);
            if (activity.kind == .conversation and activity.goal.len > 0) {
                bound_user_text = try self.allocator.dupe(u8, activity.goal);
            }
            bound_goal = try self.allocator.dupe(u8, activity.goal);
        }
        self.awaited_host_request = .{
            .request_id = try self.allocator.dupe(u8, request_id),
            .sense = try self.allocator.dupe(u8, sense),
            .purpose = try self.allocator.dupe(u8, purpose),
            .since_seconds = if (record.waiting_since_ms) |ms| @divFloor(ms, 1000) else self.now_seconds,
            .timeout_ms = (try host_capability_activation.resolvePullTimeoutMs(self, sense, purpose)).timeout_ms,
            .bound_activity_id = bound_activity_id,
            .bound_user_text = bound_user_text,
            .bound_goal = bound_goal,
        };
    } else if (record.awaiting) |awaiting| {
        if (std.mem.indexOf(u8, awaiting, "recognize") != null and std.mem.indexOf(u8, awaiting, "camera") != null) {
            self.setAwaitedHostRequest("camera", "recognize") catch |err| switch (err) {
                error.HostSenseUnavailable => {},
                else => return err,
            };
        }
    }
    return restoreDeferredSpeech(self, record);
}

fn restoreDeferredSpeech(self: *Brain, record: schema.ActivityRecord) !void {
    if (record.deferred_heard_speech_text) |text| {
        if (text.len > 0) {
            self.pending_deferred_heard_speech = try input_mod.HeardSpeech.typed(self.allocator, text);
        }
    }
}

fn mapKindToSchema(kind: activity_mod.Kind) schema.ActivityKind {
    return switch (kind) {
        .conversation => .conversation,
        .research => .research,
        .navigation => .navigation,
        .waiting => .waiting,
        .planning => .planning,
        .maintenance => .maintenance,
        .generic => .generic,
    };
}

fn mapKindFromSchema(kind: schema.ActivityKind) activity_mod.Kind {
    return switch (kind) {
        .conversation => .conversation,
        .research => .research,
        .navigation => .navigation,
        .waiting => .waiting,
        .planning => .planning,
        .maintenance => .maintenance,
        .generic => .generic,
    };
}

fn mapStatusToSchema(status: activity_mod.Status) schema.ActivityStatus {
    return switch (status) {
        .active => .active,
        .paused => .paused,
        .blocked => .blocked,
        .complete => .complete,
        .abandoned => .abandoned,
    };
}

fn mapStatusFromSchema(status: schema.ActivityStatus) activity_mod.Status {
    return switch (status) {
        .active => .active,
        .paused => .paused,
        .blocked => .blocked,
        .complete => .complete,
        .abandoned => .abandoned,
    };
}

fn parseTimelineKind(kind: []const u8) activity_mod.TimelineEventKind {
    inline for (@typeInfo(activity_mod.TimelineEventKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, kind, field.name)) return @field(activity_mod.TimelineEventKind, field.name);
    }
    return .observation;
}

fn parseOpenLoopKind(kind: []const u8) activity_mod.OpenLoopKind {
    inline for (@typeInfo(activity_mod.OpenLoopKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, kind, field.name)) return @field(activity_mod.OpenLoopKind, field.name);
    }
    return .host_sense;
}

fn parseWaitingKind(kind: []const u8) Brain.WaitingKind {
    inline for (@typeInfo(Brain.WaitingKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, kind, field.name)) return @field(Brain.WaitingKind, field.name);
    }
    return .host_sense;
}

fn parseHeardSpeechSource(source: []const u8) input_mod.HeardSpeechSource {
    inline for (@typeInfo(input_mod.HeardSpeechSource).@"enum".fields) |field| {
        if (std.mem.eql(u8, source, field.name)) return @field(input_mod.HeardSpeechSource, field.name);
    }
    return .typed_text;
}
