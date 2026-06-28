const std = @import("std");
const brain_mod = @import("brain.zig");
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
const intent_mod = ports.intent;
const openai = ports.openai;
const greeting_client = ports.greeting;
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
const experience_pipeline = @import("experience_pipeline.zig");
const experience_kinds = @import("experience_kinds.zig");
const experiential_observations = @import("experiential_observations.zig");
const context_composition = @import("context_composition.zig");
const memory_selection_mod = @import("memory_selection.zig");

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
pub fn dreamImagePrompt(allocator: std.mem.Allocator, style: []const u8, connection: []const u8, optional_text: ?[]const u8) ![]const u8 {
    const seed = if (optional_text) |text| std.mem.trim(u8, text, " \r\n\t") else "";
    if (seed.len > 0) {
        return std.fmt.allocPrint(
            allocator,
            "Create a {s} dream image for a small household robot. Visualize this dream seed: {s}. Blend these associated memories: {s}. No text, captions, UI, or labels in the image.",
            .{ style, seed, connection },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Create a {s} dream image for a small household robot. Blend these associated memories: {s}. No text, captions, UI, or labels in the image.",
        .{ style, connection },
    );
}

pub fn saveFlexibleIdentityReconciliation(self: *Brain, connection_text: []const u8, source_ids: []const []const u8, confidence: f32) ![]const u8 {
    const existing_memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const text = try std.fmt.allocPrint(
        self.allocator,
        "Dream reconciled flexible self-model material. The brain may revise what it wants, what kind of person it is, and what Superego principles it lives by, or may keep its current self-definition. Dream connection: {s}",
        .{connection_text},
    );
    var memory = try createMemoryRecord(self, text, &[_][]const u8{ "dream", "flexible_identity", "reconciled_want_achievement", "reconciled_self_model", "self_model" });
    memory.memory_id = try std.fmt.allocPrint(self.allocator, "reconciled_want_achievement_{d}_{d}_{d}", .{ self.now_seconds, existing_memories.len, source_ids.len });
    memory.scope = .long_term;
    memory.score = 5;
    memory.confidence = confidence;
    memory.salience = 0.75;
    memory.valence = 0.45;
    memory.interpretation = try std.fmt.allocPrint(self.allocator, "reconciled flexible self-model material: {s}", .{connection_text});
    try self.deps.store.saveMemoryRecord(memory);
    try self.recordExperienceLogEvent(.{
        .kind = .memory_mutation,
        .source = "brain",
        .title = "flexible_identity_reconciliation",
        .body = memory.interpretation,
        .subject = "flexible_identity_reconciliation",
        .raw = text,
        .interpretation = memory.interpretation,
        .experience_source = .brain,
        .experience_kind = .dream,
        .experience_retention = .keep_disposition,
        .derived_memory_ids = @constCast(&[_][]const u8{memory.memory_id}),
        .created_memory_id = memory.memory_id,
        .tags = memory.tags,
    });
    return memory.memory_id;
}

pub fn imagineImage(self: *Brain, prompt: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \r\n\t");
    if (trimmed.len == 0) return error.EmptyImagePrompt;
    const image = try self.deps.image_generation_service.generate(self.allocator, trimmed);
    return std.fmt.allocPrint(self.allocator, "imagined_image:\n- prompt: {s}\n- path: {s}\n- mime_type: {s}\n", .{ trimmed, image.path, image.mime_type });
}

const MaintenanceCapabilityKind = enum {
    sweep_memory,
    consolidate_memory,
    request_dream_time,
    end_conversation,
    speech,
};

const MaintenanceCapability = struct {
    kind: MaintenanceCapabilityKind,
    spec: []const u8,
    text: ?[]const u8 = null,
};

fn parseMaintenanceCapability(spec: []const u8) !MaintenanceCapability {
    const trimmed = std.mem.trim(u8, spec, " \r\n\t");
    if (std.mem.eql(u8, trimmed, "sweep_memory")) return .{ .kind = .sweep_memory, .spec = trimmed };
    if (std.mem.eql(u8, trimmed, "consolidate_memory")) return .{ .kind = .consolidate_memory, .spec = trimmed };
    if (std.mem.eql(u8, trimmed, "request_dream_time")) return .{ .kind = .request_dream_time, .spec = trimmed };
    if (std.mem.startsWith(u8, trimmed, "request_dream_time:")) {
        return .{
            .kind = .request_dream_time,
            .spec = trimmed,
            .text = std.mem.trim(u8, trimmed["request_dream_time:".len..], " \t"),
        };
    }
    if (std.mem.eql(u8, trimmed, "end_conversation")) return .{ .kind = .end_conversation, .spec = trimmed };
    if (std.mem.startsWith(u8, trimmed, "say:")) {
        return .{
            .kind = .speech,
            .spec = trimmed,
            .text = std.mem.trim(u8, trimmed["say:".len..], " \t"),
        };
    }
    return error.UnknownMaintenanceCapability;
}

pub fn maintenanceSpeechText(spec: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, spec, " \r\n\t");
    if (!std.mem.startsWith(u8, trimmed, "say:")) return null;
    const text = std.mem.trim(u8, trimmed["say:".len..], " \t");
    if (text.len == 0) return null;
    return text;
}

