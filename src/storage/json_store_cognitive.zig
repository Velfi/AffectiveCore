const std = @import("std");
const schema = @import("schema.zig");

pub fn lifecycle(time: []const u8) schema.CognitiveLifecycle {
    return .{ .created_at = time, .updated_at = time };
}

pub fn parseTimestamp(text: []const u8) i64 {
    return std.fmt.parseInt(i64, text, 10) catch 0;
}

pub fn appendOne(comptime T: type, allocator: std.mem.Allocator, slice: []T, value: T) ![]T {
    var out = try allocator.alloc(T, slice.len + 1);
    @memcpy(out[0..slice.len], slice);
    out[slice.len] = value;
    return out;
}

pub fn removeAt(comptime T: type, allocator: std.mem.Allocator, slice: []T, index: usize) ![]T {
    var out = try allocator.alloc(T, slice.len - 1);
    if (index > 0) @memcpy(out[0..index], slice[0..index]);
    if (index + 1 < slice.len) @memcpy(out[index..], slice[index + 1 ..]);
    return out;
}

pub fn cloneString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try allocator.dupe(u8, value);
}

pub fn cloneNullableString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |v| return try cloneString(allocator, v);
    return null;
}

pub fn cloneStringSlice(allocator: std.mem.Allocator, value: [][]const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, value.len);
    for (value, 0..) |v, i| out[i] = try cloneString(allocator, v);
    return out;
}

pub fn cloneStringSliceConst(allocator: std.mem.Allocator, value: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, value.len);
    for (value, 0..) |v, i| out[i] = try cloneString(allocator, v);
    return out;
}

pub fn cloneFloatSlice(allocator: std.mem.Allocator, value: []f32) ![]f32 {
    const out = try allocator.alloc(f32, value.len);
    @memcpy(out, value);
    return out;
}

pub fn cloneMemoryRevisions(allocator: std.mem.Allocator, value: []schema.MemoryRevision) ![]schema.MemoryRevision {
    var out = try allocator.alloc(schema.MemoryRevision, value.len);
    for (value, 0..) |v, i| out[i] = .{
        .time = try cloneString(allocator, v.time),
        .text = try cloneString(allocator, v.text),
        .confidence = v.confidence,
    };
    return out;
}

pub fn cloneLifecycle(allocator: std.mem.Allocator, value: schema.CognitiveLifecycle) !schema.CognitiveLifecycle {
    return .{
        .status = value.status,
        .created_at = try cloneString(allocator, value.created_at),
        .updated_at = try cloneString(allocator, value.updated_at),
        .invalidated_at = try cloneNullableString(allocator, value.invalidated_at),
        .superseded_by_id = try cloneNullableString(allocator, value.superseded_by_id),
        .revisions = try cloneMemoryRevisions(allocator, value.revisions),
    };
}

pub fn cloneTrace(allocator: std.mem.Allocator, trace: schema.Trace) !schema.Trace {
    return .{
        .trace_id = try cloneString(allocator, trace.trace_id),
        .source = trace.source,
        .kind = trace.kind,
        .scope = trace.scope,
        .text = try cloneString(allocator, trace.text),
        .interpretation = try cloneString(allocator, if (trace.interpretation.len > 0) trace.interpretation else trace.text),
        .confidence = trace.confidence,
        .salience = trace.salience,
        .valence = trace.valence,
        .arousal = trace.arousal,
        .uncertainty = trace.uncertainty,
        .decay = trace.decay,
        .access_count = trace.access_count,
        .score = trace.score,
        .vector = try cloneFloatSlice(allocator, trace.vector),
        .tags = try cloneStringSlice(allocator, trace.tags),
        .linked_trace_ids = try cloneStringSlice(allocator, trace.linked_trace_ids),
        .linked_belief_ids = try cloneStringSlice(allocator, trace.linked_belief_ids),
        .artifact_ids = try cloneStringSlice(allocator, trace.artifact_ids),
        .lifecycle = try cloneLifecycle(allocator, trace.lifecycle),
    };
}

