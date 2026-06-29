const std = @import("std");
const input_mod = @import("port_input.zig");

pub const Status = enum {
    active,
    paused,
    blocked,
    complete,
    abandoned,
};

pub const Kind = enum {
    conversation,
    research,
    navigation,
    waiting,
    planning,
    maintenance,
    generic,
};

pub const EntityRef = struct {
    id: []const u8,
    label: []const u8,
    role: []const u8 = "",
};

pub const MemoryRef = struct {
    memory_id: []const u8,
    note: []const u8 = "",
};

pub const TimelineEventKind = enum {
    opened,
    stimulus,
    action,
    observation,
    paused,
    resumed,
    waiting,
    blocked,
    summarized,
    closed,
};

pub const TimelineEvent = struct {
    at_seconds: i64,
    kind: TimelineEventKind,
    title: []const u8,
    body: []const u8,
    source_event_id: ?[]const u8 = null,
};

pub const ActivityState = struct {
    interpretation: []const u8,
    focus_text: ?[]const u8 = null,
    stimulus_text: ?[]const u8 = null,
    last_spoken_text: ?[]const u8 = null,
    waiting_kind: ?OpenLoopKind = null,
    waiting_intent: ?[]const u8 = null,
    waiting_since_seconds: ?i64 = null,
};

pub const OpenLoopKind = enum {
    host_sense,
    timer,
    human,
    camera,
    deferred_input,
    reminder,
    process,
};

pub const OpenLoop = struct {
    kind: OpenLoopKind,
    description: []const u8,
    since_seconds: i64,
};

pub const BlockerKind = enum {
    host_sense,
    brain_mode,
    hard_error,
    capability,
    policy,
};

pub const Blocker = struct {
    kind: BlockerKind,
    description: []const u8,
    since_seconds: ?i64 = null,
};

pub const CandidateAction = struct {
    action: []const u8,
    rationale: []const u8,
    strength: f32 = 0,
};

pub const ContinuationDecision = enum {
    continue_,
    pause,
    resume_,
    ask,
    switch_focus,
    summarize,
    close,
    abandon,
};

pub const ContinuationPolicy = struct {
    preferred: ContinuationDecision = .continue_,
    note: ?[]const u8 = null,
};

pub const TurnContinuation = enum {
    same_activity,
    replace_goal,
    new_child_activity,
    new_sibling_activity,
    pause_current_and_start_new,
    resume_paused,
    close_current,
};

/// Resume payload captured when an activity pauses for a host round-trip.
pub const Checkpoint = struct {
    anchor_text: []const u8,
    heard_speech: input_mod.HeardSpeech,
    observations: []const u8,
    memory: []const u8,
    spoken_text: []const u8,
    paused_at_seconds: i64,
};

/// In-flight ongoing activity owned by the brain.
pub const Active = struct {
    id: []const u8,
    parent_id: ?[]const u8 = null,
    kind: Kind,
    /// Brain-chosen label (focus text, stimulus line, etc.) — not a host dispatch type.
    kind_label: []const u8,
    status: Status,
    goal: []const u8,
    summary: []const u8,
    started_at_seconds: i64,
    updated_at_seconds: i64,
    paused_at_seconds: ?i64 = null,
    completed_at_seconds: ?i64 = null,
    originating_request_id: []const u8,
    timeline: []TimelineEvent,
    state: ActivityState,
    recent_candidate_actions: []CandidateAction = &.{},
    awaiting: ?[]const u8 = null,
    checkpoint: ?Checkpoint = null,
};

pub const View = struct {
    id: []const u8,
    parent_id: ?[]const u8 = null,
    kind: Kind,
    kind_label: []const u8,
    status: Status,
    goal: []const u8,
    summary: []const u8,
    started_at_seconds: i64,
    updated_at_seconds: i64,
    paused_at_seconds: ?i64 = null,
    completed_at_seconds: ?i64 = null,
    originating_request_id: []const u8,
    timeline: []const TimelineEvent,
    state: ActivityState,
    open_loops: []const OpenLoop,
    blockers: []const Blocker,
    candidate_actions: []const CandidateAction,
    awaiting: ?[]const u8 = null,
    checkpoint_spoken_text: ?[]const u8 = null,
};

const max_id_slug_len: usize = 32;

