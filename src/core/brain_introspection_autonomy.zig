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
const brain_autonomy = @import("brain_autonomy.zig");
const capability_registry = @import("capability_registry.zig");
const skill_tree = @import("skill_tree.zig");
const llm_routing = @import("llm_routing.zig");

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

fn traceIntrospectionLoad(self: *Brain, name: []const u8, count: usize) void {
    self.outputFmt("TRACE now={d} stage=introspect.load.done name={s} count={d}\n", .{ self.now_seconds, name, count });
}

fn skillAvailability(ctx: *anyopaque, id: skill_tree.SkillId) bool {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    return actionIsAvailable(self, id);
}

fn skillAvailabilityContext(self: *Brain) skill_tree.Availability {
    return .{ .ctx = self, .isAvailable = skillAvailability };
}

pub fn introspect(self: *Brain, query: ?[]const u8) ![]const u8 {
    const target = skill_tree.parseIntrospectQuery(query);
    self.outputFmt("TRACE now={d} stage=introspect.start query={s}\n", .{
        self.now_seconds,
        query orelse "",
    });
    return switch (target) {
        .overview => try introspectOverview(self),
        .skills_tree => try introspectSkillsTree(self),
        .skills_group => |group| try introspectSkillsGroup(self, group),
        .skill => |id| try introspectSkillDetail(self, id),
        .memory => try introspectMemory(self),
        .facts => try introspectFacts(self),
        .needs => try introspectNeeds(self),
        .capabilities => try introspectCapabilities(self),
        .senses => try introspectSenses(self),
        .autonomy => try introspectAutonomy(self),
        .focus => try introspectFocus(self),
        .identity => try introspectIdentity(self),
        .unknown => |topic| try std.fmt.allocPrint(self.allocator, "introspection: unknown query topic \"{s}\"\nDrill-down topics: skills, skill/<name>, skills/<group>, memory, facts, needs, capabilities, senses, autonomy, focus, identity\n", .{topic}),
    };
}

fn introspectOverview(self: *Brain) ![]const u8 {
    const can_read_memory = capabilityAvailable(self, .stored_memory_read);
    self.outputFmt("TRACE now={d} stage=introspect.memory_capability available={any}\n", .{ self.now_seconds, can_read_memory });
    const memories = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadMemoryRecords(self.allocator);
        traceIntrospectionLoad(self, "memory_records", loaded.len);
        break :blk loaded;
    } else &[_]schema.MemoryRecord{};
    const summaries = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadConversationSummaries(self.allocator);
        traceIntrospectionLoad(self, "conversation_summaries", loaded.len);
        break :blk loaded;
    } else &[_]schema.ConversationSummary{};
    const impressions = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadImpressions(self.allocator);
        traceIntrospectionLoad(self, "impressions", loaded.len);
        break :blk loaded;
    } else &[_]schema.Impression{};
    const appraisals = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadAppraisals(self.allocator);
        traceIntrospectionLoad(self, "appraisals", loaded.len);
        break :blk loaded;
    } else &[_]schema.Appraisal{};
    const dreams = if (can_read_memory) blk: {
        const loaded = try self.deps.store.loadDreamTimeRecords(self.allocator);
        traceIntrospectionLoad(self, "dream_time_records", loaded.len);
        break :blk loaded;
    } else &[_]schema.DreamTimeRecord{};
    var long_count: usize = 0;
    var short_count: usize = 0;
    var score_total: i64 = 0;
    var access_total: u64 = 0;
    var salient: ?schema.MemoryRecord = null;
    for (memories) |memory| {
        switch (memory.scope) {
            .long_term => long_count += 1,
            .short_term => short_count += 1,
        }
        score_total += memory.score;
        access_total += memory.access_count;
        if (salient == null or helpers.memoryIsMoreSalient(memory, salient.?)) salient = memory;
    }
    const salient_text = if (salient) |memory| try memoryOneLineSummary(self, memory) else "none yet";
    const recent_appraisal = if (appraisals.len > 0) appraisals[appraisals.len - 1].freeform else "none yet";
    const memory_status = if (can_read_memory)
        try std.fmt.allocPrint(self.allocator, "{d} long-term, {d} short-term, {d} recent summaries", .{ long_count, short_count, summaries.len })
    else
        try std.fmt.allocPrint(self.allocator, "unavailable: {s}", .{try capabilityUnavailableReason(self, .stored_memory_read)});
    const focus_status = try focusStatusSummary(self);
    const active_need_count = try countActiveNeeds(self);
    const fact_count = try countActiveFacts(self);
    const capability_counts = try capabilityAvailabilityCounts(self);
    var skill_summary = std.ArrayList(u8).empty;
    defer skill_summary.deinit(self.allocator);
    try skill_tree.appendSkillsTree(self.allocator, &skill_summary, skillAvailabilityContext(self));
    const autonomy_line = try autonomyOverviewLine(self);
    return std.fmt.allocPrint(
        self.allocator,
        "introspection overview:\n- memory: {s}\n- impressions={d} appraisals={d} dreams={d}\n- memory_score_total: {d}\n- memory_access_total: {d}\n- salient_memory: {s}\n- recent_appraisal: {s}\n- focus: {s}\n- needs: {d} active (query=needs)\n- facts: {d} active (query=facts)\n- capabilities: {d} available, {d} unavailable (query=capabilities)\n- autonomy: {s} (query=autonomy)\n{s}\nDrill-down topics: skills, skill/<name>, skills/<group>, memory, facts, needs, capabilities, senses, autonomy, focus, identity\n- uncertainty/human_needs: use say when an appraisal needs human help, clarification, or permission; use think_about for private reflection or model-mediated judgment\n",
        .{ memory_status, impressions.len, appraisals.len, dreams.len, score_total, access_total, salient_text, recent_appraisal, focus_status, active_need_count, fact_count, capability_counts.available, capability_counts.unavailable, autonomy_line, skill_summary.items },
    );
}