pub fn cloneBelief(allocator: std.mem.Allocator, belief: schema.Belief) !schema.Belief {
    return .{
        .belief_id = try cloneString(allocator, belief.belief_id),
        .key = try cloneString(allocator, belief.key),
        .proposition = try cloneString(allocator, belief.proposition),
        .confidence = belief.confidence,
        .salience = belief.salience,
        .valence = belief.valence,
        .evidence_trace_ids = try cloneStringSlice(allocator, belief.evidence_trace_ids),
        .contradiction_trace_ids = try cloneStringSlice(allocator, belief.contradiction_trace_ids),
        .tags = try cloneStringSlice(allocator, belief.tags),
        .lifecycle = try cloneLifecycle(allocator, belief.lifecycle),
    };
}

pub fn cloneEmbeddings(allocator: std.mem.Allocator, value: []schema.FaceEmbeddingRef) ![]schema.FaceEmbeddingRef {
    var out = try allocator.alloc(schema.FaceEmbeddingRef, value.len);
    for (value, 0..) |v, i| out[i] = .{
        .embedding_id = try cloneString(allocator, v.embedding_id),
        .quality_score = v.quality_score,
        .created_at = try cloneString(allocator, v.created_at),
        .source = v.source,
    };
    return out;
}

pub fn cloneSubject(allocator: std.mem.Allocator, subject: schema.Subject) !schema.Subject {
    return .{
        .subject_id = try cloneString(allocator, subject.subject_id),
        .display_name = try cloneString(allocator, subject.display_name),
        .relationship_status = subject.relationship_status,
        .greeting_style = subject.greeting_style,
        .trace_ids = try cloneStringSlice(allocator, subject.trace_ids),
        .belief_ids = try cloneStringSlice(allocator, subject.belief_ids),
        .artifact_ids = try cloneStringSlice(allocator, subject.artifact_ids),
        .embeddings = try cloneEmbeddings(allocator, subject.embeddings),
        .representative_artifact_id = try cloneNullableString(allocator, subject.representative_artifact_id),
        .representative_image_path = try cloneNullableString(allocator, subject.representative_image_path),
        .representative_quality_score = subject.representative_quality_score,
        .lifecycle = try cloneLifecycle(allocator, subject.lifecycle),
    };
}

pub fn cloneArtifact(allocator: std.mem.Allocator, artifact: schema.Artifact) !schema.Artifact {
    return .{
        .artifact_id = try cloneString(allocator, artifact.artifact_id),
        .kind = artifact.kind,
        .path = try cloneString(allocator, artifact.path),
        .mime_type = try cloneString(allocator, artifact.mime_type),
        .provenance = try cloneString(allocator, artifact.provenance),
        .retention = artifact.retention,
        .linked_trace_ids = try cloneStringSlice(allocator, artifact.linked_trace_ids),
        .lifecycle = try cloneLifecycle(allocator, artifact.lifecycle),
    };
}

pub fn cloneDream(allocator: std.mem.Allocator, dream: schema.Dream) !schema.Dream {
    return .{
        .dream_id = try cloneString(allocator, dream.dream_id),
        .selected_trace_ids = try cloneStringSlice(allocator, dream.selected_trace_ids),
        .belief_change_ids = try cloneStringSlice(allocator, dream.belief_change_ids),
        .generated_artifact_id = try cloneNullableString(allocator, dream.generated_artifact_id),
        .reflection = try cloneString(allocator, dream.reflection),
        .heat = dream.heat,
        .promoted_count = dream.promoted_count,
        .decayed_count = dream.decayed_count,
        .removed_count = dream.removed_count,
        .revised_belief_count = dream.revised_belief_count,
        .created_at = try cloneString(allocator, dream.created_at),
    };
}

