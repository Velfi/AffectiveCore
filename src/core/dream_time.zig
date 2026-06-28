const std = @import("std");
const brain_mod = @import("brain.zig");
const belief_updates = @import("belief_updates.zig");
const experience_kinds = @import("experience_kinds.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const Brain = brain_mod.Brain;

/// If a prior dream or shutdown left the brain in a non-waking mode, return to
/// waking conversation so the host is not permanently wedged.
pub fn recoverStuckBrainMode(self: *Brain) !void {
    const mode = try self.deps.store.loadBrainMode();
    switch (mode) {
        .waking, .drowsy => {},
        .dreaming, .waking_up, .unavailable => {
            _ = try self.recordSimpleExperienceEvent(experience_kinds.brain_mode_recovered, .system, @tagName(mode));
            try self.deps.store.setBrainMode(.waking);
        },
    }
}

pub fn enterDrowsy(self: *Brain) !void {
    const mode = try self.deps.store.loadBrainMode();
    if (mode != .waking and mode != .drowsy) return error.BrainUnavailable;
    try self.deps.store.setBrainMode(.drowsy);
    _ = try self.recordSimpleExperienceEvent(experience_kinds.dream_time_drowsy, .dream_time, "entering drowsy");
}

pub fn requestDreamTime(self: *Brain, prompt: ?[]const u8) !schema.MailboxItem {
    const mode = try self.deps.store.loadBrainMode();
    if (mode == .drowsy) {
        try self.deps.store.setBrainMode(.dreaming);
    } else if (mode != .waking) {
        return error.BrainUnavailable;
    } else {
        try self.deps.store.setBrainMode(.dreaming);
    }
    errdefer self.deps.store.setBrainMode(.waking) catch {};
    const entered_event = try self.recordSimpleExperienceEvent(experience_kinds.dream_time_entered, .dream_time, prompt orelse "");

    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const source_ids = try selectMemoryIds(self.allocator, memories, .{ .failure_capability_ids = &.{}, .failure_event_ids = &.{} });
    const residue = try collectDayResidue(self);
    defer {
        for (residue.failure_capability_ids) |id| self.allocator.free(id);
        self.allocator.free(residue.failure_capability_ids);
        for (residue.failure_event_ids) |id| self.allocator.free(id);
        self.allocator.free(residue.failure_event_ids);
    }
    const reconciliation_count = try reconcileContradictions(self);
    const now = try self.timestampNow();
    const cognitive_prune = try self.deps.store.pruneTombstonedCognitiveRecords(now);
    const captures_purged = try self.deps.store.sweepUnreferencedCaptures();
    const maintenance_started_event = try self.recordSimpleExperienceEvent(experience_kinds.dream_time_maintenance_started, .dream_time, "consolidation");
    const consolidation_text = self.consolidateMemory() catch "";
    const maintenance_counts = try dreamMaintenanceCounts(self, consolidation_text, reconciliation_count, residue, cognitive_prune, captures_purged);
    const maintenance_counts_json = try std.json.Stringify.valueAlloc(self.allocator, maintenance_counts, .{ .whitespace = .minified });
    const maintenance_completed_event = try self.recordSimpleExperienceEvent(experience_kinds.dream_time_maintenance_completed, .dream_time, maintenance_counts_json);

    const title = try std.fmt.allocPrint(self.allocator, "Dream {d}", .{self.now_seconds});
    const text = if (prompt) |p|
        try std.fmt.allocPrint(self.allocator, "I dreamed over: {s}", .{p})
    else if (residue.failure_capability_ids.len > 0)
        try std.fmt.allocPrint(self.allocator, "I dreamed over {d} remembered traces and {d} capability failures from today.", .{ source_ids.len, residue.failure_capability_ids.len })
    else
        try std.fmt.allocPrint(self.allocator, "I dreamed over {d} remembered traces and let the day settle into quieter patterns.", .{source_ids.len});
    const waking = try std.fmt.allocPrint(self.allocator, "I may ask more carefully where uncertainty is high, and trust repeated outcomes more than single impressions.", .{});
    const mailbox_id = try std.fmt.allocPrint(self.allocator, "mail_dream_{d}", .{self.now_seconds * 1000});
    const dream_id = try std.fmt.allocPrint(self.allocator, "dream_time_{d}", .{self.now_seconds * 1000});
    const spec: schema.DreamImageSpec = .{
        .subject = "day residue becoming memory",
        .setting = "a quiet internal room of labeled lights",
        .symbols = symbols: {
            const literals = [_][]const u8{ "threads", "windows", "small lanterns" };
            var out = try self.allocator.alloc([]const u8, literals.len);
            for (literals, 0..) |symbol, i| out[i] = try self.allocator.dupe(u8, symbol);
            break :symbols out;
        },
        .mood = "reflective",
        .visual_style = "soft cinematic illustration",
        .avoid = avoid: {
            const literals = [_][]const u8{ "photoreal faces", "text overlays" };
            var out = try self.allocator.alloc([]const u8, literals.len);
            for (literals, 0..) |item, i| out[i] = try self.allocator.dupe(u8, item);
            break :avoid out;
        },
    };
    const image_spec_json = try std.json.Stringify.valueAlloc(self.allocator, spec, .{ .whitespace = .minified });
    const dream_lifecycle_event_ids = [_][]const u8{
        entered_event.id,
        maintenance_started_event.id,
        maintenance_completed_event.id,
    };
    const memory_source_event_ids = try sourceEventIdsForMemories(self, memories, source_ids);
    const source_event_ids = try combineEventIds(self.allocator, &dream_lifecycle_event_ids, memory_source_event_ids, residue.failure_event_ids);

    const belief_proposition = if (residue.failure_capability_ids.len > 0)
        "When recognition or recall fails during the day, asking a clarifying question is more trustworthy than acting certain."
    else
        "When recognition or recall is uncertain, asking a clarifying question is more trustworthy than acting certain.";
    const belief_id = try belief_updates.onDreamTimeBelief(self, belief_proposition, source_event_ids, 0.68);

    const self_trust_id = try std.fmt.allocPrint(self.allocator, "self_trust_dream_uncertainty_{d}", .{self.now_seconds});
    const dream_confidence: f32 = if (residue.failure_capability_ids.len > 0) 0.52 else 0.58;
    try self.deps.store.upsertSelfTrust(.{
        .self_trust_id = self_trust_id,
        .faculty = "recognition_and_recall",
        .context_pattern = "uncertain recognition or recall",
        .confidence = dream_confidence,
        .evidence_event_ids = source_event_ids,
        .updated_at_ms = self.now_seconds * 1000,
    });
    const disposition_id = try std.fmt.allocPrint(self.allocator, "disp_dream_uncertainty_{d}", .{self.now_seconds});
    const generated_artifact_id = try generateDreamImageArtifact(self, spec, prompt);
    var dream_record: schema.DreamTimeRecord = .{
        .dream_id = dream_id,
        .source_event_ids = source_event_ids,
        .source_memory_ids = source_ids,
        .updated_belief_ids = try cloneEventIds(self.allocator, &[_][]const u8{belief_id}),
        .self_trust_change_ids = try cloneEventIds(self.allocator, &[_][]const u8{self_trust_id}),
        .disposition_change_ids = try cloneEventIds(self.allocator, &[_][]const u8{disposition_id}),
        .maintenance_counts_json = maintenance_counts_json,
        .generated_artifact_id = generated_artifact_id,
        .delivered_mailbox_id = mailbox_id,
        .title = title,
        .text = text,
        .waking_thought = waking,
        .image_spec = spec,
        .created_at_ms = self.now_seconds * 1000,
    };
    dream_record.delivered_mailbox_id = null;
    const disposition: schema.Disposition = .{
        .disposition_id = disposition_id,
        .context_pattern = "uncertain recognition or recall",
        .action_tendency = "ask a clarifying question before acting certain",
        .strength = if (residue.failure_capability_ids.len > 0) 0.68 else 0.62,
        .source_event_ids = source_event_ids,
        .source_dream_ids = try cloneEventIds(self.allocator, &[_][]const u8{dream_id}),
        .updated_at_ms = self.now_seconds * 1000,
    };
    try self.deps.store.upsertDisposition(disposition);
    try self.deps.store.addDreamTimeRecord(dream_record);
    const item: schema.MailboxItem = .{
        .mailbox_id = mailbox_id,
        .kind = .DreamMail,
        .title = title,
        .text = text,
        .image_artifact_id = generated_artifact_id,
        .image_spec_json = image_spec_json,
        .waking_thought = waking,
        .visible_lesson = "Uncertainty should change behavior, not become pretending.",
        .debug_details = maintenance_counts_json,
        .source_event_ids = source_event_ids,
        .source_dream_id = dream_id,
        .created_at_ms = self.now_seconds * 1000,
    };
    try self.deps.store.addMailboxItem(item);
    dream_record.delivered_mailbox_id = mailbox_id;
    try self.deps.store.addDreamTimeRecord(dream_record);
    _ = try self.recordSimpleExperienceEvent(experience_kinds.mailbox_delivered, .dream_time, mailbox_id);
    try self.deps.store.setBrainMode(.waking_up);
    _ = try self.recordSimpleExperienceEvent(experience_kinds.dream_time_waking_up, .dream_time, waking);
    try self.deps.store.setBrainMode(.waking);
    _ = try self.recordSimpleExperienceEvent(experience_kinds.dream_time_woke, .dream_time, "waking");
    return item;
}

const DayResidue = struct {
    failure_capability_ids: []const []const u8,
    failure_event_ids: []const []const u8,
};

fn wakingPeriodStartMs(self: *Brain) !i64 {
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

fn collectDayResidue(self: *Brain) !DayResidue {
    const period_start_ms = try wakingPeriodStartMs(self);
    const results = try self.deps.store.loadCapabilityResults(self.allocator);
    var capability_ids = std.ArrayList([]const u8).empty;
    var event_ids = std.ArrayList([]const u8).empty;
    for (results) |result| {
        if (result.completed_at_ms < period_start_ms) continue;
        if (result.state != .failed and result.state != .unavailable) continue;
        try capability_ids.append(self.allocator, try self.allocator.dupe(u8, result.capability_id));
        if (result.outcome_event_id.len > 0 and try experienceEventExists(self, result.outcome_event_id)) {
            try event_ids.append(self.allocator, try self.allocator.dupe(u8, result.outcome_event_id));
        }
    }
    return .{
        .failure_capability_ids = try capability_ids.toOwnedSlice(self.allocator),
        .failure_event_ids = try event_ids.toOwnedSlice(self.allocator),
    };
}

const MaintenanceCounts = struct {
    consolidation: usize = 0,
    promoted: usize = 0,
    decayed: usize = 0,
    revised: usize = 0,
    removed: usize = 0,
    contradiction_reconciliations: usize = 0,
    capability_failures_reviewed: usize = 0,
    source_events_linked: usize = 0,
    selected_memories: usize = 0,
    belief_updates: usize = 1,
    self_trust_updates: usize = 1,
    disposition_extractions: usize = 1,
    artifact_generations: usize = 1,
    mailbox_deliveries: usize = 1,
    index_repairs: usize = 0,
    embedding_refreshes: usize = 0,
    duplicate_merges: usize = 0,
    pruning_passes: usize = 1,
    cognitive_tombstoned: usize = 0,
    cognitive_purged: usize = 0,
    captures_purged: usize = 0,
};

fn dreamMaintenanceCounts(
    self: *Brain,
    consolidation_text: []const u8,
    reconciliation_count: usize,
    residue: DayResidue,
    cognitive_prune: schema.CognitivePruneResult,
    captures_purged: usize,
) !MaintenanceCounts {
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    return .{
        .consolidation = 1,
        .promoted = parseMaintenanceCount(consolidation_text, "promoted="),
        .decayed = parseMaintenanceCount(consolidation_text, "decayed="),
        .revised = parseMaintenanceCount(consolidation_text, "revised="),
        .removed = parseMaintenanceCount(consolidation_text, "removed="),
        .contradiction_reconciliations = reconciliation_count,
        .capability_failures_reviewed = residue.failure_capability_ids.len,
        .source_events_linked = residue.failure_event_ids.len,
        .selected_memories = @min(memories.len, 12),
        .cognitive_tombstoned = cognitive_prune.tombstoned,
        .cognitive_purged = cognitive_prune.purged,
        .captures_purged = captures_purged,
    };
}

fn parseMaintenanceCount(text: []const u8, prefix: []const u8) usize {
    const start = std.mem.indexOf(u8, text, prefix) orelse return 0;
    const after = text[start + prefix.len ..];
    var end: usize = 0;
    while (end < after.len and after[end] >= '0' and after[end] <= '9') : (end += 1) {}
    if (end == 0) return 0;
    return std.fmt.parseInt(usize, after[0..end], 10) catch 0;
}

fn reconcileContradictions(self: *Brain) !usize {
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    var reconciled: usize = 0;
    for (memories) |memory| {
        var has_pending = false;
        var has_flexible = false;
        for (memory.tags) |tag| {
            if (std.mem.eql(u8, tag, "pending_dream_reconciliation")) has_pending = true;
            if (std.mem.eql(u8, tag, "flexible_identity")) has_flexible = true;
        }
        if (!has_pending or !has_flexible) continue;
        _ = try self.saveFlexibleIdentityReconciliation(memory.interpretation, &[_][]const u8{memory.memory_id}, memory.confidence);
        reconciled += 1;
    }
    return reconciled;
}

fn generateDreamImageArtifact(self: *Brain, spec: schema.DreamImageSpec, prompt: ?[]const u8) !?[]const u8 {
    const connection = try std.mem.join(self.allocator, ", ", spec.symbols);
    defer self.allocator.free(connection);
    const image_prompt = try brain_dream_memory.dreamImagePrompt(self.allocator, spec.visual_style, connection, prompt);
    defer self.allocator.free(image_prompt);
    const image = self.deps.image_generation_service.generate(self.allocator, image_prompt) catch return null;
    const generated_event = try self.recordSimpleExperienceEvent(experience_kinds.dream_time_artifact_generated, .dream_time, image.path);
    const artifact_id = try std.fmt.allocPrint(self.allocator, "artifact_dream_image_{d}", .{self.now_seconds * 1000});
    const now = try self.timestampNow();
    try self.deps.store.addArtifact(.{
        .artifact_id = artifact_id,
        .kind = .image,
        .path = image.path,
        .mime_type = image.mime_type,
        .provenance = "dream_time_internal_synthesis",
        .retention = .episode,
        .source_event_ids = try cloneEventIds(self.allocator, &[_][]const u8{generated_event.id}),
        .lifecycle = .{ .created_at = now, .updated_at = now },
    });
    return artifact_id;
}

fn cloneEventIds(allocator: std.mem.Allocator, parents: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, parents.len);
    for (parents, 0..) |parent, i| out[i] = try allocator.dupe(u8, parent);
    return out;
}

fn combineEventIds(allocator: std.mem.Allocator, primary: []const []const u8, secondary: []const []const u8, tertiary: []const []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    try appendUniqueEventIds(allocator, &out, primary);
    try appendUniqueEventIds(allocator, &out, secondary);
    try appendUniqueEventIds(allocator, &out, tertiary);
    return try out.toOwnedSlice(allocator);
}

fn appendUniqueEventIds(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), ids: []const []const u8) !void {
    for (ids) |id| {
        if (id.len == 0) continue;
        var found = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, id)) {
                found = true;
                break;
            }
        }
        if (!found) try out.append(allocator, try allocator.dupe(u8, id));
    }
}

fn sourceEventIdsForMemories(self: *Brain, memories: []const schema.MemoryRecord, memory_ids: []const []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (memory_ids) |memory_id| {
        for (memories) |memory| {
            if (!std.mem.eql(u8, memory.memory_id, memory_id)) continue;
            for (memory.source_event_ids) |event_id| {
                if (event_id.len > 0 and try experienceEventExists(self, event_id)) {
                    try appendUniqueEventIds(self.allocator, &out, &[_][]const u8{event_id});
                }
            }
            break;
        }
    }
    return try out.toOwnedSlice(self.allocator);
}

fn experienceEventExists(self: *Brain, event_id: []const u8) !bool {
    const events = try self.deps.store.loadExperienceEvents(self.allocator);
    for (events) |event| {
        if (std.mem.eql(u8, event.id, event_id)) return true;
    }
    return false;
}

fn selectMemoryIds(allocator: std.mem.Allocator, memories: []const schema.MemoryRecord, residue: DayResidue) ![][]const u8 {
    _ = residue;
    const count = @min(memories.len, 12);
    var out = try allocator.alloc([]const u8, count);
    for (0..count) |i| out[i] = try allocator.dupe(u8, memories[i].memory_id);
    return out;
}