pub fn runMaintenanceCapability(self: *Brain, capability_spec: []const u8) !void {
    const capability = try parseMaintenanceCapability(capability_spec);
    try self.logMaintenanceCapabilityRequested(capability.spec);
    switch (capability.kind) {
        .sweep_memory => {
            _ = try self.sweepShortTermMemories();
            const removed = try self.deps.store.sweepExpiredExperiences(self.now_seconds);
            const speech_removed = try self.sweepSpeechArtifacts();
            const now = try self.timestampNow();
            const cognitive_prune = try self.deps.store.pruneTombstonedCognitiveRecords(now);
            const captures_purged = try self.deps.store.sweepUnreferencedCaptures();
            const result = try std.fmt.allocPrint(
                self.allocator,
                "swept short-term memories; expired_experiences_removed={d}; speech_artifacts_removed={d} audio={d} transcription_json={d}; cognitive_tombstoned={d}; cognitive_purged={d}; captures_purged={d}",
                .{ removed, speech_removed.total(), speech_removed.audio_removed, speech_removed.transcription_json_removed, cognitive_prune.tombstoned, cognitive_prune.purged, captures_purged },
            );
            try self.logMaintenanceCapabilityResult(capability.spec, result);
        },
        .consolidate_memory => {
            _ = try self.consolidateMemory();
            try self.logMaintenanceCapabilityResult(capability.spec, "consolidated memory");
        },
        .request_dream_time => {
            const item = try self.requestDreamTime(capability.text);
            const result = try std.fmt.allocPrint(self.allocator, "dream_time_delivered:{s}", .{item.mailbox_id});
            try self.logMaintenanceCapabilityResult(capability.spec, result);
        },
        .end_conversation => {
            self.conversation_speaker_context = null;
            self.last_conversation_turn_seconds = null;
            try self.logMaintenanceCapabilityResult(capability.spec, "conversation context cleared");
        },
        .speech => {
            const text = capability.text orelse return error.EmptyMaintenanceSpeech;
            self.outputFmt("\nBRAIN REMINDER:\n{s}\n", .{text});
            try self.say(text);
            try self.logMaintenanceCapabilityResult(capability.spec, text);
        },
    }
}

/// Lead the context with the bot's working memory. When focused (high attention
/// or an active plan) the focus is prominent; otherwise a single low-key line
/// signals the bot is open rather than fixed on anything.
fn appendFocusBlock(self: *Brain, out: *std.ArrayList(u8)) !void {
    if (self.focusMode() == .focused) {
        if (self.current_focus) |focus| {
            const level = self.currentFocusAttention() orelse focus.base_attention;
            try out.print(
                self.allocator,
                "CURRENT FOCUS: {s}\n- source: {s}\n- attention: {d:.3}\n\n",
                .{ focus.text, @tagName(focus.source), level },
            );
            return;
        }
    }
    try out.appendSlice(self.allocator, "focus: unfocused — open to whatever comes; no strong focus right now.\n");
}