pub fn cloneCognitiveFile(allocator: std.mem.Allocator, data: schema.CognitiveFile) !schema.CognitiveFile {
    var traces = try allocator.alloc(schema.Trace, data.traces.len);
    for (data.traces, 0..) |trace, i| traces[i] = try cloneTrace(allocator, trace);
    var beliefs = try allocator.alloc(schema.Belief, data.beliefs.len);
    for (data.beliefs, 0..) |belief, i| beliefs[i] = try cloneBelief(allocator, belief);
    var subjects = try allocator.alloc(schema.Subject, data.subjects.len);
    for (data.subjects, 0..) |subject, i| subjects[i] = try cloneSubject(allocator, subject);
    var artifacts = try allocator.alloc(schema.Artifact, data.artifacts.len);
    for (data.artifacts, 0..) |artifact, i| artifacts[i] = try cloneArtifact(allocator, artifact);
    var dreams = try allocator.alloc(schema.Dream, data.dreams.len);
    for (data.dreams, 0..) |dream, i| dreams[i] = try cloneDream(allocator, dream);
    return .{ .schema_version = data.schema_version, .traces = traces, .beliefs = beliefs, .subjects = subjects, .artifacts = artifacts, .dreams = dreams };
}

pub fn personToSubject(allocator: std.mem.Allocator, person: schema.Person) !schema.Subject {
    return .{
        .subject_id = try cloneString(allocator, person.person_id),
        .display_name = try cloneString(allocator, person.display_name),
        .relationship_status = person.relationship_status,
        .greeting_style = person.greeting_style,
        .embeddings = try cloneEmbeddings(allocator, person.embeddings),
        .representative_image_path = try cloneNullableString(allocator, person.representative_image_path),
        .representative_quality_score = person.representative_quality_score,
        .lifecycle = .{
            .status = if (person.relationship_status == .forgotten) .invalidated else .active,
            .created_at = try cloneString(allocator, person.created_at),
            .updated_at = try cloneString(allocator, person.last_seen_at orelse person.created_at),
            .invalidated_at = null,
        },
    };
}

pub fn subjectsToPeople(allocator: std.mem.Allocator, subjects: []const schema.Subject) ![]schema.Person {
    var out = try allocator.alloc(schema.Person, subjects.len);
    for (subjects, 0..) |subject, i| {
        out[i] = .{
            .person_id = try cloneString(allocator, subject.subject_id),
            .display_name = try cloneString(allocator, subject.display_name),
            .relationship_status = subject.relationship_status,
            .created_at = try cloneString(allocator, subject.lifecycle.created_at),
            .last_seen_at = try cloneString(allocator, subject.lifecycle.updated_at),
            .sighting_count = @intCast(subject.trace_ids.len),
            .greeting_style = subject.greeting_style,
            .stable_notes = try cloneStringSliceConst(allocator, &.{}),
            .recent_notes = &.{},
            .embeddings = try cloneEmbeddings(allocator, subject.embeddings),
            .representative_sighting_id = null,
            .representative_image_path = try cloneNullableString(allocator, subject.representative_image_path),
            .representative_quality_score = subject.representative_quality_score,
        };
    }
    return out;
}

pub fn memoryToTrace(allocator: std.mem.Allocator, memory: schema.MemoryRecord) !schema.Trace {
    return .{
        .trace_id = try cloneString(allocator, memory.memory_id),
        .source = .memory,
        .kind = .memory_update,
        .scope = if (memory.scope == .long_term) .long_term else .short_term,
        .text = try cloneString(allocator, memory.text),
        .interpretation = try cloneString(allocator, if (memory.interpretation.len > 0) memory.interpretation else memory.text),
        .confidence = memory.confidence,
        .salience = memory.salience,
        .valence = memory.valence,
        .decay = @max(0.0, @as(f32, @floatFromInt(memory.score)) / 5.0),
        .access_count = memory.access_count,
        .score = memory.score,
        .vector = try cloneFloatSlice(allocator, memory.vector),
        .tags = try cloneStringSlice(allocator, memory.tags),
        .lifecycle = .{
            .created_at = try cloneString(allocator, memory.created_at),
            .updated_at = try cloneString(allocator, memory.last_accessed_at orelse memory.created_at),
            .revisions = try cloneMemoryRevisions(allocator, memory.revisions),
        },
    };
}

