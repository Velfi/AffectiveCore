const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;
const ctx_mod = @import("context.zig");
const types = @import("types.zig");
const candidate_actor = @import("memory_candidate_actor.zig").MemoryCandidateActor;

pub const MemoryReconciliationActor = struct {
    pub fn reconcileCandidate(context: *const ctx_mod.ActorContext, candidate: types.MemoryCandidate) !types.ReconciliationResult {
        try candidate_actor.validate(candidate);
        if (candidate.confidence < 0.35) {
            return .{ .action = .reject, .reason = "candidate confidence below threshold" };
        }
        const beliefs = try context.store.loadBeliefs(context.allocator);
        const now = try context.timestampNow();
        for (beliefs) |belief| {
            if (!std.mem.eql(u8, belief.key, candidate.key)) continue;
            return reconcileExisting(context, belief, candidate, now);
        }
        return createBelief(context, candidate, now);
    }

    fn createBelief(
        context: *const ctx_mod.ActorContext,
        candidate: types.MemoryCandidate,
        now: []const u8,
    ) !types.ReconciliationResult {
        const belief_id = if (candidate.candidate_id.len > 0)
            try std.fmt.allocPrint(context.allocator, "belief_{s}", .{candidate.candidate_id})
        else
            try std.fmt.allocPrint(context.allocator, "belief_{s}_{d}", .{ candidate.key, context.now_seconds });
        const belief: schema.Belief = .{
            .belief_id = belief_id,
            .key = try context.allocator.dupe(u8, candidate.key),
            .proposition = try context.allocator.dupe(u8, candidate.proposition),
            .confidence = candidate.confidence,
            .salience = candidate.salience,
            .provenance = "memory_reconciliation",
            .evidence_event_ids = try context.cloneEventIds(candidate.source_event_ids),
            .tags = try context.cloneEventIds(candidate.tags),
            .lifecycle = .{
                .status = if (candidate.confidence >= 0.80) .active else .doubted,
                .created_at = now,
                .updated_at = now,
            },
        };
        try context.store.upsertBelief(belief);
        return .{ .action = .create, .belief_id = belief_id, .reason = "created new belief from memory candidate" };
    }

    fn reconcileExisting(
        context: *const ctx_mod.ActorContext,
        belief: schema.Belief,
        candidate: types.MemoryCandidate,
        now: []const u8,
    ) !types.ReconciliationResult {
        var updated = belief;
        if (std.mem.eql(u8, belief.proposition, candidate.proposition)) {
            updated.confidence = @min(1.0, @max(updated.confidence, candidate.confidence) + 0.04);
            updated.evidence_event_ids = try mergeUniqueIds(context, updated.evidence_event_ids, candidate.source_event_ids);
            updated.lifecycle.updated_at = now;
            try context.store.upsertBelief(updated);
            return .{ .action = .reinforce, .belief_id = updated.belief_id, .reason = "reinforced matching proposition" };
        }

        const correction = types.hasTag(candidate.tags, "correction") or types.hasTag(candidate.tags, "correct");
        if (correction) {
            updated.lifecycle.revisions = try appendRevision(context, updated.lifecycle.revisions, now, updated.proposition, updated.confidence);
            updated.proposition = try context.allocator.dupe(u8, candidate.proposition);
            updated.confidence = @max(0.55, candidate.confidence);
            updated.lifecycle.status = .active;
            updated.lifecycle.updated_at = now;
            updated.evidence_event_ids = try mergeUniqueIds(context, updated.evidence_event_ids, candidate.source_event_ids);
            try context.store.upsertBelief(updated);
            return .{ .action = .correct, .belief_id = updated.belief_id, .reason = "corrected proposition and preserved revision history" };
        }

        if (candidate.confidence > belief.confidence + 0.15) {
            updated.lifecycle.revisions = try appendRevision(context, updated.lifecycle.revisions, now, updated.proposition, updated.confidence);
            updated.proposition = try context.allocator.dupe(u8, candidate.proposition);
            updated.confidence = candidate.confidence;
            updated.lifecycle.status = .doubted;
            updated.lifecycle.updated_at = now;
            updated.evidence_event_ids = try mergeUniqueIds(context, updated.evidence_event_ids, candidate.source_event_ids);
            try context.store.upsertBelief(updated);
            return .{ .action = .merge, .belief_id = updated.belief_id, .reason = "merged stronger conflicting candidate" };
        }

        updated.counterevidence_event_ids = try mergeUniqueIds(context, updated.counterevidence_event_ids, candidate.source_event_ids);
        updated.lifecycle.status = .doubted;
        updated.lifecycle.updated_at = now;
        try context.store.upsertBelief(updated);
        return .{ .action = .contradict, .belief_id = updated.belief_id, .reason = "candidate contradicts existing belief" };
    }

    fn mergeUniqueIds(
        context: *const ctx_mod.ActorContext,
        left: []const []const u8,
        right: []const []const u8,
    ) ![][]const u8 {
        var merged = std.ArrayList([]const u8).empty;
        for (left) |id| try merged.append(context.allocator, try context.allocator.dupe(u8, id));
        outer: for (right) |candidate| {
            for (merged.items) |existing| {
                if (std.mem.eql(u8, existing, candidate)) continue :outer;
            }
            try merged.append(context.allocator, try context.allocator.dupe(u8, candidate));
        }
        return merged.toOwnedSlice(context.allocator);
    }

    fn appendRevision(
        context: *const ctx_mod.ActorContext,
        revisions: []const schema.MemoryRevision,
        now: []const u8,
        prior_text: []const u8,
        prior_confidence: f32,
    ) ![]schema.MemoryRevision {
        var out = std.ArrayList(schema.MemoryRevision).empty;
        for (revisions) |revision| {
            try out.append(context.allocator, .{
                .time = try context.allocator.dupe(u8, revision.time),
                .text = try context.allocator.dupe(u8, revision.text),
                .confidence = revision.confidence,
            });
        }
        try out.append(context.allocator, .{
            .time = try context.allocator.dupe(u8, now),
            .text = try context.allocator.dupe(u8, prior_text),
            .confidence = prior_confidence,
        });
        return out.toOwnedSlice(context.allocator);
    }
};