pub fn buildConversationMemory(self: *Brain) ![]const u8 {
    return buildConversationMemoryWithSpeaker(self, null, null, null);
}

pub fn buildConversationMemoryWithSpeaker(
    self: *Brain,
    speaker_context: ?[]const u8,
    sections_out: ?*std.ArrayList(context_composition.SectionStat),
    selection: ?memory_selection_mod.ResolvedMemorySelection,
) ![]const u8 {
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    var out = std.ArrayList(u8).empty;
    var before: usize = 0;

    before = out.items.len;
    try appendFocusBlock(self, &out);
    try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "focus", null);

    if (speaker_context) |context| {
        before = out.items.len;
        try out.appendSlice(self.allocator, context);
        try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "speaker", null);
    }

    before = out.items.len;
    try out.appendSlice(self.allocator, try self.selfFactsConversationSummary());
    try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "self_facts", null);

    before = out.items.len;
    try out.appendSlice(self.allocator, try self.deps.graph.summary(self.allocator, 8));
    try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "relationship_graph", null);

    before = out.items.len;
    try out.appendSlice(self.allocator, try self.activeNeedsSummary());
    try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "needs", null);

    before = out.items.len;
    try experiential_observations.appendDayArcToMemory(self, &out);
    try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "day_arc", null);

    if (selection) |resolved| {
        before = out.items.len;
        try memory_selection_mod.appendMemorySelectionToMemory(self.allocator, &out, resolved);
        try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "relevant_memories", resolved.entries.len);
    }

    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    var prng = std.Random.DefaultPrng.init(helpers.contextShuffleSeed(self.now_seconds, summaries.len));
    if (memories.len > 0) {
        before = out.items.len;
        var long_count: usize = 0;
        var short_count: usize = 0;
        for (memories) |memory| {
            switch (memory.scope) {
                .long_term => long_count += 1,
                .short_term => short_count += 1,
            }
        }
        try out.print(self.allocator, "Memory index: {d} long-term, {d} short-term. Use typed memory read models and explicit recall events when details are needed.\n", .{ long_count, short_count });
        var memory_tags = std.ArrayList([]const u8).empty;
        for (memories) |memory| {
            for (memory.tags) |tag| {
                if (memory_tags.items.len >= 32 or helpers.tagInSlice(memory_tags.items, tag)) continue;
                try memory_tags.append(self.allocator, tag);
            }
        }
        prng.random().shuffle([]const u8, memory_tags.items);
        try out.appendSlice(self.allocator, "Available memory tags:");
        for (memory_tags.items) |tag| {
            try out.print(self.allocator, " {s}", .{tag});
        }
        try out.appendSlice(self.allocator, "\n");
        try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "memory_index", memories.len);
    }

    if (summaries.len == 0) return out.toOwnedSlice(self.allocator);

    before = out.items.len;
    try out.appendSlice(self.allocator, "Recent conversation summaries (chronological):\n");
    const summary_window = self.cfg.capacity.conversation_summaries_in_context_max;
    const start = if (summaries.len > summary_window) summaries.len - summary_window else 0;
    for (summaries[start..]) |summary| {
        const age_seconds = std.fmt.parseInt(i64, summary.time, 10) catch self.now_seconds;
        const seconds_ago = @max(@as(i64, 0), self.now_seconds - age_seconds);
        try out.print(
            self.allocator,
            "- ({d}s ago) USER: \"{s}\"\n  BRAIN: \"{s}\"\n",
            .{ seconds_ago, summary.user_summary, summary.brain_summary },
        );
    }
    try context_composition.noteSection(self.allocator, sections_out, before, out.items.len, "conversation_summaries", summaries.len - start);
    return out.toOwnedSlice(self.allocator);
}

