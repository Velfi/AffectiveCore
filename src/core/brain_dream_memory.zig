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
pub fn dream(self: *Brain, optional_text: ?[]const u8, tags: []const []const u8, heat_bias: ?[]const u8) ![]const u8 {
    _ = try self.deps.store.sweepUnreferencedCaptures();
    _ = try self.consolidateMemory();
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    const pending_flexible_identity = try helpers.pendingFlexibleIdentityMemories(self.allocator, memories);
    const now = try time_mod.nowTimestamp(self.allocator);
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(@max(self.now_seconds, 0))) ^ @as(u64, memories.len * 97 + summaries.len * 13));
    const heat = helpers.rollDreamHeat(prng.random(), heat_bias);
    const confidence = helpers.dreamConfidence(heat);
    const first_index: usize = if (memories.len > 0) prng.random().intRangeLessThan(usize, 0, memories.len) else 0;
    const first = if (memories.len > 0) helpers.memoryInterpretation(memories[first_index]) else "no stored memory yet";
    const second = if (summaries.len > 0) summaries[@intCast(@mod(self.now_seconds + 1, @as(i64, @intCast(summaries.len))))].user_summary else "no recent conversation summary yet";
    const style = helpers.dreamStyle(heat);
    const flexible_text = try helpers.flexibleIdentityDreamText(self.allocator, pending_flexible_identity);
    const connection_text = if (flexible_text.len > 0)
        try std.fmt.allocPrint(self.allocator, "{s} <-> {s} <-> flexible_identity: {s}", .{ first, second, flexible_text })
    else
        try std.fmt.allocPrint(self.allocator, "{s} <-> {s}", .{ first, second });
    const dream_seed: ?[]const u8 = if (flexible_text.len > 0)
        try std.fmt.allocPrint(self.allocator, "{s}\nFlexible self-model material to reconcile through dreams: {s}", .{ optional_text orelse "", flexible_text })
    else
        optional_text;
    const dream_prompt = try Brain.dreamImagePrompt(self.allocator, style, connection_text, dream_seed);
    const dream_image = try self.deps.image_generation_service.generate(self.allocator, dream_prompt);
    const source_ids = try helpers.dreamSourceIds(self.allocator, if (memories.len > 0) memories[first_index].memory_id else null, pending_flexible_identity);
    var saved_memory_id: ?[]const u8 = null;

    if (optional_text) |text| {
        if (text.len > 0) {
            const dream_tags = if (tags.len > 0) tags else &[_][]const u8{ "dream", "reflection" };
            var memory = try createMemoryRecord(self, text, dream_tags);
            memory.score = 2;
            memory.confidence = confidence;
            memory.salience = 0.25 + heat * 0.25;
            memory.interpretation = try std.fmt.allocPrint(self.allocator, "provisional dream: {s}", .{text});
            try self.deps.store.saveMemoryRecord(memory);
            saved_memory_id = memory.memory_id;
            try self.recordRuntimeEvent(.{
                .kind = .memory_mutation,
                .source = "brain",
                .title = "dream_memory",
                .body = memory.interpretation,
                .subject = "dream_memory",
                .raw = text,
                .interpretation = memory.interpretation,
                .experience_source = .brain,
                .experience_kind = .dream,
                .experience_retention = .keep_episode,
                .derived_memory_ids = @constCast(&[_][]const u8{memory.memory_id}),
                .created_memory_id = memory.memory_id,
                .tags = memory.tags,
            });
        }
    }
    const dream_id = try std.fmt.allocPrint(self.allocator, "dream_{d}_{d}", .{ self.now_seconds, memories.len + summaries.len });
    const artifact_id = try std.fmt.allocPrint(self.allocator, "artifact_{s}", .{dream_id});
    try self.deps.store.addArtifact(.{
        .artifact_id = artifact_id,
        .kind = .image,
        .path = dream_image.path,
        .mime_type = dream_image.mime_type,
        .provenance = "dream",
        .retention = .episode,
        .linked_trace_ids = source_ids,
        .lifecycle = .{
            .status = .active,
            .created_at = now,
            .updated_at = now,
        },
    });
    try self.deps.store.addDream(.{
        .dream_id = dream_id,
        .selected_trace_ids = source_ids,
        .belief_change_ids = &.{},
        .generated_artifact_id = artifact_id,
        .reflection = connection_text,
        .heat = heat,
        .created_at = now,
    });
    if (pending_flexible_identity.len > 0) {
        const reconciliation = try saveFlexibleIdentityReconciliation(self, connection_text, source_ids, confidence);
        saved_memory_id = reconciliation;
        for (pending_flexible_identity) |memory| {
            _ = try self.deps.store.forgetMemoryRecord(memory.memory_id);
        }
    }
    const saved = if (saved_memory_id) |id| id else "none";
    try self.recordMemoryCandidateEvent(.autonomy, "brain", "dream_image", dream_image.path, .brain, .dream, .keep_episode, "dream_image", dream_prompt, dream_image.path, &.{}, &[_][]const u8{ "dream", "image" });
    return std.fmt.allocPrint(self.allocator, "dream:\n- heat: {d:.3}\n- style: {s}\n- confidence: {d:.3}\n- connection: {s}\n- source_ids: {s}\n- memory_saved: {s}\n- image_prompt: {s}\n- image_path: {s}\n- image_mime_type: {s}\n", .{
        heat,
        style,
        confidence,
        connection_text,
        try helpers.joinTags(self.allocator, source_ids),
        saved,
        dream_prompt,
        dream_image.path,
        dream_image.mime_type,
    });
}

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
    try self.recordRuntimeEvent(.{
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

pub fn runMaintenanceCommand(self: *Brain, command: []const u8) !bool {
    try self.logMaintenanceCommandSent(command);
    if (std.mem.eql(u8, command, "sweep_memory")) {
        _ = try self.sweepShortTermMemories();
        const removed = try self.deps.store.sweepExpiredExperiences(self.now_seconds);
        const runtime_events_removed = try self.deps.store.sweepRuntimeEvents();
        const speech_removed = try self.sweepSpeechArtifacts();
        const result = try std.fmt.allocPrint(
            self.allocator,
            "swept short-term memories; expired_experiences_removed={d}; runtime_events_removed={d}; speech_artifacts_removed={d} audio={d} transcription_json={d}",
            .{ removed, runtime_events_removed, speech_removed.total(), speech_removed.audio_removed, speech_removed.transcription_json_removed },
        );
        try self.logMaintenanceCommandResult(command, result);
        return true;
    }
    if (std.mem.eql(u8, command, "consolidate_memory")) {
        _ = try self.consolidateMemory();
        try self.logMaintenanceCommandResult(command, "consolidated memory");
        return true;
    }
    if (std.mem.eql(u8, command, "dream")) {
        _ = try dream(self, null, &[_][]const u8{}, null);
        try self.logMaintenanceCommandResult(command, "dream recorded");
        return true;
    }
    if (std.mem.eql(u8, command, "end_conversation")) {
        self.conversation_speaker_context = null;
        self.last_conversation_turn_seconds = null;
        try self.logMaintenanceCommandResult(command, "conversation context cleared");
        return true;
    }
    if (std.mem.startsWith(u8, command, "say:")) {
        const text = std.mem.trim(u8, command["say:".len..], " \t");
        std.debug.print("\nBRAIN REMINDER:\n{s}\n", .{text});
        try self.say(text);
        try self.logMaintenanceCommandResult(command, text);
        return true;
    }
    std.debug.print("Unknown maintenance command: {s}\n", .{command});
    try self.logMaintenanceCommandResult(command, "unknown maintenance command");
    return false;
}

pub fn buildConversationMemory(self: *Brain) ![]const u8 {
    return buildConversationMemoryWithSpeaker(self, null);
}

pub fn buildConversationMemoryWithSpeaker(self: *Brain, speaker_context: ?[]const u8) ![]const u8 {
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    var out = std.ArrayList(u8).empty;
    if (speaker_context) |context| {
        try out.appendSlice(self.allocator, context);
    }
    try out.appendSlice(self.allocator, try self.selfFactsSummary());
    try out.appendSlice(self.allocator, try self.deps.graph.summary(self.allocator, 8));
    try out.appendSlice(self.allocator, try self.activeNeedsSummary());
    var prng = std.Random.DefaultPrng.init(helpers.contextShuffleSeed(self.now_seconds, summaries.len));
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    if (memories.len > 0) {
        var long_count: usize = 0;
        var short_count: usize = 0;
        for (memories) |memory| {
            switch (memory.scope) {
                .long_term => long_count += 1,
                .short_term => short_count += 1,
            }
        }
        try out.print(self.allocator, "Memory index: {d} long-term, {d} short-term. Use recall_memory with a query and/or tags when details are needed.\n", .{ long_count, short_count });
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
    }

    if (summaries.len == 0) return out.toOwnedSlice(self.allocator);
    try out.appendSlice(self.allocator, "Recent conversation summaries:\n");
    const start = if (summaries.len > 8) summaries.len - 8 else 0;
    const recent = summaries[start..];
    const indices = try self.allocator.alloc(usize, recent.len);
    for (indices, 0..) |*index, i| index.* = i;
    prng.random().shuffle(usize, indices);
    for (indices) |index| {
        const summary = recent[index];
        try out.print(
            self.allocator,
            "- You just heard USER say \"{s}\"\n  I just said \"{s}\"\n",
            .{ summary.user_summary, summary.brain_summary },
        );
    }
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
    const now = try time_mod.nowTimestamp(self.allocator);
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
    fact.invalidated_at = null;
    fact.updated_at = now;
    fact.tags = try helpers.cloneConstStringSlice(self.allocator, tags);
    try self.deps.store.saveFactRecord(fact);
    const interpretation = try std.fmt.allocPrint(self.allocator, "fact {s}: {s}", .{ fact.key, fact.value });
    try self.recordRuntimeEvent(.{
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
        try out.print(self.allocator, "- {s}: {s} key={s} active={any} confidence={d:.3} updated_at={s}", .{ record.fact_id, record.value, record.key, record.active, record.confidence, record.updated_at });
        if (record.invalidated_at) |invalidated_at| try out.print(self.allocator, " invalidated_at={s}", .{invalidated_at});
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
    const now = try time_mod.nowTimestamp(self.allocator);
    const invalidated = try self.deps.store.invalidateFactRecord(id, now);
    if (!invalidated) return error.FactNotFound;
    const interpretation = try std.fmt.allocPrint(self.allocator, "invalidated fact {s}", .{id});
    try self.recordRuntimeEvent(.{
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
    const now = try time_mod.nowTimestamp(self.allocator);
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
    const now = try time_mod.nowTimestamp(self.allocator);
    const seed_slug = try helpers.slugify(self.allocator, doc.name);
    const tags = try helpers.seedEntryTags(self.allocator, entry.kind, seed_slug);
    const salience: f32 = switch (entry.kind) {
        .core_value => 0.90,
        .operating_tendency => 0.70,
        .want => 0.75,
        .superego_principle => 0.85,
    };
    const score: i32 = switch (entry.kind) {
        .core_value => 8,
        .operating_tendency => 5,
        .want => 5,
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

pub fn addExperience(
    self: *Brain,
    source: schema.ExperienceSource,
    kind: schema.ExperienceKind,
    subject: []const u8,
    raw: []const u8,
    interpretation: []const u8,
    retention: schema.ExperienceRetention,
    derived_memory_ids: []const []const u8,
    tags: []const []const u8,
) ![]const u8 {
    const now = try time_mod.nowTimestamp(self.allocator);
    const existing = try self.deps.store.loadExperiences(self.allocator);
    const experience_id = try std.fmt.allocPrint(self.allocator, "experience_{d}_{d}_{d}", .{ self.now_seconds, existing.len, raw.len });
    const expires_at = try self.experienceExpiry(retention);
    try self.deps.store.addExperience(.{
        .experience_id = experience_id,
        .time = now,
        .source = source,
        .kind = kind,
        .subject = try self.allocator.dupe(u8, subject),
        .raw = try self.allocator.dupe(u8, raw),
        .interpretation = try self.allocator.dupe(u8, interpretation),
        .confidence = 0.70,
        .salience = emotion.estimateSalience(interpretation, tags),
        .valence = emotion.estimateValence(interpretation),
        .retention = retention,
        .expires_at = expires_at,
        .derived_memory_ids = try helpers.cloneConstStringSlice(self.allocator, derived_memory_ids),
        .related_experience_ids = &.{},
        .tags = try helpers.cloneConstStringSlice(self.allocator, tags),
    });
    return experience_id;
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
    if (heard_speech.source != .speech_transcription) return;
    try observations.print(
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
    );
}
