const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const events = @import("events.zig");
const facts = @import("facts.zig");
const greeting = @import("greeting_policy.zig");
const identity = @import("identity.zig");
const interrupt_mod = @import("interrupt.zig");
const state_mod = @import("state.zig");
const schema = @import("../storage/schema.zig");
const store_mod = @import("../storage/store.zig");
const graph_store = @import("../storage/graph_store.zig");
const intent_mod = @import("../api/intent_client.zig");
const openai = @import("../api/openai_client.zig");
const greeting_client = @import("../api/greeting_client.zig");
const speech_mod = @import("../api/speech_client.zig");
const chat_mod = @import("../api/chat_client.zig");
const skills_mod = @import("../api/skills.zig");
const email_mod = @import("../api/email_client.zig");
const autonomy_mod = @import("../api/autonomy_client.zig");
const psyche_client = @import("../api/psyche_client.zig");
const want_achievement_mod = @import("../api/want_achievement_client.zig");
const image_mod = @import("../api/image_client.zig");
const audio_mod = @import("../api/audio_client.zig");
const camera_mod = @import("../platform/common/camera.zig");
const speaker_mod = @import("../platform/common/speaker.zig");
const input_mod = @import("../platform/common/input.zig");
const button_mod = @import("../platform/common/button.zig");
const command_log_mod = @import("../platform/common/command_log.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
const system_senses_mod = @import("../platform/common/system_senses.zig");
const time_mod = @import("time.zig");
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const seed_mod = @import("seed.zig");
const vector_index = @import("vector_index.zig");
const emotion = @import("emotion.zig");
const process = @import("../platform/common/process.zig");
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;
const BrainDeps = brain_mod.BrainDeps;
const CommandBatchResult = brain_mod.CommandBatchResult;
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
pub fn experienceExpiry(self: *Brain, retention: schema.ExperienceRetention) !?[]const u8 {
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
    const cutoff_ms = (self.now_seconds - speech_artifact_ttl_seconds) * 1000;
    var result = SpeechArtifactSweepResult{};
    var dir = try helpers.openDirPath(io, self.cfg.audio_input_dir);
    defer dir.close(io);
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const kind = helpers.speechArtifactKind(entry.name) orelse continue;
        const timestamp_ms = helpers.speechArtifactTimestampMs(entry.name) orelse return error.InvalidSpeechArtifactName;
        if (timestamp_ms > cutoff_ms) continue;
        try dir.deleteFile(io, entry.name);
        switch (kind) {
            .audio => result.audio_removed += 1,
            .transcription_json => result.transcription_json_removed += 1,
        }
    }
    return result;
}

pub fn createImpression(self: *Brain, source: schema.ImpressionSource, text: []const u8, tags: []const []const u8) !schema.Impression {
    const now = try time_mod.nowTimestamp(self.allocator);
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
    const now = try time_mod.nowTimestamp(self.allocator);
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
    const result = try self.deps.want_achievement_detector.detect(self.allocator, trimmed, candidates);
    var reinforced: usize = 0;
    for (result.matches) |match| {
        if (match.confidence < 0.72) continue;
        const want = helpers.findSelfWantById(memories, match.memory_id) orelse return error.UnknownWantAchievementMemoryId;
        try reinforceAchievedWant(self, want, match, trimmed);
        reinforced += 1;
    }
    return reinforced;
}

