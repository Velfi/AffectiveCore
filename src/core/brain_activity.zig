const std = @import("std");
const brain_mod = @import("brain.zig");
const activity_mod = @import("activity.zig");
const activity_persistence = @import("activity_persistence.zig");
const input_mod = @import("port_input.zig");
const ports = @import("ports.zig");
const chat_mod = ports.chat;
const intent_mod = @import("port_intent.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;
const Active = activity_mod.Active;
const Checkpoint = activity_mod.Checkpoint;

pub const StimulusDispatch = struct {
    request_id: []const u8 = "",
};

pub const DerivedActivityLabels = struct {
    kind_label: []const u8,
    goal: []const u8,
};

pub const ActivityOrchestration = enum {
    user_speech,
    salient_sense,
    reminder,
};

const max_activity_label_len: usize = 120;
pub const ActivityStackOverflow = error.ActivityStackOverflow;

pub fn deriveActivityLabelsFromState(self: *Brain, anchor: []const u8) !DerivedActivityLabels {
    const kind_source = if (self.current_focus) |focus|
        focus.text
    else if (self.current_stimulus_context) |stimulus|
        stimulus
    else
        anchor;
    return .{
        .kind_label = try truncateLabel(self.allocator, kind_source, max_activity_label_len),
        .goal = try self.allocator.dupe(u8, anchor),
    };
}

pub fn inferActivityKind(self: *Brain, orchestration: ActivityOrchestration) activity_mod.Kind {
    if (self.active_activity) |active| return active.kind;
    return switch (orchestration) {
        .user_speech => .conversation,
        .reminder => .waiting,
        .salient_sense => if (self.waiting_for != null) .waiting else .generic,
    };
}

fn truncateLabel(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]const u8 {
    if (text.len <= max_len) return try allocator.dupe(u8, text);
    var end = max_len;
    while (end > 0 and (text[end] & 0b1100_0000) == 0b1000_0000) end -= 1;
    return try std.fmt.allocPrint(allocator, "{s}...", .{text[0..end]});
}

pub const PauseForHostSense = struct {
    kind_label: []const u8,
    goal: []const u8,
    awaiting: []const u8,
    originating_request_id: []const u8,
    anchor_text: []const u8,
    heard_speech: input_mod.HeardSpeech,
    memory: []const u8,
    observations: []const u8,
    spoken_text: []const u8,
};

pub fn activityAwaitingHost(self: *Brain) bool {
    const active = self.active_activity orelse return false;
    return active.status == .paused and active.checkpoint != null;
}

pub fn conversationAwaitingHost(self: *Brain) bool {
    return self.awaitedHostRequestActive();
}

pub fn activeActivityId(self: *Brain) ?[]const u8 {
    return if (self.active_activity) |active| active.id else null;
}

pub fn attachActivityFields(self: *Brain, result: brain_mod.ConversationTurnResult) !brain_mod.ConversationTurnResult {
    const dispatch_id = try duplicateDispatchId(self, result.dispatch_id);
    const awaited = try awaitedHostRequestOutcomeFields(self);
    const active = self.active_activity orelse return .{
        .user_text = result.user_text,
        .spoken_text = result.spoken_text,
        .user_summary = result.user_summary,
        .brain_summary = result.brain_summary,
        .dispatch_id = dispatch_id,
        .interrupted_by = result.interrupted_by,
        .awaiting_host_sense = self.awaitedHostRequestActive(),
        .awaited_host_sense = awaited.sense,
        .awaited_host_purpose = awaited.purpose,
        .awaited_host_timeout_ms = awaited.timeout_ms,
        .activity_id = result.activity_id,
        .activity_kind = result.activity_kind,
        .activity_kind_label = result.activity_kind_label,
        .activity_state = result.activity_state,
        .activity_goal = result.activity_goal,
        .activity_awaiting = result.activity_awaiting,
    };
    const awaiting_host = active.checkpoint != null;
    return .{
        .user_text = result.user_text,
        .spoken_text = result.spoken_text,
        .user_summary = result.user_summary,
        .brain_summary = result.brain_summary,
        .dispatch_id = dispatch_id,
        .interrupted_by = result.interrupted_by,
        .awaiting_host_sense = self.awaitedHostRequestActive(),
        .awaited_host_sense = awaited.sense,
        .awaited_host_purpose = awaited.purpose,
        .awaited_host_timeout_ms = awaited.timeout_ms,
        .activity_id = try self.allocator.dupe(u8, active.id),
        .activity_kind = try self.allocator.dupe(u8, @tagName(active.kind)),
        .activity_kind_label = try self.allocator.dupe(u8, active.kind_label),
        .activity_state = try self.allocator.dupe(u8, activity_mod.activityStateTag(active.status, awaiting_host)),
        .activity_goal = try self.allocator.dupe(u8, active.goal),
        .activity_awaiting = if (active.awaiting) |awaiting| try self.allocator.dupe(u8, awaiting) else null,
    };
}

fn awaitedHostRequestOutcomeFields(self: *Brain) !struct { sense: ?[]const u8, purpose: ?[]const u8, timeout_ms: ?u32 } {
    const req = self.awaited_host_request orelse return .{ .sense = null, .purpose = null, .timeout_ms = null };
    return .{
        .sense = try self.allocator.dupe(u8, req.sense),
        .purpose = try self.allocator.dupe(u8, req.purpose),
        .timeout_ms = req.timeout_ms,
    };
}

fn duplicateDispatchId(self: *Brain, existing: []const u8) ![]const u8 {
    if (existing.len > 0) return self.allocator.dupe(u8, existing);
    if (self.current_dispatch_request_id) |id| return self.allocator.dupe(u8, id);
    return self.allocator.dupe(u8, "");
}

pub fn ensureActiveActivity(
    self: *Brain,
    anchor: []const u8,
    originating_request_id: []const u8,
    orchestration: ActivityOrchestration,
) !void {
    if (orchestration == .user_speech and self.activity_stack.items.len > 0) {
        try collapseActivityStack(self, "user speech collapsed stale stack");
    }
    if (self.active_activity) |*active| {
        if (active.status == .paused and active.checkpoint == null) {
            active.status = .active;
            active.paused_at_seconds = null;
            const resumed_body = try self.allocator.dupe(u8, "Resumed after idle pause.");
            try pushTimelineEvent(self, active, self.now_seconds, .resumed, "resumed", resumed_body, null);
            self.allocator.free(resumed_body);
            active.updated_at_seconds = self.now_seconds;
            try persistActiveActivityToStore(self);
            return;
        }
        switch (orchestration) {
            .user_speech => {
                if (active.kind != .conversation) {
                    try replaceActivityGoal(self, anchor, "user speech superseded prior activity");
                }
                return;
            },
            .salient_sense, .reminder => try pushActiveOntoStack(self, @tagName(orchestration)),
        }
    }

    const parent_id = immediateParentActivityId(self);
    try openActivity(self, anchor, originating_request_id, orchestration, parent_id);
}

fn immediateParentActivityId(self: *Brain) ?[]const u8 {
    if (self.activity_stack.items.len == 0) return null;
    return self.activity_stack.items[self.activity_stack.items.len - 1].id;
}

pub fn openActivity(
    self: *Brain,
    anchor: []const u8,
    originating_request_id: []const u8,
    orchestration: ActivityOrchestration,
    parent_id: ?[]const u8,
) !void {
    const labels = try deriveActivityLabelsFromState(self, anchor);
    defer self.allocator.free(labels.kind_label);
    defer self.allocator.free(labels.goal);

    const salt = std.hash.Wyhash.hash(0, originating_request_id) ^ std.hash.Wyhash.hash(0, anchor);
    const id = try activity_mod.newId(self.allocator, self.now_seconds, labels.kind_label, salt);
    const interpretation = try std.fmt.allocPrint(self.allocator, "Activity opened for: {s}", .{labels.goal});
    var timeline = try self.allocator.alloc(activity_mod.TimelineEvent, 1);
    timeline[0] = .{
        .at_seconds = self.now_seconds,
        .kind = .opened,
        .title = try self.allocator.dupe(u8, "activity opened"),
        .body = try self.allocator.dupe(u8, labels.goal),
        .source_event_id = null,
    };
    self.active_activity = .{
        .id = id,
        .parent_id = if (parent_id) |parent| try self.allocator.dupe(u8, parent) else null,
        .kind = inferActivityKind(self, orchestration),
        .kind_label = try self.allocator.dupe(u8, labels.kind_label),
        .status = .active,
        .goal = try self.allocator.dupe(u8, labels.goal),
        .summary = try self.allocator.dupe(u8, labels.goal),
        .started_at_seconds = self.now_seconds,
        .updated_at_seconds = self.now_seconds,
        .originating_request_id = try self.allocator.dupe(u8, originating_request_id),
        .timeline = timeline,
        .state = try buildActivityState(self, interpretation, ""),
    };
    traceActivity(self, "activity.open", id, .active, labels.kind_label, labels.goal, "");
    try persistActiveActivityToStore(self);
}

pub fn pushActiveOntoStack(self: *Brain, reason: []const u8) !void {
    const active = &(self.active_activity orelse return error.NoActiveActivity);
    if (active.checkpoint != null) return error.ActivityAwaitingHostCheckpoint;
    if (self.activity_stack.items.len >= self.cfg.capacity.activity_stack_max) return ActivityStackOverflow;

    active.status = .paused;
    active.paused_at_seconds = self.now_seconds;
    active.updated_at_seconds = self.now_seconds;
    const pause_body = try self.allocator.dupe(u8, reason);
    try pushTimelineEvent(self, active, self.now_seconds, .paused, "stacked", pause_body, null);
    self.allocator.free(pause_body);

    const moved = self.active_activity.?;
    self.active_activity = null;
    try self.activity_stack.append(self.allocator, moved);
    traceActivity(self, "activity.stack.push", moved.id, .paused, moved.kind_label, moved.goal, reason);
    try persistActiveActivityToStore(self);
    try persistActivityStackToStore(self);
}

pub fn resumeParentFromStack(self: *Brain) !void {
    if (self.activity_stack.items.len == 0) return error.ActivityStackEmpty;
    if (self.active_activity != null) return error.ActiveActivityAlreadyPresent;

    var parent = self.activity_stack.pop().?;
    parent.status = .active;
    parent.paused_at_seconds = null;
    parent.updated_at_seconds = self.now_seconds;
    self.active_activity = parent;

    const resumed_body = try self.allocator.dupe(u8, "Resumed after child activity completed.");
    try pushTimelineEvent(self, &self.active_activity.?, self.now_seconds, .resumed, "stack resume", resumed_body, null);
    self.allocator.free(resumed_body);
    traceActivity(
        self,
        "activity.stack.pop",
        self.active_activity.?.id,
        .active,
        self.active_activity.?.kind_label,
        self.active_activity.?.goal,
        "",
    );
    try persistActiveActivityToStore(self);
    try persistActivityStackToStore(self);
}

pub fn abandonActivityStack(self: *Brain, reason: []const u8) !void {
    while (self.activity_stack.items.len > 0) {
        const paused = self.activity_stack.pop().?;
        self.active_activity = paused;
        try archiveActiveActivity(self, .abandoned, reason);
    }
    try persistActivityStackToStore(self);
}

pub fn collapseActivityStack(self: *Brain, reason: []const u8) !void {
    while (self.activity_stack.items.len > 0) {
        var paused = self.activity_stack.pop().?;
        paused.status = .abandoned;
        paused.updated_at_seconds = self.now_seconds;
        paused.completed_at_seconds = self.now_seconds;
        const closed_body = try self.allocator.dupe(u8, reason);
        try pushTimelineEvent(self, &paused, self.now_seconds, .closed, "abandoned", closed_body, null);
        self.allocator.free(closed_body);
        const record = try activity_persistence.toRecord(self.allocator, paused, persistContext(self, reason));
        defer freeActivityRecord(self.allocator, record);
        try consolidateActivityMemory(self, record, reason);
        try self.deps.store.appendActivityHistory(record);
        traceActivity(self, "activity.archive", paused.id, .abandoned, paused.kind_label, paused.goal, reason);
        activity_mod.freeActive(self.allocator, paused);
    }
    try persistActivityStackToStore(self);
}

pub fn completeSubtaskActivity(
    self: *Brain,
    user_text: []const u8,
    spoken_text: []const u8,
    turn: ?chat_mod.ChatTurn,
) !void {
    if (activityAwaitingHost(self)) return;
    try appendTurnEvents(self, user_text, spoken_text, turn);
    if (self.active_activity.?.parent_id != null) {
        try closeActiveActivity(self, .complete, "subtask complete");
    }
}

pub fn abandonOrchestrationSubtask(self: *Brain, reason: []const u8) !void {
    if (self.active_activity == null) return;
    if (self.active_activity.?.parent_id != null) {
        try closeActiveActivity(self, .abandoned, reason);
        return;
    }
    try archiveActiveActivity(self, .abandoned, reason);
}

pub fn beginSubtask(self: *Brain, goal_text: []const u8) ![]const u8 {
    const goal = std.mem.trim(u8, goal_text, " \r\n\t");
    if (goal.len == 0) return error.MissingSubtaskGoal;
    if (self.active_activity == null) return error.NoActiveActivity;
    if (activityAwaitingHost(self)) return error.ActivityAwaitingHostCheckpoint;

    const parent_id = try self.allocator.dupe(u8, self.active_activity.?.id);
    defer self.allocator.free(parent_id);

    try pushActiveOntoStack(self, "begin_subtask");
    try openActivity(
        self,
        goal,
        self.current_dispatch_request_id orelse "",
        .user_speech,
        parent_id,
    );

    return try std.fmt.allocPrint(
        self.allocator,
        "subtask_begun:\n- goal: {s}\n- parent_id: {s}\n- child_id: {s}\n",
        .{ goal, parent_id, self.active_activity.?.id },
    );
}

pub fn resumeParentTask(self: *Brain) ![]const u8 {
    if (self.active_activity == null) return error.NoActiveActivity;
    if (self.active_activity.?.parent_id == null and self.activity_stack.items.len == 0) {
        return error.NoParentActivityToResume;
    }

    const child_goal = try self.allocator.dupe(u8, self.active_activity.?.goal);
    defer self.allocator.free(child_goal);

    try closeActiveActivity(self, .complete, "resume_parent");

    const resumed_goal = if (self.active_activity) |active| active.goal else "";
    return try std.fmt.allocPrint(
        self.allocator,
        "subtask_completed:\n- child_goal: {s}\n- resumed_goal: {s}\n",
        .{ child_goal, resumed_goal },
    );
}

pub fn classifyTurnContinuation(self: *Brain, user_text: []const u8, turn_complete: bool) !activity_mod.TurnContinuation {
    _ = turn_complete;
    const immediate = try intent_mod.classifyHeuristic(self.allocator, .provide_name, user_text);
    if (immediate.action == .quit) return .close_current;

    if (self.active_activity) |active| {
        if (focusDivergesFromActivity(self, active, user_text)) return .replace_goal;
    }

    return .same_activity;
}

pub fn replaceActivityGoal(self: *Brain, new_goal: []const u8, reason: []const u8) !void {
    const active = &(self.active_activity orelse return error.NoActiveActivity);
    const trimmed = std.mem.trim(u8, new_goal, " \r\n\t");
    if (trimmed.len == 0) return error.MissingSubtaskGoal;

    const old_goal = try self.allocator.dupe(u8, active.goal);
    defer self.allocator.free(old_goal);

    const body = try std.fmt.allocPrint(self.allocator, "{s} -> {s}", .{ old_goal, trimmed });
    defer self.allocator.free(body);
    try pushTimelineEvent(self, active, self.now_seconds, .observation, reason, body, null);

    self.allocator.free(active.goal);
    active.goal = try self.allocator.dupe(u8, trimmed);
    self.allocator.free(active.summary);
    active.summary = try self.allocator.dupe(u8, trimmed);
    active.kind = .conversation;
    active.updated_at_seconds = self.now_seconds;
    traceActivity(self, "activity.goal.replace", active.id, active.status, active.kind_label, trimmed, reason);
    try persistActiveActivityToStore(self);
}

pub fn applyTurnContinuation(
    self: *Brain,
    cont: activity_mod.TurnContinuation,
    user_text: []const u8,
    spoken_text: []const u8,
    turn: ?chat_mod.ChatTurn,
    turn_complete: bool,
) !void {
    _ = turn_complete;
    switch (cont) {
        .same_activity => try appendTurnEvents(self, user_text, spoken_text, turn),
        .replace_goal => {
            try collapseActivityStack(self, "goal replace collapsed stale stack");
            try replaceActivityGoal(self, user_text, "goal replaced");
            try appendTurnEvents(self, user_text, spoken_text, turn);
        },
        .close_current => {
            try abandonActivityStack(self, "user_quit cascaded");
            if (self.active_activity != null) try archiveActiveActivity(self, .complete, "user_quit");
        },
        .pause_current_and_start_new => {
            const parent_id = if (self.active_activity) |active| active.parent_id else null;
            try pushActiveOntoStack(self, "topic switch");
            try openActivity(self, user_text, self.current_dispatch_request_id orelse "", .user_speech, parent_id);
            try appendTurnEvents(self, user_text, spoken_text, turn);
        },
        .new_child_activity => {
            const parent_id = if (self.active_activity) |active| active.id else null;
            try pushActiveOntoStack(self, "child subtask");
            try openActivity(self, user_text, self.current_dispatch_request_id orelse "", .user_speech, parent_id);
            try appendTurnEvents(self, user_text, spoken_text, turn);
        },
        .new_sibling_activity => {
            const parent_id = if (self.active_activity) |active| active.parent_id else null;
            try pushActiveOntoStack(self, "sibling activity");
            try openActivity(self, user_text, self.current_dispatch_request_id orelse "", .user_speech, parent_id);
            try appendTurnEvents(self, user_text, spoken_text, turn);
        },
        .resume_paused => try appendTurnEvents(self, user_text, spoken_text, turn),
    }
}

pub fn appendTurnEvents(self: *Brain, user_text: []const u8, spoken_text: []const u8, turn: ?chat_mod.ChatTurn) !void {
    const active = &(self.active_activity orelse return);
    try pushTimelineEvent(self, active, self.now_seconds, .observation, "user turn", user_text, null);
    if (spoken_text.len > 0) {
        try pushTimelineEvent(self, active, self.now_seconds, .observation, "spoken response", spoken_text, null);
    }
    if (turn) |chat_turn| {
        if (chat_turn.brain_summary.len > 0) {
            self.allocator.free(active.summary);
            active.summary = try self.allocator.dupe(u8, chat_turn.brain_summary);
        }
        try recordCandidateActionsFromTurn(self, chat_turn);
    }
    const interpretation = try std.fmt.allocPrint(self.allocator, "Continuing activity: {s}", .{active.goal});
    try updateActivityState(self, active, interpretation, spoken_text);
    active.updated_at_seconds = self.now_seconds;
    try persistActiveActivityToStore(self);
}

pub fn pauseActiveActivityForIdle(self: *Brain, reason: []const u8) !void {
    const active = &(self.active_activity orelse return);
    if (active.status == .paused) return;
    active.status = .paused;
    active.paused_at_seconds = self.now_seconds;
    active.updated_at_seconds = self.now_seconds;
    try pushTimelineEvent(self, active, self.now_seconds, .waiting, "idle timeout", reason, null);
    traceActivity(self, "activity.pause_idle", active.id, .paused, active.kind_label, active.goal, reason);
    try persistActiveActivityToStore(self);
    const snapshot = try activity_persistence.toRecord(self.allocator, active.*, persistContext(self, reason));
    defer freeActivityRecord(self.allocator, snapshot);
    try consolidateActivityMemory(self, snapshot, reason);
}

pub fn closeActiveActivity(self: *Brain, status: activity_mod.Status, reason: []const u8) !void {
    const resume_parent = if (self.active_activity) |active| active.parent_id != null else false;
    try archiveActiveActivity(self, status, reason);
    if (status == .complete and resume_parent) {
        try resumeParentFromStack(self);
    }
}

pub fn archiveActiveActivity(self: *Brain, status: activity_mod.Status, reason: []const u8) !void {
    const active = &self.active_activity.?;
    active.status = status;
    active.updated_at_seconds = self.now_seconds;
    if (status == .complete or status == .abandoned) {
        active.completed_at_seconds = self.now_seconds;
    }
    const closed_body = try self.allocator.dupe(u8, reason);
    try pushTimelineEvent(self, active, self.now_seconds, .closed, @tagName(status), closed_body, null);
    self.allocator.free(closed_body);

    const record = try activity_persistence.toRecord(self.allocator, active.*, persistContext(self, reason));
    defer freeActivityRecord(self.allocator, record);
    try consolidateActivityMemory(self, record, reason);
    try self.deps.store.appendActivityHistory(record);

    traceActivity(self, "activity.archive", active.id, status, active.kind_label, active.goal, reason);
    clearActiveActivity(self);
    try self.deps.store.saveActiveActivity(null);
}

pub fn pauseForHostSense(self: *Brain, pause: PauseForHostSense) !void {
    const checkpoint = Checkpoint{
        .anchor_text = try self.allocator.dupe(u8, pause.anchor_text),
        .heard_speech = try cloneHeardSpeech(self, pause.heard_speech),
        .observations = try self.allocator.dupe(u8, pause.observations),
        .memory = try self.allocator.dupe(u8, pause.memory),
        .spoken_text = try self.allocator.dupe(u8, pause.spoken_text),
        .paused_at_seconds = self.now_seconds,
    };

    const interpretation = try std.fmt.allocPrint(
        self.allocator,
        "Paused for host-delivered sense: {s}",
        .{pause.awaiting},
    );

    if (self.active_activity == null) {
        const salt = std.hash.Wyhash.hash(0, pause.originating_request_id) ^ std.hash.Wyhash.hash(0, pause.kind_label);
        const id = try activity_mod.newId(self.allocator, self.now_seconds, pause.kind_label, salt);
        var timeline = try self.allocator.alloc(activity_mod.TimelineEvent, 2);
        timeline[0] = .{
            .at_seconds = self.now_seconds,
            .kind = .opened,
            .title = try self.allocator.dupe(u8, "activity opened"),
            .body = try self.allocator.dupe(u8, pause.goal),
            .source_event_id = null,
        };
        timeline[1] = .{
            .at_seconds = self.now_seconds,
            .kind = .paused,
            .title = try self.allocator.dupe(u8, "paused for host sense"),
            .body = try self.allocator.dupe(u8, pause.awaiting),
            .source_event_id = null,
        };
        self.active_activity = .{
            .id = id,
            .kind = inferActivityKind(self, .user_speech),
            .kind_label = try self.allocator.dupe(u8, pause.kind_label),
            .status = .paused,
            .goal = try self.allocator.dupe(u8, pause.goal),
            .summary = try self.allocator.dupe(u8, pause.goal),
            .started_at_seconds = self.now_seconds,
            .updated_at_seconds = self.now_seconds,
            .paused_at_seconds = self.now_seconds,
            .originating_request_id = try self.allocator.dupe(u8, pause.originating_request_id),
            .timeline = timeline,
            .state = try buildActivityState(self, try self.allocator.dupe(u8, interpretation), pause.spoken_text),
            .awaiting = try self.allocator.dupe(u8, pause.awaiting),
            .checkpoint = checkpoint,
        };
        traceActivity(self, "activity.open_paused", id, .paused, pause.kind_label, pause.goal, pause.awaiting);
        try persistActiveActivityToStore(self);
        return;
    }

    const active = &self.active_activity.?;
    if (active.checkpoint) |previous| activity_mod.freeCheckpoint(self.allocator, previous);
    if (active.awaiting) |awaiting| self.allocator.free(awaiting);
    self.allocator.free(active.goal);
    active.goal = try self.allocator.dupe(u8, pause.goal);
    active.summary = try self.allocator.dupe(u8, pause.goal);
    active.awaiting = try self.allocator.dupe(u8, pause.awaiting);
    active.status = .paused;
    active.updated_at_seconds = self.now_seconds;
    active.paused_at_seconds = self.now_seconds;
    active.checkpoint = checkpoint;
    try updateActivityState(self, active, interpretation, pause.spoken_text);
    try pushTimelineEvent(self, active, self.now_seconds, .paused, "paused for host sense", pause.awaiting, null);
    traceActivity(self, "activity.pause", active.id, .paused, active.kind_label, pause.goal, pause.awaiting);
    try persistActiveActivityToStore(self);
}

pub fn resumeActiveActivity(self: *Brain) !Checkpoint {
    if (self.active_activity == null) return error.NoActiveActivity;
    const active = &self.active_activity.?;
    if (active.status != .paused) return error.NoActiveActivity;
    const checkpoint = active.checkpoint orelse return error.MissingActivityCheckpoint;
    active.status = .active;
    active.updated_at_seconds = self.now_seconds;
    active.paused_at_seconds = null;
    active.checkpoint = null;
    const resumed_body = try self.allocator.dupe(u8, "Resumed after host-delivered sense.");
    try pushTimelineEvent(self, active, self.now_seconds, .resumed, "resumed", resumed_body, null);
    self.allocator.free(resumed_body);
    traceActivity(self, "activity.resume", active.id, .active, active.kind_label, active.goal, active.awaiting orelse "");
    try persistActiveActivityToStore(self);
    return checkpoint;
}

pub fn completeActiveActivity(self: *Brain) !void {
    try closeActiveActivity(self, .complete, "completed");
}

pub fn supersedeActiveActivity(self: *Brain) !void {
    try closeActiveActivity(self, .abandoned, "superseded");
}

pub fn clearActiveActivity(self: *Brain) void {
    const active = self.active_activity orelse return;
    self.active_activity = null;
    activity_mod.freeActive(self.allocator, active);
}

pub fn activityView(self: *Brain, allocator: std.mem.Allocator) !?activity_mod.View {
    const active = self.active_activity orelse return null;
    const open_loops = try deriveOpenLoops(self, allocator);
    errdefer freeOpenLoops(allocator, open_loops);
    const blockers = try deriveBlockers(self, allocator);
    errdefer freeBlockers(allocator, blockers);
    const candidate_actions = try deriveCandidateActions(self, allocator);
    errdefer freeCandidateActions(allocator, candidate_actions);
    return .{
        .id = active.id,
        .parent_id = active.parent_id,
        .kind = active.kind,
        .kind_label = active.kind_label,
        .status = active.status,
        .goal = active.goal,
        .summary = active.summary,
        .started_at_seconds = active.started_at_seconds,
        .updated_at_seconds = active.updated_at_seconds,
        .paused_at_seconds = active.paused_at_seconds,
        .completed_at_seconds = active.completed_at_seconds,
        .originating_request_id = active.originating_request_id,
        .timeline = active.timeline,
        .state = active.state,
        .open_loops = open_loops,
        .blockers = blockers,
        .candidate_actions = candidate_actions,
        .awaiting = active.awaiting,
        .checkpoint_spoken_text = if (active.checkpoint) |cp| cp.spoken_text else null,
    };
}

pub fn appendActivityObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const view = try activityView(self, self.allocator);
    if (view == null) {
        try out.appendSlice(self.allocator, "active_activity: none\n");
        return;
    }
    const activity = view.?;
    defer activity_mod.freeViewExtras(self.allocator, activity);
    try out.print(
        self.allocator,
        "active_activity:\n- note: stay with this unless they clearly moved on.\n- id: {s}\n- kind: {s}\n- kind_label: {s}\n- status: {s}\n- goal: {s}\n- summary: {s}\n- interpretation: {s}\n",
        .{
            activity.id,
            @tagName(activity.kind),
            activity.kind_label,
            activity_mod.statusTag(activity.status),
            activity.goal,
            activity.summary,
            activity.state.interpretation,
        },
    );
    if (activity.awaiting) |awaiting| {
        try out.print(self.allocator, "- awaiting: {s}\n", .{awaiting});
    }
    if (activity.parent_id) |parent| {
        try out.print(self.allocator, "- parent_id: {s}\n", .{parent});
    }
    try appendActivityStackObservation(self, out);
    if (activity.open_loops.len > 0) {
        try out.appendSlice(self.allocator, "- open_loops:\n");
        for (activity.open_loops) |loop| {
            try out.print(
                self.allocator,
                "  - {s}: {s} (since {d}s ago)\n",
                .{ @tagName(loop.kind), loop.description, @max(@as(i64, 0), self.now_seconds - loop.since_seconds) },
            );
        }
    }
    if (activity.blockers.len > 0) {
        try out.appendSlice(self.allocator, "- blockers:\n");
        for (activity.blockers) |blocker| {
            if (blocker.since_seconds) |since| {
                try out.print(
                    self.allocator,
                    "  - {s}: {s} (since {d}s ago)\n",
                    .{ @tagName(blocker.kind), blocker.description, @max(@as(i64, 0), self.now_seconds - since) },
                );
            } else {
                try out.print(self.allocator, "  - {s}: {s}\n", .{ @tagName(blocker.kind), blocker.description });
            }
        }
    }
    if (activity.candidate_actions.len > 0) {
        try out.appendSlice(self.allocator, "- candidate_actions:\n");
        for (activity.candidate_actions) |candidate| {
            try out.print(
                self.allocator,
                "  - {s}: {s} (strength {d:.2})\n",
                .{ candidate.action, candidate.rationale, candidate.strength },
            );
        }
    }
    if (activity.timeline.len > 0) {
        try out.appendSlice(self.allocator, "- recent_timeline:\n");
        const start = if (activity.timeline.len > 4) activity.timeline.len - 4 else 0;
        for (activity.timeline[start..]) |event| {
            try out.print(
                self.allocator,
                "  - [{s}] {s}: {s}\n",
                .{ @tagName(event.kind), event.title, event.body },
            );
        }
    }
}

