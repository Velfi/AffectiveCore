const std = @import("std");
const brain_mod = @import("brain.zig");
const brain_process = @import("brain_process.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const facts = @import("facts.zig");
const greeting = @import("greeting_policy.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const state_mod = @import("state.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const store_mod = ports.store;
const graph_store = ports.graph_store;
const openai = ports.openai;
const speech_mod = ports.speech;
const chat_mod = ports.chat;
const skills_mod = ports.skills;
const email_mod = ports.email;
const autonomy_mod = ports.autonomy;
const psyche_client = ports.psyche;
const want_achievement_mod = ports.want_achievement;
const image_mod = ports.image;
const audio_mod = ports.audio;
const camera_mod = ports.camera;
const speaker_mod = ports.speaker;
const input_mod = ports.input;
const button_mod = ports.button;
const event_log_mod = ports.event_log;
const facial_expression = ports.facial_expression;
const system_senses_mod = ports.system_senses;
const time_mod = @import("time.zig");
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const seed_mod = @import("seed.zig");
const vector_index = @import("vector_index.zig");
const emotion = @import("emotion.zig");
const process = ports.process;
const helpers = @import("brain_helpers.zig");
const llm_voice = @import("llm_voice.zig");
const context_composition = @import("context_composition.zig");
const experience_kinds = @import("experience_kinds.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
const ActionPressureBatchResult = brain_mod.ActionPressureBatchResult;
const ConversationTurnResult = brain_mod.ConversationTurnResult;
const ConversationSpeakerContext = brain_mod.Brain.ConversationSpeakerContext;
const QuietHours = brain_mod.Brain.QuietHours;
const SelfDirectiveKind = brain_mod.Brain.SelfDirectiveKind;
const SpeechArtifactSweepResult = brain_mod.SpeechArtifactSweepResult;
const MediaKind = helpers.MediaKind;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const speech_artifact_prefix = brain_mod.speech_artifact_prefix;
const speech_audio_suffix = brain_mod.speech_audio_suffix;
const speech_transcription_json_suffix = brain_mod.speech_transcription_json_suffix;
pub fn experienceExpiry(self: *Brain, retention: schema.MemoryExperienceRetention) !?[]const u8 {
    const seconds: ?i64 = switch (retention) {
        .raw_ephemeral => 7 * 86_400,
        .discard => 86_400,
        .summarize, .keep_episode, .keep_fact, .keep_disposition => null,
    };
    if (seconds) |delta| return try std.fmt.allocPrint(self.allocator, "{d}", .{self.now_seconds + delta});
    return null;
}

pub fn sweepSpeechArtifacts(self: *Brain) !SpeechArtifactSweepResult {
    if (self.cfg.audio_input_dir.len == 0) return error.MissingAudioInputDir;
    const io = self.deps.io orelse return error.MissingBrainIo;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const cutoff_ms = (self.now_seconds - speech_artifact_ttl_seconds) * 1000;
    const result = try fs.sweepSpeechArtifacts(io, .{
        .dir_path = self.cfg.audio_input_dir,
        .prefix = speech_artifact_prefix,
        .audio_suffix = speech_audio_suffix,
        .transcription_json_suffix = speech_transcription_json_suffix,
        .cutoff_ms = cutoff_ms,
    });
    return .{
        .audio_removed = result.audio_removed,
        .transcription_json_removed = result.transcription_json_removed,
    };
}

pub fn createImpression(self: *Brain, source: schema.ImpressionSource, text: []const u8, tags: []const []const u8) !schema.Impression {
    const now = try self.timestampNow();
    return .{
        .impression_id = try std.fmt.allocPrint(self.allocator, "impression_{d}_{d}_{s}", .{ self.now_seconds, text.len, @tagName(source) }),
        .source = source,
        .text = try self.allocator.dupe(u8, text),
        .tags = try helpers.cloneConstStringSlice(self.allocator, tags),
        .created_at = now,
        .salience = emotion.estimateSalience(text, tags),
    };
}

pub fn createAppraisal(self: *Brain, query: []const u8, impression_id: ?[]const u8, tags: []const []const u8) !schema.Appraisal {
    const now = try self.timestampNow();
    const signals = emotion.appraise(query);
    return .{
        .appraisal_id = try std.fmt.allocPrint(self.allocator, "appraisal_{d}_{d}", .{ self.now_seconds, query.len }),
        .impression_id = if (impression_id) |id| try self.allocator.dupe(u8, id) else null,
        .query = try self.allocator.dupe(u8, query),
        .valence = signals.valence,
        .arousal = signals.arousal,
        .confidence = signals.confidence,
        .uncertainty = signals.uncertainty,
        .social_warmth = signals.social_warmth,
        .curiosity = signals.curiosity,
        .stress = signals.stress,
        .feeling_label = signals.feeling_label,
        .action_tendency = signals.action_tendency,
        .expression = signals.expression,
        .dynamics = signals.dynamics,
        .freeform = try emotion.describe(self.allocator, query, signals),
        .tags = try helpers.cloneConstStringSlice(self.allocator, tags),
        .created_at = now,
    };
}

pub fn appraiseEvent(self: *Brain, text: []const u8, tags: []const []const u8) ![]const u8 {
    const impression = try createImpression(self, .self_reflection, text, tags);
    try self.deps.store.addImpression(impression);
    const appraisal = try createAppraisal(self, text, impression.impression_id, tags);
    try self.deps.store.addAppraisal(appraisal);
    return std.fmt.allocPrint(self.allocator, "appraisal:\n- valence: {d:.3}\n- arousal: {d:.3}\n- confidence: {d:.3}\n- uncertainty: {d:.3}\n- social_warmth: {d:.3}\n- curiosity: {d:.3}\n- stress: {d:.3}\n- feeling_label: {s}\n- action_tendency: {s}\n- expression: {s}\n- dynamics: {s}\n- freeform: {s}\n", .{
        appraisal.valence,
        appraisal.arousal,
        appraisal.confidence,
        appraisal.uncertainty,
        appraisal.social_warmth,
        appraisal.curiosity,
        appraisal.stress,
        appraisal.feeling_label,
        appraisal.action_tendency,
        appraisal.expression,
        appraisal.dynamics,
        appraisal.freeform,
    });
}

pub fn feelAbout(self: *Brain, query: []const u8, tags: []const []const u8) ![]const u8 {
    const appraisal = try createAppraisal(self, query, null, tags);
    try self.deps.store.addAppraisal(appraisal);
    return std.fmt.allocPrint(self.allocator, "feeling:\n- query: {s}\n- feeling_label: {s}\n- valence: {d:.3}\n- arousal: {d:.3}\n- confidence: {d:.3}\n- uncertainty: {d:.3}\n- action_tendency: {s}\n- expression: {s}\n- dynamics: {s}\n- freeform: {s}\n", .{
        query,
        appraisal.feeling_label,
        appraisal.valence,
        appraisal.arousal,
        appraisal.confidence,
        appraisal.uncertainty,
        appraisal.action_tendency,
        appraisal.expression,
        appraisal.dynamics,
        appraisal.freeform,
    });
}

pub fn detectWantAchievements(self: *Brain, event_text: []const u8) !usize {
    const trimmed = std.mem.trim(u8, event_text, " \r\n\t");
    if (trimmed.len == 0) return 0;
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const candidates = try helpers.wantAchievementCandidates(self.allocator, memories);
    if (candidates.len == 0) return 0;
    try self.traceContextComposition(context_composition.auditWantAchievement(trimmed, candidates));
    const result = try self.deps.want_achievement_detector.detect(self.allocator, trimmed, candidates);
    var reinforced: usize = 0;
    for (result.matches) |match| {
        if (match.confidence < 0.72) continue;
        const want = helpers.findSelfWantById(memories, match.memory_id) orelse continue;
        try reinforceAchievedWant(self, want, match, trimmed);
        reinforced += 1;
    }
    return reinforced;
}

pub fn reinforceAchievedWant(self: *Brain, want: schema.MemoryRecord, match: want_achievement_mod.WantAchievementMatch, event_text: []const u8) !void {
    const now = try self.timestampNow();
    const strength = helpers.wantReinforcementStrength(want);
    const existing_appraisals = try self.deps.store.loadAppraisals(self.allocator);
    const tags = try helpers.cloneConstStringSlice(self.allocator, &[_][]const u8{ "self_model", "self_want", "want_achievement", "positive_reinforcement", "flexible_identity" });
    const action_tendency_text = if (wantRelatesToInteractionSharing(want))
        try self.allocator.dupe(u8, "acknowledge achievement in speech when user is present")
    else
        try self.allocator.dupe(u8, "integrate achievement and reconsider self-definition");
    const appraisal = schema.Appraisal{
        .appraisal_id = try std.fmt.allocPrint(self.allocator, "appraisal_want_achievement_{d}_{d}_{s}", .{ self.now_seconds, existing_appraisals.len, want.memory_id }),
        .impression_id = null,
        .query = try std.fmt.allocPrint(self.allocator, "want achieved: {s}; evidence: {s}", .{ helpers.memoryInterpretation(want), match.evidence }),
        .valence = 0.35 + 0.50 * strength,
        .arousal = 0.25 + 0.45 * strength,
        .confidence = @max(0.75, match.confidence),
        .uncertainty = 1.0 - match.confidence,
        .social_warmth = 0.55,
        .curiosity = 0.40 + 0.35 * strength,
        .stress = 0.05,
        .feeling_label = try self.allocator.dupe(u8, "reinforced satisfaction"),
        .action_tendency = action_tendency_text,
        .expression = try self.allocator.dupe(u8, "open and warm"),
        .dynamics = try self.allocator.dupe(u8, "positive reinforcement opens a short flexible identity period until dream reconciliation"),
        .freeform = try std.fmt.allocPrint(self.allocator, "Achieving this want lands positively with reinforcement_strength={d:.3}; the brain should carry this into flexible identity dreaming. evidence={s}", .{ strength, match.evidence }),
        .tags = tags,
        .created_at = now,
    };
    try self.deps.store.addAppraisal(appraisal);

    var updated = want;
    updated.score += @intFromFloat(@ceil(1.0 + strength * 4.0));
    updated.access_count += 1;
    updated.last_accessed_at = now;
    updated.confidence = @min(1.0, @max(updated.confidence, match.confidence));
    updated.valence = @min(0.85, updated.valence + 0.10 + strength * 0.20);
    updated.revisions = try helpers.appendRevision(self.allocator, updated.revisions, .{
        .time = now,
        .text = try std.fmt.allocPrint(self.allocator, "achieved with reinforcement_strength={d:.3}; evidence: {s}", .{ strength, match.evidence }),
        .confidence = match.confidence,
    });
    try self.deps.store.saveMemoryRecord(updated);

    const pending_text = try std.fmt.allocPrint(self.allocator, "A want was achieved: {s}\nEvidence: {s}\nEvent: {s}\nReinforcement strength: {d:.3}\nThis should be reconciled as flexible identity material during the next dream.", .{
        helpers.memoryInterpretation(want),
        match.evidence,
        event_text,
        strength,
    });
    const existing_memories = try self.deps.store.loadMemoryRecords(self.allocator);
    var pending = try self.createMemoryRecord(pending_text, &[_][]const u8{ "want_achievement", "positive_reinforcement", "flexible_identity", "pending_dream_reconciliation", "self_model" });
    pending.memory_id = try std.fmt.allocPrint(self.allocator, "pending_want_achievement_{d}_{d}_{s}", .{ self.now_seconds, existing_memories.len, want.memory_id });
    pending.scope = .short_term;
    pending.score = @intFromFloat(@ceil(1.0 + strength * 4.0));
    pending.confidence = match.confidence;
    pending.salience = @min(1.0, 0.45 + strength * 0.50);
    pending.valence = 0.35 + strength * 0.45;
    pending.interpretation = try std.fmt.allocPrint(self.allocator, "pending flexible identity from achieved want {s}: {s}", .{ want.memory_id, match.evidence });
    try self.deps.store.saveMemoryRecord(pending);
    _ = try self.recordExperienceLogEvent(.{
        .kind = .memory_mutation,
        .source = "brain",
        .title = "want_achievement",
        .body = pending.interpretation,
        .subject = "want_achievement",
        .raw = pending_text,
        .interpretation = pending.interpretation,
        .experience_source = .brain,
        .experience_kind = .appraisal,
        .experience_retention = .keep_disposition,
        .derived_memory_ids = @constCast(&[_][]const u8{ pending.memory_id, want.memory_id }),
        .created_memory_id = pending.memory_id,
        .tags = pending.tags,
    });
}

fn wantRelatesToInteractionSharing(want: schema.MemoryRecord) bool {
    for (want.tags) |tag| {
        if (std.mem.eql(u8, tag, "express") or std.mem.eql(u8, tag, "share")) return true;
    }
    const text = helpers.memoryInterpretation(want);
    return std.mem.indexOf(u8, text, "share") != null
        or std.mem.indexOf(u8, text, "connect") != null
        or std.mem.indexOf(u8, text, "interact") != null
        or std.mem.indexOf(u8, text, "speak") != null
        or std.mem.indexOf(u8, text, "talk") != null;
}

pub fn thinkAbout(self: *Brain, query: []const u8, tags: []const []const u8) ![]const u8 {
    const topic = std.mem.trim(u8, query, " \r\n\t");
    if (topic.len == 0) return self.allocator.dupe(u8, "thought:\n- topic: none\n- next: choose a topic before reflecting\n");

    const recall = try recallMemories(self, topic, tags);
    const appraisal = try createAppraisal(self, topic, null, tags);
    try self.deps.store.addAppraisal(appraisal);
    const thought_text = try std.fmt.allocPrint(self.allocator, "I thought about {s}. {s}", .{ topic, appraisal.freeform });
    var memory = try self.createMemoryRecord(thought_text, if (tags.len > 0) tags else &[_][]const u8{ "thought", "reflection" });
    memory.score = 2;
    memory.confidence = appraisal.confidence;
    memory.salience = @max(0.35, appraisal.curiosity * 0.6 + appraisal.uncertainty * 0.3);
    memory.interpretation = try std.fmt.allocPrint(self.allocator, "reflection on {s}: {s}", .{ topic, appraisal.freeform });
    // TODO(memory-runtime-merge): remove direct memory writes once runtime candidate reconciliation is fully registered.
    try self.recordMemoryCandidateEvent(
        .memory_mutation,
        "memory",
        "memory.candidate",
        memory.interpretation,
        .brain,
        .memory_update,
        .keep_disposition,
        "thought",
        topic,
        memory.interpretation,
        &[_][]const u8{},
        memory.tags,
    );
    try self.deps.store.saveMemoryRecord(memory);
    _ = try self.recordExperienceLogEvent(.{
        .kind = .memory_mutation,
        .source = "memory",
        .title = "thought",
        .body = memory.interpretation,
        .action = "think_about",
        .subject = "thought",
        .raw = topic,
        .interpretation = memory.interpretation,
        .experience_source = .memory,
        .experience_kind = .memory_update,
        .experience_retention = .keep_disposition,
        .derived_memory_ids = @constCast(&[_][]const u8{memory.memory_id}),
        .created_memory_id = memory.memory_id,
        .tags = memory.tags,
    });
    return std.fmt.allocPrint(self.allocator, "thought:\n- topic: {s}\n- confidence: {d:.3}\n- uncertainty: {d:.3}\n- memory_saved: {s}\n- reflection: {s}\n{s}", .{
        topic,
        appraisal.confidence,
        appraisal.uncertainty,
        memory.memory_id,
        appraisal.freeform,
        recall,
    });
}

pub fn defineSelf(self: *Brain, kind: SelfDirectiveKind, text: []const u8, tags: []const []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return error.EmptySelfDefinition;
    const directive_tags = try helpers.selfDirectiveTags(self.allocator, kind, tags);
    const impression = try createImpression(self, .self_reflection, trimmed, directive_tags);
    try self.deps.store.addImpression(impression);
    const appraisal = try createAppraisal(self, trimmed, impression.impression_id, directive_tags);
    try self.deps.store.addAppraisal(appraisal);
    var memory = try self.createMemoryRecord(trimmed, directive_tags);
    memory.scope = .long_term;
    memory.score = 5;
    memory.confidence = @max(0.75, appraisal.confidence);
    memory.salience = @max(0.70, emotion.estimateSalience(trimmed, directive_tags));
    memory.interpretation = try std.fmt.allocPrint(self.allocator, "self-defined {s}: {s}", .{ @tagName(kind), trimmed });
    if (kind == .want) try helpers.assignWantFulfillmentCriterion(self.allocator, &memory);
    // TODO(memory-runtime-merge): remove direct memory writes once runtime candidate reconciliation is fully registered.
    try self.recordMemoryCandidateEvent(
        .memory_mutation,
        "brain",
        "memory.candidate",
        memory.interpretation,
        .brain,
        .self_definition,
        .keep_disposition,
        @tagName(kind),
        trimmed,
        memory.interpretation,
        &[_][]const u8{},
        memory.tags,
    );
    try self.deps.store.saveMemoryRecord(memory);
    _ = try self.recordExperienceLogEvent(.{
        .kind = .memory_mutation,
        .source = "brain",
        .title = @tagName(kind),
        .body = memory.interpretation,
        .subject = @tagName(kind),
        .raw = trimmed,
        .interpretation = memory.interpretation,
        .experience_source = .brain,
        .experience_kind = .self_definition,
        .experience_retention = .keep_disposition,
        .derived_memory_ids = @constCast(&[_][]const u8{memory.memory_id}),
        .created_memory_id = memory.memory_id,
        .tags = memory.tags,
    });
    return std.fmt.allocPrint(
        self.allocator,
        "self_definition:\n- kind: {s}\n- memory_saved: {s}\n- text: {s}\n- appraisal: {s}\n",
        .{ @tagName(kind), memory.memory_id, trimmed, appraisal.freeform },
    );
}

pub fn editSelf(self: *Brain, kind: SelfDirectiveKind, memory_id: []const u8, text: []const u8, tags: []const []const u8) ![]const u8 {
    const trimmed_id = std.mem.trim(u8, memory_id, " \r\n\t");
    if (trimmed_id.len == 0) return error.MissingSelfDefinitionMemoryId;
    const trimmed_text = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed_text.len == 0) return error.EmptySelfDefinition;

    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const existing = helpers.findMemoryById(memories, trimmed_id) orelse return error.SelfDefinitionNotFound;
    const required_tag = switch (kind) {
        .need => "self_need",
        .want => "self_want",
        .goal => "self_goal",
    };
    if (!helpers.tagInSlice(existing.tags, required_tag)) return error.SelfDefinitionKindMismatch;

    const directive_tags = try helpers.selfDirectiveTags(self.allocator, kind, tags);
    const now = try self.timestampNow();
    var updated = existing;
    updated.text = try self.allocator.dupe(u8, trimmed_text);
    updated.interpretation = try std.fmt.allocPrint(self.allocator, "self-defined {s}: {s}", .{ @tagName(kind), trimmed_text });
    updated.vector = try vector_index.embedQuery(self.allocator, self.deps.embedding_service, trimmed_text, directive_tags);
    updated.confidence = @max(existing.confidence, 0.78);
    updated.salience = @max(existing.salience, emotion.estimateSalience(trimmed_text, directive_tags));
    updated.tags = directive_tags;
    updated.score = @max(existing.score, 5);
    if (kind == .want) try helpers.assignWantFulfillmentCriterion(self.allocator, &updated);
    updated.scope = .long_term;
    updated.revisions = try helpers.appendRevision(self.allocator, existing.revisions, .{
        .time = now,
        .text = try std.fmt.allocPrint(self.allocator, "edited self-defined {s}: {s}", .{ @tagName(kind), trimmed_text }),
        .confidence = updated.confidence,
    });
    // TODO(memory-runtime-merge): remove direct memory writes once runtime candidate reconciliation is fully registered.
    try self.recordMemoryCandidateEvent(
        .memory_mutation,
        "brain",
        "memory.candidate",
        updated.interpretation,
        .brain,
        .self_definition,
        .keep_disposition,
        @tagName(kind),
        trimmed_text,
        updated.interpretation,
        &[_][]const u8{updated.memory_id},
        updated.tags,
    );
    try self.deps.store.saveMemoryRecord(updated);
    _ = try self.recordExperienceLogEvent(.{
        .kind = .memory_mutation,
        .source = "brain",
        .title = @tagName(kind),
        .body = updated.interpretation,
        .subject = @tagName(kind),
        .raw = trimmed_text,
        .interpretation = updated.interpretation,
        .experience_source = .brain,
        .experience_kind = .self_definition,
        .experience_retention = .keep_disposition,
        .derived_memory_ids = @constCast(&[_][]const u8{updated.memory_id}),
        .created_memory_id = updated.memory_id,
        .tags = updated.tags,
    });

    const impression = try createImpression(self, .self_reflection, trimmed_text, directive_tags);
    try self.deps.store.addImpression(impression);
    const appraisal = try createAppraisal(self, trimmed_text, impression.impression_id, directive_tags);
    try self.deps.store.addAppraisal(appraisal);

    return std.fmt.allocPrint(
        self.allocator,
        "self_definition_edited:\n- kind: {s}\n- memory_id: {s}\n- text: {s}\n- appraisal: {s}\n",
        .{ @tagName(kind), updated.memory_id, trimmed_text, appraisal.freeform },
    );
}

/// The strongest thing worth attending to right now, with the attention weight
/// the focus layer carries it at. Shared by the `choose_attention` skill (which
/// formats it) and `refreshFocus` (which holds it), so attention and focus are
/// one mechanism rather than two.
const DerivedFocus = struct {
    priority: []const u8,
    target: []const u8,
    detail: []const u8,
    base_attention: f32,
};

fn deriveTopPriority(self: *Brain) !DerivedFocus {
    if (currentStimulusAttention(self.current_stimulus_context, self.current_stimulus_seconds, self.now_seconds)) |intensity| {
        if (intensity >= 0.55) {
            return .{
                .priority = "current_stimulus",
                .target = self.current_stimulus_context.?,
                .detail = try std.fmt.allocPrint(self.allocator, "- reason: attention_intensity={d:.3}\n", .{intensity}),
                .base_attention = intensity,
            };
        }
    }
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const active_needs = try needs_mod.evaluate(self.allocator, .{
        .memory_records = memories,
    });
    defer needs_mod.freeNeeds(self.allocator, active_needs);
    for (active_needs) |need| {
        if (need.urgency == .urgent or need.urgency == .need) {
            return .{
                .priority = "self_need",
                .target = need.text,
                .detail = try std.fmt.allocPrint(self.allocator, "- urgency: {s}\n- reason: {s}\n", .{ @tagName(need.urgency), need.evidence }),
                .base_attention = if (need.urgency == .urgent) 0.75 else 0.62,
            };
        }
    }
    const appraisals = try self.deps.store.loadAppraisals(self.allocator);
    var best_memory: ?schema.MemoryRecord = null;
    for (memories) |memory| {
        if (best_memory == null or helpers.memoryIsMoreSalient(memory, best_memory.?)) best_memory = memory;
    }
    if (appraisals.len > 0) {
        const recent = appraisals[appraisals.len - 1];
        if (recent.stress >= 0.55 or recent.uncertainty > 0.65) {
            return .{
                .priority = "unresolved_appraisal",
                .target = recent.query,
                .detail = try std.fmt.allocPrint(self.allocator, "- reason: uncertainty={d:.3} stress={d:.3}\n", .{ recent.uncertainty, recent.stress }),
                .base_attention = @max(recent.stress, recent.uncertainty),
            };
        }
    }
    if (best_memory) |memory| {
        return .{
            .priority = "salient_memory",
            .target = try self.memoryOneLineSummary(memory),
            .detail = try std.fmt.allocPrint(self.allocator, "- reason: score={d} salience={d:.3}\n", .{ memory.score, memory.salience }),
            // Background salience is a weak focus: held, but not enough on its own
            // to flip the bot into focused mode (stays below focus_threshold).
            .base_attention = 0.40,
        };
    }
    return .{
        .priority = "curiosity",
        .target = "wait for the next human-driven interaction",
        .detail = "",
        .base_attention = 0.20,
    };
}

pub fn chooseAttention(self: *Brain) ![]const u8 {
    const derived = try deriveTopPriority(self);
    return std.fmt.allocPrint(
        self.allocator,
        "attention:\n- priority: {s}\n- target: {s}\n{s}",
        .{ derived.priority, derived.target, derived.detail },
    );
}

/// Promote the strongest current attention into a held, decaying focus.
pub fn deriveTopPriorityFocus(self: *Brain) !Brain.Focus {
    const derived = try deriveTopPriority(self);
    return .{
        .text = try self.allocator.dupe(u8, derived.target),
        .source = .derived,
        .set_at = self.now_seconds,
        .base_attention = derived.base_attention,
    };
}

pub fn setFocus(self: *Brain, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return error.EmptyFocus;
    self.current_focus = .{
        .text = try self.allocator.dupe(u8, trimmed),
        .source = .self_set,
        .set_at = self.now_seconds,
        .base_attention = self_set_focus_attention,
    };
    try self.appendEventLog("state", "set_focus", trimmed);
    brain_process.syncActivityContextFromBrain(self) catch |err| self.traceError("activity.sync_focus_failed", err);
    return std.fmt.allocPrint(self.allocator, "focus_set:\n- source: self_set\n- text: {s}\n", .{trimmed});
}

pub fn clearFocus(self: *Brain) ![]const u8 {
    self.current_focus = null;
    try self.appendEventLog("state", "clear_focus", "focus cleared");
    return self.allocator.dupe(u8, "focus_cleared\n");
}

/// Keep a still-fresh self-set plan (override wins until it decays); otherwise
/// derive the focus from the strongest current attention.
pub fn refreshFocus(self: *Brain) !void {
    if (self.current_focus) |focus| {
        if (focus.source == .self_set and currentFocusAttention(self.current_focus, self.now_seconds) != null) {
            return;
        }
    }
    self.current_focus = try deriveTopPriorityFocus(self);
}

pub fn focusMode(self: *Brain) Brain.FocusMode {
    const stimulus = currentStimulusAttention(self.current_stimulus_context, self.current_stimulus_seconds, self.now_seconds) orelse 0;
    const focus = currentFocusAttention(self.current_focus, self.now_seconds) orelse 0;
    return if (@max(stimulus, focus) >= focus_threshold) .focused else .unfocused;
}

const current_stimulus_attention_ttl_seconds: i64 = 120;
const current_focus_attention_ttl_seconds: i64 = current_stimulus_attention_ttl_seconds;
const focus_threshold: f32 = 0.55;
const self_set_focus_attention: f32 = 0.75;

/// Focus attention decays linearly to zero across the TTL, then clears (null),
/// mirroring currentStimulusAttention so working memory fades with age.
pub fn currentFocusAttention(focus: ?Brain.Focus, now_seconds: i64) ?f32 {
    const held = focus orelse return null;
    const age = now_seconds - held.set_at;
    if (age < 0 or age > current_focus_attention_ttl_seconds) return null;
    const ttl: f32 = @floatFromInt(current_focus_attention_ttl_seconds);
    const remaining = 1.0 - (@as(f32, @floatFromInt(age)) / ttl);
    return held.base_attention * remaining;
}

fn currentStimulusAttention(context: ?[]const u8, stimulus_seconds: ?i64, now_seconds: i64) ?f32 {
    const text = context orelse return null;
    const seen_at = stimulus_seconds orelse return null;
    if (now_seconds - seen_at > current_stimulus_attention_ttl_seconds) return null;
    const needle = "attention_intensity=";
    const start = std.mem.indexOf(u8, text, needle) orelse return null;
    const value_start = start + needle.len;
    var value_end = value_start;
    while (value_end < text.len) : (value_end += 1) {
        const ch = text[value_end];
        if (!((ch >= '0' and ch <= '9') or ch == '.')) break;
    }
    if (value_end == value_start) return null;
    return std.fmt.parseFloat(f32, text[value_start..value_end]) catch null;
}

pub fn consolidateMemory(self: *Brain) ![]const u8 {
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    var promoted: usize = 0;
    var decayed: usize = 0;
    var removed: usize = 0;
    var revised: usize = 0;
    for (memories) |memory| {
        var updated = memory;
        if (updated.scope == .short_term) {
            if (updated.score >= 5 or updated.salience >= 0.75 or updated.access_count >= 3) {
                updated.scope = .long_term;
                promoted += 1;
            } else {
                updated.score -= 1;
                updated.salience *= 0.92;
                decayed += 1;
            }
        }
        if (updated.access_count > 0 and updated.revisions.len == 0) {
            updated.revisions = try helpers.appendRevision(self.allocator, updated.revisions, .{
                .time = try self.timestampNow(),
                .text = try std.fmt.allocPrint(self.allocator, "recalled and stabilized: {s}", .{helpers.memoryInterpretation(updated)}),
                .confidence = updated.confidence,
            });
            revised += 1;
        }
        if (updated.scope == .short_term and updated.score <= 0 and updated.salience < 0.30) {
            _ = try self.deps.store.forgetMemoryRecord(updated.memory_id);
            removed += 1;
        } else {
            try self.deps.store.saveMemoryRecord(updated);
        }
    }
    return std.fmt.allocPrint(self.allocator, "memory_consolidation:\n- promoted={d}\n- decayed={d}\n- revised={d}\n- removed={d}\n", .{ promoted, decayed, revised, removed });
}

pub fn recallMemories(self: *Brain, query: []const u8, tags: []const []const u8) ![]const u8 {
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "memory_recall:\n");
    const results = try vector_index.search(self.allocator, self.deps.embedding_service, memories, query, tags, 8);
    const expected_dimensions = self.deps.embedding_service.dimensions();
    for (results) |result| {
        const memory = memories[result.memory_index];
        var updated = memory;
        if (updated.vector.len != expected_dimensions) {
            updated.vector = try vector_index.embedMemory(self.allocator, self.deps.embedding_service, updated);
        }
        updated.access_count += 1;
        updated.score += 2;
        updated.last_accessed_at = try self.timestampNow();
        updated.revisions = try helpers.appendRevision(self.allocator, updated.revisions, .{
            .time = updated.last_accessed_at.?,
            .text = try std.fmt.allocPrint(self.allocator, "recalled with query '{s}'", .{query}),
            .confidence = @min(1.0, updated.confidence + 0.03),
        });
        updated.confidence = @min(1.0, updated.confidence + 0.03);
        if (updated.scope == .short_term and (updated.access_count >= 3 or updated.score >= 5)) updated.scope = .long_term;
        try self.deps.store.saveMemoryRecord(updated);

        const impression = try createImpression(self, .recalled_memory, helpers.memoryInterpretation(updated), updated.tags);
        try self.deps.store.addImpression(impression);
        const recall_payload = try std.fmt.allocPrint(
            self.allocator,
            "memory_id={s}\nquery={s}\naccess_count={d}\nscope={s}",
            .{ updated.memory_id, query, updated.access_count, @tagName(updated.scope) },
        );
        _ = try self.recordSimpleExperienceEvent(experience_kinds.memory_recalled, .memory, recall_payload);

        const line = try llm_voice.formatSalientMemoryLine(self.allocator, helpers.memoryInterpretation(updated));
        defer self.allocator.free(line);
        try out.print(self.allocator, "- {s}\n", .{line});
    }
    if (results.len == 0) {
        try out.appendSlice(self.allocator, "- ");
        try out.appendSlice(self.allocator, llm_voice.empty_inner_state);
        try out.appendSlice(self.allocator, "\n");
    }
    return out.toOwnedSlice(self.allocator);
}

pub fn sweepShortTermMemories(self: *Brain) ![]const u8 {
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "memory_sweep:\n");
    var decayed: usize = 0;
    var removed: usize = 0;
    for (memories) |memory| {
        if (memory.scope != .short_term) continue;
        var updated = memory;
        updated.score -= 1;
        decayed += 1;
        if (updated.score <= 0) {
            _ = try self.deps.store.forgetMemoryRecord(updated.memory_id);
            removed += 1;
        } else {
            try self.deps.store.saveMemoryRecord(updated);
        }
    }
    try out.print(self.allocator, "- I let {d} short-term memories fade; {d} slipped away entirely.\n", .{ decayed, removed });
    return out.toOwnedSlice(self.allocator);
}

pub fn logSimple(self: *Brain, state: state_mod.BrainState, image: ?[]const u8, person_id: ?[]const u8, brain_text: ?[]const u8, update: []const u8) !void {
    _ = image;
    _ = person_id;
    const interpretation = brain_text orelse update;
    _ = try self.recordExperienceLogEvent(.{
        .kind = .state_change,
        .source = "brain",
        .title = state.jsonName(),
        .body = interpretation,
        .subject = state.jsonName(),
        .raw = update,
        .interpretation = interpretation,
        .experience_source = .brain,
        .experience_kind = .action,
        .experience_retention = .summarize,
        .tags = @constCast(&[_][]const u8{ "state", state.jsonName() }),
    });
}
