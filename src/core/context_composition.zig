const std = @import("std");
const chat = @import("port_chat.zig");
const want_port = @import("port_want_achievement.zig");
const psyche_mod = @import("psyche.zig");
const memory_types = @import("actors/memory/types.zig");
const context_salience = @import("context_salience.zig");
const context_tokens = @import("context_tokens.zig");

pub const ContextBlock = struct {
    kind: context_salience.ContextSectionKind,
    text: []const u8,
    rank: u16,
    protected: bool,
    order_index: usize,
    count: ?usize = null,
};

pub const TrimResult = struct {
    memory: []const u8,
    observations: []const u8,
    memory_sections: []SectionStat,
    dropped: []const []const u8,

    pub fn deinit(self: TrimResult, allocator: std.mem.Allocator) void {
        allocator.free(self.memory);
        allocator.free(self.observations);
        for (self.memory_sections) |section| allocator.free(section.name);
        allocator.free(self.memory_sections);
        for (self.dropped) |name| allocator.free(name);
        allocator.free(self.dropped);
    }
};

fn isMemoryBlock(block: ContextBlock) bool {
    return switch (block.kind) {
        .memory => true,
        .observation => false,
    };
}

pub fn sortBlocks(blocks: []ContextBlock) void {
    std.mem.sort(ContextBlock, blocks, {}, struct {
        fn lessThan(_: void, lhs: ContextBlock, rhs: ContextBlock) bool {
            if (lhs.rank != rhs.rank) return lhs.rank > rhs.rank;
            const lhs_mem = isMemoryBlock(lhs);
            const rhs_mem = isMemoryBlock(rhs);
            if (lhs_mem != rhs_mem) return lhs_mem;
            return lhs.order_index < rhs.order_index;
        }
    }.lessThan);
}

fn userPromptFixedOverheadBytes(user_text: []const u8, stimulus: chat.StimulusKind) usize {
    const header = "# Compact Memory\n\n# User Input\n\n# Observations\n";
    const stimulus_label = switch (stimulus) {
        .heard_speech => "heard speech",
        .reconsideration => "reconsideration",
        .host_sense_delivery => "awaited sense delivery",
        .orchestration => "orchestration",
    };
    // "Stimulus ({label}): \"{text}\"" plus newlines between sections
    return header.len + "Stimulus (".len + stimulus_label.len + "): \"".len + user_text.len + "\"".len + 2;
}

fn blocksTokenEstimate(blocks: []const ContextBlock) usize {
    var total: usize = 0;
    for (blocks) |block| total += context_tokens.estimateTokens(block.text);
    return total;
}

pub fn assembleBlocks(allocator: std.mem.Allocator, blocks: []const ContextBlock) !struct {
    memory: []const u8,
    observations: []const u8,
    memory_sections: []SectionStat,
} {
    var memory_out = std.ArrayList(u8).empty;
    defer memory_out.deinit(allocator);
    var observation_out = std.ArrayList(u8).empty;
    defer observation_out.deinit(allocator);
    var memory_sections = std.ArrayList(SectionStat).empty;
    errdefer {
        for (memory_sections.items) |section| allocator.free(section.name);
        memory_sections.deinit(allocator);
    }

    for (blocks) |block| {
        if (block.text.len == 0) continue;
        if (isMemoryBlock(block)) {
            const before = memory_out.items.len;
            try memory_out.appendSlice(allocator, block.text);
            const name = try allocator.dupe(u8, block.kind.sectionName());
            try memory_sections.append(allocator, .{
                .name = name,
                .bytes = memory_out.items.len - before,
                .count = block.count,
            });
        } else {
            try observation_out.appendSlice(allocator, block.text);
        }
    }

    return .{
        .memory = try memory_out.toOwnedSlice(allocator),
        .observations = try observation_out.toOwnedSlice(allocator),
        .memory_sections = try memory_sections.toOwnedSlice(allocator),
    };
}