pub fn traceToMemory(allocator: std.mem.Allocator, trace: schema.Trace) !schema.MemoryRecord {
    return .{
        .memory_id = try cloneString(allocator, trace.trace_id),
        .scope = if (trace.scope == .long_term) .long_term else .short_term,
        .text = try cloneString(allocator, trace.text),
        .original_text = try cloneString(allocator, trace.text),
        .interpretation = try cloneString(allocator, if (trace.interpretation.len > 0) trace.interpretation else trace.text),
        .vector = try cloneFloatSlice(allocator, trace.vector),
        .confidence = trace.confidence,
        .valence = trace.valence,
        .salience = trace.salience,
        .tags = try cloneStringSlice(allocator, trace.tags),
        .revisions = try cloneMemoryRevisions(allocator, trace.lifecycle.revisions),
        .created_at = try cloneString(allocator, trace.lifecycle.created_at),
        .last_accessed_at = try cloneString(allocator, trace.lifecycle.updated_at),
        .access_count = trace.access_count,
        .score = trace.score,
    };
}

pub fn tracesToMemories(allocator: std.mem.Allocator, traces: []const schema.Trace) ![]schema.MemoryRecord {
    var out = std.ArrayList(schema.MemoryRecord).empty;
    for (traces) |trace| {
        if (trace.lifecycle.status == .invalidated) continue;
        if (trace.lifecycle.status == .pending_deletion) continue;
        if (trace.kind == .summary or trace.kind == .appraisal) continue;
        try out.append(allocator, try traceToMemory(allocator, trace));
    }
    return out.toOwnedSlice(allocator);
}

pub fn factToBelief(allocator: std.mem.Allocator, fact: schema.FactRecord) !schema.Belief {
    return .{
        .belief_id = try cloneString(allocator, fact.fact_id),
        .key = try cloneString(allocator, fact.key),
        .proposition = try cloneString(allocator, fact.value),
        .confidence = fact.confidence,
        .tags = try cloneStringSlice(allocator, fact.tags),
        .lifecycle = .{
            .status = if (!fact.active) .invalidated else if (fact.confidence < 0.75) .doubted else .active,
            .created_at = try cloneString(allocator, fact.created_at),
            .updated_at = try cloneString(allocator, fact.updated_at),
            .invalidated_at = try cloneNullableString(allocator, fact.invalidated_at),
            .revisions = try cloneMemoryRevisions(allocator, fact.revisions),
        },
    };
}

pub fn beliefToFact(allocator: std.mem.Allocator, belief: schema.Belief) !schema.FactRecord {
    return .{
        .fact_id = try cloneString(allocator, belief.belief_id),
        .key = try cloneString(allocator, belief.key),
        .value = try cloneString(allocator, belief.proposition),
        .active = belief.lifecycle.status == .active or belief.lifecycle.status == .doubted,
        .confidence = belief.confidence,
        .source = "belief",
        .tags = try cloneStringSlice(allocator, belief.tags),
        .revisions = try cloneMemoryRevisions(allocator, belief.lifecycle.revisions),
        .created_at = try cloneString(allocator, belief.lifecycle.created_at),
        .updated_at = try cloneString(allocator, belief.lifecycle.updated_at),
        .invalidated_at = try cloneNullableString(allocator, belief.lifecycle.invalidated_at),
    };
}

