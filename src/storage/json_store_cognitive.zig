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
    if (slice.len > 0) allocator.free(slice);
    return out;
}

pub fn removeAt(comptime T: type, allocator: std.mem.Allocator, slice: []T, index: usize) ![]T {
    var out = try allocator.alloc(T, slice.len - 1);
    if (index > 0) @memcpy(out[0..index], slice[0..index]);
    if (index + 1 < slice.len) @memcpy(out[index..], slice[index + 1 ..]);
    if (slice.len > 0) allocator.free(slice);
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
        .pending_deletion_at = try cloneNullableString(allocator, value.pending_deletion_at),
        .pending_deletion_reason = try cloneNullableString(allocator, value.pending_deletion_reason),
        .pending_deletion_source = try cloneNullableString(allocator, value.pending_deletion_source),
        .revisions = try cloneMemoryRevisions(allocator, value.revisions),
    };
}

pub fn cloneBelief(allocator: std.mem.Allocator, belief: schema.Belief) !schema.Belief {
    return .{
        .belief_id = try cloneString(allocator, belief.belief_id),
        .evidence_event_ids = try cloneStringSlice(allocator, belief.evidence_event_ids),
        .counterevidence_event_ids = try cloneStringSlice(allocator, belief.counterevidence_event_ids),
        .context = try cloneString(allocator, belief.context),
        .decay = belief.decay,
        .provenance = try cloneString(allocator, belief.provenance),
        .key = try cloneString(allocator, belief.key),
        .proposition = try cloneString(allocator, belief.proposition),
        .confidence = belief.confidence,
        .salience = belief.salience,
        .valence = belief.valence,
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
        .source_event_ids = try cloneStringSlice(allocator, subject.source_event_ids),
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
        .source_event_ids = try cloneStringSlice(allocator, artifact.source_event_ids),
        .lifecycle = try cloneLifecycle(allocator, artifact.lifecycle),
    };
}

pub fn cloneExperienceEvent(allocator: std.mem.Allocator, event: schema.ExperienceEvent) !schema.ExperienceEvent {
    return .{
        .id = try cloneString(allocator, event.id),
        .brain_id = try cloneString(allocator, event.brain_id),
        .host_id = try cloneString(allocator, event.host_id),
        .timestamp_ms = event.timestamp_ms,
        .source = event.source,
        .kind = try cloneString(allocator, event.kind),
        .payload = try cloneString(allocator, event.payload),
        .salience = event.salience,
        .confidence = event.confidence,
        .valence = event.valence,
        .arousal = event.arousal,
        .uncertainty = event.uncertainty,
        .causal_parent_ids = try cloneStringSlice(allocator, event.causal_parent_ids),
        .retention = event.retention,
        .visibility = event.visibility,
    };
}

pub fn cloneHostBinding(allocator: std.mem.Allocator, binding: schema.HostBinding) !schema.HostBinding {
    return .{
        .host_id = try cloneString(allocator, binding.host_id),
        .platform = try cloneString(allocator, binding.platform),
        .app_version = try cloneString(allocator, binding.app_version),
        .attached_at_ms = binding.attached_at_ms,
        .permissions = try cloneStringSlice(allocator, binding.permissions),
        .capability_ids = try cloneStringSlice(allocator, binding.capability_ids),
        .provider_availability = try cloneString(allocator, binding.provider_availability),
        .sensor_quality = try cloneString(allocator, binding.sensor_quality),
        .local_policy = try cloneString(allocator, binding.local_policy),
    };
}

pub fn cloneCapabilityStatus(allocator: std.mem.Allocator, status: schema.CapabilityStatus) !schema.CapabilityStatus {
    return .{
        .capability_id = try cloneString(allocator, status.capability_id),
        .host_id = try cloneString(allocator, status.host_id),
        .permission = status.permission,
        .availability = status.availability,
        .quality = status.quality,
        .reliability = status.reliability,
        .cost = status.cost,
        .latency_ms = status.latency_ms,
        .risk = status.risk,
        .unavailable_reason = try cloneString(allocator, status.unavailable_reason),
        .updated_at_ms = status.updated_at_ms,
    };
}

