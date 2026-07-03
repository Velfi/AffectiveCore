const std = @import("std");
const brain_mod = @import("brain.zig");
const experience_kinds = @import("experience_kinds.zig");
const brain_dream_memory = @import("brain_dream_memory.zig");
const helpers = @import("brain_helpers.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const clock_mod = @import("../platform/common/clock.zig");
const Brain = brain_mod.Brain;

pub const DreamModel = struct {
    last_dream_day_key: ?[]const u8 = null,
    dream_available_today: bool = true,
    dreamed_today: bool = false,
};

pub fn dreamedToday(self: *Brain, io: std.Io) !bool {
    const today = try localDayKey(self, io);
    defer self.allocator.free(today);
    const dreams = try self.deps.store.loadDreamTimeRecords(self.allocator);
    for (dreams) |dream| {
        const dream_day = try clock_mod.localDayKeyFromUnix(self.allocator, @divTrunc(dream.created_at_ms, 1000));
        defer self.allocator.free(dream_day);
        if (std.mem.eql(u8, dream_day, today)) return true;
    }
    return false;
}

pub fn dreamModel(self: *Brain, io: std.Io) !DreamModel {
    const today = try localDayKey(self, io);
    defer self.allocator.free(today);
    const dreams = try self.deps.store.loadDreamTimeRecords(self.allocator);
    var last_day_key: ?[]const u8 = null;
    var last_ms: i64 = 0;
    var dreamed = false;
    for (dreams) |dream| {
        const dream_day = try clock_mod.localDayKeyFromUnix(self.allocator, @divTrunc(dream.created_at_ms, 1000));
        if (std.mem.eql(u8, dream_day, today)) dreamed = true;
        if (dream.created_at_ms >= last_ms) {
            if (last_day_key) |previous| self.allocator.free(previous);
            last_ms = dream.created_at_ms;
            last_day_key = dream_day;
        } else {
            self.allocator.free(dream_day);
        }
    }
    return .{
        .last_dream_day_key = last_day_key,
        .dream_available_today = !dreamed,
        .dreamed_today = dreamed,
    };
}

fn localDayKey(self: *Brain, io: std.Io) ![]const u8 {
    self.syncClock(io);
    return clock_mod.localDayKeyFromUnix(self.allocator, self.now_seconds);
}

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
    var persist = try self.deps.store.deferredPersistGuard();
    const item = requestDreamTimeWhilePersisting(self, prompt) catch |err| {
        persist.cancel() catch return error.DeferredPersistEndFailed;
        return err;
    };
    try persist.commit();
    return item;
}