fn introspectSkillsTree(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "introspection:\n");
    try skill_tree.appendSkillsTree(self.allocator, &out, skillAvailabilityContext(self));
    return out.toOwnedSlice(self.allocator);
}

fn introspectSkillsGroup(self: *Brain, group: skill_tree.SkillGroup) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "introspection:\n");
    try skill_tree.appendGroupCatalog(self.allocator, &out, group, skillAvailabilityContext(self));
    return out.toOwnedSlice(self.allocator);
}

fn introspectSkillDetail(self: *Brain, id: skill_tree.SkillId) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "introspection:\n");
    try skill_tree.appendSkillDetail(self.allocator, &out, id, skillAvailabilityContext(self));
    if (try actionUnavailableReason(self, id)) |reason| {
        try out.print(self.allocator, "unavailable_reason: {s}\n", .{reason});
    }
    return out.toOwnedSlice(self.allocator);
}

fn introspectMemory(self: *Brain) ![]const u8 {
    const can_read_memory = capabilityAvailable(self, .stored_memory_read);
    const memories = if (can_read_memory) try self.deps.store.loadMemoryRecords(self.allocator) else &[_]schema.MemoryRecord{};
    const summaries = if (can_read_memory) try self.deps.store.loadConversationSummaries(self.allocator) else &[_]schema.ConversationSummary{};
    var long_count: usize = 0;
    var short_count: usize = 0;
    var score_total: i64 = 0;
    var access_total: u64 = 0;
    var salient: ?schema.MemoryRecord = null;
    for (memories) |memory| {
        switch (memory.scope) {
            .long_term => long_count += 1,
            .short_term => short_count += 1,
        }
        score_total += memory.score;
        access_total += memory.access_count;
        if (salient == null or helpers.memoryIsMoreSalient(memory, salient.?)) salient = memory;
    }
    const salient_text = if (salient) |memory| try memoryOneLineSummary(self, memory) else "none yet";
    const memory_status = if (can_read_memory)
        try std.fmt.allocPrint(self.allocator, "{d} long-term, {d} short-term, {d} recent summaries", .{ long_count, short_count, summaries.len })
    else
        try std.fmt.allocPrint(self.allocator, "unavailable: {s}", .{try capabilityUnavailableReason(self, .stored_memory_read)});
    return std.fmt.allocPrint(
        self.allocator,
        "introspection memory:\n- memory: {s}\n- memory_score_total: {d}\n- memory_access_total: {d}\n- salient_memory: {s}\n",
        .{ memory_status, score_total, access_total, salient_text },
    );
}