pub fn cloneCapabilityRequest(allocator: std.mem.Allocator, request: schema.CapabilityRequest) !schema.CapabilityRequest {
    return .{
        .request_id = try cloneString(allocator, request.request_id),
        .capability_id = try cloneString(allocator, request.capability_id),
        .host_id = try cloneString(allocator, request.host_id),
        .state = request.state,
        .input = try cloneString(allocator, request.input),
        .causal_parent_ids = try cloneStringSlice(allocator, request.causal_parent_ids),
        .created_at_ms = request.created_at_ms,
    };
}

pub fn cloneCapabilityResult(allocator: std.mem.Allocator, result: schema.CapabilityResult) !schema.CapabilityResult {
    return .{
        .request_id = try cloneString(allocator, result.request_id),
        .capability_id = try cloneString(allocator, result.capability_id),
        .host_id = try cloneString(allocator, result.host_id),
        .state = result.state,
        .output = try cloneString(allocator, result.output),
        .error_message = try cloneString(allocator, result.error_message),
        .outcome_event_id = try cloneString(allocator, result.outcome_event_id),
        .pressure_id = try cloneString(allocator, result.pressure_id),
        .outcome_id = try cloneString(allocator, result.outcome_id),
        .completed_at_ms = result.completed_at_ms,
    };
}

pub fn cloneSelfTrustEntry(allocator: std.mem.Allocator, entry: schema.SelfTrustEntry) !schema.SelfTrustEntry {
    return .{
        .self_trust_id = try cloneString(allocator, entry.self_trust_id),
        .faculty = try cloneString(allocator, entry.faculty),
        .context_pattern = try cloneString(allocator, entry.context_pattern),
        .confidence = entry.confidence,
        .evidence_event_ids = try cloneStringSlice(allocator, entry.evidence_event_ids),
        .counterevidence_event_ids = try cloneStringSlice(allocator, entry.counterevidence_event_ids),
        .updated_at_ms = entry.updated_at_ms,
    };
}

pub fn cloneDisposition(allocator: std.mem.Allocator, disposition: schema.Disposition) !schema.Disposition {
    return .{
        .disposition_id = try cloneString(allocator, disposition.disposition_id),
        .context_pattern = try cloneString(allocator, disposition.context_pattern),
        .action_tendency = try cloneString(allocator, disposition.action_tendency),
        .strength = disposition.strength,
        .source_event_ids = try cloneStringSlice(allocator, disposition.source_event_ids),
        .source_dream_ids = try cloneStringSlice(allocator, disposition.source_dream_ids),
        .updated_at_ms = disposition.updated_at_ms,
    };
}

pub fn cloneActionPressure(allocator: std.mem.Allocator, pressure: schema.ActionPressure) !schema.ActionPressure {
    return .{
        .pressure_id = try cloneString(allocator, pressure.pressure_id),
        .subsystem = try cloneString(allocator, pressure.subsystem),
        .proposed_action = try cloneString(allocator, pressure.proposed_action),
        .capability_id = try cloneString(allocator, pressure.capability_id),
        .rationale = try cloneString(allocator, pressure.rationale),
        .strength = pressure.strength,
        .urgency = pressure.urgency,
        .valence = pressure.valence,
        .risk = pressure.risk,
        .causal_parent_ids = try cloneStringSlice(allocator, pressure.causal_parent_ids),
        .created_at_ms = pressure.created_at_ms,
        .expires_at_ms = pressure.expires_at_ms,
    };
}

pub fn cloneActionOutcome(allocator: std.mem.Allocator, outcome: schema.ActionOutcome) !schema.ActionOutcome {
    return .{
        .outcome_id = try cloneString(allocator, outcome.outcome_id),
        .pressure_id = try cloneString(allocator, outcome.pressure_id),
        .capability_request_id = try cloneString(allocator, outcome.capability_request_id),
        .capability_result_id = try cloneString(allocator, outcome.capability_result_id),
        .selected_action = try cloneString(allocator, outcome.selected_action),
        .suppressed = outcome.suppressed,
        .executed = outcome.executed,
        .result_event_id = try cloneString(allocator, outcome.result_event_id),
        .source_event_ids = try cloneStringSlice(allocator, outcome.source_event_ids),
        .prediction_error = outcome.prediction_error,
        .reinforcement_value = outcome.reinforcement_value,
        .created_at_ms = outcome.created_at_ms,
    };
}

