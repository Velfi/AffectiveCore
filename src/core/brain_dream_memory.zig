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
const chat_mod = @import("port_chat.zig");
const openai = ports.openai;
const speech_mod = ports.speech;
const skills_mod = ports.skills;
const email_mod = ports.email;
const autonomy_mod = ports.autonomy;
const psyche_client = ports.psyche;
const want_achievement_mod = ports.want_achievement;
const persona_directive_mod = ports.persona_directive;
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
const experience_pipeline = @import("experience_pipeline.zig");
const experience_kinds = @import("experience_kinds.zig");
const experiential_observations = @import("experiential_observations.zig");
const present_moment = @import("present_moment.zig");
const context_composition = @import("context_composition.zig");
const context_salience = @import("context_salience.zig");
const memory_selection_mod = @import("memory_selection.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const process_recipe_memory = @import("process_recipe_memory.zig");

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
            "Create a {s} dream image for a being. Visualize this dream seed: {s}. Blend these associated memories: {s}. No text, captions, UI, or labels in the image.",
            .{ style, seed, connection },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Create a {s} dream image for a being. Blend these associated memories: {s}. No text, captions, UI, or labels in the image.",
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
    _ = try self.recordExperienceLogEvent(.{
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
    return buildConversationMemoryWithSpeaker(self, null, null, null, .heard_speech);
}

fn appendMemoryBlock(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(context_composition.ContextBlock),
    kind: context_salience.MemoryKind,
    text: []const u8,
    stimulus: chat_mod.StimulusKind,
    contact_open: bool,
    order: *usize,
    count: ?usize,
) !void {
    if (text.len == 0) return;
    try blocks.append(allocator, .{
        .kind = .{ .memory = kind },
        .text = try allocator.dupe(u8, text),
        .rank = context_salience.memoryRank(kind, stimulus, contact_open),
        .protected = context_salience.isMemoryProtected(kind),
        .order_index = order.*,
        .count = count,
    });
    order.* += 1;
}

fn appendKnownProcessesMemoryBlock(brain: *Brain, out: *std.ArrayList(u8)) !void {
    try process_recipe_memory.appendKnownProcessesMemoryBlock(brain, out);
}

fn captureMemorySection(
    allocator: std.mem.Allocator,
    blocks: *std.ArrayList(context_composition.ContextBlock),
    kind: context_salience.MemoryKind,
    stimulus: chat_mod.StimulusKind,
    contact_open: bool,
    order: *usize,
    count: ?usize,
    build: *const fn (*Brain, *std.ArrayList(u8)) anyerror!void,
    brain: *Brain,
) !void {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try build(brain, &buf);
    try appendMemoryBlock(allocator, blocks, kind, buf.items, stimulus, contact_open, order, count);
}

pub fn buildConversationMemoryBlocks(
    self: *Brain,
    speaker_context: ?[]const u8,
    selection: ?memory_selection_mod.ResolvedMemorySelection,
    stimulus: chat_mod.StimulusKind,
) ![]context_composition.ContextBlock {
    const contact_open = present_moment.contactWindowOpen(self);
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    var blocks = std.ArrayList(context_composition.ContextBlock).empty;
    errdefer conversation_context_freeMemoryBlocks(self.allocator, blocks.items);
    var order: usize = 0;
    const allocator = self.allocator;

    {
        const persona = try self.personaDirectiveConversationSummary();
        try appendMemoryBlock(allocator, &blocks, .persona_directive, persona, stimulus, contact_open, &order, null);
    }
    try captureMemorySection(allocator, &blocks, .focus, stimulus, contact_open, &order, null, appendFocusBlock, self);

    if (speaker_context) |context| {
        try appendMemoryBlock(allocator, &blocks, .speaker, context, stimulus, contact_open, &order, null);
    }

    {
        const self_facts = try self.selfFactsConversationSummary();
        try appendMemoryBlock(allocator, &blocks, .self_facts, self_facts, stimulus, contact_open, &order, null);
    }
    {
        const graph = try self.deps.graph.summary(allocator, 8);
        try appendMemoryBlock(allocator, &blocks, .relationship_graph, graph, stimulus, contact_open, &order, null);
    }
    {
        const needs = try self.activeNeedsSummary();
        try appendMemoryBlock(allocator, &blocks, .needs, needs, stimulus, contact_open, &order, null);
    }
    try captureMemorySection(allocator, &blocks, .known_processes, stimulus, contact_open, &order, null, appendKnownProcessesMemoryBlock, self);
    {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try experiential_observations.appendDayArcToMemory(self, &buf);
        try appendMemoryBlock(allocator, &blocks, .day_arc, buf.items, stimulus, contact_open, &order, null);
    }

    if (selection) |resolved| {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try memory_selection_mod.appendMemorySelectionToMemory(
            allocator,
            &buf,
            resolved,
            self.cfg.capacity.memory_context_bytes_max,
        );
        try appendMemoryBlock(allocator, &blocks, .relevant_memories, buf.items, stimulus, contact_open, &order, resolved.entries.len);
    }

    const memories = try self.deps.store.loadMemoryRecords(allocator);
    var prng = std.Random.DefaultPrng.init(helpers.contextShuffleSeed(self.now_seconds, summaries.len));
    if (memories.len > 0) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        var long_count: usize = 0;
        var short_count: usize = 0;
        for (memories) |memory| {
            switch (memory.scope) {
                .long_term => long_count += 1,
                .short_term => short_count += 1,
            }
        }
        try buf.print(allocator, "Memory index: {d} long-term, {d} short-term. Use typed memory read models and explicit recall events when details are needed.\n", .{ long_count, short_count });
        var memory_tags = std.ArrayList([]const u8).empty;
        defer memory_tags.deinit(allocator);
        for (memories) |memory| {
            for (memory.tags) |tag| {
                if (memory_tags.items.len >= 32 or helpers.tagInSlice(memory_tags.items, tag)) continue;
                try memory_tags.append(allocator, tag);
            }
        }
        prng.random().shuffle([]const u8, memory_tags.items);
        try buf.appendSlice(allocator, "Available memory tags:");
        for (memory_tags.items) |tag| {
            try buf.print(allocator, " {s}", .{tag});
        }
        try buf.appendSlice(allocator, "\n");
        try appendMemoryBlock(allocator, &blocks, .memory_index, buf.items, stimulus, contact_open, &order, memories.len);
    }

    if (summaries.len > 0) {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "Recent conversation summaries (chronological):\n");
        const summary_window = present_moment.conversationSummaryCap(self);
        const start = if (summaries.len > summary_window) summaries.len - summary_window else 0;
        for (summaries[start..]) |summary| {
            const age_seconds = std.fmt.parseInt(i64, summary.time, 10) catch self.now_seconds;
            const seconds_ago = @max(@as(i64, 0), self.now_seconds - age_seconds);
            try buf.print(
                allocator,
                "- ({d}s ago) USER: \"{s}\"\n  BRAIN: \"{s}\"\n",
                .{ seconds_ago, summary.user_summary, summary.brain_summary },
            );
        }
        try appendMemoryBlock(allocator, &blocks, .conversation_summaries, buf.items, stimulus, contact_open, &order, summaries.len - start);
    }

    return try blocks.toOwnedSlice(allocator);
}