fn appendActivityStackObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    if (self.activity_stack.items.len == 0) return;
    try out.appendSlice(self.allocator, "- activity_stack (root to parent):\n");
    for (self.activity_stack.items, 0..) |frame, depth| {
        try out.print(
            self.allocator,
            "  - depth={d} id={s} goal=\"{s}\" status={s}\n",
            .{ depth, frame.id, frame.goal, activity_mod.statusTag(frame.status) },
        );
    }
    const root = self.activity_stack.items[0];
    try out.print(self.allocator, "- main_goal: \"{s}\"\n", .{root.goal});
}

fn focusDivergesFromActivity(self: *Brain, active: Active, user_text: []const u8) bool {
    if (textsShareTopic(user_text, active.goal)) return false;
    if (isContinuationUtterance(user_text)) return false;
    if (self.current_focus) |focus| {
        if (textsShareTopic(focus.text, active.goal)) return false;
        if (textsShareTopic(user_text, focus.text)) return false;
    }
    for (self.activity_stack.items) |frame| {
        if (textsShareTopic(user_text, frame.goal)) return false;
    }
    if (active.kind == .conversation) return looksLikeNewTopic(user_text);
    return true;
}

fn isContinuationUtterance(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len <= 4) return true;
    const patterns = [_][]const u8{
        "never mind",
        "nevermind",
        "where were we",
        "where did we",
        "yes,",
        "yes ",
        "yeah",
        "yep",
        "no,",
        "no ",
        "continue",
        "go on",
        "go ahead",
        "summarize",
        "sorry",
        "what did you",
        "didn't catch",
        "did not catch",
        "repeat",
        "clarify",
    };
    for (patterns) |pattern| {
        if (std.ascii.indexOfIgnoreCase(trimmed, pattern) != null) return true;
    }
    return false;
}