pub fn trimToTokenBudget(
    allocator: std.mem.Allocator,
    memory_blocks: []ContextBlock,
    observation_blocks: []ContextBlock,
    user_text: []const u8,
    stimulus: chat.StimulusKind,
    max_tokens: usize,
) !TrimResult {
    var all = std.ArrayList(ContextBlock).empty;
    defer all.deinit(allocator);
    var order: usize = 0;
    for (memory_blocks) |block| {
        try all.append(allocator, block);
        order += 1;
    }
    for (observation_blocks) |block| {
        try all.append(allocator, .{
            .kind = block.kind,
            .text = block.text,
            .rank = block.rank,
            .protected = block.protected,
            .order_index = order,
            .count = block.count,
        });
        order += 1;
    }

    const fixed_overhead = userPromptFixedOverheadBytes(user_text, stimulus);
    const fixed_tokens = context_tokens.estimateTokensFromByteLength(fixed_overhead);
    if (fixed_tokens >= max_tokens) return error.ContextBudgetExceeded;

    const content_budget = max_tokens - fixed_tokens;

    var protected_blocks = std.ArrayList(ContextBlock).empty;
    defer protected_blocks.deinit(allocator);
    var droppable_blocks = std.ArrayList(ContextBlock).empty;
    defer droppable_blocks.deinit(allocator);

    for (all.items) |block| {
        if (block.protected) {
            try protected_blocks.append(allocator, block);
        } else if (block.text.len > 0) {
            try droppable_blocks.append(allocator, block);
        }
    }

    const protected_tokens = blocksTokenEstimate(protected_blocks.items);
    if (protected_tokens > content_budget) return error.ContextBudgetExceeded;

    sortBlocks(droppable_blocks.items);
    var included_droppable = std.ArrayList(ContextBlock).empty;
    defer included_droppable.deinit(allocator);
    var used_tokens = protected_tokens;
    for (droppable_blocks.items) |block| {
        const block_tokens = context_tokens.estimateTokens(block.text);
        if (used_tokens + block_tokens <= content_budget) {
            try included_droppable.append(allocator, block);
            used_tokens += block_tokens;
        }
    }

    var included = std.ArrayList(ContextBlock).empty;
    defer included.deinit(allocator);
    for (protected_blocks.items) |block| {
        if (block.text.len > 0) try included.append(allocator, block);
    }
    try included.appendSlice(allocator, included_droppable.items);
    sortBlocks(included.items);

    var dropped = std.ArrayList([]const u8).empty;
    errdefer {
        for (dropped.items) |name| allocator.free(name);
        dropped.deinit(allocator);
    }
    for (droppable_blocks.items) |block| {
        var kept = false;
        for (included_droppable.items) |inc| {
            if (inc.order_index == block.order_index) {
                kept = true;
                break;
            }
        }
        if (!kept) {
            const dropped_name = try std.fmt.allocPrint(allocator, "dropped.{s}", .{block.kind.sectionName()});
            try dropped.append(allocator, dropped_name);
        }
    }

    const assembled = try assembleBlocks(allocator, included.items);
    return .{
        .memory = assembled.memory,
        .observations = assembled.observations,
        .memory_sections = assembled.memory_sections,
        .dropped = try dropped.toOwnedSlice(allocator),
    };
}

pub fn appendToBuffer(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (text.len == 0) return;
    try out.appendSlice(allocator, text);
}

pub const SectionStat = struct {
    name: []const u8,
    bytes: usize,
    count: ?usize = null,
};

pub const ContextCompositionReport = struct {
    operation: []const u8,
    turn_index: ?usize = null,
    total_bytes: usize,
    system_prompt_bytes: ?usize = null,
    compact_memory_bytes: usize = 0,
    observations_bytes: usize = 0,
    user_prompt_bytes: usize = 0,
    user_prompt_tokens: usize = 0,
    sections: []const SectionStat,
};

threadlocal var report_sections_scratch: [16]SectionStat = undefined;

fn finishReport(
    operation: []const u8,
    total_bytes: usize,
    in_sections: []const SectionStat,
    extra: struct {
        turn_index: ?usize = null,
        system_prompt_bytes: ?usize = null,
        compact_memory_bytes: usize = 0,
        observations_bytes: usize = 0,
        user_prompt_bytes: usize = 0,
        user_prompt_tokens: usize = 0,
    },
) ContextCompositionReport {
    std.debug.assert(in_sections.len <= report_sections_scratch.len);
    @memcpy(report_sections_scratch[0..in_sections.len], in_sections);
    return .{
        .operation = operation,
        .turn_index = extra.turn_index,
        .total_bytes = total_bytes,
        .system_prompt_bytes = extra.system_prompt_bytes,
        .compact_memory_bytes = extra.compact_memory_bytes,
        .observations_bytes = extra.observations_bytes,
        .user_prompt_bytes = extra.user_prompt_bytes,
        .user_prompt_tokens = extra.user_prompt_tokens,
        .sections = report_sections_scratch[0..in_sections.len],
    };
}