pub fn formatConversationSummaryForMemory(allocator: std.mem.Allocator, user_summary: []const u8, brain_summary: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "You just heard USER say \"{s}\"\nI just said \"{s}\"",
        .{ user_summary, brain_summary },
    );
}

pub fn setFact(self: *Brain, key_text: []const u8, value_text: []const u8, tags: []const []const u8) ![]const u8 {
    const key = std.mem.trim(u8, key_text, " \r\n\t");
    const value = std.mem.trim(u8, value_text, " \r\n\t");
    if (key.len == 0) return error.EmptyFactKey;
    if (value.len == 0) return error.EmptyFactValue;
    const now = try self.timestampNow();
    const records = try self.deps.store.loadFactRecords(self.allocator);
    var target: ?schema.FactRecord = null;
    for (records) |record| {
        if (record.active and std.ascii.eqlIgnoreCase(record.key, key)) target = record;
    }

    var fact = if (target) |record| record else schema.FactRecord{
        .fact_id = try std.fmt.allocPrint(self.allocator, "fact_{s}_{d}_{d}", .{ try helpers.slugify(self.allocator, key), self.now_seconds, records.len }),
        .key = try self.allocator.dupe(u8, key),
        .value = "",
        .confidence = 0.90,
        .source = "brain",
        .tags = &.{},
        .created_at = now,
        .updated_at = now,
    };
    if (target != null) {
        const changed = !std.mem.eql(u8, fact.value, value);
        fact.revisions = try helpers.appendRevision(self.allocator, fact.revisions, .{
            .time = now,
            .text = try std.fmt.allocPrint(self.allocator, "revised {s}: {s}", .{ fact.key, fact.value }),
            .confidence = fact.confidence,
        });
        if (changed) fact.confidence = @min(fact.confidence, 0.65);
    }
    fact.value = try self.allocator.dupe(u8, value);
    fact.active = true;
    fact.updated_at = now;
    fact.tags = try helpers.cloneConstStringSlice(self.allocator, tags);
    // TODO(memory-runtime-merge): replace direct fact mutation with candidate-only reconciliation once runtime registration lands.
    try self.recordMemoryCandidateEvent(
        .memory_mutation,
        "brain",
        "memory.candidate",
        value,
        .brain,
        .memory_update,
        .keep_fact,
        key,
        value,
        value,
        &[_][]const u8{},
        fact.tags,
    );
    try self.deps.store.saveFactRecord(fact);
    const interpretation = try std.fmt.allocPrint(self.allocator, "fact {s}: {s}", .{ fact.key, fact.value });
    try self.recordExperienceLogEvent(.{
        .kind = .memory_mutation,
        .source = "brain",
        .title = "set_fact",
        .body = interpretation,
        .subject = "set_fact",
        .raw = value,
        .interpretation = interpretation,
        .experience_source = .brain,
        .experience_kind = .memory_update,
        .experience_retention = .keep_fact,
        .derived_memory_ids = @constCast(&[_][]const u8{fact.fact_id}),
        .created_fact_id = fact.fact_id,
        .tags = fact.tags,
    });
    return std.fmt.allocPrint(self.allocator, "fact_saved:\n- fact_id: {s}\n- key: {s}\n- value: {s}\n", .{ fact.fact_id, fact.key, fact.value });
}