fn looksLikeNewTopic(user_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, user_text, " \r\n\t");
    if (trimmed.len < 28) return false;
    const openers = [_][]const u8{
        "explain ",
        "tell me about ",
        "what is ",
        "what are ",
        "how does ",
        "how do ",
        "describe ",
    };
    for (openers) |opener| {
        if (std.ascii.startsWithIgnoreCase(trimmed, opener)) return true;
    }
    var words: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (!std.ascii.isAlphanumeric(trimmed[i])) continue;
        while (i < trimmed.len and std.ascii.isAlphanumeric(trimmed[i])) i += 1;
        words += 1;
    }
    return words >= 6 and trimmed.len >= 36;
}

fn textsShareTopic(a: []const u8, b: []const u8) bool {
    var shared: usize = 0;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (!std.ascii.isAlphanumeric(a[i])) continue;
        const start = i;
        while (i < a.len and std.ascii.isAlphanumeric(a[i])) i += 1;
        if (i - start < 4) continue;
        if (std.ascii.indexOfIgnoreCase(b, a[start..i]) != null) shared += 1;
        if (shared >= 1) return true;
    }
    return false;
}

fn deriveOpenLoops(self: *Brain, allocator: std.mem.Allocator) ![]activity_mod.OpenLoop {
    var loops = std.ArrayList(activity_mod.OpenLoop).empty;
    errdefer {
        for (loops.items) |loop| allocator.free(loop.description);
        loops.deinit(allocator);
    }
    if (self.waiting_for) |waiting| {
        const kind: activity_mod.OpenLoopKind = switch (waiting.kind) {
            .host_sense => .host_sense,
            .timer => .timer,
            .human => .human,
        };
        try loops.append(allocator, .{
            .kind = kind,
            .description = try allocator.dupe(u8, waiting.intent),
            .since_seconds = waiting.since,
        });
    }
    if (self.awaitedHostRequestMatches("camera", "recognize")) {
        try loops.append(allocator, .{
            .kind = .camera,
            .description = try std.fmt.allocPrint(
                allocator,
                "host {s} for {s} (request_id={s})",
                .{
                    self.awaited_host_request.?.sense,
                    self.awaited_host_request.?.purpose,
                    self.awaited_host_request.?.request_id,
                },
            ),
            .since_seconds = self.awaited_host_request.?.since_seconds,
        });
    }
    if (self.pending_deferred_heard_speech != null) {
        try loops.append(allocator, .{
            .kind = .deferred_input,
            .description = try allocator.dupe(u8, "deferred user speech while activity paused"),
            .since_seconds = self.now_seconds,
        });
    }
    if (self.active_activity) |active| {
        if (active.awaiting) |awaiting| {
            const duplicate = if (self.waiting_for) |waiting| std.mem.eql(u8, waiting.intent, awaiting) else false;
            if (!duplicate) {
                try loops.append(allocator, .{
                    .kind = .host_sense,
                    .description = try allocator.dupe(u8, awaiting),
                    .since_seconds = active.paused_at_seconds orelse active.updated_at_seconds,
                });
            }
        }
    }
    return try loops.toOwnedSlice(allocator);
}

