const std = @import("std");
const brain_mod = @import("brain.zig");
const emotion = @import("emotion.zig");
const memory_actors = @import("actors/memory/mod.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;

pub const ExperiencePipeline = struct {
    pub const record = recordExperienceEvent;
    pub const recordSimple = recordSimpleExperienceEvent;
    pub const recordExperienceLogMirror = recordExperienceLogMirrorEvent;
    pub const recordMemoryFormation = recordMemoryExperience;
};

pub fn timestampMs(self: *Brain) i64 {
    return self.now_seconds * 1000;
}

pub fn currentHostId(self: *Brain) []const u8 {
    const bindings = self.deps.store.loadHostBindings(self.allocator) catch return "core";
    if (bindings.len == 0) return "core";
    var newest = bindings[0];
    for (bindings[1..]) |binding| {
        if (binding.attached_at_ms >= newest.attached_at_ms) newest = binding;
    }
    return newest.host_id;
}

fn nextEventOrdinal(self: *Brain) usize {
    const events = self.deps.store.loadExperienceEvents(self.allocator) catch return 0;
    return events.len;
}

pub fn ensureHostBinding(self: *Brain, host_id: []const u8) !void {
    const bindings = self.deps.store.loadHostBindings(self.allocator) catch &.{};
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.host_id, host_id)) return;
    }
    try self.deps.store.upsertHostBinding(.{
        .host_id = try self.allocator.dupe(u8, host_id),
        .platform = if (std.mem.eql(u8, host_id, "core")) "core" else "unknown",
        .attached_at_ms = @max(timestampMs(self), 1),
        .local_policy = "brain_owned_state",
    });
}

pub fn makeEvent(self: *Brain, kind: []const u8, source: schema.ExperienceEventSource, payload: []const u8, parents: []const []const u8) !schema.ExperienceEvent {
    return .{
        .id = try std.fmt.allocPrint(self.allocator, "evt_{d}_{d}_{s}_{d}", .{ timestampMs(self), nextEventOrdinal(self), kind, payload.len }),
        .brain_id = self.cfg.brain_id,
        .host_id = try self.allocator.dupe(u8, currentHostId(self)),
        .timestamp_ms = timestampMs(self),
        .source = source,
        .kind = kind,
        .payload = payload,
        .causal_parent_ids = try cloneParents(self.allocator, parents),
        .retention = .episode,
        .visibility = .internal,
    };
}

pub fn recordExperienceEvent(self: *Brain, event: schema.ExperienceEvent) !void {
    try ensureHostBinding(self, event.host_id);
    try self.deps.store.addExperienceEvent(event);
    if (!std.mem.eql(u8, event.kind, "memory.candidate")) return;
    var actor_context: memory_actors.context.ActorContext = .{
        .allocator = self.allocator,
        .store = self.deps.store,
        .now_seconds = self.now_seconds,
        .brain_id = self.cfg.brain_id,
        .host_id = event.host_id,
    };
    _ = try memory_actors.MemoryIngestActor.ingest(&actor_context, event);
}

pub fn recordSimpleExperienceEvent(self: *Brain, kind: []const u8, source: schema.ExperienceEventSource, payload: []const u8) !schema.ExperienceEvent {
    const event = try makeEvent(self, kind, source, payload, &.{});
    try recordExperienceEvent(self, event);
    return event;
}

pub fn recordExperienceLogMirrorEvent(self: *Brain, event: schema.ExperienceLogEvent) !void {
    const payload = try std.json.Stringify.valueAlloc(self.allocator, event, .{ .whitespace = .minified });
    const experience_log_id = if (event.event_id.len > 0)
        event.event_id
    else
        try std.fmt.allocPrint(self.allocator, "experience_log_{d}_{d}_{s}", .{ timestampMs(self), nextEventOrdinal(self), @tagName(event.kind) });
    try recordExperienceEvent(self, .{
        .id = experience_log_id,
        .brain_id = self.cfg.brain_id,
        .host_id = try self.allocator.dupe(u8, currentHostId(self)),
        .timestamp_ms = timestampMs(self),
        .source = sourceFromExperienceLog(event),
        .kind = try std.fmt.allocPrint(self.allocator, "ExperienceLog.{s}", .{@tagName(event.kind)}),
        .payload = payload,
        .salience = salienceFromExperienceLog(event),
        .confidence = if (event.confidence > 0) event.confidence else 0.70,
        .valence = emotion.estimateValence(if (event.interpretation.len > 0) event.interpretation else payload),
        .arousal = 0.0,
        .uncertainty = if (event.confidence > 0) 1.0 - event.confidence else 0.30,
        .causal_parent_ids = try cloneParents(self.allocator, &.{}),
        .retention = retentionFromExperienceLog(event),
        .visibility = if (event.kind == .developer_log) .developer else .internal,
    });
}