fn introspectFacts(self: *Brain) ![]const u8 {
    const self_facts = try selfFactsSummary(self);
    return std.fmt.allocPrint(self.allocator, "introspection facts:\n{s}", .{self_facts});
}

fn introspectNeeds(self: *Brain) ![]const u8 {
    const needs_status = try activeNeedsSummary(self);
    return std.fmt.allocPrint(self.allocator, "introspection needs:\n{s}", .{needs_status});
}

fn introspectCapabilities(self: *Brain) ![]const u8 {
    const capabilities = try capabilityCatalog(self);
    return std.fmt.allocPrint(self.allocator, "introspection capabilities:\n{s}", .{capabilities});
}

fn introspectSenses(self: *Brain) ![]const u8 {
    const senses = try sensesSummary(self);
    return std.fmt.allocPrint(self.allocator, "introspection senses:\n- senses: {s}\n", .{senses});
}

fn introspectAutonomy(self: *Brain) ![]const u8 {
    const autonomy_status = try brain_autonomy.autonomyIntrospection(self);
    return std.fmt.allocPrint(self.allocator, "introspection autonomy:\n{s}", .{autonomy_status});
}

fn introspectFocus(self: *Brain) ![]const u8 {
    const focus_status = try focusStatusSummary(self);
    return std.fmt.allocPrint(self.allocator, "introspection focus:\n- focus: {s}\n", .{focus_status});
}

fn introspectIdentity(self: *Brain) ![]const u8 {
    const can_read_memory = capabilityAvailable(self, .stored_memory_read);
    const memories = if (can_read_memory) try self.deps.store.loadMemoryRecords(self.allocator) else &[_]schema.MemoryRecord{};
    const flexible_identity_status = try flexibleIdentitySummary(self, memories);
    return std.fmt.allocPrint(self.allocator, "introspection identity:\n{s}", .{flexible_identity_status});
}

fn countActiveFacts(self: *Brain) !usize {
    const records = try self.deps.store.loadFactRecords(self.allocator);
    var count: usize = 0;
    for (records) |record| {
        if (record.active) count += 1;
    }
    return count;
}

fn countActiveNeeds(self: *Brain) !usize {
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const power = try self.deps.system_senses.power(self.allocator);
    const autonomy_state = try brain_autonomy.autonomyStateForNeeds(self);
    const active_needs = try needs_mod.evaluate(self.allocator, .{
        .now_seconds = self.now_seconds,
        .conversation_summaries = summaries,
        .memory_records = memories,
        .relationship_graph = try self.deps.graph.summary(self.allocator, 8),
        .power = power,
        .autonomy_control_capacity = if (autonomy_state) |state| state.control_capacity else null,
        .autonomy_max_capacity = if (autonomy_state) |state| state.max_capacity else self.cfg.autonomy_full_max_capacity,
        .autonomy_sleeping = if (autonomy_state) |state| state.sleeping else null,
    });
    defer needs_mod.freeNeeds(self.allocator, active_needs);
    return active_needs.len;
}

const CapabilityCounts = struct {
    available: usize,
    unavailable: usize,
};

fn capabilityAvailabilityCounts(self: *Brain) !CapabilityCounts {
    var counts = CapabilityCounts{ .available = 0, .unavailable = 0 };
    inline for (@typeInfo(chat_mod.Capability).@"enum".fields) |field| {
        const capability: chat_mod.Capability = @field(chat_mod.Capability, field.name);
        if (capabilityAvailable(self, capability)) {
            counts.available += 1;
        } else {
            counts.unavailable += 1;
        }
    }
    return counts;
}

fn autonomyOverviewLine(self: *Brain) ![]const u8 {
    const state = try brain_autonomy.autonomyStateForNeeds(self);
    if (state) |value| {
        return std.fmt.allocPrint(self.allocator, "mode={s} control={d:.2}/{d:.2} sleeping={any}", .{
            self.cfg.autonomy_mode,
            value.control_capacity,
            value.max_capacity,
            value.sleeping,
        });
    }
    return std.fmt.allocPrint(self.allocator, "mode={s} state=unavailable", .{self.cfg.autonomy_mode});
}

