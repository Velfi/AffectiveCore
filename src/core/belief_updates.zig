const std = @import("std");
const brain_mod = @import("brain.zig");
const memory_actors = @import("actors/memory/mod.zig");
const experience_kinds = @import("experience_kinds.zig");
const learning = @import("learning.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;

fn cloneEventIds(allocator: std.mem.Allocator, parents: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, parents.len);
    for (parents, 0..) |parent, i| out[i] = try allocator.dupe(u8, parent);
    return out;
}

fn cloneTags(allocator: std.mem.Allocator, tags: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, tags.len);
    for (tags, 0..) |tag, i| out[i] = try allocator.dupe(u8, tag);
    return out;
}

pub fn onIdentityHypothesis(self: *Brain, hypothesis: schema.IdentityHypothesis, candidate_name: []const u8) !void {
    if (candidate_name.len == 0) return;
    const key = try std.fmt.allocPrint(self.allocator, "current_subject_is_{s}", .{candidate_name});
    const proposition = try std.fmt.allocPrint(
        self.allocator,
        "The current subject may be {s} (decision={s}, confidence={d:.2}).",
        .{ candidate_name, @tagName(hypothesis.decision), hypothesis.confidence },
    );
    const now_text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.now_seconds});
    const belief_id = try std.fmt.allocPrint(self.allocator, "belief_subject_{s}_{d}", .{ candidate_name, self.now_seconds });
    try upsertBeliefWithEvent(self, .{
        .belief_id = belief_id,
        .key = key,
        .proposition = proposition,
        .confidence = hypothesis.confidence,
        .salience = 0.70,
        .valence = 0.10,
        .evidence_event_ids = hypothesis.evidence_event_ids,
        .provenance = hypothesis.provenance,
        .tags = try cloneTags(self.allocator, &[_][]const u8{ "identity", "hypothesis" }),
        .lifecycle = .{
            .status = if (hypothesis.decision == .recognized) .active else .doubted,
            .created_at = now_text,
            .updated_at = now_text,
        },
    }, experience_kinds.belief_created);
}

pub fn onIdentityCorrection(self: *Brain, person_id: []const u8, corrected_name: []const u8, mistaken_hypothesis_event_id: []const u8) !void {
    const beliefs = try self.deps.store.loadBeliefs(self.allocator);
    const now_text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.now_seconds});
    const mistaken = try mistakenIdentityFromHypothesisEvent(self, mistaken_hypothesis_event_id);
    defer if (mistaken) |identity| {
        self.allocator.free(identity.name);
        if (identity.person_id.len > 0) self.allocator.free(identity.person_id);
    };

    for (beliefs) |belief| {
        if (belief.lifecycle.status == .invalidated or belief.lifecycle.status == .pending_deletion) continue;
        var should_invalidate = false;

        if (mistaken_hypothesis_event_id.len > 0) {
            for (belief.evidence_event_ids) |evidence_id| {
                if (std.mem.eql(u8, evidence_id, mistaken_hypothesis_event_id)) {
                    should_invalidate = true;
                    break;
                }
            }
        }

        if (!should_invalidate) {
            if (mistaken) |identity| {
                if (identity.name.len > 0) {
                    const mistaken_key = try std.fmt.allocPrint(self.allocator, "current_subject_is_{s}", .{identity.name});
                    defer self.allocator.free(mistaken_key);
                    if (std.mem.eql(u8, belief.key, mistaken_key)) should_invalidate = true;
                }
                if (!should_invalidate and identity.person_id.len > 0) {
                    for (belief.tags) |tag| {
                        if (std.mem.eql(u8, tag, identity.person_id)) {
                            should_invalidate = true;
                            break;
                        }
                    }
                }
            }
        }

        if (!should_invalidate) continue;
        _ = try self.recordSimpleExperienceEvent(experience_kinds.belief_contradicted, .user, belief.proposition);
        _ = try self.deps.store.invalidateBelief(belief.belief_id, now_text);
    }
    _ = person_id;
    _ = corrected_name;
}