fn conversation_context_freeMemoryBlocks(allocator: std.mem.Allocator, blocks: []context_composition.ContextBlock) void {
    for (blocks) |block| allocator.free(block.text);
    if (blocks.len > 0) allocator.free(blocks);
}

pub fn buildConversationMemoryWithSpeaker(
    self: *Brain,
    speaker_context: ?[]const u8,
    sections_out: ?*std.ArrayList(context_composition.SectionStat),
    selection: ?memory_selection_mod.ResolvedMemorySelection,
    stimulus: chat_mod.StimulusKind,
) ![]const u8 {
    const blocks = try buildConversationMemoryBlocks(self, speaker_context, selection, stimulus);
    defer conversation_context_freeMemoryBlocks(self.allocator, blocks);
    context_composition.sortBlocks(blocks);
    const assembled = try context_composition.assembleBlocks(self.allocator, blocks);
    if (sections_out) |sections| {
        for (assembled.memory_sections) |section| {
            try sections.append(self.allocator, section);
        }
        self.allocator.free(assembled.memory_sections);
    } else {
        for (assembled.memory_sections) |section| self.allocator.free(section.name);
        self.allocator.free(assembled.memory_sections);
    }
    return assembled.memory;
}

pub fn formatConversationSummaryForMemory(allocator: std.mem.Allocator, user_summary: []const u8, brain_summary: []const u8) ![]const u8 {
    return formatTurnSummaryForMemory(allocator, .heard_speech, user_summary, brain_summary);
}