pub fn cloneDreamImageSpec(allocator: std.mem.Allocator, spec: schema.DreamImageSpec) !schema.DreamImageSpec {
    return .{
        .subject = try cloneString(allocator, spec.subject),
        .setting = try cloneString(allocator, spec.setting),
        .symbols = try cloneStringSlice(allocator, spec.symbols),
        .mood = try cloneString(allocator, spec.mood),
        .visual_style = try cloneString(allocator, spec.visual_style),
        .avoid = try cloneStringSlice(allocator, spec.avoid),
    };
}

pub fn cloneDreamTimeRecord(allocator: std.mem.Allocator, dream: schema.DreamTimeRecord) !schema.DreamTimeRecord {
    return .{
        .dream_id = try cloneString(allocator, dream.dream_id),
        .source_event_ids = try cloneStringSlice(allocator, dream.source_event_ids),
        .source_memory_ids = try cloneStringSlice(allocator, dream.source_memory_ids),
        .updated_belief_ids = try cloneStringSlice(allocator, dream.updated_belief_ids),
        .self_trust_change_ids = try cloneStringSlice(allocator, dream.self_trust_change_ids),
        .disposition_change_ids = try cloneStringSlice(allocator, dream.disposition_change_ids),
        .maintenance_counts_json = try cloneString(allocator, dream.maintenance_counts_json),
        .generated_artifact_id = try cloneNullableString(allocator, dream.generated_artifact_id),
        .delivered_mailbox_id = try cloneNullableString(allocator, dream.delivered_mailbox_id),
        .title = try cloneString(allocator, dream.title),
        .text = try cloneString(allocator, dream.text),
        .waking_thought = try cloneString(allocator, dream.waking_thought),
        .persona = try cloneString(allocator, dream.persona),
        .short_term = try cloneString(allocator, dream.short_term),
        .long_term = try cloneString(allocator, dream.long_term),
        .image_spec = try cloneDreamImageSpec(allocator, dream.image_spec),
        .created_at_ms = dream.created_at_ms,
    };
}

pub fn cloneMailboxItem(allocator: std.mem.Allocator, item: schema.MailboxItem) !schema.MailboxItem {
    return .{
        .mailbox_id = try cloneString(allocator, item.mailbox_id),
        .kind = item.kind,
        .title = try cloneString(allocator, item.title),
        .text = try cloneString(allocator, item.text),
        .image_artifact_id = try cloneNullableString(allocator, item.image_artifact_id),
        .image_spec_json = try cloneString(allocator, item.image_spec_json),
        .waking_thought = try cloneString(allocator, item.waking_thought),
        .visible_lesson = try cloneString(allocator, item.visible_lesson),
        .debug_details = try cloneString(allocator, item.debug_details),
        .source_event_ids = try cloneStringSlice(allocator, item.source_event_ids),
        .source_dream_id = try cloneNullableString(allocator, item.source_dream_id),
        .created_at_ms = item.created_at_ms,
        .read_at_ms = item.read_at_ms,
    };
}

pub fn cloneIdentityHypothesis(allocator: std.mem.Allocator, hypothesis: schema.IdentityHypothesis) !schema.IdentityHypothesis {
    return .{
        .hypothesis_id = try cloneString(allocator, hypothesis.hypothesis_id),
        .decision = hypothesis.decision,
        .candidates_json = try cloneString(allocator, hypothesis.candidates_json),
        .evidence_event_ids = try cloneStringSlice(allocator, hypothesis.evidence_event_ids),
        .confidence = hypothesis.confidence,
        .contradictions = try cloneStringSlice(allocator, hypothesis.contradictions),
        .provenance = try cloneString(allocator, hypothesis.provenance),
        .created_at_ms = hypothesis.created_at_ms,
    };
}

pub fn cloneActivityTimelineEvent(allocator: std.mem.Allocator, event: schema.ActivityTimelineEvent) !schema.ActivityTimelineEvent {
    return .{
        .at_ms = event.at_ms,
        .kind = try cloneString(allocator, event.kind),
        .title = try cloneString(allocator, event.title),
        .body = try cloneString(allocator, event.body),
        .source_event_id = try cloneNullableString(allocator, event.source_event_id),
    };
}

pub fn cloneActivityCandidateAction(allocator: std.mem.Allocator, candidate: schema.ActivityCandidateAction) !schema.ActivityCandidateAction {
    return .{
        .action = try cloneString(allocator, candidate.action),
        .rationale = try cloneString(allocator, candidate.rationale),
        .strength = candidate.strength,
    };
}