fn deriveBlockers(self: *Brain, allocator: std.mem.Allocator) ![]activity_mod.Blocker {
    var blockers = std.ArrayList(activity_mod.Blocker).empty;
    errdefer {
        for (blockers.items) |blocker| allocator.free(blocker.description);
        blockers.deinit(allocator);
    }
    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode != .waking) {
        try blockers.append(allocator, .{
            .kind = .brain_mode,
            .description = try std.fmt.allocPrint(allocator, "brain mode is {s}", .{@tagName(brain_mode)}),
            .since_seconds = self.now_seconds,
        });
    }
    if (self.pending_hard_error) |hard_error| {
        try blockers.append(allocator, .{
            .kind = .hard_error,
            .description = try std.fmt.allocPrint(
                allocator,
                "{s} on {s}: {s}",
                .{ hard_error.error_name, hard_error.action_pressure, hard_error.recovery_hint },
            ),
            .since_seconds = self.now_seconds,
        });
    }
    if (activityAwaitingHost(self)) {
        try blockers.append(allocator, .{
            .kind = .host_sense,
            .description = try allocator.dupe(u8, "waiting for host-delivered sense before continuing"),
            .since_seconds = if (self.active_activity) |active| active.paused_at_seconds else null,
        });
    }
    return try blockers.toOwnedSlice(allocator);
}