pub fn beliefsToFacts(allocator: std.mem.Allocator, beliefs: []const schema.Belief) ![]schema.FactRecord {
    var out = try allocator.alloc(schema.FactRecord, beliefs.len);
    for (beliefs, 0..) |belief, i| out[i] = try beliefToFact(allocator, belief);
    return out;
}

pub fn sightingToTrace(allocator: std.mem.Allocator, sighting: schema.Sighting) !schema.Trace {
    const text = sighting.description orelse sighting.change_summary orelse "visual sighting";
    const trace_id = try cloneString(allocator, sighting.sighting_id);
    return .{
        .trace_id = trace_id,
        .source = .visual,
        .kind = .perception,
        .scope = .long_term,
        .text = try cloneString(allocator, text),
        .interpretation = try cloneString(allocator, sighting.change_summary orelse text),
        .confidence = sighting.confidence,
        .salience = @max(0.4, sighting.confidence),
        .tags = try cloneStringSliceConst(allocator, if (sighting.person_id != null) &[_][]const u8{ "sighting", "person" } else &[_][]const u8{"sighting"}),
        .artifact_ids = if (sighting.image_path != null) try cloneStringSliceConst(allocator, &[_][]const u8{trace_id}) else &.{},
        .lifecycle = lifecycle(try cloneString(allocator, sighting.seen_at)),
    };
}

pub fn imageArtifact(allocator: std.mem.Allocator, id: []const u8, path: []const u8, time: []const u8, trace_ids: []const []const u8) !schema.Artifact {
    return .{
        .artifact_id = try cloneString(allocator, id),
        .kind = .image,
        .path = try cloneString(allocator, path),
        .mime_type = "image/jpeg",
        .provenance = "camera",
        .linked_trace_ids = try cloneStringSliceConst(allocator, trace_ids),
        .lifecycle = lifecycle(try cloneString(allocator, time)),
    };
}

pub fn appraisalToTrace(allocator: std.mem.Allocator, appraisal: schema.Appraisal) !schema.Trace {
    return .{
        .trace_id = try cloneString(allocator, appraisal.appraisal_id),
        .source = .brain,
        .kind = .appraisal,
        .scope = .short_term,
        .text = try cloneString(allocator, appraisal.query),
        .interpretation = try cloneString(allocator, appraisal.freeform),
        .confidence = appraisal.confidence,
        .salience = @max(appraisal.curiosity, appraisal.stress),
        .valence = appraisal.valence,
        .arousal = appraisal.arousal,
        .uncertainty = appraisal.uncertainty,
        .tags = try cloneStringSlice(allocator, appraisal.tags),
        .lifecycle = lifecycle(try cloneString(allocator, appraisal.created_at)),
    };
}

pub fn traceToAppraisal(allocator: std.mem.Allocator, trace: schema.Trace) !schema.Appraisal {
    return .{
        .appraisal_id = try cloneString(allocator, trace.trace_id),
        .impression_id = null,
        .query = try cloneString(allocator, trace.text),
        .valence = trace.valence,
        .arousal = trace.arousal,
        .confidence = trace.confidence,
        .uncertainty = trace.uncertainty,
        .social_warmth = 0.5,
        .curiosity = trace.salience,
        .stress = @max(0, trace.uncertainty - 0.3),
        .feeling_label = "remembered",
        .action_tendency = "integrate",
        .expression = "quiet",
        .dynamics = "trace appraisal",
        .freeform = try cloneString(allocator, trace.interpretation),
        .tags = try cloneStringSlice(allocator, trace.tags),
        .created_at = try cloneString(allocator, trace.lifecycle.created_at),
    };
}

