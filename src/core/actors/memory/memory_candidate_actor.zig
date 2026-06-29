const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;
const ctx_mod = @import("context.zig");
const types = @import("types.zig");

pub const MemoryCandidateActor = struct {
    pub fn validate(candidate: types.MemoryCandidate) !void {
        if (candidate.key.len == 0) return error.MissingCandidateKey;
        if (candidate.proposition.len == 0) return error.MissingCandidateProposition;
        if (candidate.evidence.len == 0) return error.MissingCandidateEvidence;
        if (candidate.source_event_ids.len == 0) return error.MissingCandidateSourceEvents;
        if (candidate.confidence < 0 or candidate.confidence > 1) return error.InvalidCandidateConfidence;
        if (candidate.salience < 0 or candidate.salience > 1) return error.InvalidCandidateSalience;
    }

    pub fn receiveCandidate(context: *const ctx_mod.ActorContext, candidate: types.MemoryCandidate) !schema.MemoryRecord {
        try validate(candidate);
        const now = try context.timestampNow();
        const candidate_id = if (candidate.candidate_id.len > 0)
            candidate.candidate_id
        else
            try std.fmt.allocPrint(context.allocator, "memory_candidate_{d}_{s}", .{ context.now_seconds, candidate.key });
        const memory_id = try std.fmt.allocPrint(context.allocator, "candidate_{s}", .{candidate_id});
        const created: schema.MemoryRecord = .{
            .memory_id = memory_id,
            .status = .candidate,
            .source_event_ids = try context.cloneEventIds(candidate.source_event_ids),
            .scope = .short_term,
            .text = try context.allocator.dupe(u8, candidate.proposition),
            .original_text = try context.allocator.dupe(u8, candidate.evidence),
            .interpretation = try std.fmt.allocPrint(
                context.allocator,
                "memory.candidate {s} ({s})",
                .{ candidate.proposition, @tagName(candidate.kind) },
            ),
            .confidence = candidate.confidence,
            .salience = candidate.salience,
            .tags = try context.cloneEventIds(candidate.tags),
            .created_at = now,
            .last_accessed_at = null,
            .access_count = 0,
            .score = 1,
        };
        try context.store.saveMemoryRecord(created);
        return created;
    }

    pub fn receiveCandidateEvent(context: *const ctx_mod.ActorContext, event: schema.ExperienceEvent) !schema.MemoryRecord {
        if (!std.mem.eql(u8, event.kind, "memory.candidate")) return error.UnexpectedCandidateEventKind;
        if (event.payload.len == 0) return error.MissingCandidatePayload;
        const JsonCandidate = struct {
            candidate_id: []const u8 = "",
            key: []const u8 = "",
            proposition: []const u8 = "",
            evidence: []const u8 = "",
            kind: types.CandidateKind = .belief,
            confidence: f32 = 0.50,
            salience: f32 = 0.40,
            tags: []const []const u8 = &.{},
        };
        var parsed = try std.json.parseFromSlice(JsonCandidate, context.allocator, event.payload, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return receiveCandidate(context, .{
            .candidate_id = parsed.value.candidate_id,
            .key = parsed.value.key,
            .proposition = parsed.value.proposition,
            .evidence = parsed.value.evidence,
            .kind = parsed.value.kind,
            .confidence = parsed.value.confidence,
            .salience = parsed.value.salience,
            .source_event_ids = if (event.causal_parent_ids.len > 0) event.causal_parent_ids else &[_][]const u8{event.id},
            .tags = parsed.value.tags,
        });
    }

    pub fn candidateFromExperienceLog(
        context: *const ctx_mod.ActorContext,
        event: schema.ExperienceLogEvent,
        parents: []const []const u8,
    ) !?types.MemoryCandidate {
        const action = event.action orelse return null;
        if (action.len == 0) return null;
        if (!std.mem.eql(u8, action, "define_need") and
            !std.mem.eql(u8, action, "define_want") and
            !std.mem.eql(u8, action, "define_goal") and
            !std.mem.eql(u8, action, "edit_need") and
            !std.mem.eql(u8, action, "edit_want") and
            !std.mem.eql(u8, action, "edit_goal") and
            !std.mem.eql(u8, action, "set_fact") and
            !std.mem.eql(u8, action, "think_about"))
        {
            return null;
        }
        const key = if (event.subject.len > 0 and !std.mem.eql(u8, event.subject, action))
            event.subject
        else if (std.mem.startsWith(u8, action, "edit_"))
            action["edit_".len..]
        else if (std.mem.startsWith(u8, action, "define_"))
            action["define_".len..]
        else if (std.mem.eql(u8, action, "think_about"))
            "thought"
        else
            action;
        const proposition = if (event.interpretation.len > 0) event.interpretation else event.body;
        const evidence = if (event.raw.len > 0) event.raw else event.body;
        if (proposition.len == 0 or evidence.len == 0) return error.InvalidCandidateEventPayload;
        return .{
            .candidate_id = try std.fmt.allocPrint(context.allocator, "candidate_{d}_{s}", .{ context.now_seconds, key }),
            .key = key,
            .proposition = proposition,
            .evidence = evidence,
            .kind = switch (action[0]) {
                's' => .fact,
                else => .belief,
            },
            .confidence = if (event.confidence > 0) event.confidence else 0.62,
            .salience = 0.55,
            .source_event_ids = parents,
            .tags = event.tags,
        };
    }
};