pub fn reinforceAchievedWant(self: *Brain, want: schema.MemoryRecord, match: want_achievement_mod.WantAchievementMatch, event_text: []const u8) !void {
    const now = try time_mod.nowTimestamp(self.allocator);
    const strength = helpers.wantReinforcementStrength(want);
    const existing_appraisals = try self.deps.store.loadAppraisals(self.allocator);
    const tags = try helpers.cloneConstStringSlice(self.allocator, &[_][]const u8{ "self_model", "self_want", "want_achievement", "positive_reinforcement", "flexible_identity" });
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
        .action_tendency = try self.allocator.dupe(u8, "integrate achievement and reconsider self-definition"),
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
    try self.recordRuntimeEvent(.{
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
    try self.deps.store.saveMemoryRecord(memory);
    try self.recordRuntimeEvent(.{
        .kind = .memory_mutation,
        .source = "memory",
        .title = "thought",
        .body = memory.interpretation,
        .command = "think_about",
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
    try self.deps.store.saveMemoryRecord(memory);
    try self.recordRuntimeEvent(.{
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
    };
    if (!helpers.tagInSlice(existing.tags, required_tag)) return error.SelfDefinitionKindMismatch;

    const directive_tags = try helpers.selfDirectiveTags(self.allocator, kind, tags);
    const now = try time_mod.nowTimestamp(self.allocator);
    var updated = existing;
    updated.text = try self.allocator.dupe(u8, trimmed_text);
    updated.interpretation = try std.fmt.allocPrint(self.allocator, "self-defined {s}: {s}", .{ @tagName(kind), trimmed_text });
    updated.vector = try vector_index.embedQuery(self.allocator, trimmed_text, directive_tags);
    updated.confidence = @max(existing.confidence, 0.78);
    updated.salience = @max(existing.salience, emotion.estimateSalience(trimmed_text, directive_tags));
    updated.tags = directive_tags;
    updated.score = @max(existing.score, 5);
    updated.scope = .long_term;
    updated.revisions = try helpers.appendRevision(self.allocator, existing.revisions, .{
        .time = now,
        .text = try std.fmt.allocPrint(self.allocator, "edited self-defined {s}: {s}", .{ @tagName(kind), trimmed_text }),
        .confidence = updated.confidence,
    });
    try self.deps.store.saveMemoryRecord(updated);
    try self.recordRuntimeEvent(.{
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

pub fn chooseAttention(self: *Brain) ![]const u8 {
    if (currentStimulusAttention(self.current_stimulus_context, self.current_stimulus_seconds, self.now_seconds)) |intensity| {
        if (intensity >= 0.55) {
            return std.fmt.allocPrint(self.allocator, "attention:\n- priority: current_stimulus\n- target: {s}\n- reason: attention_intensity={d:.3}\n", .{ self.current_stimulus_context.?, intensity });
        }
    }
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const power = try self.deps.system_senses.power(self.allocator);
    const autonomy_state = try self.autonomyStateForNeeds();
    const active_needs = try needs_mod.evaluate(self.allocator, .{
        .now_seconds = self.now_seconds,
        .conversation_summaries = summaries,
        .memory_records = memories,
        .relationship_graph = try self.deps.graph.summary(self.allocator, 8),
        .power = power,
        .autonomy_energy_remaining = if (autonomy_state) |state| state.energy_remaining else null,
        .autonomy_daily_energy = self.cfg.autonomy_daily_energy,
        .autonomy_sleeping = if (autonomy_state) |state| state.sleeping else null,
    });
    for (active_needs) |need| {
        if (need.urgency == .urgent or need.urgency == .need) {
            return std.fmt.allocPrint(self.allocator, "attention:\n- priority: self_need\n- target: {s}\n- urgency: {s}\n- reason: {s}\n", .{ need.text, @tagName(need.urgency), need.evidence });
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
            return std.fmt.allocPrint(self.allocator, "attention:\n- priority: unresolved_appraisal\n- target: {s}\n- reason: uncertainty={d:.3} stress={d:.3}\n", .{ recent.query, recent.uncertainty, recent.stress });
        }
    }
    if (best_memory) |memory| {
        return std.fmt.allocPrint(self.allocator, "attention:\n- priority: salient_memory\n- target: {s}\n- reason: score={d} salience={d:.3}\n", .{ try self.memoryOneLineSummary(memory), memory.score, memory.salience });
    }
    return self.allocator.dupe(u8, "attention:\n- priority: curiosity\n- target: wait for the next human-driven interaction\n");
}

const current_stimulus_attention_ttl_seconds: i64 = 120;

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

pub fn askHuman(self: *Brain, text: []const u8) ![]const u8 {
    const impression = try createImpression(self, .self_reflection, text, &[_][]const u8{ "human", "help", "unresolved" });
    try self.deps.store.addImpression(impression);
    std.debug.print("\nBRAIN:\n{s}\n", .{text});
    try self.appendCommandLog("brain", "Brain", text);
    return std.fmt.allocPrint(self.allocator, "human_question:\n- text: {s}\n", .{text});
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
                .time = try time_mod.nowTimestamp(self.allocator),
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
    const results = try vector_index.search(self.allocator, memories, query, tags, 8);
    for (results) |result| {
        const memory = memories[result.memory_index];
        var updated = memory;
        if (updated.vector.len != vector_index.dimensions) {
            updated.vector = try vector_index.embedMemory(self.allocator, updated);
        }
        updated.access_count += 1;
        updated.score += 2;
        updated.last_accessed_at = try time_mod.nowTimestamp(self.allocator);
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

        const line = try std.fmt.allocPrint(self.allocator, "- {s}: {s} [{s}] scope={s} accessed={d} score={d} confidence={d:.3} salience={d:.3} vector_score={d:.3} similarity={d:.3}\n", .{
            updated.memory_id,
            helpers.memoryInterpretation(updated),
            try helpers.joinTags(self.allocator, updated.tags),
            @tagName(updated.scope),
            updated.access_count,
            updated.score,
            updated.confidence,
            updated.salience,
            result.score,
            result.similarity,
        });
        try out.appendSlice(self.allocator, line);
    }
    if (results.len == 0) try out.appendSlice(self.allocator, "- none\n");
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
    const line = try std.fmt.allocPrint(self.allocator, "- decayed={d} removed={d}\n", .{ decayed, removed });
    try out.appendSlice(self.allocator, line);
    return out.toOwnedSlice(self.allocator);
}

pub fn logSimple(self: *Brain, state: state_mod.BrainState, image: ?[]const u8, person_id: ?[]const u8, brain_text: ?[]const u8, update: []const u8) !void {
    _ = image;
    _ = person_id;
    const interpretation = brain_text orelse update;
    try self.recordRuntimeEvent(.{
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