pub const observation_section_markers = [_][]const u8{
    "user_text:",
    "heard_speech sense:",
    "user_language_hint:",
    "social_context:",
    "read_models_snapshot:",
    "attention_capacity:",
    "Current skill availability:",
    "skill_library:",
    "recent_experience:",
    "stimulus_continuity:",
    "waiting_for:",
    "active_activity:",
    "associative_recall_possibilities:",
    "memory_selection:",
    "host_capability_summary:",
    "host_capability_activations:",
    "facial_expression_catalog:",
    "host_sense_pull_requested:",
    "host_sense_delivered:",
    "checkpoint_resume:",
    "conversation_cotext:",
    "prior_outward_reply:",
    "skill_failed:",
    "recognition_dedup:",
    "subsystem_pressure_selected:",
    "subsystem_pressure_suppressed:",
    "memory_retrieval:",
    "capability_execution.",
    "overlap_nudge:",
    "stimulus_response_nudge:",
    "orchestration_nudge:",
    "salient_sense:",
    "salient_sense_during_conversation:",
    "emoji_reaction:",
    "emoji_reaction_during_conversation:",
    "present_moment:",
    "deferred_coherence:",
    "action_suppressed:",
    "introspect_result:",
    "skill_result:",
};

pub fn sumSections(sections: []const SectionStat) usize {
    var total: usize = 0;
    for (sections) |section| total += section.bytes;
    return total;
}

const MarkerHit = struct {
    offset: usize,
    name: []const u8,
};

fn markerName(marker: []const u8) []const u8 {
    if (std.mem.endsWith(u8, marker, ":")) return marker[0 .. marker.len - 1];
    return marker;
}

pub fn auditMarkedSections(allocator: std.mem.Allocator, text: []const u8, markers: []const []const u8) ![]SectionStat {
    if (text.len == 0) return try allocator.alloc(SectionStat, 0);

    var hits = std.ArrayList(MarkerHit).empty;
    defer hits.deinit(allocator);

    for (markers) |marker| {
        var search_from: usize = 0;
        while (search_from < text.len) {
            const relative = std.mem.indexOfPos(u8, text, search_from, marker) orelse break;
            const at_line_start = relative == 0 or text[relative - 1] == '\n';
            if (!at_line_start) {
                search_from = relative + marker.len;
                continue;
            }
            try hits.append(allocator, .{ .offset = relative, .name = markerName(marker) });
            search_from = relative + marker.len;
        }
    }

    if (hits.items.len == 0) {
        const out = try allocator.alloc(SectionStat, 1);
        out[0] = .{ .name = try allocator.dupe(u8, "other"), .bytes = text.len };
        return out;
    }

    std.mem.sort(MarkerHit, hits.items, {}, struct {
        fn lessThan(_: void, lhs: MarkerHit, rhs: MarkerHit) bool {
            return lhs.offset < rhs.offset;
        }
    }.lessThan);

    var merged = std.ArrayList(MarkerHit).empty;
    defer merged.deinit(allocator);
    for (hits.items) |hit| {
        if (merged.items.len > 0 and merged.items[merged.items.len - 1].offset == hit.offset) continue;
        try merged.append(allocator, hit);
    }

    var sections = std.ArrayList(SectionStat).empty;
    errdefer sections.deinit(allocator);

    if (merged.items[0].offset > 0) {
        try sections.append(allocator, .{ .name = try allocator.dupe(u8, "other"), .bytes = merged.items[0].offset });
    }

    var index: usize = 0;
    while (index < merged.items.len) : (index += 1) {
        const hit = merged.items[index];
        const end = if (index + 1 < merged.items.len) merged.items[index + 1].offset else text.len;
        const section_name = try std.fmt.allocPrint(allocator, "observations.{s}", .{hit.name});
        try sections.append(allocator, .{ .name = section_name, .bytes = end - hit.offset });
    }

    return try sections.toOwnedSlice(allocator);
}