pub fn experienceToTrace(allocator: std.mem.Allocator, experience: schema.Experience) !schema.Trace {
    return .{
        .trace_id = try cloneString(allocator, experience.experience_id),
        .source = experienceSourceToTraceSource(experience.source),
        .kind = experienceKindToTraceKind(experience.kind),
        .scope = if (experience.retention == .keep_fact or experience.retention == .keep_disposition) .long_term else .short_term,
        .text = try cloneString(allocator, experience.raw),
        .interpretation = try cloneString(allocator, experience.interpretation),
        .confidence = experience.confidence,
        .salience = experience.salience,
        .valence = experience.valence,
        .tags = try cloneStringSlice(allocator, experience.tags),
        .linked_trace_ids = try cloneStringSlice(allocator, experience.related_experience_ids),
        .linked_belief_ids = try cloneStringSlice(allocator, experience.derived_memory_ids),
        .lifecycle = lifecycle(try cloneString(allocator, experience.time)),
    };
}

pub fn traceToExperience(allocator: std.mem.Allocator, trace: schema.Trace) !schema.Experience {
    return .{
        .experience_id = try cloneString(allocator, trace.trace_id),
        .time = try cloneString(allocator, trace.lifecycle.created_at),
        .source = .memory,
        .kind = .memory_update,
        .subject = try cloneString(allocator, @tagName(trace.kind)),
        .raw = try cloneString(allocator, trace.text),
        .interpretation = try cloneString(allocator, trace.interpretation),
        .confidence = trace.confidence,
        .salience = trace.salience,
        .valence = trace.valence,
        .retention = if (trace.scope == .long_term) .keep_fact else .raw_ephemeral,
        .derived_memory_ids = try cloneStringSlice(allocator, trace.linked_belief_ids),
        .related_experience_ids = try cloneStringSlice(allocator, trace.linked_trace_ids),
        .tags = try cloneStringSlice(allocator, trace.tags),
    };
}

pub fn experienceSourceToTraceSource(source: schema.ExperienceSource) schema.CognitiveTraceSource {
    return switch (source) {
        .human => .human,
        .brain => .brain,
        .environment => .environment,
        .model => .model,
        .maintenance => .maintenance,
        .autonomy => .autonomy,
        .memory => .memory,
    };
}

pub fn impressionSourceToTraceSource(source: schema.ImpressionSource) schema.CognitiveTraceSource {
    return switch (source) {
        .user_speech => .human,
        .visual_observation => .visual,
        .reminder => .maintenance,
        .dream => .dream,
        .command_failure => .command,
        .recalled_memory, .self_reflection => .memory,
    };
}

pub fn experienceKindToTraceKind(kind: schema.ExperienceKind) schema.CognitiveTraceKind {
    return switch (kind) {
        .perception => .perception,
        .utterance => .utterance,
        .action => .action,
        .command_result => .command_result,
        .failure => .failure,
        .memory_update => .memory_update,
        .appraisal => .appraisal,
        .dream => .dream,
        .self_definition => .self_definition,
        .reminder => .reminder,
        .summary => .summary,
    };
}

pub fn collectCaptureReferences(allocator: std.mem.Allocator, referenced: *std.StringHashMap(void), captures_path: []const u8, data: schema.CognitiveFile) !void {
    for (data.subjects) |subject| if (subject.representative_image_path) |path| try putCaptureReference(allocator, referenced, captures_path, path);
    for (data.artifacts) |artifact| try putCaptureReference(allocator, referenced, captures_path, artifact.path);
    for (data.traces) |trace| {
        try putCaptureReference(allocator, referenced, captures_path, trace.text);
        try putCaptureReference(allocator, referenced, captures_path, trace.interpretation);
    }
}

pub fn putCaptureReference(allocator: std.mem.Allocator, referenced: *std.StringHashMap(void), captures_path: []const u8, path: []const u8) !void {
    if (!std.mem.startsWith(u8, path, captures_path)) return;
    if (path.len <= captures_path.len or path[captures_path.len] != '/') return;
    if (std.mem.indexOfScalar(u8, path[captures_path.len + 1 ..], '\n') != null) return;
    try referenced.put(try allocator.dupe(u8, path), {});
}