pub fn cloneActivityCheckpoint(allocator: std.mem.Allocator, checkpoint: schema.ActivityCheckpoint) !schema.ActivityCheckpoint {
    return .{
        .anchor_text = try cloneString(allocator, checkpoint.anchor_text),
        .heard_speech_text = try cloneString(allocator, checkpoint.heard_speech_text),
        .heard_speech_source = try cloneString(allocator, checkpoint.heard_speech_source),
        .observations = try cloneString(allocator, checkpoint.observations),
        .memory = try cloneString(allocator, checkpoint.memory),
        .spoken_text = try cloneString(allocator, checkpoint.spoken_text),
        .paused_at_ms = checkpoint.paused_at_ms,
    };
}

pub fn cloneActivityRecord(allocator: std.mem.Allocator, record: schema.ActivityRecord) !schema.ActivityRecord {
    var timeline = try allocator.alloc(schema.ActivityTimelineEvent, record.timeline.len);
    for (record.timeline, 0..) |event, i| timeline[i] = try cloneActivityTimelineEvent(allocator, event);
    var candidate_actions = try allocator.alloc(schema.ActivityCandidateAction, record.candidate_actions.len);
    for (record.candidate_actions, 0..) |candidate, i| candidate_actions[i] = try cloneActivityCandidateAction(allocator, candidate);
    return .{
        .id = try cloneString(allocator, record.id),
        .parent_id = try cloneNullableString(allocator, record.parent_id),
        .kind = record.kind,
        .kind_label = try cloneString(allocator, record.kind_label),
        .status = record.status,
        .goal = try cloneString(allocator, record.goal),
        .summary = try cloneString(allocator, record.summary),
        .started_at_ms = record.started_at_ms,
        .updated_at_ms = record.updated_at_ms,
        .paused_at_ms = record.paused_at_ms,
        .completed_at_ms = record.completed_at_ms,
        .originating_request_id = try cloneString(allocator, record.originating_request_id),
        .interpretation = try cloneString(allocator, record.interpretation),
        .focus_text = try cloneNullableString(allocator, record.focus_text),
        .stimulus_text = try cloneNullableString(allocator, record.stimulus_text),
        .last_spoken_text = try cloneNullableString(allocator, record.last_spoken_text),
        .waiting_kind = try cloneNullableString(allocator, record.waiting_kind),
        .waiting_intent = try cloneNullableString(allocator, record.waiting_intent),
        .waiting_since_ms = record.waiting_since_ms,
        .awaiting = try cloneNullableString(allocator, record.awaiting),
        .timeline = timeline,
        .candidate_actions = candidate_actions,
        .checkpoint = if (record.checkpoint) |checkpoint| try cloneActivityCheckpoint(allocator, checkpoint) else null,
        .awaited_host_request_id = try cloneNullableString(allocator, record.awaited_host_request_id),
        .awaited_host_sense = try cloneNullableString(allocator, record.awaited_host_sense),
        .awaited_host_purpose = try cloneNullableString(allocator, record.awaited_host_purpose),
        .deferred_heard_speech_text = try cloneNullableString(allocator, record.deferred_heard_speech_text),
        .close_reason = try cloneNullableString(allocator, record.close_reason),
    };
}

pub fn freeActivityRecord(allocator: std.mem.Allocator, record: schema.ActivityRecord) void {
    allocator.free(record.id);
    if (record.parent_id) |parent| allocator.free(parent);
    allocator.free(record.kind_label);
    allocator.free(record.goal);
    allocator.free(record.summary);
    allocator.free(record.originating_request_id);
    allocator.free(record.interpretation);
    if (record.focus_text) |text| allocator.free(text);
    if (record.stimulus_text) |text| allocator.free(text);
    if (record.last_spoken_text) |text| allocator.free(text);
    if (record.waiting_kind) |text| allocator.free(text);
    if (record.waiting_intent) |text| allocator.free(text);
    if (record.awaiting) |text| allocator.free(text);
    if (record.awaited_host_request_id) |text| allocator.free(text);
    if (record.awaited_host_sense) |text| allocator.free(text);
    if (record.awaited_host_purpose) |text| allocator.free(text);
    if (record.deferred_heard_speech_text) |text| allocator.free(text);
    if (record.close_reason) |text| allocator.free(text);
    for (record.timeline) |event| {
        allocator.free(event.kind);
        allocator.free(event.title);
        allocator.free(event.body);
        if (event.source_event_id) |id| allocator.free(id);
    }
    allocator.free(record.timeline);
    for (record.candidate_actions) |candidate| {
        allocator.free(candidate.action);
        allocator.free(candidate.rationale);
    }
    allocator.free(record.candidate_actions);
    if (record.checkpoint) |checkpoint| {
        allocator.free(checkpoint.anchor_text);
        allocator.free(checkpoint.heard_speech_text);
        allocator.free(checkpoint.heard_speech_source);
        allocator.free(checkpoint.observations);
        allocator.free(checkpoint.memory);
        allocator.free(checkpoint.spoken_text);
    }
}