fn slugifyLabel(slug_buf: *[max_id_slug_len]u8, label: []const u8) []const u8 {
    var len: usize = 0;
    var prev_underscore = false;
    for (label) |ch| {
        if (len >= max_id_slug_len) break;
        const out: u8 = if (std.ascii.isAlphanumeric(ch))
            std.ascii.toLower(ch)
        else if (ch == ' ' or ch == '-' or ch == '_')
            '_'
        else
            continue;
        if (out == '_' and prev_underscore) continue;
        slug_buf[len] = out;
        len += 1;
        prev_underscore = out == '_';
    }
    while (len > 0 and slug_buf[len - 1] == '_') len -= 1;
    if (len == 0) {
        @memcpy(slug_buf[0..7], "generic");
        return slug_buf[0..7];
    }
    return slug_buf[0..len];
}

pub fn newId(allocator: std.mem.Allocator, now_seconds: i64, kind_label: []const u8, salt: u64) ![]const u8 {
    var slug_buf: [max_id_slug_len]u8 = undefined;
    const slug = slugifyLabel(&slug_buf, kind_label);
    return std.fmt.allocPrint(allocator, "act_{s}_{d}_{x}", .{ slug, now_seconds, salt });
}

pub fn statusTag(status: Status) []const u8 {
    return @tagName(status);
}

pub fn activityStateTag(status: Status, awaiting_host: bool) []const u8 {
    if (awaiting_host and status == .paused) return "awaiting_host";
    return @tagName(status);
}

pub fn freeHeardSpeech(allocator: std.mem.Allocator, heard_speech: input_mod.HeardSpeech) void {
    allocator.free(heard_speech.text);
    if (heard_speech.provider) |provider| allocator.free(provider);
    if (heard_speech.model_path) |model_path| allocator.free(model_path);
    if (heard_speech.audio_path) |audio_path| allocator.free(audio_path);
    if (heard_speech.raw_provider_json_path) |raw_path| allocator.free(raw_path);
    if (heard_speech.summary_json) |summary_json| allocator.free(summary_json);
}

pub fn freeTimelineEvent(allocator: std.mem.Allocator, event: TimelineEvent) void {
    allocator.free(event.title);
    allocator.free(event.body);
    if (event.source_event_id) |id| allocator.free(id);
}

pub fn freeCheckpoint(allocator: std.mem.Allocator, checkpoint: Checkpoint) void {
    allocator.free(checkpoint.anchor_text);
    allocator.free(checkpoint.observations);
    allocator.free(checkpoint.memory);
    allocator.free(checkpoint.spoken_text);
    freeHeardSpeech(allocator, checkpoint.heard_speech);
}

pub fn freeActive(allocator: std.mem.Allocator, active: Active) void {
    allocator.free(active.id);
    if (active.parent_id) |parent_id| allocator.free(parent_id);
    allocator.free(active.kind_label);
    allocator.free(active.goal);
    allocator.free(active.summary);
    allocator.free(active.originating_request_id);
    allocator.free(active.state.interpretation);
    if (active.state.focus_text) |text| allocator.free(text);
    if (active.state.stimulus_text) |text| allocator.free(text);
    if (active.state.last_spoken_text) |text| allocator.free(text);
    if (active.state.waiting_intent) |text| allocator.free(text);
    for (active.recent_candidate_actions) |candidate| {
        allocator.free(candidate.action);
        allocator.free(candidate.rationale);
    }
    allocator.free(active.recent_candidate_actions);
    if (active.awaiting) |awaiting| allocator.free(awaiting);
    for (active.timeline) |event| freeTimelineEvent(allocator, event);
    allocator.free(active.timeline);
    if (active.checkpoint) |checkpoint| freeCheckpoint(allocator, checkpoint);
}

pub fn freeViewExtras(allocator: std.mem.Allocator, view: View) void {
    for (view.open_loops) |loop| allocator.free(loop.description);
    allocator.free(view.open_loops);
    for (view.blockers) |blocker| allocator.free(blocker.description);
    allocator.free(view.blockers);
    for (view.candidate_actions) |candidate| {
        allocator.free(candidate.action);
        allocator.free(candidate.rationale);
    }
    allocator.free(view.candidate_actions);
}

test "activity id generation" {
    const id = try newId(std.testing.allocator, 100, "look", 42);
    defer std.testing.allocator.free(id);
    try std.testing.expect(std.mem.startsWith(u8, id, "act_look_100_"));
}