pub fn prefixMemorySections(allocator: std.mem.Allocator, sections: []const SectionStat) ![]SectionStat {
    var out = try allocator.alloc(SectionStat, sections.len);
    for (sections, 0..) |section, index| {
        const name = try std.fmt.allocPrint(allocator, "compact_memory.{s}", .{section.name});
        out[index] = .{ .name = name, .bytes = section.bytes, .count = section.count };
    }
    return out;
}

fn appendOwnedSection(allocator: std.mem.Allocator, out: *std.ArrayList(SectionStat), section: SectionStat) !void {
    try out.append(allocator, .{
        .name = try allocator.dupe(u8, section.name),
        .bytes = section.bytes,
        .count = section.count,
    });
}

pub const top_section_limit: usize = 10;

pub fn ownedTopSections(
    allocator: std.mem.Allocator,
    sections: []const SectionStat,
    limit: usize,
) ![]SectionStat {
    if (sections.len == 0) return try allocator.alloc(SectionStat, 0);
    const ranked = try allocator.alloc(SectionStat, sections.len);
    @memcpy(ranked, sections);
    std.mem.sort(SectionStat, ranked, {}, struct {
        fn lessThan(_: void, lhs: SectionStat, rhs: SectionStat) bool {
            if (lhs.bytes != rhs.bytes) return lhs.bytes > rhs.bytes;
            return std.mem.order(u8, lhs.name, rhs.name) == .lt;
        }
    }.lessThan);
    const take = @min(limit, ranked.len);
    var out = try allocator.alloc(SectionStat, take);
    for (0..take) |index| {
        out[index] = .{
            .name = try allocator.dupe(u8, ranked[index].name),
            .bytes = ranked[index].bytes,
            .count = ranked[index].count,
        };
    }
    allocator.free(ranked);
    return out;
}

pub fn auditConversationPrompt(
    allocator: std.mem.Allocator,
    memory: []const u8,
    memory_sections: []const SectionStat,
    user_text: []const u8,
    observations: []const u8,
    turn_index: ?usize,
) !ContextCompositionReport {
    const prompt_audit = try chat.auditChatPrompt(allocator, memory, user_text, observations, .heard_speech);
    const observation_sections = try auditMarkedSections(allocator, observations, &observation_section_markers);
    defer {
        for (observation_sections) |section| allocator.free(section.name);
        allocator.free(observation_sections);
    }

    const prefixed_memory = try prefixMemorySections(allocator, memory_sections);
    defer {
        for (prefixed_memory) |section| allocator.free(section.name);
        allocator.free(prefixed_memory);
    }

    var user_input_bytes: usize = 0;
    const user_input_line = try std.fmt.allocPrint(allocator, "Stimulus: \"{s}\"", .{user_text});
    defer allocator.free(user_input_line);
    user_input_bytes = user_input_line.len;

    var combined = std.ArrayList(SectionStat).empty;
    errdefer {
        for (combined.items) |section| allocator.free(section.name);
        combined.deinit(allocator);
    }
    for (prefixed_memory) |section| try appendOwnedSection(allocator, &combined, section);
    try appendOwnedSection(allocator, &combined, .{ .name = "user_input", .bytes = user_input_bytes });
    for (observation_sections) |section| try appendOwnedSection(allocator, &combined, section);

    return .{
        .operation = "conversation_chat",
        .turn_index = turn_index,
        .total_bytes = prompt_audit.user_prompt_bytes + prompt_audit.system_prompt_bytes,
        .system_prompt_bytes = prompt_audit.system_prompt_bytes,
        .compact_memory_bytes = prompt_audit.compact_memory_bytes,
        .observations_bytes = prompt_audit.observations_bytes,
        .user_prompt_bytes = prompt_audit.user_prompt_bytes,
        .user_prompt_tokens = prompt_audit.user_prompt_tokens,
        .sections = try combined.toOwnedSlice(allocator),
    };
}

pub fn auditPsycheSharedInputs(inputs: psyche_mod.SharedInputs) ContextCompositionReport {
    const sections = [_]SectionStat{
        .{ .name = "needs", .bytes = needListBytes(inputs.needs), .count = inputs.needs.len },
        .{ .name = "memories", .bytes = memoryListBytes(inputs.memories), .count = inputs.memories.len },
        .{ .name = "appraisals", .bytes = appraisalListBytes(inputs.appraisals), .count = inputs.appraisals.len },
        .{ .name = "impressions", .bytes = impressionListBytes(inputs.impressions), .count = inputs.impressions.len },
        .{ .name = "relationship_graph", .bytes = inputs.relationship_graph.len },
        .{ .name = "affordances", .bytes = inputs.affordances.len },
        .{ .name = "superego_self_model", .bytes = inputs.superego_self_model.len },
        .{ .name = "current_stimulus", .bytes = inputs.current_stimulus.len },
        .{ .name = "blocked", .bytes = inputs.blocked.len },
        .{ .name = "mode", .bytes = inputs.mode.len },
        .{ .name = "now", .bytes = inputs.now.len },
    };
    return finishReport("psyche_shared", sumSections(&sections), &sections, .{});
}