pub fn cloneCognitiveFile(allocator: std.mem.Allocator, data: schema.CognitiveFile) !schema.CognitiveFile {
    var events = try allocator.alloc(schema.ExperienceEvent, data.events.len);
    for (data.events, 0..) |event, i| events[i] = try cloneExperienceEvent(allocator, event);
    var host_bindings = try allocator.alloc(schema.HostBinding, data.host_bindings.len);
    for (data.host_bindings, 0..) |binding, i| host_bindings[i] = try cloneHostBinding(allocator, binding);
    var capability_statuses = try allocator.alloc(schema.CapabilityStatus, data.capability_statuses.len);
    for (data.capability_statuses, 0..) |status, i| capability_statuses[i] = try cloneCapabilityStatus(allocator, status);
    var capability_requests = try allocator.alloc(schema.CapabilityRequest, data.capability_requests.len);
    for (data.capability_requests, 0..) |request, i| capability_requests[i] = try cloneCapabilityRequest(allocator, request);
    var capability_results = try allocator.alloc(schema.CapabilityResult, data.capability_results.len);
    for (data.capability_results, 0..) |result, i| capability_results[i] = try cloneCapabilityResult(allocator, result);
    var self_trust = try allocator.alloc(schema.SelfTrustEntry, data.self_trust.len);
    for (data.self_trust, 0..) |entry, i| self_trust[i] = try cloneSelfTrustEntry(allocator, entry);
    var dispositions = try allocator.alloc(schema.Disposition, data.dispositions.len);
    for (data.dispositions, 0..) |disposition, i| dispositions[i] = try cloneDisposition(allocator, disposition);
    var action_pressures = try allocator.alloc(schema.ActionPressure, data.action_pressures.len);
    for (data.action_pressures, 0..) |pressure, i| action_pressures[i] = try cloneActionPressure(allocator, pressure);
    var action_outcomes = try allocator.alloc(schema.ActionOutcome, data.action_outcomes.len);
    for (data.action_outcomes, 0..) |outcome, i| action_outcomes[i] = try cloneActionOutcome(allocator, outcome);
    var dream_time_records = try allocator.alloc(schema.DreamTimeRecord, data.dream_time_records.len);
    for (data.dream_time_records, 0..) |dream, i| dream_time_records[i] = try cloneDreamTimeRecord(allocator, dream);
    var mailbox_items = try allocator.alloc(schema.MailboxItem, data.mailbox_items.len);
    for (data.mailbox_items, 0..) |item, i| mailbox_items[i] = try cloneMailboxItem(allocator, item);
    var identity_hypotheses = try allocator.alloc(schema.IdentityHypothesis, data.identity_hypotheses.len);
    for (data.identity_hypotheses, 0..) |hypothesis, i| identity_hypotheses[i] = try cloneIdentityHypothesis(allocator, hypothesis);
    var memories = try allocator.alloc(schema.MemoryRecord, data.memories.len);
    for (data.memories, 0..) |memory, i| memories[i] = try cloneMemoryRecord(allocator, memory);
    var impressions = try allocator.alloc(schema.Impression, data.impressions.len);
    for (data.impressions, 0..) |impression, i| impressions[i] = try cloneImpression(allocator, impression);
    var appraisals = try allocator.alloc(schema.Appraisal, data.appraisals.len);
    for (data.appraisals, 0..) |appraisal, i| appraisals[i] = try cloneAppraisal(allocator, appraisal);
    var conversation_summaries = try allocator.alloc(schema.ConversationSummary, data.conversation_summaries.len);
    for (data.conversation_summaries, 0..) |summary, i| conversation_summaries[i] = try cloneConversationSummary(allocator, summary);
    var sightings = try allocator.alloc(schema.Sighting, data.sightings.len);
    for (data.sightings, 0..) |sighting, i| sightings[i] = try cloneSighting(allocator, sighting);
    var beliefs = try allocator.alloc(schema.Belief, data.beliefs.len);
    for (data.beliefs, 0..) |belief, i| beliefs[i] = try cloneBelief(allocator, belief);
    var subjects = try allocator.alloc(schema.Subject, data.subjects.len);
    for (data.subjects, 0..) |subject, i| subjects[i] = try cloneSubject(allocator, subject);
    var artifacts = try allocator.alloc(schema.Artifact, data.artifacts.len);
    for (data.artifacts, 0..) |artifact, i| artifacts[i] = try cloneArtifact(allocator, artifact);
    const active_activity = if (data.active_activity) |record| try cloneActivityRecord(allocator, record) else null;
    var activity_history = try allocator.alloc(schema.ActivityRecord, data.activity_history.len);
    for (data.activity_history, 0..) |record, i| activity_history[i] = try cloneActivityRecord(allocator, record);
    var activity_stack = try allocator.alloc(schema.ActivityRecord, data.activity_stack.len);
    for (data.activity_stack, 0..) |record, i| activity_stack[i] = try cloneActivityRecord(allocator, record);
    return .{
        .brain_id = try cloneString(allocator, data.brain_id),
        .brain_mode = data.brain_mode,
        .events = events,
        .host_bindings = host_bindings,
        .capability_statuses = capability_statuses,
        .capability_requests = capability_requests,
        .capability_results = capability_results,
        .self_trust = self_trust,
        .dispositions = dispositions,
        .action_pressures = action_pressures,
        .action_outcomes = action_outcomes,
        .dream_time_records = dream_time_records,
        .mailbox_items = mailbox_items,
        .identity_hypotheses = identity_hypotheses,
        .memories = memories,
        .impressions = impressions,
        .appraisals = appraisals,
        .conversation_summaries = conversation_summaries,
        .sightings = sightings,
        .beliefs = beliefs,
        .subjects = subjects,
        .artifacts = artifacts,
        .active_activity = active_activity,
        .activity_stack = activity_stack,
        .activity_history = activity_history,
    };
}