/// One-line view of working memory for the introspect summary.
fn focusStatusSummary(self: *Brain) ![]const u8 {
    if (self.focusMode() == .focused) {
        if (self.current_focus) |focus| {
            const level = self.currentFocusAttention() orelse focus.base_attention;
            return std.fmt.allocPrint(self.allocator, "focused ({s}): {s} (attention={d:.3})", .{ @tagName(focus.source), focus.text, level });
        }
        return self.allocator.dupe(u8, "focused");
    }
    return self.allocator.dupe(u8, "unfocused");
}

pub fn memoryOneLineSummary(self: *Brain, memory: schema.MemoryRecord) ![]const u8 {
    const raw = helpers.memoryInterpretation(memory);
    const first_line_end = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    const first_line = raw[0..first_line_end];
    const max_len: usize = 160;
    const summary = if (first_line.len > max_len)
        try std.fmt.allocPrint(self.allocator, "{s}...", .{first_line[0..max_len]})
    else
        first_line;
    return std.fmt.allocPrint(
        self.allocator,
        "{s} ({s}; score={d}; salience={d:.3})",
        .{ summary, memory.memory_id, memory.score, memory.salience },
    );
}

pub fn affordanceObservation(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try appendAffordanceObservation(self, &out);
    return out.toOwnedSlice(self.allocator);
}

pub fn appendAffordanceObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    try appendLlmPolicyObservation(self, out);
    try out.appendSlice(self.allocator, "Current skill availability:\n");
    try appendAffordanceCatalog(self, out);
}

pub fn appendLlmPolicyObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const quality = llm_routing.LlmQuality.parse(self.cfg.llm_quality) catch .auto;
    const policy = try llm_routing.formatLlmPolicyObservation(self.allocator, quality, self.last_conversation_effort_tier);
    defer self.allocator.free(policy);
    try out.appendSlice(self.allocator, policy);
}

pub fn affordanceCatalog(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try appendAffordanceCatalog(self, &out);
    return out.toOwnedSlice(self.allocator);
}

pub fn appendAffordanceCatalog(self: *Brain, out: *std.ArrayList(u8)) !void {
    try skill_tree.appendConversationSummary(self.allocator, out, skillAvailabilityContext(self));
}

pub fn appendAffordanceCatalogFull(self: *Brain, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(self.allocator, "callable:\n");
    inline for (@typeInfo(chat_mod.ActionProposalType).@"enum".fields) |field| {
        const action: chat_mod.ActionProposalType = @field(chat_mod.ActionProposalType, field.name);
        if (chat_mod.actionSpec(action)) |spec| {
            if (actionIsAvailable(self, action)) {
                try out.print(self.allocator, "- {s}: {s}\n", .{ skills_mod.name(action), spec.description });
            }
        }
    }
}

pub fn actionUnavailableReason(self: *Brain, action: chat_mod.ActionProposalType) !?[]const u8 {
    var visiting = [_]bool{false} ** @typeInfo(chat_mod.ActionProposalType).@"enum".fields.len;
    return skillUnavailableReason(self, action, &visiting);
}

pub fn actionIsAvailable(self: *Brain, action: chat_mod.ActionProposalType) bool {
    var visiting = [_]bool{false} ** @typeInfo(chat_mod.ActionProposalType).@"enum".fields.len;
    return skillIsAvailable(self, action, &visiting);
}

pub fn skillIsAvailable(self: *Brain, action: chat_mod.ActionProposalType, visiting: *[@typeInfo(chat_mod.ActionProposalType).@"enum".fields.len]bool) bool {
    const spec = skills_mod.spec(action) orelse return false;
    const index = @intFromEnum(action);
    if (visiting[index]) return false;
    visiting[index] = true;
    defer visiting[index] = false;

    if (action == .describe_image) {
        if (!senseAvailable(self, .visual_description)) return false;
        if (!senseAvailable(self, .live_camera) and !senseAvailable(self, .stored_image_read)) return false;
    } else {
        for (spec.requires_senses) |sense| {
            if (!senseAvailable(self, sense)) return false;
        }
    }
    for (spec.requires_skills) |required| {
        if (!skillIsAvailable(self, required, visiting)) return false;
    }
    return true;
}