fn deriveCandidateActions(self: *Brain, allocator: std.mem.Allocator) ![]activity_mod.CandidateAction {
    if (self.active_activity) |active| {
        if (active.recent_candidate_actions.len > 0) {
            var copied = try allocator.alloc(activity_mod.CandidateAction, active.recent_candidate_actions.len);
            for (active.recent_candidate_actions, 0..) |candidate, i| {
                copied[i] = .{
                    .action = try allocator.dupe(u8, candidate.action),
                    .rationale = try allocator.dupe(u8, candidate.rationale),
                    .strength = candidate.strength,
                };
            }
            return copied;
        }
    }
    const pressures = self.deps.store.loadActionPressures(allocator) catch return &.{};
    defer allocator.free(pressures);
    var candidates = std.ArrayList(activity_mod.CandidateAction).empty;
    errdefer {
        for (candidates.items) |candidate| {
            allocator.free(candidate.action);
            allocator.free(candidate.rationale);
        }
        candidates.deinit(allocator);
    }
    for (pressures) |pressure| {
        if (pressure.expires_at_ms) |expires_at_ms| {
            if (expires_at_ms <= self.now_seconds * 1000) continue;
        }
        try candidates.append(allocator, .{
            .action = try allocator.dupe(u8, pressure.proposed_action),
            .rationale = try allocator.dupe(u8, pressure.rationale),
            .strength = pressure.strength,
        });
        if (candidates.items.len >= self.cfg.capacity.candidate_actions_max) break;
    }
    return try candidates.toOwnedSlice(allocator);
}

