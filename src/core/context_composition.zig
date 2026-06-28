const std = @import("std");
const chat = @import("port_chat.zig");
const greeting_port = @import("port_greeting.zig");
const intent_port = @import("port_intent.zig");
const want_port = @import("port_want_achievement.zig");
const psyche_mod = @import("psyche.zig");
const memory_types = @import("actors/memory/types.zig");

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
    "host_sense_pull_requested:",
    "host_sense_delivered:",
    "prior_outward_reply:",
    "skill_failed:",
    "recognition_dedup:",
    "subsystem_pressure_selected:",
    "subsystem_pressure_suppressed:",
    "memory_retrieval:",
    "capability_execution.",
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
        out[0] = .{ .name = "other", .bytes = text.len };
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
        try sections.append(allocator, .{ .name = "other", .bytes = merged.items[0].offset });
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

pub fn auditConversationPrompt(
    allocator: std.mem.Allocator,
    memory: []const u8,
    memory_sections: []const SectionStat,
    user_text: []const u8,
    observations: []const u8,
    turn_index: ?usize,
) !ContextCompositionReport {
    const prompt_audit = try chat.auditChatPrompt(allocator, memory, user_text, observations);
    const observation_sections = try auditMarkedSections(allocator, observations, &observation_section_markers);
    defer allocator.free(observation_sections);

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
    defer combined.deinit(allocator);
    for (prefixed_memory) |section| try combined.append(allocator, section);
    try combined.append(allocator, .{ .name = "user_input", .bytes = user_input_bytes });
    for (observation_sections) |section| try combined.append(allocator, section);

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

pub fn auditGreetingContext(context: greeting_port.GreetingContext) ContextCompositionReport {
    const sections = [_]SectionStat{
        .{ .name = "visual_description", .bytes = context.visual_description.len },
        .{ .name = "change_summary", .bytes = context.change_summary.len },
        .{ .name = "senses", .bytes = context.senses.len },
        .{ .name = "interior_state", .bytes = context.interior_state.len },
        .{ .name = "stable_notes", .bytes = notesBytes(context.stable_notes), .count = context.stable_notes.len },
        .{ .name = "recent_notes", .bytes = notesBytes(context.recent_notes), .count = context.recent_notes.len },
        .{ .name = "person_name", .bytes = if (context.person_name) |name| name.len else 0 },
    };
    return finishReport("greeting", sumSections(&sections), &sections, .{});
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

pub fn auditIntent(context: intent_port.IntentContext, utterance: []const u8) ContextCompositionReport {
    const sections = [_]SectionStat{
        .{ .name = "context_tag", .bytes = @tagName(context).len },
        .{ .name = "utterance", .bytes = utterance.len },
    };
    return finishReport("intent_classify", @tagName(context).len + utterance.len, &sections, .{});
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