fn requestDreamTimeWhilePersisting(self: *Brain, prompt: ?[]const u8) !schema.MailboxItem {
    const io = self.deps.io orelse return error.LocalDateUnavailable;
    if (try dreamedToday(self, io)) return error.DreamAlreadyCompletedToday;
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
    var experience_event_ids = try experienceEventIdSet(self);
    defer experience_event_ids.deinit();
    const source_ids = try selectMemoryIds(self.allocator, memories, .{ .failure_capability_ids = &.{}, .failure_event_ids = &.{} });
    const residue = try collectDayResidue(self, &experience_event_ids);
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
    const text = try buildDreamMailboxText(
        self.allocator,
        prompt,
        source_ids.len,
        residue,
        reconciliation_count,
        maintenance_counts,
    );
    const mailbox_id = try std.fmt.allocPrint(self.allocator, "mail_dream_{d}", .{self.now_seconds * 1000});
    const dream_id = try std.fmt.allocPrint(self.allocator, "dream_time_{d}", .{self.now_seconds * 1000});
    const spec = try buildDreamImageSpec(self.allocator, memories, source_ids, residue, prompt);
    const image_spec_json = try std.json.Stringify.valueAlloc(self.allocator, spec, .{ .whitespace = .minified });
    const dream_lifecycle_event_ids = [_][]const u8{
        entered_event.id,
        maintenance_started_event.id,
        maintenance_completed_event.id,
    };
    const memory_source_event_ids = try sourceEventIdsForMemories(self, memories, source_ids, &experience_event_ids);
    const source_event_ids = try combineEventIds(self.allocator, &dream_lifecycle_event_ids, memory_source_event_ids, residue.failure_event_ids);

    const generated_artifact_id = try generateDreamImageArtifact(self, spec, prompt);
    const persona_residue = try collectPersonaResidue(self, memories, source_ids, residue);
    defer freePersonaResidue(self.allocator, persona_residue);
    const persona_directive = try self.synthesizeDreamPersonaDirective(reconciliation_count, persona_residue);
    defer persona_directive.deinit(self.allocator);
    try self.setPersonaDirective(persona_directive);
    const waking = try self.allocator.dupe(u8, persona_directive.short_term);
    const persona_directive_event = try self.recordSimpleExperienceEvent(
        experience_kinds.dream_time_persona_directive_synthesized,
        .dream_time,
        dream_id,
    );
    const dream_source_event_ids = try combineEventIds(
        self.allocator,
        source_event_ids,
        &[_][]const u8{persona_directive_event.id},
        &.{},
    );
    defer {
        for (dream_source_event_ids) |id| self.allocator.free(id);
        self.allocator.free(dream_source_event_ids);
    }
    var dream_record: schema.DreamTimeRecord = .{
        .dream_id = dream_id,
        .source_event_ids = try cloneEventIds(self.allocator, dream_source_event_ids),
        .source_memory_ids = source_ids,
        .updated_belief_ids = &.{},
        .self_trust_change_ids = &.{},
        .disposition_change_ids = &.{},
        .maintenance_counts_json = maintenance_counts_json,
        .generated_artifact_id = generated_artifact_id,
        .delivered_mailbox_id = mailbox_id,
        .title = title,
        .text = text,
        .waking_thought = waking,
        .persona = try self.allocator.dupe(u8, persona_directive.persona),
        .short_term = try self.allocator.dupe(u8, persona_directive.short_term),
        .long_term = try self.allocator.dupe(u8, persona_directive.long_term),
        .image_spec = spec,
        .created_at_ms = self.now_seconds * 1000,
    };
    dream_record.delivered_mailbox_id = null;
    try self.deps.store.addDreamTimeRecord(dream_record);
    const item: schema.MailboxItem = .{
        .mailbox_id = mailbox_id,
        .kind = .DreamMail,
        .title = title,
        .text = text,
        .image_artifact_id = generated_artifact_id,
        .image_spec_json = image_spec_json,
        .waking_thought = waking,
        .visible_lesson = "",
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

fn collectDayResidue(self: *Brain, experience_event_ids: *const std.StringHashMap(void)) !DayResidue {
    const period_start_ms = try wakingPeriodStartMs(self);
    const results = try self.deps.store.loadCapabilityResults(self.allocator);
    var capability_ids = std.ArrayList([]const u8).empty;
    var event_ids = std.ArrayList([]const u8).empty;
    for (results) |result| {
        if (result.completed_at_ms < period_start_ms) continue;
        if (result.state != .failed and result.state != .unavailable) continue;
        try capability_ids.append(self.allocator, try self.allocator.dupe(u8, result.capability_id));
        if (result.outcome_event_id.len > 0 and experience_event_ids.contains(result.outcome_event_id)) {
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
    belief_updates: usize = 0,
    self_trust_updates: usize = 0,
    disposition_extractions: usize = 0,
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

fn buildDreamMailboxText(
    allocator: std.mem.Allocator,
    prompt: ?[]const u8,
    memory_count: usize,
    residue: DayResidue,
    reconciliation_count: usize,
    counts: MaintenanceCounts,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    if (prompt) |seed| {
        const trimmed = std.mem.trim(u8, seed, " \r\n\t");
        if (trimmed.len > 0) try out.print(allocator, "Focus: {s}\n\n", .{trimmed});
    }
    try out.appendSlice(allocator, "Overnight consolidation:\n");
    try out.print(allocator, "- memories reviewed: {d}\n", .{memory_count});
    try out.print(allocator, "- capability failures reviewed: {d}\n", .{residue.failure_capability_ids.len});
    try out.print(allocator, "- contradiction reconciliations: {d}\n", .{reconciliation_count});
    if (counts.promoted > 0 or counts.decayed > 0 or counts.removed > 0 or counts.revised > 0) {
        try out.print(
            allocator,
            "- memory changes: promoted={d} decayed={d} revised={d} removed={d}\n",
            .{ counts.promoted, counts.decayed, counts.revised, counts.removed },
        );
    }
    if (counts.cognitive_purged > 0 or counts.captures_purged > 0) {
        try out.print(
            allocator,
            "- cleanup: cognitive_purged={d} captures_purged={d}\n",
            .{ counts.cognitive_purged, counts.captures_purged },
        );
    }
    return out.toOwnedSlice(allocator);
}

fn buildDreamImageSpec(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
    residue: DayResidue,
    prompt: ?[]const u8,
) !schema.DreamImageSpec {
    const subject = try dreamImageSubject(allocator, memories, source_ids, residue, prompt);
    const setting = try dreamImageSetting(allocator, memories, source_ids, residue);
    const symbols = try dreamImageSymbols(allocator, memories, source_ids, residue);
    const mood = try dreamImageMood(allocator, memories, source_ids, residue);
    const visual_style = try dreamImageVisualStyle(allocator, memories, source_ids, residue);
    const avoid = try dreamImageAvoidList(allocator);
    return .{
        .subject = subject,
        .setting = setting,
        .symbols = symbols,
        .mood = mood,
        .visual_style = visual_style,
        .avoid = avoid,
    };
}

fn dreamImageSubject(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
    residue: DayResidue,
    prompt: ?[]const u8,
) ![]const u8 {
    if (prompt) |seed| {
        const trimmed = std.mem.trim(u8, seed, " \r\n\t");
        if (trimmed.len > 0) return truncateDreamPhrase(allocator, trimmed, 96);
    }
    if (try firstSelectedMemoryInterpretation(allocator, memories, source_ids)) |interpretation| {
        return interpretation;
    }
    if (residue.failure_capability_ids.len > 0) {
        return allocator.dupe(u8, "unsettled traces from today's failed capabilities");
    }
    return allocator.dupe(u8, "remembered traces settling into quieter patterns");
}

fn dreamImageSetting(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
    residue: DayResidue,
) ![]const u8 {
    if (try secondSelectedMemoryInterpretation(allocator, memories, source_ids)) |interpretation| {
        return interpretation;
    }
    if (residue.failure_capability_ids.len > 0) {
        return allocator.dupe(u8, "a dim interior where failed attempts replay as soft light");
    }
    return allocator.dupe(u8, "a quiet internal room shaped by the day's residue");
}

fn dreamImageSymbols(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
    residue: DayResidue,
) ![][]const u8 {
    var symbols = std.ArrayList([]const u8).empty;
    errdefer {
        for (symbols.items) |symbol| allocator.free(symbol);
        symbols.deinit(allocator);
    }
    for (source_ids) |memory_id| {
        for (memories) |memory| {
            if (!std.mem.eql(u8, memory.memory_id, memory_id)) continue;
            for (memory.tags) |tag| {
                if (isGenericDreamSymbolTag(tag)) continue;
                try appendUniqueOwnedString(allocator, &symbols, tag);
            }
            break;
        }
    }
    for (residue.failure_capability_ids) |capability_id| {
        try appendUniqueOwnedString(allocator, &symbols, capability_id);
    }
    if (symbols.items.len == 0) {
        const literals = [_][]const u8{ "threads", "windows", "small lanterns" };
        for (literals) |literal| try symbols.append(allocator, try allocator.dupe(u8, literal));
    }
    const count = @min(symbols.items.len, 4);
    const out = try allocator.alloc([]const u8, count);
    for (0..count) |i| out[i] = symbols.items[i];
    for (symbols.items[count..]) |extra| allocator.free(extra);
    symbols.deinit(allocator);
    return out;
}

fn dreamImageMood(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
    residue: DayResidue,
) ![]const u8 {
    var valence_sum: f32 = 0;
    var count: usize = 0;
    for (source_ids) |memory_id| {
        for (memories) |memory| {
            if (!std.mem.eql(u8, memory.memory_id, memory_id)) continue;
            valence_sum += memory.valence;
            count += 1;
            break;
        }
    }
    if (count > 0) {
        const average = valence_sum / @as(f32, @floatFromInt(count));
        if (average >= 0.35) return allocator.dupe(u8, "hopeful");
        if (average <= -0.35) return allocator.dupe(u8, "uneasy");
    }
    if (residue.failure_capability_ids.len > 0) return allocator.dupe(u8, "restless");
    return allocator.dupe(u8, "reflective");
}

fn dreamImageVisualStyle(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
    residue: DayResidue,
) ![]const u8 {
    var salience_peak: f32 = 0;
    for (source_ids) |memory_id| {
        for (memories) |memory| {
            if (!std.mem.eql(u8, memory.memory_id, memory_id)) continue;
            salience_peak = @max(salience_peak, memory.salience);
            break;
        }
    }
    if (salience_peak >= 0.85) return allocator.dupe(u8, "painterly surreal illustration");
    if (residue.failure_capability_ids.len > 0) return allocator.dupe(u8, "moody cinematic illustration");
    return allocator.dupe(u8, "soft cinematic illustration");
}

fn dreamImageAvoidList(allocator: std.mem.Allocator) ![][]const u8 {
    const literals = [_][]const u8{ "photoreal faces", "text overlays" };
    var out = try allocator.alloc([]const u8, literals.len);
    for (literals, 0..) |literal, i| out[i] = try allocator.dupe(u8, literal);
    return out;
}

fn firstSelectedMemoryInterpretation(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
) !?[]const u8 {
    for (source_ids) |memory_id| {
        for (memories) |memory| {
            if (!std.mem.eql(u8, memory.memory_id, memory_id)) continue;
            const interpretation = helpers.memoryInterpretation(memory);
            if (interpretation.len == 0) return null;
            return try truncateDreamPhrase(allocator, interpretation, 96);
        }
    }
    return null;
}

fn secondSelectedMemoryInterpretation(
    allocator: std.mem.Allocator,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
) !?[]const u8 {
    var seen_first = false;
    for (source_ids) |memory_id| {
        for (memories) |memory| {
            if (!std.mem.eql(u8, memory.memory_id, memory_id)) continue;
            const interpretation = helpers.memoryInterpretation(memory);
            if (!seen_first) {
                seen_first = true;
                break;
            }
            if (interpretation.len == 0) return null;
            return try truncateDreamPhrase(allocator, interpretation, 96);
        }
    }
    return null;
}

fn truncateDreamPhrase(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]const u8 {
    if (text.len <= max_len) return allocator.dupe(u8, text);
    var end = max_len;
    while (end > 0 and text[end - 1] != ' ') end -= 1;
    if (end == 0) end = max_len;
    return allocator.dupe(u8, text[0..end]);
}

fn isGenericDreamSymbolTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "dream") or
        std.mem.eql(u8, tag, "memory") or
        std.mem.eql(u8, tag, "self_model") or
        std.mem.eql(u8, tag, "flexible_identity");
}

fn appendUniqueOwnedString(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), value: []const u8) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try out.append(allocator, try allocator.dupe(u8, value));
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

fn sourceEventIdsForMemories(
    self: *Brain,
    memories: []const schema.MemoryRecord,
    memory_ids: []const []const u8,
    experience_event_ids: *const std.StringHashMap(void),
) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (memory_ids) |memory_id| {
        for (memories) |memory| {
            if (!std.mem.eql(u8, memory.memory_id, memory_id)) continue;
            for (memory.source_event_ids) |event_id| {
                if (event_id.len > 0 and experience_event_ids.contains(event_id)) {
                    try appendUniqueEventIds(self.allocator, &out, &[_][]const u8{event_id});
                }
            }
            break;
        }
    }
    return try out.toOwnedSlice(self.allocator);
}

fn experienceEventIdSet(self: *Brain) !std.StringHashMap(void) {
    const events = try self.deps.store.loadExperienceEvents(self.allocator);
    var out = std.StringHashMap(void).init(self.allocator);
    for (events) |event| {
        try out.put(event.id, {});
    }
    return out;
}

fn collectPersonaResidue(
    self: *Brain,
    memories: []const schema.MemoryRecord,
    source_ids: []const []const u8,
    residue: DayResidue,
) !brain_dream_memory.DreamPersonaResidue {
    var interpretations = std.ArrayList([]const u8).empty;
    for (source_ids) |memory_id| {
        for (memories) |memory| {
            if (!std.mem.eql(u8, memory.memory_id, memory_id)) continue;
            try interpretations.append(self.allocator, try self.allocator.dupe(u8, helpers.memoryInterpretation(memory)));
            break;
        }
    }
    return .{
        .failure_capability_ids = residue.failure_capability_ids,
        .memory_interpretations = try interpretations.toOwnedSlice(self.allocator),
    };
}

fn freePersonaResidue(allocator: std.mem.Allocator, residue: brain_dream_memory.DreamPersonaResidue) void {
    for (residue.memory_interpretations) |interpretation| allocator.free(interpretation);
    if (residue.memory_interpretations.len > 0) allocator.free(residue.memory_interpretations);
}

fn selectMemoryIds(allocator: std.mem.Allocator, memories: []const schema.MemoryRecord, residue: DayResidue) ![][]const u8 {
    _ = residue;
    const count = @min(memories.len, 12);
    var out = try allocator.alloc([]const u8, count);
    for (0..count) |i| out[i] = try allocator.dupe(u8, memories[i].memory_id);
    return out;
}