pub fn cloneMemoryRecord(allocator: std.mem.Allocator, memory: schema.MemoryRecord) !schema.MemoryRecord {
    return .{
        .memory_id = try cloneString(allocator, memory.memory_id),
        .source_event_ids = try cloneStringSlice(allocator, memory.source_event_ids),
        .entities = try cloneStringSlice(allocator, memory.entities),
        .outcome = try cloneString(allocator, memory.outcome),
        .prediction_error = memory.prediction_error,
        .reinforcement_value = memory.reinforcement_value,
        .internal_synthesis = memory.internal_synthesis,
        .scope = memory.scope,
        .text = try cloneString(allocator, memory.text),
        .original_text = try cloneString(allocator, memory.original_text),
        .interpretation = try cloneString(allocator, memory.interpretation),
        .fulfillment_criterion = try cloneString(allocator, memory.fulfillment_criterion),
        .vector = try cloneFloatSlice(allocator, memory.vector),
        .confidence = memory.confidence,
        .valence = memory.valence,
        .salience = memory.salience,
        .tags = try cloneStringSlice(allocator, memory.tags),
        .revisions = try cloneMemoryRevisions(allocator, memory.revisions),
        .created_at = try cloneString(allocator, memory.created_at),
        .last_accessed_at = try cloneNullableString(allocator, memory.last_accessed_at),
        .access_count = memory.access_count,
        .score = memory.score,
    };
}

pub fn cloneImpression(allocator: std.mem.Allocator, impression: schema.Impression) !schema.Impression {
    return .{
        .impression_id = try cloneString(allocator, impression.impression_id),
        .source = impression.source,
        .text = try cloneString(allocator, impression.text),
        .tags = try cloneStringSlice(allocator, impression.tags),
        .created_at = try cloneString(allocator, impression.created_at),
        .salience = impression.salience,
    };
}