pub fn auditPsycheEgoContext(shared_bytes: usize, id_bytes: usize, superego_bytes: usize) ContextCompositionReport {
    const sections = [_]SectionStat{
        .{ .name = "shared", .bytes = shared_bytes },
        .{ .name = "id_turn", .bytes = id_bytes },
        .{ .name = "superego_turn", .bytes = superego_bytes },
    };
    return finishReport("psyche_ego", shared_bytes + id_bytes + superego_bytes, &sections, .{});
}

pub fn auditAutonomyPlan(context_bytes: usize) ContextCompositionReport {
    const sections = [_]SectionStat{
        .{ .name = "ego_context", .bytes = context_bytes },
    };
    return finishReport("autonomy_plan", context_bytes, &sections, .{});
}

pub fn auditWantAchievement(event_text: []const u8, wants: []const want_port.WantCandidate) ContextCompositionReport {
    var wants_bytes: usize = 0;
    for (wants) |want| {
        wants_bytes += want.memory_id.len + want.text.len + want.interpretation.len;
    }
    const sections = [_]SectionStat{
        .{ .name = "event", .bytes = event_text.len },
        .{ .name = "active_wants", .bytes = wants_bytes, .count = wants.len },
    };
    return finishReport("want_achievement", event_text.len + wants_bytes, &sections, .{});
}

pub fn auditMemoryExtraction(episode_text: []const u8) ContextCompositionReport {
    const sections = [_]SectionStat{
        .{ .name = "episode_text", .bytes = episode_text.len },
    };
    return finishReport("memory_extraction", episode_text.len, &sections, .{});
}

pub fn auditMemorySelection(user_utterance: []const u8, candidates: []const @import("port_memory_selection.zig").MemoryCandidate) ContextCompositionReport {
    var candidate_bytes: usize = 0;
    for (candidates) |candidate| {
        candidate_bytes += candidate.memory_id.len + candidate.interpretation.len;
    }
    const sections = [_]SectionStat{
        .{ .name = "what_reached_you", .bytes = user_utterance.len },
        .{ .name = "candidates", .bytes = candidate_bytes, .count = candidates.len },
    };
    return finishReport("memory_selection", user_utterance.len + candidate_bytes, &sections, .{});
}

pub fn auditMemoryRetrieval(query: []const u8, matches: []const memory_types.RetrievalMatch) ContextCompositionReport {
    var match_bytes: usize = 0;
    for (matches) |match| {
        match_bytes += match.memory_id.len + match.text.len;
    }
    const sections = [_]SectionStat{
        .{ .name = "query", .bytes = query.len },
        .{ .name = "matches", .bytes = match_bytes, .count = matches.len },
    };
    return finishReport("memory_retrieval", query.len + match_bytes, &sections, .{});
}

pub fn auditPsycheConsult(voice: []const u8, shared_context_bytes: usize) ContextCompositionReport {
    const sections = [_]SectionStat{
        .{ .name = voice, .bytes = shared_context_bytes },
    };
    return finishReport("psyche_consult", shared_context_bytes, &sections, .{});
}

fn needListBytes(needs: []const @import("needs.zig").Need) usize {
    var total: usize = 0;
    for (needs) |need| {
        total += need.need_id.len + need.text.len + need.evidence.len + need.desired_action.len;
    }
    return total;
}

fn memoryListBytes(memories: []const @import("ports.zig").schema.MemoryRecord) usize {
    var total: usize = 0;
    for (memories) |memory| {
        total += memory.text.len + memory.interpretation.len + memory.memory_id.len;
    }
    return total;
}

fn appraisalListBytes(appraisals: []const @import("ports.zig").schema.Appraisal) usize {
    var total: usize = 0;
    for (appraisals) |appraisal| {
        total += appraisal.query.len + appraisal.freeform.len + appraisal.feeling_label.len;
    }
    return total;
}