const MistakenIdentity = struct {
    person_id: []const u8,
    name: []const u8,
};

fn mistakenIdentityFromHypothesisEvent(self: *Brain, hypothesis_event_id: []const u8) !?MistakenIdentity {
    if (hypothesis_event_id.len == 0) return null;
    const hypotheses = try self.deps.store.loadIdentityHypotheses(self.allocator);
    for (hypotheses) |hypothesis| {
        for (hypothesis.evidence_event_ids) |evidence_id| {
            if (!std.mem.eql(u8, evidence_id, hypothesis_event_id)) continue;
            return try firstCandidateFromHypothesis(self.allocator, hypothesis.candidates_json);
        }
    }
    return null;
}

fn firstCandidateFromHypothesis(allocator: std.mem.Allocator, candidates_json: []const u8) !?MistakenIdentity {
    const Candidate = struct { person_id: []const u8 = "", name: []const u8 = "" };
    var parsed = try std.json.parseFromSlice([]Candidate, allocator, candidates_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.len == 0) return null;
    const candidate = parsed.value[0];
    if (candidate.name.len == 0 and candidate.person_id.len == 0) return null;
    return .{
        .person_id = if (candidate.person_id.len > 0) try allocator.dupe(u8, candidate.person_id) else try allocator.dupe(u8, ""),
        .name = if (candidate.name.len > 0) try allocator.dupe(u8, candidate.name) else try allocator.dupe(u8, ""),
    };
}

pub fn onHostCapabilityChange(self: *Brain, status: schema.CapabilityStatus, prior: ?schema.CapabilityStatus, source_event_ids: []const []const u8) !void {
    const quality_delta = if (prior) |p| @abs(status.quality - p.quality) else status.quality;
    const reliability_delta = if (prior) |p| @abs(status.reliability - p.reliability) else status.reliability;
    if (quality_delta < 0.15 and reliability_delta < 0.15 and prior != null) return;

    const key = try std.fmt.allocPrint(self.allocator, "host_{s}_reliable", .{status.capability_id});
    const proposition = try std.fmt.allocPrint(
        self.allocator,
        "Host capability {s} is {s} (quality={d:.2}, reliability={d:.2}).",
        .{ status.capability_id, @tagName(status.availability), status.quality, status.reliability },
    );
    const now_text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.now_seconds});
    const belief_id = try std.fmt.allocPrint(self.allocator, "belief_host_{s}_{d}", .{ status.capability_id, self.now_seconds });
    try upsertBeliefWithEvent(self, .{
        .belief_id = belief_id,
        .key = key,
        .proposition = proposition,
        .confidence = status.reliability,
        .salience = 0.55,
        .valence = if (status.availability == .available) 0.20 else -0.20,
        .evidence_event_ids = try cloneEventIds(self.allocator, source_event_ids),
        .provenance = "host_binding",
        .tags = try cloneTags(self.allocator, &[_][]const u8{ "host", "capability" }),
        .lifecycle = .{
            .status = if (status.availability == .available) .active else .doubted,
            .created_at = now_text,
            .updated_at = now_text,
        },
    }, if (prior == null) experience_kinds.belief_created else experience_kinds.belief_updated);
}

pub fn onHostDetach(self: *Brain, host_id: []const u8) !void {
    const proposition = try std.fmt.allocPrint(self.allocator, "Host {s} detached; body capabilities may be unavailable.", .{host_id});
    const now_text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.now_seconds});
    try upsertBeliefWithEvent(self, .{
        .belief_id = try std.fmt.allocPrint(self.allocator, "belief_host_detached_{d}", .{self.now_seconds}),
        .key = "host_body_available",
        .proposition = proposition,
        .confidence = 0.90,
        .salience = 0.75,
        .valence = -0.30,
        .provenance = "host_binding",
        .tags = try cloneTags(self.allocator, &[_][]const u8{ "host", "detach" }),
        .lifecycle = .{
            .status = .doubted,
            .created_at = now_text,
            .updated_at = now_text,
        },
    }, experience_kinds.belief_updated);
}

