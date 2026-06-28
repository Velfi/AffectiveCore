const std = @import("std");
const brain_mod = @import("brain.zig");
const experience_kinds = @import("experience_kinds.zig");
const identity = @import("identity.zig");
const read_models = @import("read_models.zig");
const learning = @import("learning.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;

pub const CompositeResult = struct {
    result: identity.IdentityResult,
    hypothesis: schema.IdentityHypothesis,
    decision: schema.IdentityDecision,
    fused_confidence: f32,
    evidence: []schema.IdentityEvidence,
    explanation: []const u8,
};

pub fn recognizeSubject(self: *Brain, path: []const u8, parents: []const []const u8) !CompositeResult {
    const visual = try gatherVisualEvidence(self, path);
    const context = try gatherContextEvidence(self);
    const memory = try loadIdentityMemories(self);
    defer self.allocator.free(memory);

    const self_trust = try learning.selfTrustForFaculty(self, "recognition", context.context_pattern);
    const fused = try fuseCandidates(self, visual, context, memory, self_trust);
    const hypothesis = try emitIdentityHypothesis(self, path, fused, parents);

    return .{
        .result = fused.result,
        .hypothesis = hypothesis,
        .decision = hypothesis.decision,
        .fused_confidence = fused.confidence,
        .evidence = fused.evidence,
        .explanation = fused.explanation,
    };
}

const VisualBundle = struct {
    result: identity.IdentityResult,
    evidence: schema.IdentityEvidence,
};

const FusedRecognition = struct {
    result: identity.IdentityResult,
    decision: schema.IdentityDecision,
    confidence: f32,
    evidence: []schema.IdentityEvidence,
    explanation: []const u8,
};

const ContextEvidenceBundle = struct {
    context_pattern: []const u8,
    evidence: schema.IdentityEvidence,
    dim_context: bool,
};

fn gatherVisualEvidence(self: *Brain, path: []const u8) !VisualBundle {
    const result = try self.deps.recognizer.identify(self.allocator, path);
    self.outputRecognitionResult(result);
    const candidate_id = result.person_id orelse "";
    const explanation = try std.fmt.allocPrint(
        self.allocator,
        "visual recognizer: match={s} confidence={d:.2} people={d}",
        .{ @tagName(result.match_status), result.confidence, result.people_count },
    );
    const evidence_event = try self.recordSimpleExperienceEvent(experience_kinds.recognition_visual_evidence, .sense, explanation);
    return .{
        .result = result,
        .evidence = .{
            .strategy_id = "visual_recognizer",
            .candidate_person_id = try self.allocator.dupe(u8, candidate_id),
            .score = result.confidence,
            .confidence = result.confidence,
            .supports_identity = result.match_status == .known or result.match_status == .uncertain,
            .contradicts_identity = result.match_status == .none or result.match_status == .multiple,
            .explanation = explanation,
            .source_event_ids = try self.allocator.dupe([]const u8, &[_][]const u8{evidence_event.id}),
        },
    };
}

fn gatherContextEvidence(self: *Brain) !ContextEvidenceBundle {
    const snapshot = try read_models.readModelsSnapshot(self, self.allocator);
    const speaker = snapshot.conversation_context_model.active_speaker_label;
    const focus = snapshot.focus_model.text;
    const dim_light = snapshot.visual_state_model.last_observation_path == null;
    const context_pattern = if (dim_light)
        "dim or missing visual context"
    else if (speaker != null)
        "conversation with active speaker"
    else
        "ambient recognition context";

    const explanation = try std.fmt.allocPrint(
        self.allocator,
        "context: speaker={s} focus={s} dim_light={any}",
        .{ speaker orelse "none", focus orelse "none", dim_light },
    );
    const evidence_event = try self.recordSimpleExperienceEvent(experience_kinds.recognition_context_evidence, .subsystem, explanation);
    return .{
        .context_pattern = try self.allocator.dupe(u8, context_pattern),
        .dim_context = dim_light,
        .evidence = .{
            .strategy_id = "context",
            .score = if (speaker != null) 0.55 else 0.25,
            .confidence = if (speaker != null) 0.60 else 0.30,
            .supports_identity = speaker != null,
            .contradicts_identity = dim_light,
            .explanation = explanation,
            .source_event_ids = try self.allocator.dupe([]const u8, &[_][]const u8{evidence_event.id}),
        },
    };
}

fn loadIdentityMemories(self: *Brain) ![]schema.IdentityEvidence {
    var out = std.ArrayList(schema.IdentityEvidence).empty;
    const people = try self.deps.store.loadPeople(self.allocator);

    var count: usize = 0;
    for (people) |person| {
        if (person.relationship_status == .forgotten) continue;
        if (count >= 5) break;
        const explanation = try std.fmt.allocPrint(
            self.allocator,
            "memory recall: known person {s} sightings={d}",
            .{ person.display_name, person.sighting_count },
        );
        const evidence_event = try self.recordSimpleExperienceEvent(experience_kinds.recognition_memory_evidence, .memory, explanation);
        try out.append(self.allocator, .{
            .strategy_id = "memory_recall",
            .candidate_person_id = try self.allocator.dupe(u8, person.person_id),
            .score = @min(1.0, 0.40 + @as(f32, @floatFromInt(person.sighting_count)) * 0.05),
            .confidence = 0.55,
            .supports_identity = true,
            .explanation = explanation,
            .source_event_ids = try self.allocator.dupe([]const u8, &[_][]const u8{evidence_event.id}),
        });
        count += 1;
    }
    return try out.toOwnedSlice(self.allocator);
}

fn identityEvidenceConfidence(confidence: f32) f32 {
    return @min(1.0, @max(0.0, confidence));
}

fn fuseCandidates(
    self: *Brain,
    visual: VisualBundle,
    context: ContextEvidenceBundle,
    memory: []schema.IdentityEvidence,
    self_trust: f32,
) !FusedRecognition {
    const result = visual.result;
    const fused_confidence = identityEvidenceConfidence(result.confidence);

    const decision = decisionFromFused(result, fused_confidence, self_trust, context.dim_context);
    const explanation = try std.fmt.allocPrint(
        self.allocator,
        "identity confidence={d:.2} self_trust={d:.2} decision={s}; {s}",
        .{ fused_confidence, self_trust, @tagName(decision), visual.evidence.explanation },
    );

    var evidence = try self.allocator.alloc(schema.IdentityEvidence, 2 + memory.len);
    evidence[0] = visual.evidence;
    evidence[1] = context.evidence;
    @memcpy(evidence[2..], memory);

    return .{
        .result = result,
        .decision = decision,
        .confidence = fused_confidence,
        .evidence = evidence,
        .explanation = explanation,
    };
}

fn decisionFromFused(result: identity.IdentityResult, confidence: f32, self_trust: f32, dim_context: bool) schema.IdentityDecision {
    if (!result.person_present or result.match_status == .none) return .unknown;
    if (result.match_status == .multiple) return .conflict;
    if (self_trust < learning.identity_risk_trust_threshold or dim_context) {
        if (confidence >= 0.55) return .suspected;
        return .unknown;
    }
    return switch (result.match_status) {
        .known => if (confidence >= 0.70) .recognized else .soft_matched,
        .uncertain => .suspected,
        .unknown => .unknown,
        .multiple => .conflict,
        .none => .unknown,
    };
}

fn emitIdentityHypothesis(self: *Brain, path: []const u8, fused: FusedRecognition, parents: []const []const u8) !schema.IdentityHypothesis {
    var source_ids = std.ArrayList([]const u8).empty;
    for (parents) |parent| try source_ids.append(self.allocator, parent);
    for (fused.evidence) |item| {
        for (item.source_event_ids) |event_id| {
            if (!containsEventId(source_ids.items, event_id)) try source_ids.append(self.allocator, event_id);
        }
    }
    return self.recordIdentityHypothesis(path, fused.result, fused.decision, source_ids.items, fused.confidence);
}

fn containsEventId(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, expected)) return true;
    }
    return false;
}

test "low self trust yields uncertain decision path" {
    const decision = decisionFromFused(.{
        .person_present = true,
        .match_status = .known,
        .confidence = 0.90,
        .candidate_name = "Sam",
        .people_count = 1,
    }, 0.80, 0.30, true);
    try std.testing.expect(decision == .suspected or decision == .unknown);
}