pub fn skillUnavailableReason(self: *Brain, action: chat_mod.ActionProposalType, visiting: *[@typeInfo(chat_mod.ActionProposalType).@"enum".fields.len]bool) !?[]const u8 {
    if (action == .unknown) return "unknown skill";
    const spec = skills_mod.spec(action) orelse return "unknown skill";
    const index = @intFromEnum(action);
    if (visiting[index]) return error.CyclicSkillDependency;
    visiting[index] = true;
    defer visiting[index] = false;

    if (action == .describe_image) {
        if (!senseAvailable(self, .visual_description)) return try capabilityUnavailableReason(self, .visual_description);
        if (!senseAvailable(self, .live_camera) and !senseAvailable(self, .stored_image_read)) return "no live camera or uploaded image is available for this body";
    } else {
        for (spec.requires_senses) |sense| {
            if (!senseAvailable(self, sense)) return try capabilityUnavailableReason(self, sense);
        }
    }
    for (spec.requires_skills) |required| {
        if (try skillUnavailableReason(self, required, visiting)) |reason| {
            return try std.fmt.allocPrint(self.allocator, "required skill {s} unavailable: {s}", .{ skills_mod.name(required), reason });
        }
    }
    return null;
}

pub fn capabilityAvailable(self: *Brain, capability: chat_mod.Capability) bool {
    return senseAvailable(self, capability);
}

pub fn senseAvailable(self: *Brain, capability: chat_mod.Capability) bool {
    const capability_id = @tagName(capability);
    const statuses = self.deps.store.loadCapabilityStatuses(self.allocator) catch return depsSenseAvailable(self, capability);
    if (statuses.len > 0) {
        for (statuses) |status| {
            const canonical = capability_registry.canonicalId(status.capability_id);
            if (!std.mem.eql(u8, canonical, capability_id) and !std.mem.eql(u8, status.capability_id, capability_id)) continue;
            return status.availability == .available or status.availability == .degraded;
        }
        return depsSenseAvailable(self, capability);
    }
    return depsSenseAvailable(self, capability);
}

fn depsSenseAvailable(self: *Brain, capability: chat_mod.Capability) bool {
    if (!self.deps.capabilities.has(capability)) return false;
    return switch (capability) {
        .stored_image_read => self.last_visual_observation_path != null,
        .reminder_io => self.deps.io != null,
        .orientation_query => self.deps.orientation_query != null,
        .email_delivery => self.deps.email_service != null,
        .local_process_io => self.deps.io != null,
        .audio_classification, .audio_transcription => self.deps.audio_inspection_service != null,
        .video_inspection => false,
        .facial_expression_output => self.deps.facial_expression_output != null,
        else => true,
    };
}

pub fn capabilityUnavailableReason(self: *Brain, capability: chat_mod.Capability) ![]const u8 {
    if (!self.deps.capabilities.has(capability)) {
        return skills_mod.senseUnavailableReason(capability);
    }
    return switch (capability) {
        .stored_image_read => "there is no previous retained visual observation to read or compare",
        .reminder_io => "local reminder I/O is unavailable",
        .orientation_query => if (self.deps.orientation_query == null)
            "orientation query is not configured"
        else
            "orientation query is unavailable",
        .email_delivery => if (self.deps.email_service == null)
            "email service is not configured"
        else
            "email delivery is unavailable",
        .local_process_io => "local process I/O is unavailable",
        .audio_classification => "audio classification service is not configured",
        .audio_transcription => "audio transcription service is not configured",
        .video_inspection => "video inspection is not configured",
        .facial_expression_output => if (self.deps.facial_expression_output == null)
            "facial expression output is not configured"
        else
            "facial expression output is unavailable",
        else => try std.fmt.allocPrint(self.allocator, "{s} is unavailable", .{@tagName(capability)}),
    };
}

pub fn capabilityCatalog(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    inline for (@typeInfo(chat_mod.Capability).@"enum".fields) |field| {
        const capability: chat_mod.Capability = @field(chat_mod.Capability, field.name);
        if (capabilityAvailable(self, capability)) {
            try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: available\n", .{field.name}));
        } else {
            try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: unavailable: {s}\n", .{ field.name, try capabilityUnavailableReason(self, capability) }));
        }
    }
    return out.toOwnedSlice(self.allocator);
}