pub fn recallFacts(self: *Brain, query_text: []const u8, tags: []const []const u8) ![]const u8 {
    const query = std.mem.trim(u8, query_text, " \r\n\t");
    const records = try self.deps.store.loadFactRecords(self.allocator);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "fact_recall:\n");
    var matched: usize = 0;
    for (records) |record| {
        if (!helpers.factMatches(record, query, tags)) continue;
        matched += 1;
        const recall_payload = try std.fmt.allocPrint(
            self.allocator,
            "fact_id={s}\nquery={s}\nactive={any}\nconfidence={d:.3}",
            .{ record.fact_id, query, record.active, record.confidence },
        );
        _ = try self.recordSimpleExperienceEvent(experience_kinds.memory_recalled, .memory, recall_payload);
        try out.print(self.allocator, "- {s}: {s} key={s} active={any} confidence={d:.3} updated_at={s}", .{ record.fact_id, record.value, record.key, record.active, record.confidence, record.updated_at });
        try out.appendSlice(self.allocator, " tags=");
        try out.appendSlice(self.allocator, try helpers.joinTags(self.allocator, record.tags));
        try out.append(self.allocator, '\n');
    }
    if (matched == 0) try out.appendSlice(self.allocator, "- none\n");
    return out.toOwnedSlice(self.allocator);
}

pub fn invalidateFact(self: *Brain, fact_id_text: []const u8, key_text: []const u8) ![]const u8 {
    const fact_id = std.mem.trim(u8, fact_id_text, " \r\n\t");
    const key = std.mem.trim(u8, key_text, " \r\n\t");
    if (fact_id.len == 0 and key.len == 0) return error.MissingFactIdentifier;
    const records = try self.deps.store.loadFactRecords(self.allocator);
    var target_id: ?[]const u8 = null;
    if (fact_id.len > 0) {
        target_id = fact_id;
    } else {
        for (records) |record| {
            if (!record.active or !std.ascii.eqlIgnoreCase(record.key, key)) continue;
            if (target_id != null) return error.AmbiguousFactKey;
            target_id = record.fact_id;
        }
    }
    const id = target_id orelse return error.FactNotFound;
    const now = try self.timestampNow();
    const invalidated = try self.deps.store.invalidateFactRecord(id, now);
    if (!invalidated) return error.FactNotFound;
    const interpretation = try std.fmt.allocPrint(self.allocator, "invalidated fact {s}", .{id});
    try self.recordExperienceLogEvent(.{
        .kind = .memory_mutation,
        .source = "brain",
        .title = "invalidate_fact",
        .body = interpretation,
        .subject = "invalidate_fact",
        .raw = id,
        .interpretation = interpretation,
        .experience_source = .brain,
        .experience_kind = .memory_update,
        .experience_retention = .keep_fact,
        .derived_memory_ids = @constCast(&[_][]const u8{id}),
        .invalidated_fact_id = id,
        .tags = @constCast(&[_][]const u8{ "fact", "invalidated" }),
    });
    return std.fmt.allocPrint(self.allocator, "fact_invalidated:\n- fact_id: {s}\n", .{id});
}

pub fn createMemoryRecord(self: *Brain, text: []const u8, tags: []const []const u8) !schema.MemoryRecord {
    const now = try self.timestampNow();
    const existing = try self.deps.store.loadMemoryRecords(self.allocator);
    return .{
        .memory_id = try std.fmt.allocPrint(self.allocator, "memory_{d}_{d}_{d}", .{ self.now_seconds, existing.len, text.len }),
        .scope = .short_term,
        .text = try self.allocator.dupe(u8, text),
        .original_text = try self.allocator.dupe(u8, text),
        .interpretation = try self.allocator.dupe(u8, text),
        .vector = try vector_index.embedQuery(self.allocator, text, tags),
        .confidence = 0.70,
        .valence = emotion.estimateValence(text),
        .salience = emotion.estimateSalience(text, tags),
        .tags = try helpers.cloneConstStringSlice(self.allocator, tags),
        .revisions = &.{},
        .created_at = now,
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
    };
}