pub fn formatTurnSummaryForMemory(
    allocator: std.mem.Allocator,
    stimulus_kind: chat_mod.StimulusKind,
    user_summary: []const u8,
    brain_summary: []const u8,
) ![]const u8 {
    return switch (stimulus_kind) {
        .heard_speech => std.fmt.allocPrint(
            allocator,
            "You just heard USER say \"{s}\"\nI just said \"{s}\"",
            .{ user_summary, brain_summary },
        ),
        .reconsideration, .host_sense_delivery => std.fmt.allocPrint(
            allocator,
            "While we were talking, I noticed \"{s}\"\nI considered \"{s}\"",
            .{ user_summary, brain_summary },
        ),
        .orchestration => std.fmt.allocPrint(
            allocator,
            "A salient event arrived: \"{s}\"\nI decided \"{s}\"",
            .{ user_summary, brain_summary },
        ),
    };
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
    _ = try self.recordExperienceLogEvent(.{
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
        try out.print(self.allocator, "- I recall: {s} ({s})\n", .{ record.value, record.key });
    }
    if (matched == 0) {
        try out.appendSlice(self.allocator, "- ");
        try out.appendSlice(self.allocator, llm_voice.empty_inner_state);
        try out.appendSlice(self.allocator, "\n");
    }
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
    _ = try self.recordExperienceLogEvent(.{
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
        .vector = try vector_index.embedQuery(self.allocator, self.deps.embedding_service, text, tags),
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

pub fn setPersonaVoiceLines(self: *Brain, lines: []const []const u8) !void {
    for (self.persona_voice_lines) |line| self.allocator.free(line);
    if (self.persona_voice_lines.len > 0) self.allocator.free(self.persona_voice_lines);
    if (lines.len == 0) {
        self.persona_voice_lines = &.{};
        return;
    }
    const owned = try self.allocator.alloc([]const u8, lines.len);
    for (lines, 0..) |line, index| {
        owned[index] = try self.allocator.dupe(u8, line);
    }
    self.persona_voice_lines = owned;
}

pub fn clearPersonaDirective(self: *Brain) void {
    if (self.persona_directive) |directive| {
        directive.deinit(self.allocator);
        self.persona_directive = null;
    }
}

pub fn setPersonaDirective(self: *Brain, directive: persona_directive_mod.PersonaDirective) !void {
    clearPersonaDirective(self);
    self.persona_directive = try directive.dupe(self.allocator);
}

pub fn refreshPersonaDirectiveFromStore(self: *Brain) !void {
    clearPersonaDirective(self);
    const dreams = try self.deps.store.loadDreamTimeRecords(self.allocator);
    var latest_ms: i64 = 0;
    var latest: ?schema.DreamTimeRecord = null;
    for (dreams) |dream| {
        if (dream.created_at_ms < latest_ms) continue;
        if (dream.persona.len == 0 or dream.short_term.len == 0 or dream.long_term.len == 0) continue;
        latest_ms = dream.created_at_ms;
        latest = dream;
    }
    if (latest) |dream| {
        try setPersonaDirective(self, .{
            .persona = dream.persona,
            .short_term = dream.short_term,
            .long_term = dream.long_term,
        });
    }
}

pub fn activePersonaDirective(self: *Brain) !persona_directive_mod.PersonaDirective {
    if (self.persona_directive) |directive| return try directive.dupe(self.allocator);
    return persona_directive_mod.PersonaDirective.defaults(self.allocator);
}

pub fn personaDirectiveConversationSummary(self: *Brain) ![]const u8 {
    const directive = try activePersonaDirective(self);
    defer directive.deinit(self.allocator);
    const formatted = try directive.formatForMemory(self.allocator);
    const persona_max_bytes: usize = 600;
    if (formatted.len <= persona_max_bytes) return formatted;
    defer self.allocator.free(formatted);
    var end = persona_max_bytes;
    while (end > 0 and formatted[end - 1] != '\n') end -= 1;
    if (end == 0) return error.PersonaDirectiveSummaryTooLarge;
    return self.allocator.dupe(u8, formatted[0..end]);
}

fn appendTaggedSeedMemories(
    self: *Brain,
    out: *std.ArrayList(u8),
    section: []const u8,
    tag: []const u8,
) !void {
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    try out.appendSlice(self.allocator, section);
    var count: usize = 0;
    for (memories) |memory| {
        if (!helpers.tagInSlice(memory.tags, tag)) continue;
        count += 1;
        try out.print(self.allocator, "- {s}\n", .{memory.text});
    }
    if (count == 0) try out.appendSlice(self.allocator, "- none\n");
}

pub fn buildDreamPersonaSynthesisContext(
    self: *Brain,
    reconciliation_count: usize,
    residue: DreamPersonaResidue,
) ![]const u8 {
    const prior = try activePersonaDirective(self);
    defer prior.deinit(self.allocator);
    const prior_text = try prior.formatFieldLines(self.allocator);
    defer self.allocator.free(prior_text);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(self.allocator);
    try out.appendSlice(self.allocator, "prior_persona_directive:\n");
    try out.appendSlice(self.allocator, prior_text);
    try out.appendSlice(self.allocator, "\nseed_voice:\n");
    if (self.persona_voice_lines.len == 0) {
        try out.appendSlice(self.allocator, "- none\n");
    } else {
        for (self.persona_voice_lines) |line| {
            try out.print(self.allocator, "- {s}\n", .{line});
        }
    }

    try appendTaggedSeedMemories(self, &out, "\nseed_core_values:\n", "core_value");
    try appendTaggedSeedMemories(self, &out, "\nseed_operating_tendencies:\n", "seed_operating_tendency");

    try out.appendSlice(self.allocator, "\nday_residue:\n");
    try out.print(self.allocator, "- capability_failures_reviewed: {d}\n", .{residue.failure_capability_ids.len});
    try out.print(self.allocator, "- contradiction_reconciliations: {d}\n", .{reconciliation_count});
    for (residue.memory_interpretations) |interpretation| {
        try out.print(self.allocator, "- {s}\n", .{interpretation});
    }

    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    const period_start_ms = try wakingPeriodStartMsForPersona(self);
    try out.appendSlice(self.allocator, "\nconversation_summaries:\n");
    var summary_count: usize = 0;
    for (summaries) |summary| {
        const age_seconds = std.fmt.parseInt(i64, summary.time, 10) catch self.now_seconds;
        const summary_ms = age_seconds * 1000;
        if (summary_ms < period_start_ms) continue;
        summary_count += 1;
        try out.print(
            self.allocator,
            "- USER: \"{s}\" BRAIN: \"{s}\"\n",
            .{ summary.user_summary, summary.brain_summary },
        );
    }
    if (summary_count == 0) try out.appendSlice(self.allocator, "- none\n");

    const needs = try self.activeNeedsSummary();
    defer self.allocator.free(needs);
    try out.appendSlice(self.allocator, "\n");
    try out.appendSlice(self.allocator, needs);

    try out.appendSlice(self.allocator, "\ndream_maintenance:\n");
    try out.print(self.allocator, "- capability_failures_reviewed: {d}\n", .{residue.failure_capability_ids.len});
    try out.print(self.allocator, "- contradiction_reconciliations: {d}\n", .{reconciliation_count});
    return out.toOwnedSlice(self.allocator);
}

pub const DreamPersonaResidue = struct {
    failure_capability_ids: []const []const u8,
    memory_interpretations: []const []const u8,
};

fn wakingPeriodStartMsForPersona(self: *Brain) !i64 {
    const dreams = try self.deps.store.loadDreamTimeRecords(self.allocator);
    var latest_wake_ms: i64 = 0;
    for (dreams) |dream| {
        if (dream.created_at_ms > latest_wake_ms) latest_wake_ms = dream.created_at_ms;
    }
    if (latest_wake_ms > 0) return latest_wake_ms;

    const now_ms = self.now_seconds * 1000;
    const seconds_in_day: i64 = @mod(self.now_seconds, 86400);
    return now_ms - seconds_in_day * 1000;
}

pub fn synthesizeDreamPersonaDirective(
    self: *Brain,
    reconciliation_count: usize,
    residue: DreamPersonaResidue,
) !persona_directive_mod.PersonaDirective {
    const base_context = try buildDreamPersonaSynthesisContext(self, reconciliation_count, residue);
    defer self.allocator.free(base_context);
    const context = try appendDreamPersonaPsycheConsult(self, base_context);
    defer self.allocator.free(context);
    return self.deps.persona_directive_synthesizer.synthesize(self.allocator, context);
}

fn appendDreamPersonaPsycheConsult(self: *Brain, context: []const u8) ![]const u8 {
    if (!(try brain_autonomy.psycheEnabled(self))) return self.allocator.dupe(u8, context);
    const psyche = self.deps.psyche_service orelse return error.MissingPsycheService;
    const io = self.deps.io orelse return error.MissingIo;
    const state = (try brain_autonomy.autonomyStateForNeeds(self)) orelse return error.MissingAutonomyState;
    const shared = try brain_autonomy.buildPsycheSharedContext(self, io, state);
    defer self.allocator.free(shared);

    var psyche_input = std.ArrayList(u8).empty;
    defer psyche_input.deinit(self.allocator);
    try psyche_input.appendSlice(self.allocator, shared);
    try psyche_input.appendSlice(self.allocator, "\ndream_consolidation:\n");
    try psyche_input.appendSlice(self.allocator, context);

    const turns = try psyche.consultBoth(self.allocator, psyche_input.items);
    const id_text = try psyche_client.formatIdTurn(self.allocator, turns.id);
    defer self.allocator.free(id_text);
    const superego_text = try psyche_client.formatSuperegoTurn(self.allocator, turns.superego);
    defer self.allocator.free(superego_text);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(self.allocator);
    try out.appendSlice(self.allocator, context);
    try out.appendSlice(self.allocator, "\npsyche_consult:\n");
    try out.appendSlice(self.allocator, id_text);
    try out.appendSlice(self.allocator, superego_text);
    return out.toOwnedSlice(self.allocator);
}

pub fn personaConversationSummary(self: *Brain) ![]const u8 {
    return personaDirectiveConversationSummary(self);
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
        .vector = try vector_index.embedQuery(self.allocator, self.deps.embedding_service, entry.text, tags),
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