pub fn sensesSummary(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "camera, image description, image comparison, microphone transcription, speech output, date/time");
    const power = try self.deps.system_senses.power(self.allocator);
    var has_battery = false;
    var has_external = false;
    for (power.supplies) |supply| {
        if (std.mem.eql(u8, supply.kind, "Battery")) {
            has_battery = true;
        } else if (supply.online != null) {
            has_external = true;
        }
    }
    if (has_battery) try out.appendSlice(self.allocator, ", battery level");
    if (has_external) try out.appendSlice(self.allocator, ", plugged-in power state");
    const storage = try self.deps.system_senses.storage(self.allocator);
    if (storage.volumes.len > 0) try out.appendSlice(self.allocator, ", storage fullness");
    const database = try self.deps.system_senses.database(self.allocator);
    if (database.databases.len > 0) try out.appendSlice(self.allocator, ", database statistics");
    try out.appendSlice(self.allocator, ", Nano Banana image generation");
    if (capabilityAvailable(self, .email_delivery)) try out.appendSlice(self.allocator, ", email delivery");
    return out.toOwnedSlice(self.allocator);
}

pub fn timeObservation(self: *Brain) ![]const u8 {
    const datetime = try self.deps.system_senses.datetime(self.allocator);
    _ = try self.observeSenseStimulus(.{
        .kind = .time,
        .source = "system_senses",
        .signature = "datetime",
        .raw_magnitude = 0.15,
        .curiosity = 0.05,
        .metadata = "time sense read",
    });
    return system_senses_mod.formatDateTime(self.allocator, datetime);
}

pub fn powerObservation(self: *Brain) ![]const u8 {
    const power = try self.deps.system_senses.power(self.allocator);
    const metrics = powerSenseMetrics(power);
    const signature = try std.fmt.allocPrint(self.allocator, "power:battery:external={any}", .{metrics.external_online});
    _ = try self.observeSenseStimulus(.{
        .kind = .power,
        .source = "system_senses",
        .signature = signature,
        .raw_magnitude = metrics.raw_magnitude,
        .threat = metrics.threat,
        .curiosity = 0.12,
        .safety_relevant = metrics.threat >= 0.35,
        .metadata = "power sense read",
    });
    return system_senses_mod.formatPower(self.allocator, power);
}

pub fn storageObservation(self: *Brain) ![]const u8 {
    const storage = try self.deps.system_senses.storage(self.allocator);
    const max_used = maxStorageUsedPercent(storage);
    const signature = "storage:max_used";
    _ = try self.observeSenseStimulus(.{
        .kind = .storage,
        .source = "system_senses",
        .signature = signature,
        .raw_magnitude = @as(f32, @floatFromInt(max_used)) / 100.0,
        .threat = storageThreat(max_used),
        .curiosity = 0.10,
        .safety_relevant = max_used >= 90,
        .metadata = "storage sense read",
    });
    return system_senses_mod.formatStorage(self.allocator, storage);
}

pub fn databaseObservation(self: *Brain) ![]const u8 {
    const database = try self.deps.system_senses.database(self.allocator);
    const total_bytes = totalDatabaseBytes(database);
    const signature = try std.fmt.allocPrint(self.allocator, "database:count={d}:mb={d}", .{ database.databases.len, total_bytes / (1024 * 1024) });
    _ = try self.observeSenseStimulus(.{
        .kind = .database,
        .source = "system_senses",
        .signature = signature,
        .raw_magnitude = @min(1.0, @as(f32, @floatFromInt(@min(total_bytes, 512 * 1024 * 1024))) / @as(f32, @floatFromInt(512 * 1024 * 1024))),
        .threat = if (total_bytes >= 512 * 1024 * 1024) 0.30 else 0,
        .curiosity = 0.10,
        .metadata = "database sense read",
    });
    return system_senses_mod.formatDatabase(self.allocator, database);
}

const PowerMetrics = struct {
    min_battery_percent: ?u8 = null,
    external_online: bool = false,
    raw_magnitude: f32 = 0.15,
    threat: f32 = 0,
};