fn freeOpenLoops(allocator: std.mem.Allocator, loops: []activity_mod.OpenLoop) void {
    for (loops) |loop| allocator.free(loop.description);
    allocator.free(loops);
}

fn freeBlockers(allocator: std.mem.Allocator, blockers: []activity_mod.Blocker) void {
    for (blockers) |blocker| allocator.free(blocker.description);
    allocator.free(blockers);
}

fn freeCandidateActions(allocator: std.mem.Allocator, candidates: []activity_mod.CandidateAction) void {
    for (candidates) |candidate| {
        allocator.free(candidate.action);
        allocator.free(candidate.rationale);
    }
    allocator.free(candidates);
}

fn buildActivityState(self: *Brain, interpretation: []const u8, spoken_text: []const u8) !activity_mod.ActivityState {
    const focus_text = if (self.current_focus) |focus| try self.allocator.dupe(u8, focus.text) else null;
    const stimulus_text = if (self.current_stimulus_context) |stimulus| try self.allocator.dupe(u8, stimulus) else null;
    const last_spoken = if (spoken_text.len > 0) try self.allocator.dupe(u8, spoken_text) else null;
    const waiting_kind: ?activity_mod.OpenLoopKind = if (self.waiting_for) |waiting| switch (waiting.kind) {
        .host_sense => .host_sense,
        .timer => .timer,
        .human => .human,
    } else null;
    const waiting_intent = if (self.waiting_for) |waiting| try self.allocator.dupe(u8, waiting.intent) else null;
    const waiting_since = if (self.waiting_for) |waiting| waiting.since else null;
    return .{
        .interpretation = interpretation,
        .focus_text = focus_text,
        .stimulus_text = stimulus_text,
        .last_spoken_text = last_spoken,
        .waiting_kind = waiting_kind,
        .waiting_intent = waiting_intent,
        .waiting_since_seconds = waiting_since,
    };
}