pub fn cloneAppraisal(allocator: std.mem.Allocator, appraisal: schema.Appraisal) !schema.Appraisal {
    return .{
        .appraisal_id = try cloneString(allocator, appraisal.appraisal_id),
        .impression_id = try cloneNullableString(allocator, appraisal.impression_id),
        .query = try cloneString(allocator, appraisal.query),
        .valence = appraisal.valence,
        .arousal = appraisal.arousal,
        .confidence = appraisal.confidence,
        .uncertainty = appraisal.uncertainty,
        .social_warmth = appraisal.social_warmth,
        .curiosity = appraisal.curiosity,
        .stress = appraisal.stress,
        .feeling_label = try cloneString(allocator, appraisal.feeling_label),
        .action_tendency = try cloneString(allocator, appraisal.action_tendency),
        .expression = try cloneString(allocator, appraisal.expression),
        .dynamics = try cloneString(allocator, appraisal.dynamics),
        .freeform = try cloneString(allocator, appraisal.freeform),
        .tags = try cloneStringSlice(allocator, appraisal.tags),
        .created_at = try cloneString(allocator, appraisal.created_at),
    };
}

pub fn cloneConversationSummary(allocator: std.mem.Allocator, summary: schema.ConversationSummary) !schema.ConversationSummary {
    return .{
        .summary_id = try cloneString(allocator, summary.summary_id),
        .time = try cloneString(allocator, summary.time),
        .user_summary = try cloneString(allocator, summary.user_summary),
        .brain_summary = try cloneString(allocator, summary.brain_summary),
    };
}

pub fn cloneSighting(allocator: std.mem.Allocator, sighting: schema.Sighting) !schema.Sighting {
    return .{
        .sighting_id = try cloneString(allocator, sighting.sighting_id),
        .person_id = try cloneNullableString(allocator, sighting.person_id),
        .seen_at = try cloneString(allocator, sighting.seen_at),
        .confidence = sighting.confidence,
        .image_path = try cloneNullableString(allocator, sighting.image_path),
        .description = try cloneNullableString(allocator, sighting.description),
        .change_summary = try cloneNullableString(allocator, sighting.change_summary),
        .retained_until = try cloneNullableString(allocator, sighting.retained_until),
        .source_event_ids = try cloneStringSlice(allocator, sighting.source_event_ids),
    };
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
            .sighting_count = @intCast(subject.source_event_ids.len),
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
    };
}

pub fn beliefsToFacts(allocator: std.mem.Allocator, beliefs: []const schema.Belief) ![]schema.FactRecord {
    var out = try allocator.alloc(schema.FactRecord, beliefs.len);
    for (beliefs, 0..) |belief, i| out[i] = try beliefToFact(allocator, belief);
    return out;
}

pub fn imageArtifact(allocator: std.mem.Allocator, id: []const u8, path: []const u8, time: []const u8, source_event_ids: []const []const u8) !schema.Artifact {
    return .{
        .artifact_id = try cloneString(allocator, id),
        .kind = .image,
        .path = try cloneString(allocator, path),
        .mime_type = "image/jpeg",
        .provenance = "camera",
        .source_event_ids = try cloneStringSliceConst(allocator, source_event_ids),
        .lifecycle = lifecycle(try cloneString(allocator, time)),
    };
}

pub fn collectCaptureReferences(allocator: std.mem.Allocator, referenced: *std.StringHashMap(void), captures_path: []const u8, data: schema.CognitiveFile) !void {
    for (data.subjects) |subject| if (subject.representative_image_path) |path| try putCaptureReference(allocator, referenced, captures_path, path);
    for (data.artifacts) |artifact| try putCaptureReference(allocator, referenced, captures_path, artifact.path);
    for (data.memories) |memory| {
        try putCaptureReference(allocator, referenced, captures_path, memory.text);
        try putCaptureReference(allocator, referenced, captures_path, memory.original_text);
    }
    for (data.sightings) |sighting| {
        if (sighting.image_path) |path| try putCaptureReference(allocator, referenced, captures_path, path);
        if (sighting.description) |description| try putCaptureReference(allocator, referenced, captures_path, description);
    }
}

pub fn putCaptureReference(allocator: std.mem.Allocator, referenced: *std.StringHashMap(void), captures_path: []const u8, path: []const u8) !void {
    if (!std.mem.startsWith(u8, path, captures_path)) return;
    if (path.len <= captures_path.len or path[captures_path.len] != '/') return;
    if (std.mem.indexOfScalar(u8, path[captures_path.len + 1 ..], '\n') != null) return;
    try referenced.put(try allocator.dupe(u8, path), {});
}