pub fn seedEntryMemory(self: *Brain, doc: seed_mod.SeedDocument, entry: seed_mod.SeedEntry) !schema.MemoryRecord {
    const now = try self.timestampNow();
    const seed_slug = try helpers.slugify(self.allocator, doc.name);
    const tags = try helpers.seedEntryTags(self.allocator, entry.kind, seed_slug);
    const salience: f32 = switch (entry.kind) {
        .core_value => 0.90,
        .operating_tendency => 0.70,
        .want => 0.75,
        .goal => 0.75,
        .superego_principle => 0.85,
    };
    const score: i32 = switch (entry.kind) {
        .core_value => 8,
        .operating_tendency => 5,
        .want => 5,
        .goal => 5,
        .superego_principle => 7,
    };
    return .{
        .memory_id = try std.fmt.allocPrint(self.allocator, "seed_{s}_{s}_{d}", .{ seed_slug, entry.kind.tag(), entry.index }),
        .scope = .long_term,
        .text = try self.allocator.dupe(u8, entry.text),
        .original_text = try self.allocator.dupe(u8, entry.text),
        .interpretation = try std.fmt.allocPrint(self.allocator, "seed {s} {s}: {s}", .{ doc.name, entry.kind.label(), entry.text }),
        .vector = try vector_index.embedQuery(self.allocator, entry.text, tags),
        .confidence = 0.95,
        .valence = emotion.estimateValence(entry.text),
        .salience = salience,
        .tags = tags,
        .revisions = &.{},
        .created_at = now,
        .last_accessed_at = null,
        .access_count = 0,
        .score = score,
    };
}

pub fn recordExperienceFromLog(
    self: *Brain,
    source: schema.MemoryExperienceSource,
    kind: schema.MemoryExperienceKind,
    subject: []const u8,
    raw: []const u8,
    interpretation: []const u8,
    retention: schema.MemoryExperienceRetention,
    derived_memory_ids: []const []const u8,
    tags: []const []const u8,
) ![]const u8 {
    return experience_pipeline.recordMemoryExperience(self, source, kind, subject, raw, interpretation, retention, derived_memory_ids, tags, &.{});
}

pub fn heardSpeechRaw(self: *Brain, heard_speech: input_mod.HeardSpeech) ![]const u8 {
    return switch (heard_speech.source) {
        .typed_text => self.allocator.dupe(u8, heard_speech.text),
        .speech_transcription => std.fmt.allocPrint(
            self.allocator,
            "heard_speech:\nsource: speech_transcription\nprovider: {s}\nmodel_path: {s}\naudio_path: {s}\nraw_provider_json_path: {s}\ntranscript: {s}\nsummary_json:\n{s}",
            .{
                heard_speech.provider orelse return error.MissingHeardSpeechProvider,
                heard_speech.model_path orelse return error.MissingHeardSpeechModelPath,
                heard_speech.audio_path orelse return error.MissingHeardSpeechAudioPath,
                heard_speech.raw_provider_json_path orelse return error.MissingHeardSpeechProviderJsonPath,
                heard_speech.text,
                heard_speech.summary_json orelse return error.MissingHeardSpeechSummaryJson,
            },
        ),
    };
}

pub fn appendHeardSpeechObservation(self: *Brain, observations: *std.ArrayList(u8), heard_speech: input_mod.HeardSpeech) !void {
    switch (heard_speech.source) {
        .typed_text => try observations.print(
            self.allocator,
            "user_text:\n- source: typed_text\n- text: {s}\n",
            .{heard_speech.text},
        ),
        .speech_transcription => try observations.print(
            self.allocator,
            "heard_speech sense:\n- source: speech_transcription\n- provider: {s}\n- model_path: {s}\n- audio_path: {s}\n- raw_provider_json_path: {s}\n- speaker_continuity: {s}\n- transcript: {s}\n- summary_json:\n{s}\n",
            .{
                heard_speech.provider orelse return error.MissingHeardSpeechProvider,
                heard_speech.model_path orelse return error.MissingHeardSpeechModelPath,
                heard_speech.audio_path orelse return error.MissingHeardSpeechAudioPath,
                heard_speech.raw_provider_json_path orelse return error.MissingHeardSpeechProviderJsonPath,
                self.current_stimulus_context orelse "none",
                heard_speech.text,
                heard_speech.summary_json orelse return error.MissingHeardSpeechSummaryJson,
            },
        ),
    }
}