pub fn recordMemoryExperience(
    self: *Brain,
    source: schema.MemoryExperienceSource,
    kind: schema.MemoryExperienceKind,
    subject: []const u8,
    raw: []const u8,
    interpretation: []const u8,
    retention: schema.MemoryExperienceRetention,
    derived_memory_ids: []const []const u8,
    tags: []const []const u8,
    parents: []const []const u8,
) ![]const u8 {
    const event_log = try self.deps.store.loadExperienceEvents(self.allocator);
    const experience_id = try std.fmt.allocPrint(self.allocator, "experience_event_{d}_{d}_{d}_{d}", .{ self.now_seconds, nextEventOrdinal(self), event_log.len, raw.len });
    const expires_at = try self.experienceExpiry(retention);
    const payload = try formatExperienceEventPayload(self, source, kind, subject, raw, interpretation, retention, expires_at, derived_memory_ids, tags);
    const event: schema.ExperienceEvent = .{
        .id = experience_id,
        .brain_id = try self.allocator.dupe(u8, self.cfg.brain_id),
        .host_id = try self.allocator.dupe(u8, currentHostId(self)),
        .timestamp_ms = timestampMs(self),
        .source = eventSourceFromMemoryExperienceSource(source),
        .kind = try std.fmt.allocPrint(self.allocator, "Memory.ExperienceRecorded.{s}", .{@tagName(kind)}),
        .payload = payload,
        .salience = emotion.estimateSalience(interpretation, tags),
        .confidence = 0.70,
        .valence = emotion.estimateValence(interpretation),
        .arousal = 0.0,
        .uncertainty = 0.30,
        .causal_parent_ids = try cloneParents(self.allocator, parents),
        .retention = eventRetentionFromMemoryExperienceRetention(retention),
        .visibility = .internal,
    };
    try recordExperienceEvent(self, event);
    return experience_id;
}

fn formatExperienceEventPayload(
    self: *Brain,
    source: schema.MemoryExperienceSource,
    kind: schema.MemoryExperienceKind,
    subject: []const u8,
    raw: []const u8,
    interpretation: []const u8,
    retention: schema.MemoryExperienceRetention,
    expires_at: ?[]const u8,
    derived_memory_ids: []const []const u8,
    tags: []const []const u8,
) ![]const u8 {
    return std.json.Stringify.valueAlloc(self.allocator, .{
        .source = @tagName(source),
        .kind = @tagName(kind),
        .subject = subject,
        .raw = raw,
        .interpretation = interpretation,
        .retention = @tagName(retention),
        .expires_at = expires_at,
        .derived_memory_ids = derived_memory_ids,
        .tags = tags,
    }, .{});
}

fn eventSourceFromMemoryExperienceSource(source: schema.MemoryExperienceSource) schema.ExperienceEventSource {
    return switch (source) {
        .human => .user,
        .brain, .model => .subsystem,
        .environment => .sense,
        .maintenance => .system,
        .autonomy => .autonomy,
        .memory => .memory,
    };
}

fn eventRetentionFromMemoryExperienceRetention(retention: schema.MemoryExperienceRetention) schema.ExperienceEventRetention {
    return switch (retention) {
        .raw_ephemeral => .ephemeral,
        .summarize, .keep_episode => .episode,
        .keep_fact => .durable,
        .keep_disposition => .disposition,
        .discard => .discard,
    };
}

fn sourceFromExperienceLog(event: schema.ExperienceLogEvent) schema.ExperienceEventSource {
    if (event.experience_source) |source| return switch (source) {
        .human => .user,
        .brain, .model => .subsystem,
        .environment => .sense,
        .maintenance => .system,
        .autonomy => .autonomy,
        .memory => .memory,
    };
    return switch (event.kind) {
        .user_utterance => .user,
        .observation, .perception => .sense,
        .capability_requested, .capability_result => .capability,
        .memory_mutation => .memory,
        .autonomy, .psyche => .autonomy,
        .system, .@"error" => .system,
        else => .subsystem,
    };
}

fn retentionFromExperienceLog(event: schema.ExperienceLogEvent) schema.ExperienceEventRetention {
    if (event.experience_retention) |retention| return switch (retention) {
        .raw_ephemeral => .ephemeral,
        .summarize, .keep_episode => .episode,
        .keep_fact => .durable,
        .keep_disposition => .disposition,
        .discard => .discard,
    };
    return switch (event.kind) {
        .developer_log => .ephemeral,
        .memory_mutation, .state_change => .durable,
        else => .episode,
    };
}

fn salienceFromExperienceLog(event: schema.ExperienceLogEvent) f32 {
    return switch (event.kind) {
        .@"error" => 0.85,
        .memory_mutation, .state_change => 0.70,
        .user_utterance, .brain_utterance => 0.55,
        else => 0.40,
    };
}

fn cloneParents(allocator: std.mem.Allocator, parents: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, parents.len);
    for (parents, 0..) |parent, i| out[i] = try allocator.dupe(u8, parent);
    return out;
}