pub fn onCapabilityFailurePattern(self: *Brain, faculty: []const u8, failure_count: usize, source_event_ids: []const []const u8) !void {
    if (failure_count == 0) return;
    const key = try std.fmt.allocPrint(self.allocator, "faculty_{s}_reliable", .{faculty});
    const proposition = try std.fmt.allocPrint(
        self.allocator,
        "Faculty {s} has {d} recent capability failures; reliability may be lower than assumed.",
        .{ faculty, failure_count },
    );
    const now_text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.now_seconds});
    try upsertBeliefWithEvent(self, .{
        .belief_id = try std.fmt.allocPrint(self.allocator, "belief_faculty_{s}_{d}", .{ faculty, self.now_seconds }),
        .key = key,
        .proposition = proposition,
        .confidence = @max(0.35, 1.0 - @as(f32, @floatFromInt(failure_count)) * 0.12),
        .salience = 0.60,
        .valence = -0.25,
        .counterevidence_event_ids = try cloneEventIds(self.allocator, source_event_ids),
        .provenance = "capability_learning",
        .tags = try cloneTags(self.allocator, &[_][]const u8{ "faculty", "capability_failure" }),
        .lifecycle = .{
            .status = .doubted,
            .created_at = now_text,
            .updated_at = now_text,
        },
    }, experience_kinds.belief_updated);
}

pub fn onDreamTimeBelief(self: *Brain, proposition: []const u8, source_event_ids: []const []const u8, confidence: f32) ![]const u8 {
    const now_text = try std.fmt.allocPrint(self.allocator, "{d}", .{self.now_seconds});
    const belief_id = try std.fmt.allocPrint(self.allocator, "belief_dream_uncertainty_{d}", .{self.now_seconds});
    try upsertBeliefWithEvent(self, .{
        .belief_id = belief_id,
        .key = "dream_time.integration",
        .proposition = proposition,
        .confidence = confidence,
        .salience = 0.62,
        .valence = 0.20,
        .evidence_event_ids = try cloneEventIds(self.allocator, source_event_ids),
        .provenance = "dream_time",
        .tags = try cloneTags(self.allocator, &[_][]const u8{ "dream_time", "uncertainty" }),
        .lifecycle = .{
            .status = .active,
            .created_at = now_text,
            .updated_at = now_text,
        },
    }, experience_kinds.belief_created);
    return belief_id;
}

fn upsertBeliefWithEvent(self: *Brain, belief: schema.Belief, event_kind: []const u8) !void {
    try self.deps.store.upsertBelief(belief);
    _ = try self.recordSimpleExperienceEvent(event_kind, .memory, belief.proposition);
}

pub fn countRecentCapabilityFailures(self: *Brain, capability_id: []const u8) !usize {
    const results = try self.deps.store.loadCapabilityResults(self.allocator);
    var count: usize = 0;
    for (results) |result| {
        if (!std.mem.eql(u8, result.capability_id, capability_id)) continue;
        if (result.state == .failed or result.state == .unavailable) count += 1;
    }
    return count;
}

pub fn facultyFailureBeliefUpdate(self: *Brain, capability_id: []const u8, source_event_ids: []const []const u8) !void {
    const faculty = learning.facultyForCapability(capability_id);
    const failures = try countRecentCapabilityFailures(self, capability_id);
    try onCapabilityFailurePattern(self, faculty, failures, source_event_ids);
}

pub fn reconcileMemoryCandidate(
    self: *Brain,
    candidate: memory_actors.types.MemoryCandidate,
) !memory_actors.types.ReconciliationResult {
    var actor_context: memory_actors.context.ActorContext = .{
        .allocator = self.allocator,
        .store = self.deps.store,
        .now_seconds = self.now_seconds,
        .brain_id = self.cfg.brain_id,
        .host_id = self.currentHostId(),
    };
    return memory_actors.MemoryReconciliationActor.reconcileCandidate(&actor_context, candidate);
}

pub fn auditBeliefProvenance(self: *Brain, belief_id: []const u8) ![]const u8 {
    return self.queryRuntimeMemoryAudit(belief_id);
}