fn updateActivityState(self: *Brain, active: *Active, interpretation: []const u8, spoken_text: []const u8) !void {
    self.allocator.free(active.state.interpretation);
    if (active.state.focus_text) |text| self.allocator.free(text);
    if (active.state.stimulus_text) |text| self.allocator.free(text);
    if (active.state.last_spoken_text) |text| self.allocator.free(text);
    if (active.state.waiting_intent) |text| self.allocator.free(text);
    active.state = try buildActivityState(self, try self.allocator.dupe(u8, interpretation), spoken_text);
}

fn pushTimelineEvent(
    self: *Brain,
    active: *Active,
    at_seconds: i64,
    kind: activity_mod.TimelineEventKind,
    title: []const u8,
    body: []const u8,
    source_event_id: ?[]const u8,
) !void {
    const new_timeline = try appendTimelineEvent(
        self.allocator,
        active.timeline,
        at_seconds,
        kind,
        title,
        body,
        source_event_id,
    );
    freeTimeline(self.allocator, active.timeline);
    active.timeline = new_timeline;
}

fn freeTimeline(allocator: std.mem.Allocator, timeline: []activity_mod.TimelineEvent) void {
    for (timeline) |event| activity_mod.freeTimelineEvent(allocator, event);
    allocator.free(timeline);
}

fn appendTimelineEvent(
    allocator: std.mem.Allocator,
    timeline: []const activity_mod.TimelineEvent,
    at_seconds: i64,
    kind: activity_mod.TimelineEventKind,
    title: []const u8,
    body: []const u8,
    source_event_id: ?[]const u8,
) ![]activity_mod.TimelineEvent {
    var events = std.ArrayList(activity_mod.TimelineEvent).empty;
    try events.appendSlice(allocator, timeline);
    try events.append(allocator, .{
        .at_seconds = at_seconds,
        .kind = kind,
        .title = try allocator.dupe(u8, title),
        .body = try allocator.dupe(u8, body),
        .source_event_id = if (source_event_id) |id| try allocator.dupe(u8, id) else null,
    });
    return try events.toOwnedSlice(allocator);
}

fn traceActivity(
    self: *Brain,
    stage: []const u8,
    activity_id: []const u8,
    status: activity_mod.Status,
    kind_label: []const u8,
    goal: []const u8,
    awaiting: []const u8,
) void {
    self.outputFmt(
        "TRACE now={d} dispatch_id={s} stage={s} activity_id={s} activity_status={s} activity_kind_label={s} activity_goal=\"{s}\" activity_awaiting={s}\n",
        .{ self.now_seconds, self.current_dispatch_request_id orelse "(none)", stage, activity_id, activity_mod.statusTag(status), kind_label, goal, awaiting },
    );
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

fn persistContext(self: *Brain, close_reason: ?[]const u8) activity_persistence.PersistContext {
    const req = self.awaited_host_request;
    return .{
        .awaited_host_request_id = if (req) |value| value.request_id else null,
        .awaited_host_sense = if (req) |value| value.sense else null,
        .awaited_host_purpose = if (req) |value| value.purpose else null,
        .deferred_heard_speech_text = if (self.pending_deferred_heard_speech) |deferred| deferred.text else null,
        .close_reason = close_reason,
    };
}

fn consolidateActivityMemory(self: *Brain, record: schema.ActivityRecord, reason: []const u8) !void {
    const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
        .activity = record,
        .reason = reason,
    }, .{ .whitespace = .minified });
    try self.publishRuntimeMemoryConsolidation(payload, "brain_activity.lifecycle");
}