fn powerSenseMetrics(power: system_senses_mod.PowerSnapshot) PowerMetrics {
    var out = PowerMetrics{};
    for (power.supplies) |supply| {
        if (supply.online) |online| out.external_online = out.external_online or online;
        if (!std.mem.eql(u8, supply.kind, "Battery")) continue;
        const capacity = supply.capacity_percent orelse continue;
        out.min_battery_percent = if (out.min_battery_percent) |current| @min(current, capacity) else capacity;
    }
    if (out.min_battery_percent) |capacity| {
        out.raw_magnitude = 1.0 - (@as(f32, @floatFromInt(capacity)) / 100.0);
        if (!out.external_online and capacity <= 5) out.threat = 0.95 else if (!out.external_online and capacity <= 15) out.threat = 0.65 else if (!out.external_online and capacity <= 30) out.threat = 0.35;
    }
    return out;
}

fn maxStorageUsedPercent(storage: system_senses_mod.StorageSnapshot) u8 {
    var max_used: u8 = 0;
    for (storage.volumes) |volume| max_used = @max(max_used, volume.used_percent);
    return max_used;
}

fn storageThreat(max_used: u8) f32 {
    if (max_used >= 98) return 0.85;
    if (max_used >= 90) return 0.55;
    if (max_used >= 80) return 0.25;
    return 0;
}

fn totalDatabaseBytes(database: system_senses_mod.DatabaseSnapshot) u64 {
    var total: u64 = 0;
    for (database.databases) |db| total += db.total_bytes;
    return total;
}

pub fn selfFactsSummary(self: *Brain) ![]const u8 {
    const records = try self.deps.store.loadFactRecords(self.allocator);
    return facts.formatSummary(self.allocator, records, self.now_seconds, null);
}

pub fn selfFactsConversationSummary(self: *Brain) ![]const u8 {
    const records = try self.deps.store.loadFactRecords(self.allocator);
    return facts.formatSummary(self.allocator, records, self.now_seconds, facts.conversation_self_facts_max_bytes);
}

pub fn activeNeedsSummary(self: *Brain) ![]const u8 {
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const power = try self.deps.system_senses.power(self.allocator);
    const autonomy_state = try brain_autonomy.autonomyStateForNeeds(self);
    const active_needs = try needs_mod.evaluate(self.allocator, .{
        .now_seconds = self.now_seconds,
        .conversation_summaries = summaries,
        .memory_records = memories,
        .relationship_graph = try self.deps.graph.summary(self.allocator, 8),
        .power = power,
        .autonomy_control_capacity = if (autonomy_state) |state| state.control_capacity else null,
        .autonomy_max_capacity = if (autonomy_state) |state| state.max_capacity else self.cfg.autonomy_full_max_capacity,
        .autonomy_sleeping = if (autonomy_state) |state| state.sleeping else null,
    });
    return needs_mod.formatNeeds(self.allocator, active_needs);
}

pub fn flexibleIdentitySummary(self: *Brain, memories: []const schema.MemoryRecord) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, "flexible_identity_box:\n");
    var count: usize = 0;
    for (memories) |memory| {
        if (!helpers.tagInSlice(memory.tags, "flexible_identity") or !helpers.tagInSlice(memory.tags, "pending_dream_reconciliation")) continue;
        count += 1;
        try out.print(self.allocator, "- {s}: salience={d:.3}; score={d}; text={s}\n", .{ memory.memory_id, memory.salience, memory.score, helpers.memoryInterpretation(memory) });
    }
    if (count == 0) try out.appendSlice(self.allocator, "- none\n");
    return out.toOwnedSlice(self.allocator);
}

pub fn superegoSelfModelSummary(self: *Brain, memories: []const schema.MemoryRecord) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var count: usize = 0;
    for (memories) |memory| {
        if (!helpers.tagInSlice(memory.tags, "superego_principle")) continue;
        if (helpers.tagInSlice(memory.tags, "pending_dream_reconciliation")) continue;
        count += 1;
        try out.print(self.allocator, "- principle:{s}: {s}; confidence={d:.2}; salience={d:.2}\n", .{
            memory.memory_id,
            helpers.memoryInterpretation(memory),
            memory.confidence,
            memory.salience,
        });
    }
    if (count == 0) try out.appendSlice(self.allocator, "- none\n");
    return out.toOwnedSlice(self.allocator);
}