fn impressionListBytes(impressions: []const @import("ports.zig").schema.Impression) usize {
    var total: usize = 0;
    for (impressions) |impression| {
        total += impression.text.len + impression.impression_id.len;
    }
    return total;
}

fn notesBytes(notes: []const []const u8) usize {
    var total: usize = 0;
    for (notes) |note| total += note.len;
    return total;
}

pub fn traceReport(now_seconds: i64, report: ContextCompositionReport, write: *const fn (now_seconds: i64, line: []const u8) void) void {
    traceReportCtx(null, now_seconds, "(none)", report, defaultWriteAdapter, write);
}

fn defaultWriteAdapter(ctx: ?*anyopaque, now_seconds: i64, line: []const u8, write: *const fn (now_seconds: i64, line: []const u8) void) void {
    _ = ctx;
    write(now_seconds, line);
}

pub fn traceReportCtx(
    ctx: ?*anyopaque,
    now_seconds: i64,
    dispatch_id: []const u8,
    report: ContextCompositionReport,
    adapter: *const fn (ctx: ?*anyopaque, now_seconds: i64, line: []const u8, write: *const fn (now_seconds: i64, line: []const u8) void) void,
    write: *const fn (now_seconds: i64, line: []const u8) void,
) void {
    var summary_buf: [320]u8 = undefined;
    const summary_line = if (report.turn_index) |turn_index| blk: {
        if (report.system_prompt_bytes) |system_prompt_bytes| {
            break :blk std.fmt.bufPrint(
                &summary_buf,
                "TRACE now={d} dispatch_id={s} stage=context.composition operation={s} turn={d} total_bytes={d} system_prompt_bytes={d}\n",
                .{ now_seconds, dispatch_id, report.operation, turn_index, report.total_bytes, system_prompt_bytes },
            ) catch return;
        }
        break :blk std.fmt.bufPrint(&summary_buf, "TRACE now={d} dispatch_id={s} stage=context.composition operation={s} turn={d} total_bytes={d}\n", .{ now_seconds, dispatch_id, report.operation, turn_index, report.total_bytes }) catch return;
    } else if (report.system_prompt_bytes) |system_prompt_bytes| blk: {
        break :blk std.fmt.bufPrint(
            &summary_buf,
            "TRACE now={d} dispatch_id={s} stage=context.composition operation={s} total_bytes={d} system_prompt_bytes={d}\n",
            .{ now_seconds, dispatch_id, report.operation, report.total_bytes, system_prompt_bytes },
        ) catch return;
    } else std.fmt.bufPrint(&summary_buf, "TRACE now={d} dispatch_id={s} stage=context.composition operation={s} total_bytes={d}\n", .{ now_seconds, dispatch_id, report.operation, report.total_bytes }) catch return;
    adapter(ctx, now_seconds, summary_line, write);

    for (report.sections) |section| {
        var section_buf: [448]u8 = undefined;
        const line = if (section.count) |count|
            std.fmt.bufPrint(&section_buf, "TRACE now={d} dispatch_id={s} stage=context.composition operation={s} section={s} bytes={d} count={d}\n", .{ now_seconds, dispatch_id, report.operation, section.name, section.bytes, count }) catch continue
        else
            std.fmt.bufPrint(&section_buf, "TRACE now={d} dispatch_id={s} stage=context.composition operation={s} section={s} bytes={d}\n", .{ now_seconds, dispatch_id, report.operation, section.name, section.bytes }) catch continue;
        adapter(ctx, now_seconds, line, write);
    }
}

pub fn traceReportToDebug(now_seconds: i64, report: ContextCompositionReport) void {
    traceReportCtx(null, now_seconds, "(none)", report, defaultWriteAdapter, traceWriteDebug);
}

fn traceWriteDebug(_: i64, line: []const u8) void {
    std.debug.print("{s}", .{line});
}

pub fn noteSection(
    allocator: std.mem.Allocator,
    sections: ?*std.ArrayList(SectionStat),
    out_len_before: usize,
    out_len_after: usize,
    name: []const u8,
    count: ?usize,
) !void {
    const sections_list = sections orelse return;
    if (out_len_after <= out_len_before) return;
    try sections_list.append(allocator, .{
        .name = name,
        .bytes = out_len_after - out_len_before,
        .count = count,
    });
}