pub fn syncActivityContextFromBrain(self: *Brain) !void {
    const active = &(self.active_activity orelse return);
    active.updated_at_seconds = self.now_seconds;
    if (active.state.focus_text) |text| self.allocator.free(text);
    if (active.state.stimulus_text) |text| self.allocator.free(text);
    if (active.state.waiting_intent) |text| self.allocator.free(text);
    active.state.focus_text = if (self.current_focus) |focus| try self.allocator.dupe(u8, focus.text) else null;
    active.state.stimulus_text = if (self.current_stimulus_context) |stimulus| try self.allocator.dupe(u8, stimulus) else null;
    active.state.waiting_kind = if (self.waiting_for) |waiting| switch (waiting.kind) {
        .host_sense => .host_sense,
        .timer => .timer,
        .human => .human,
    } else null;
    active.state.waiting_intent = if (self.waiting_for) |waiting| try self.allocator.dupe(u8, waiting.intent) else null;
    active.state.waiting_since_seconds = if (self.waiting_for) |waiting| waiting.since else null;
    try persistActiveActivityToStore(self);
}

pub fn persistActiveActivityToStore(self: *Brain) !void {
    const active = self.active_activity orelse {
        try self.deps.store.saveActiveActivity(null);
        return;
    };
    const record = try activity_persistence.toRecord(self.allocator, active, persistContext(self, null));
    defer freeActivityRecord(self.allocator, record);
    try self.deps.store.saveActiveActivity(record);
}

pub fn persistActivityStackToStore(self: *Brain) !void {
    var records = std.ArrayList(schema.ActivityRecord).empty;
    defer {
        for (records.items) |record| freeActivityRecord(self.allocator, record);
        records.deinit(self.allocator);
    }
    for (self.activity_stack.items) |frame| {
        try records.append(self.allocator, try activity_persistence.toRecord(self.allocator, frame, persistContext(self, null)));
    }
    try self.deps.store.saveActivityStack(records.items);
}

pub fn clearActivityStack(self: *Brain) void {
    for (self.activity_stack.items) |frame| activity_mod.freeActive(self.allocator, frame);
    self.activity_stack.clearRetainingCapacity();
}

pub fn restorePersistedActivity(self: *Brain) !void {
    const loaded = try self.deps.store.loadActiveActivity(self.allocator);
    if (self.active_activity != null) clearActiveActivity(self);
    clearActivityStack(self);

    const stack_records = try self.deps.store.loadActivityStack(self.allocator);
    defer {
        for (stack_records) |stack_record| freeActivityRecord(self.allocator, stack_record);
        self.allocator.free(stack_records);
    }
    for (stack_records) |stack_record| {
        try self.activity_stack.append(self.allocator, try activity_persistence.fromRecord(self.allocator, stack_record));
    }

    const record = loaded orelse return;
    defer freeActivityRecord(self.allocator, record);
    self.active_activity = try activity_persistence.fromRecord(self.allocator, record);
    try activity_persistence.applyRecordContext(self, record);
    if (stackLooksStaleForConversationRestore(self)) {
        try collapseActivityStack(self, "restore collapsed stale conversation stack");
    }
}

fn stackLooksStaleForConversationRestore(self: *Brain) bool {
    const active = self.active_activity orelse return false;
    if (active.kind != .conversation or self.activity_stack.items.len == 0) return false;
    const top = self.activity_stack.items[self.activity_stack.items.len - 1];
    if (std.mem.eql(u8, top.goal, active.goal)) return true;
    return self.activity_stack.items.len >= self.cfg.capacity.activity_stack_max -| 1;
}

pub fn recordCandidateActionsFromTurn(self: *Brain, turn: chat_mod.ChatTurn) !void {
    const active = &(self.active_activity orelse return);
    for (active.recent_candidate_actions) |candidate| {
        self.allocator.free(candidate.action);
        self.allocator.free(candidate.rationale);
    }
    self.allocator.free(active.recent_candidate_actions);
    var candidates = std.ArrayList(activity_mod.CandidateAction).empty;
    errdefer {
        for (candidates.items) |candidate| {
            self.allocator.free(candidate.action);
            self.allocator.free(candidate.rationale);
        }
        candidates.deinit(self.allocator);
    }
    for (turn.action_pressures, 0..) |proposal, index| {
        const action_name = @tagName(proposal.action);
        const rationale = try proposalRationale(self.allocator, proposal);
        const strength = @max(0.10, 1.0 - @as(f32, @floatFromInt(index)) * 0.12);
        try candidates.append(self.allocator, .{
            .action = try self.allocator.dupe(u8, action_name),
            .rationale = rationale,
            .strength = strength,
        });
        const timeline_body = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ action_name, rationale });
        defer self.allocator.free(timeline_body);
        try pushTimelineEvent(self, active, self.now_seconds, .action, "candidate action", timeline_body, null);
    }
    active.recent_candidate_actions = try candidates.toOwnedSlice(self.allocator);
    active.updated_at_seconds = self.now_seconds;
    try persistActiveActivityToStore(self);
}

fn proposalRationale(allocator: std.mem.Allocator, proposal: chat_mod.ActionProposal) ![]const u8 {
    if (proposal.text) |text| return try allocator.dupe(u8, text);
    if (chat_mod.actionSpec(proposal.action)) |spec| return try allocator.dupe(u8, spec.description);
    return try allocator.dupe(u8, @tagName(proposal.action));
}

fn freeActivityRecord(allocator: std.mem.Allocator, record: schema.ActivityRecord) void {
    @import("../storage/json_store_cognitive.zig").freeActivityRecord(allocator, record);
}
