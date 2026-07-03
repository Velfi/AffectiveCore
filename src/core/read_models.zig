const std = @import("std");
const brain_mod = @import("brain.zig");
const activity_mod = @import("activity.zig");
const process_runtime_mod = @import("process_runtime.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const llm_routing = @import("llm_routing.zig");
const brain_context_stats = @import("brain_context_stats.zig");
const context_tokens = @import("context_tokens.zig");
const config_mod = @import("config.zig");
const present_moment = @import("present_moment.zig");
const needs_mod = @import("needs.zig");
const dream_time_mod = @import("dream_time.zig");
const system_senses_mod = ports.system_senses;

const Brain = brain_mod.Brain;

pub const PresentMomentModel = struct {
    contact_window_open: bool = false,
    last_user_text: ?[]const u8 = null,
    last_spoken_text: ?[]const u8 = null,
    in_flight_purpose: ?[]const u8 = null,
    in_flight_sense: ?[]const u8 = null,
    in_flight_seconds: ?i64 = null,
    user_request_overlap: ?[]const u8 = null,
    overlap_confidence: ?f32 = null,
    deferred_speech_pending: bool = false,
    stimulus_inbox_pending: usize = 0,
};

pub const CurrentStimulusModel = struct {
    text: ?[]const u8 = null,
    observed_at_ms: ?i64 = null,
    age_ms: ?i64 = null,
    stale: bool = false,
};

pub const ConversationContextModel = struct {
    summary_count: usize = 0,
    latest_user_summary: ?[]const u8 = null,
    latest_brain_summary: ?[]const u8 = null,
    latest_summary_time: ?[]const u8 = null,
    active_speaker_label: ?[]const u8 = null,
    last_user_text_at_ms: ?i64 = null,
};

pub const FocusModel = struct {
    text: ?[]const u8 = null,
    source: ?[]const u8 = null,
    set_at_ms: ?i64 = null,
    attention: f32 = 0.0,
    stale: bool = false,
};

pub const VisualStateModel = struct {
    last_observation_path: ?[]const u8 = null,
    updated_at_ms: ?i64 = null,
    uploaded: bool = false,
    awaited_host_request_id: ?[]const u8 = null,
    awaited_host_sense: ?[]const u8 = null,
    awaited_host_purpose: ?[]const u8 = null,
};

pub const NeedSummary = struct {
    need_id: []const u8,
    text: []const u8,
    urgency: []const u8,
    desired_action: []const u8,
    urgency_score: f32,
};

pub const NeedModel = struct {
    self_defined_need_count: usize = 0,
    self_defined_want_count: usize = 0,
    long_term_memory_count: usize = 0,
    short_term_memory_count: usize = 0,
    urgent_need_count: usize = 0,
    top_needs: []NeedSummary = &.{},
};

pub const AppraisalSummary = struct {
    valence: f32 = 0,
    arousal: f32 = 0,
    salience: f32 = 0,
    confidence: f32 = 0,
    summary: ?[]const u8 = null,
    feeling_label: ?[]const u8 = null,
    action_tendency: ?[]const u8 = null,
};

pub const IntentionSummary = struct {
    goal: []const u8,
    priority: ?f32 = null,
    expected_action: ?[]const u8 = null,
    stopping_condition: ?[]const u8 = null,
};

pub const InnerStateModel = struct {
    latest_appraisal: ?AppraisalSummary = null,
    active_intention: ?IntentionSummary = null,
};

pub const DreamModel = dream_time_mod.DreamModel;

pub const AutonomyControlModel = struct {
    mode: []const u8 = "full",
    background_agency_enabled: bool = true,
    control_capacity: f32 = 0.0,
    max_capacity: f32 = 0.0,
    social_engagement: f32 = 0.0,
    social_appetite: f32 = 0.0,
    attention_status: []const u8 = "quietly_observing",
    effective_threshold_bias: f32 = 0.0,
    replenish_points_per_minute: f32 = 0.0,
    last_capacity_replenish_at: ?i64 = null,
    actions_available: bool = false,
    blocked_reason: []const u8 = "none",
    remaining_actions: u32 = 0,
};

pub const BeliefModel = struct {
    active_count: usize = 0,
    doubted_count: usize = 0,
    invalidated_count: usize = 0,
    pending_deletion_count: usize = 0,
    salient: ?BeliefSummary = null,
};

pub const BeliefSummary = struct {
    belief_id: []const u8,
    proposition: []const u8,
    confidence: f32,
    salience: f32,
    status: schema.CognitiveStatus,
};

pub const SelfTrustModel = struct {
    entry_count: usize = 0,
    strongest: ?SelfTrustSummary = null,
};

pub const SelfTrustSummary = struct {
    self_trust_id: []const u8,
    faculty: []const u8,
    context_pattern: []const u8,
    confidence: f32,
};

pub const DispositionModel = struct {
    disposition_count: usize = 0,
    strongest: ?DispositionSummary = null,
};

pub const DispositionSummary = struct {
    disposition_id: []const u8,
    context_pattern: []const u8,
    action_tendency: []const u8,
    strength: f32,
};

pub const HostCapabilitySummary = struct {
    capability_id: []const u8,
    availability: schema.CapabilityAvailability,
    quality: f32,
    reliability: f32,
};

pub const HostCapabilityModel = struct {
    host_id: ?[]const u8 = null,
    available_count: usize = 0,
    unavailable_count: usize = 0,
    degraded_count: usize = 0,
    entries: []HostCapabilitySummary = &.{},
};

pub const ActiveProcessModel = process_runtime_mod.ActiveProcessModel;

pub const ActivityModel = struct {
    activity_id: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    kind_label: ?[]const u8 = null,
    status: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    interpretation: ?[]const u8 = null,
    awaiting: ?[]const u8 = null,
    originating_request_id: ?[]const u8 = null,
    checkpoint_spoken_text: ?[]const u8 = null,
    open_loop_count: usize = 0,
    blocker_count: usize = 0,
    candidate_action_count: usize = 0,
    timeline_event_count: usize = 0,
    activity_history_count: usize = 0,
    paused_at_ms: ?i64 = null,
    stack_depth: usize = 0,
    stack_max: usize = 0,
};

pub const CapacityModel = struct {
    configured: config_mod.CapacityConfig,
    focus_in_use: bool,
    activity_stack_depth: usize,
    activity_active: bool,
    memory_total: usize,
    open_loop_count: usize,
    candidate_action_count: usize,
    last_chat_tokens: ?usize,
    budget_exceeded_count: u64,
    under_pressure: bool,
};

pub const LlmPolicyModel = struct {
    user_quality: []const u8,
    allowed_tiers: []const u8,
    conversation_reasoning_effort: []const u8,
    conversation_model_count: usize,
    last_effort_tier: ?[]const u8 = null,
};

pub const OperationUsageSummary = struct {
    operation: []const u8,
    call_count: u64,
    total_bytes: u64,
    max_bytes: u64,
    total_tokens: u64,
    max_tokens: u64,
};

pub const SectionUsageSummary = struct {
    section: []const u8,
    total_bytes: u64,
    appearance_count: u64,
};

pub const LastDispatchSectionModel = struct {
    section: []const u8,
    bytes: usize,
    count: ?usize = null,
};

pub const LastDispatchModel = struct {
    dispatch_id: []const u8,
    at_ms: i64,
    operation: []const u8,
    user_prompt_tokens: usize,
    budget_exceeded: bool,
    sections: []LastDispatchSectionModel = &.{},
};

pub const ContextUsageModel = struct {
    updated_at_ms: ?i64 = null,
    total_composition_count: u64 = 0,
    total_process_goal_count: u64 = 0,
    total_composed_steps: u64 = 0,
    budget_exceeded_count: u64 = 0,
    max_context_tokens: usize,
    last_conversation_tokens: ?usize = null,
    last_conversation_bytes: ?usize = null,
    last_conversation_at_ms: ?i64 = null,
    last_dispatch: ?LastDispatchModel = null,
    operations: []OperationUsageSummary = &.{},
    top_sections: []SectionUsageSummary = &.{},
};

pub const SubsystemUsageSummary = struct {
    subsystem: []const u8,
    call_count: u64,
    success_count: u64,
    error_count: u64,
    request_bytes: u64,
    response_bytes: u64,
    max_response_bytes: u64,
};

pub const LastLlmCallModel = struct {
    subsystem: []const u8,
    provider: []const u8,
    model: []const u8,
    effort_tier: ?[]const u8 = null,
    response_bytes: usize,
    at_ms: i64,
};

pub const LlmUsageModel = struct {
    updated_at_ms: ?i64 = null,
    total_llm_calls: u64 = 0,
    total_llm_errors: u64 = 0,
    subsystems: []SubsystemUsageSummary = &.{},
    last_call: ?LastLlmCallModel = null,
};

pub const Snapshot = struct {
    brain_mode: schema.BrainMode,

    llm_policy_model: LlmPolicyModel,
    present_moment_model: PresentMomentModel,
    current_stimulus_model: CurrentStimulusModel,
    conversation_context_model: ConversationContextModel,
    focus_model: FocusModel,
    visual_state_model: VisualStateModel,
    need_model: NeedModel,
    inner_state_model: InnerStateModel,
    dream_model: DreamModel,
    autonomy_control_model: AutonomyControlModel,
    belief_model: BeliefModel,
    self_trust_model: SelfTrustModel,
    disposition_model: DispositionModel,
    host_capability_model: HostCapabilityModel,
    activity_model: ActivityModel,
    active_process_model: ActiveProcessModel,
    context_usage_model: ContextUsageModel,
    llm_usage_model: LlmUsageModel,
    capacity_model: CapacityModel,

    current_stimulus: ?[]const u8,
    focus: ?[]const u8,
    event_count: usize,
    memory_count: usize,
    belief_count: usize,
    self_trust_count: usize,
    disposition_count: usize,
    action_pressure_count: usize,
    mailbox_count: usize,
    capability_count: usize,
};

pub fn readModelsSnapshot(self: *Brain, allocator: std.mem.Allocator) !Snapshot {
    if (self.deps.io) |io| self.syncClock(io);
    const events = try self.deps.store.loadExperienceEvents(allocator);
    const memories = try self.deps.store.loadMemoryRecords(allocator);
    const summaries = try self.deps.store.loadConversationSummaries(allocator);
    const beliefs = try self.deps.store.loadBeliefs(allocator);
    const self_trust = try self.deps.store.loadSelfTrust(allocator);
    const dispositions = try self.deps.store.loadDispositions(allocator);
    const action_pressures = try self.deps.store.loadActionPressures(allocator);
    const mailbox = try self.deps.store.loadMailboxItems(allocator);
    const capabilities = try self.deps.store.loadCapabilityStatuses(allocator);
    const llm_policy = try llmPolicyModel(self, allocator);
    try self.ensureContextStatsLoaded();
    const context_usage = try contextUsageModel(self, allocator);
    const llm_usage = try llmUsageModel(self, allocator);
    const activity = activityModel(self);
    const capacity_model = capacityModel(self, memories.len, activity);
    const evaluated_needs = try evaluatedNeedModel(allocator, memories);
    const inner_state = try innerStateModel(self, allocator);
    const dream_model = try dreamStateModel(self);
    return .{
        .brain_mode = try self.deps.store.loadBrainMode(),
        .llm_policy_model = llm_policy,
        .present_moment_model = presentMomentModel(self),
        .current_stimulus_model = currentStimulusModel(self),
        .conversation_context_model = conversationContextModel(self, summaries),
        .focus_model = focusModel(self),
        .visual_state_model = visualStateModel(self),
        .need_model = evaluated_needs,
        .inner_state_model = inner_state,
        .dream_model = dream_model,
        .autonomy_control_model = autonomyControlModel(self),
        .belief_model = beliefModel(beliefs),
        .self_trust_model = selfTrustModel(self_trust),
        .disposition_model = dispositionModel(dispositions),
        .host_capability_model = hostCapabilityModel(capabilities, null),
        .activity_model = activity,
        .active_process_model = process_runtime_mod.activeProcessModel(self),
        .context_usage_model = context_usage,
        .llm_usage_model = llm_usage,
        .capacity_model = capacity_model,
        .current_stimulus = self.current_stimulus_context,
        .focus = if (self.current_focus) |focus| focus.text else null,
        .event_count = events.len,
        .memory_count = memories.len,
        .belief_count = beliefs.len,
        .self_trust_count = self_trust.len,
        .disposition_count = dispositions.len,
        .action_pressure_count = action_pressures.len,
        .mailbox_count = mailbox.len,
        .capability_count = capabilities.len,
    };
}

fn llmPolicyModel(self: *Brain, allocator: std.mem.Allocator) !LlmPolicyModel {
    const quality = llm_routing.LlmQuality.parse(self.cfg.llm_quality) catch .auto;
    const allowed = try llm_routing.formatAllowedTiers(allocator, quality);
    return .{
        .user_quality = self.cfg.llm_quality,
        .allowed_tiers = allowed,
        .conversation_reasoning_effort = self.cfg.conversation_reasoning_effort,
        .conversation_model_count = self.cfg.conversation_roster.entries.len,
        .last_effort_tier = if (self.last_conversation_effort_tier) |tier| @tagName(tier) else null,
    };
}

fn contextUsageModel(self: *Brain, allocator: std.mem.Allocator) !ContextUsageModel {
    const stats = &self.context_stats;
    const operation_names = try brain_context_stats.sortedOperationNames(stats, allocator);
    defer allocator.free(operation_names);

    var operations = try allocator.alloc(OperationUsageSummary, operation_names.len);
    for (operation_names, 0..) |name, index| {
        const totals = stats.operations.get(name) orelse unreachable;
        operations[index] = .{
            .operation = name,
            .call_count = totals.call_count,
            .total_bytes = totals.total_bytes,
            .max_bytes = totals.max_bytes,
            .total_tokens = totals.total_tokens,
            .max_tokens = totals.max_tokens,
        };
    }

    const section_ranks = try brain_context_stats.topSectionRanks(stats, allocator);
    defer allocator.free(section_ranks);
    var top_sections = try allocator.alloc(SectionUsageSummary, section_ranks.len);
    for (section_ranks, 0..) |rank, index| {
        top_sections[index] = .{
            .section = rank.name,
            .total_bytes = rank.totals.total_bytes,
            .appearance_count = rank.totals.appearance_count,
        };
    }

    return .{
        .updated_at_ms = if (stats.updated_at_seconds > 0) stats.updated_at_seconds * 1000 else null,
        .total_composition_count = stats.total_composition_count,
        .total_process_goal_count = stats.total_process_goal_count,
        .total_composed_steps = stats.total_composed_steps,
        .budget_exceeded_count = stats.budget_exceeded_count,
        .max_context_tokens = self.cfg.capacity.chat_context_tokens_max,
        .last_conversation_tokens = stats.last_conversation_tokens,
        .last_conversation_bytes = stats.last_conversation_bytes,
        .last_conversation_at_ms = if (stats.last_conversation_at_seconds) |seconds| seconds * 1000 else null,
        .last_dispatch = try lastDispatchModel(self, allocator),
        .operations = operations,
        .top_sections = top_sections,
    };
}

fn lastDispatchModel(self: *Brain, allocator: std.mem.Allocator) !?LastDispatchModel {
    const last = self.context_stats.last_dispatch orelse return null;
    var sections = try allocator.alloc(LastDispatchSectionModel, last.sections.len);
    for (last.sections, 0..) |section, index| {
        sections[index] = .{
            .section = section.section,
            .bytes = section.bytes,
            .count = section.count,
        };
    }
    return .{
        .dispatch_id = last.dispatch_id,
        .at_ms = last.at_seconds * 1000,
        .operation = last.operation,
        .user_prompt_tokens = last.user_prompt_tokens,
        .budget_exceeded = last.budget_exceeded,
        .sections = sections,
    };
}

fn llmUsageModel(self: *Brain, allocator: std.mem.Allocator) !LlmUsageModel {
    const stats = &self.context_stats;
    const subsystem_names = try brain_context_stats.sortedLlmSubsystemNames(stats, allocator);
    defer allocator.free(subsystem_names);

    var subsystems = try allocator.alloc(SubsystemUsageSummary, subsystem_names.len);
    for (subsystem_names, 0..) |name, index| {
        const totals = stats.llm_subsystems.get(name) orelse unreachable;
        subsystems[index] = .{
            .subsystem = name,
            .call_count = totals.call_count,
            .success_count = totals.success_count,
            .error_count = totals.error_count,
            .request_bytes = totals.request_bytes,
            .response_bytes = totals.response_bytes,
            .max_response_bytes = totals.max_response_bytes,
        };
    }

    const last_call: ?LastLlmCallModel = if (stats.last_llm_call) |last| .{
        .subsystem = last.subsystem,
        .provider = last.provider,
        .model = last.model,
        .effort_tier = last.effort_tier,
        .response_bytes = last.response_bytes,
        .at_ms = last.at_seconds * 1000,
    } else null;

    return .{
        .updated_at_ms = if (stats.updated_at_seconds > 0) stats.updated_at_seconds * 1000 else null,
        .total_llm_calls = stats.total_llm_calls,
        .total_llm_errors = stats.total_llm_errors,
        .subsystems = subsystems,
        .last_call = last_call,
    };
}

fn presentMomentModel(self: *Brain) PresentMomentModel {
    const active = self.active_activity;
    const last_user = if (active) |a| if (a.kind == .conversation and a.goal.len > 0) a.goal else null else null;
    const last_spoken = if (active) |a| a.state.last_spoken_text else null;
    const overlap = if (last_user) |text| present_moment.detectRequestOverlap(self, text) else null;
    const req = self.awaited_host_request;
    return .{
        .contact_window_open = present_moment.contactWindowOpen(self),
        .last_user_text = last_user,
        .last_spoken_text = last_spoken,
        .in_flight_purpose = if (req) |value| value.purpose else null,
        .in_flight_sense = if (req) |value| value.sense else null,
        .in_flight_seconds = if (req) |value| @max(@as(i64, 0), self.now_seconds - value.since_seconds) else null,
        .user_request_overlap = if (overlap) |o| o.in_flight_kind else null,
        .overlap_confidence = if (overlap) |o| o.confidence else null,
        .deferred_speech_pending = self.pending_deferred_heard_speech != null,
        .stimulus_inbox_pending = self.stimulus_inbox.pendingCount(),
    };
}

fn currentStimulusModel(self: *Brain) CurrentStimulusModel {
    const observed_at = if (self.current_stimulus_seconds) |seconds| seconds * 1000 else null;
    const age_ms: ?i64 = if (self.current_stimulus_seconds) |seconds| @max(@as(i64, 0), self.now_seconds - seconds) * 1000 else null;
    return .{
        .text = self.current_stimulus_context,
        .observed_at_ms = observed_at,
        .age_ms = age_ms,
        .stale = if (age_ms) |age| age > 5 * 60 * 1000 else false,
    };
}

fn conversationContextModel(self: *Brain, summaries: []const schema.ConversationSummary) ConversationContextModel {
    const latest = latestSummary(summaries);
    return .{
        .summary_count = summaries.len,
        .latest_user_summary = if (latest) |summary| summary.user_summary else null,
        .latest_brain_summary = if (latest) |summary| summary.brain_summary else null,
        .latest_summary_time = if (latest) |summary| summary.time else null,
        .active_speaker_label = if (self.conversation_speaker_context) |context| context.chat_label else null,
        .last_user_text_at_ms = if (self.last_conversation_turn_seconds) |seconds| seconds * 1000 else null,
    };
}

fn focusModel(self: *Brain) FocusModel {
    if (self.current_focus) |focus| {
        const age = @max(@as(i64, 0), self.now_seconds - focus.set_at);
        return .{
            .text = focus.text,
            .source = @tagName(focus.source),
            .set_at_ms = focus.set_at * 1000,
            .attention = focus.base_attention,
            .stale = age > 15 * 60,
        };
    }
    return .{};
}

fn visualStateModel(self: *Brain) VisualStateModel {
    const req = self.awaited_host_request;
    return .{
        .last_observation_path = self.last_visual_observation_path,
        .updated_at_ms = if (self.last_visual_update_seconds) |seconds| seconds * 1000 else null,
        .uploaded = self.last_visual_observation_uploaded,
        .awaited_host_request_id = if (req) |value| value.request_id else null,
        .awaited_host_sense = if (req) |value| value.sense else null,
        .awaited_host_purpose = if (req) |value| value.purpose else null,
    };
}

fn activityModel(self: *Brain) ActivityModel {
    const stack_depth = self.activity_stack.items.len;
    const stack_max = self.cfg.capacity.activity_stack_max;
    const active = self.active_activity orelse {
        const history = self.deps.store.loadActivityHistory(self.allocator) catch &.{};
        defer if (history.len > 0) {
            for (history) |record| @import("../storage/json_store_cognitive.zig").freeActivityRecord(self.allocator, record);
            self.allocator.free(history);
        };
        return .{
            .activity_history_count = history.len,
            .stack_depth = stack_depth,
            .stack_max = stack_max,
        };
    };
    const history = self.deps.store.loadActivityHistory(self.allocator) catch &.{};
    defer if (history.len > 0) {
        for (history) |record| @import("../storage/json_store_cognitive.zig").freeActivityRecord(self.allocator, record);
        self.allocator.free(history);
    };
    const awaiting_host = active.checkpoint != null;
    var open_loop_count: usize = 0;
    if (self.waiting_for != null) open_loop_count += 1;
    if (self.awaitedHostRequestActive()) open_loop_count += 1;
    if (self.pending_deferred_heard_speech != null) open_loop_count += 1;
    if (active.awaiting != null) open_loop_count += 1;
    var blocker_count: usize = 0;
    const brain_mode = self.deps.store.loadBrainMode() catch .waking;
    if (brain_mode != .waking) blocker_count += 1;
    if (self.pending_hard_error != null) blocker_count += 1;
    if (active.status == .paused and active.checkpoint != null) blocker_count += 1;
    return .{
        .activity_id = active.id,
        .kind = @tagName(active.kind),
        .kind_label = active.kind_label,
        .status = activity_mod.activityStateTag(active.status, awaiting_host),
        .goal = active.goal,
        .summary = active.summary,
        .interpretation = active.state.interpretation,
        .awaiting = active.awaiting,
        .originating_request_id = active.originating_request_id,
        .checkpoint_spoken_text = if (active.checkpoint) |cp| cp.spoken_text else null,
        .open_loop_count = open_loop_count,
        .blocker_count = blocker_count,
        .candidate_action_count = active.recent_candidate_actions.len,
        .timeline_event_count = active.timeline.len,
        .activity_history_count = history.len,
        .paused_at_ms = if (active.paused_at_seconds) |seconds| seconds * 1000 else if (active.checkpoint) |cp| cp.paused_at_seconds * 1000 else null,
        .stack_depth = self.activity_stack.items.len,
        .stack_max = self.cfg.capacity.activity_stack_max,
    };
}

fn capacityModel(self: *Brain, memory_total: usize, activity: ActivityModel) CapacityModel {
    const cfg = self.cfg.capacity;
    const stack_depth = activity.stack_depth;
    const open_loops = activity.open_loop_count;
    const budget_failures = self.context_stats.budget_exceeded_count;
    const under_pressure = stack_depth >= cfg.activity_stack_max -| 1 or
        open_loops >= cfg.open_loops_soft_max or
        budget_failures > 0;
    return .{
        .configured = cfg,
        .focus_in_use = self.current_focus != null,
        .activity_stack_depth = stack_depth,
        .activity_active = self.active_activity != null,
        .memory_total = memory_total,
        .open_loop_count = open_loops,
        .candidate_action_count = activity.candidate_action_count,
        .last_chat_tokens = self.context_stats.last_conversation_tokens,
        .budget_exceeded_count = budget_failures,
        .under_pressure = under_pressure,
    };
}

fn needUrgencyScore(urgency: needs_mod.NeedUrgency) f32 {
    return switch (urgency) {
        .urgent => 1.0,
        .need => 0.75,
        .watch => 0.5,
        .satisfied => 0.25,
    };
}

fn evaluatedNeedModel(allocator: std.mem.Allocator, memories: []const schema.MemoryRecord) !NeedModel {
    var counts = NeedModel{};
    for (memories) |memory| {
        switch (memory.scope) {
            .long_term => counts.long_term_memory_count += 1,
            .short_term => counts.short_term_memory_count += 1,
        }
        if (hasTag(memory.tags, "need")) counts.self_defined_need_count += 1;
        if (hasTag(memory.tags, "want")) counts.self_defined_want_count += 1;
    }

    const active_needs = try needs_mod.evaluate(allocator, .{
        .memory_records = memories,
    });
    defer needs_mod.freeNeeds(allocator, active_needs);

    const RankedNeed = struct { need: needs_mod.Need, score: f32 };
    var ranked = std.ArrayList(RankedNeed).empty;
    for (active_needs) |need| {
        const score = needUrgencyScore(need.urgency);
        if (need.urgency == .urgent or need.urgency == .need) counts.urgent_need_count += 1;
        try ranked.append(allocator, .{ .need = need, .score = score });
    }
    std.mem.sortUnstable(RankedNeed, ranked.items, {}, struct {
        fn lessThan(_: void, a: RankedNeed, b: RankedNeed) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const top_count = @min(ranked.items.len, 5);
    var top_needs = try allocator.alloc(NeedSummary, top_count);
    for (ranked.items[0..top_count], 0..) |entry, index| {
        top_needs[index] = .{
            .need_id = try allocator.dupe(u8, entry.need.need_id),
            .text = try allocator.dupe(u8, entry.need.text),
            .urgency = try allocator.dupe(u8, @tagName(entry.need.urgency)),
            .desired_action = try allocator.dupe(u8, entry.need.desired_action),
            .urgency_score = entry.score,
        };
    }
    counts.top_needs = top_needs;
    return counts;
}

fn innerStateModel(self: *Brain, allocator: std.mem.Allocator) !InnerStateModel {
    var model: InnerStateModel = .{};
    const appraisals = try self.deps.store.loadAppraisals(allocator);
    if (appraisals.len > 0) {
        const latest = appraisals[appraisals.len - 1];
        model.latest_appraisal = .{
            .valence = latest.valence,
            .arousal = latest.arousal,
            .salience = latest.stress,
            .confidence = latest.confidence,
            .summary = if (latest.freeform.len > 0) try allocator.dupe(u8, latest.freeform) else null,
            .feeling_label = if (latest.feeling_label.len > 0) try allocator.dupe(u8, latest.feeling_label) else null,
            .action_tendency = if (latest.action_tendency.len > 0) try allocator.dupe(u8, latest.action_tendency) else null,
        };
    }
    if (self.active_process) |process| {
        if (process.goal.len > 0) {
            model.active_intention = .{
                .goal = try allocator.dupe(u8, process.goal),
                .priority = null,
                .expected_action = if (process.user_anchor.len > 0) try allocator.dupe(u8, process.user_anchor) else null,
                .stopping_condition = if (process.composition_reason) |reason| try allocator.dupe(u8, reason) else null,
            };
        }
    }
    return model;
}

fn dreamStateModel(self: *Brain) !DreamModel {
    const io = self.deps.io orelse return .{};
    return try dream_time_mod.dreamModel(self, io);
}

fn needModel(memories: []const schema.MemoryRecord) NeedModel {
    var model = NeedModel{};
    for (memories) |memory| {
        switch (memory.scope) {
            .long_term => model.long_term_memory_count += 1,
            .short_term => model.short_term_memory_count += 1,
        }
        if (hasTag(memory.tags, "need")) model.self_defined_need_count += 1;
        if (hasTag(memory.tags, "want")) model.self_defined_want_count += 1;
    }
    return model;
}

fn autonomyControlModel(self: *Brain) AutonomyControlModel {
    const threshold_bias = self.cfg.autonomy_full_threshold_bias;
    const default_max = self.cfg.autonomy_full_max_capacity;
    const default_remaining = @import("maintenance.zig").autonomyRemainingActionCount(default_max);
    const io = self.deps.io orelse return .{
        .mode = self.cfg.autonomy_mode,
        .background_agency_enabled = true,
        .max_capacity = default_max,
        .control_capacity = default_max,
        .social_appetite = 0.0,
        .attention_status = "quietly_observing",
        .effective_threshold_bias = threshold_bias,
        .actions_available = true,
        .blocked_reason = "none",
        .remaining_actions = default_remaining,
    };
    const fs = self.deps.filesystem orelse return .{
        .mode = self.cfg.autonomy_mode,
        .background_agency_enabled = true,
        .max_capacity = default_max,
        .control_capacity = default_max,
        .social_appetite = 0.0,
        .attention_status = "quietly_observing",
        .effective_threshold_bias = threshold_bias,
        .actions_available = true,
        .blocked_reason = "none",
        .remaining_actions = default_remaining,
    };
    const maintenance_mod = @import("maintenance.zig");
    var state = maintenance_mod.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, self.defaultAutonomySleeping(), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    }) catch return .{
        .mode = self.cfg.autonomy_mode,
        .background_agency_enabled = true,
        .max_capacity = default_max,
        .control_capacity = default_max,
        .social_appetite = 0.0,
        .attention_status = "waiting",
        .effective_threshold_bias = threshold_bias,
        .actions_available = false,
        .blocked_reason = "autonomy_overdrawn",
        .remaining_actions = 0,
    };
    const brain_autonomy = @import("brain_autonomy.zig");
    const replenish_rate = brain_autonomy.autonomyReplenishRatePerSecond(self.cfg);
    maintenance_mod.replenishCapacity(&state, replenish_rate, self.now_seconds);
    const effective_capacity = maintenance_mod.projectControlCapacity(state, replenish_rate, self.now_seconds);
    const blocked = brain_autonomy.autonomyBlockedReason(self, io, state) catch "autonomy_overdrawn";
    const remaining_actions = maintenance_mod.autonomyRemainingActionCount(effective_capacity);
    return .{
        .mode = self.cfg.autonomy_mode,
        .background_agency_enabled = true,
        .control_capacity = effective_capacity,
        .max_capacity = state.max_capacity,
        .social_engagement = state.social_engagement,
        .social_appetite = state.social_engagement,
        .attention_status = if (state.sleeping) "resting" else if (self.stimulus_inbox.pendingCount() > 0) "curious" else if (std.mem.eql(u8, blocked, "none")) "quietly_observing" else "waiting",
        .effective_threshold_bias = threshold_bias,
        .replenish_points_per_minute = brain_autonomy.autonomyReplenishPointsPerMinute(self.cfg),
        .last_capacity_replenish_at = self.now_seconds,
        .actions_available = std.mem.eql(u8, blocked, "none"),
        .blocked_reason = blocked,
        .remaining_actions = remaining_actions,
    };
}

fn beliefModel(beliefs: []const schema.Belief) BeliefModel {
    var model = BeliefModel{};
    for (beliefs) |belief| {
        switch (belief.lifecycle.status) {
            .active => model.active_count += 1,
            .doubted => model.doubted_count += 1,
            .invalidated => model.invalidated_count += 1,
            .pending_deletion => model.pending_deletion_count += 1,
        }
        if (model.salient == null or belief.salience > model.salient.?.salience) {
            model.salient = .{
                .belief_id = belief.belief_id,
                .proposition = belief.proposition,
                .confidence = belief.confidence,
                .salience = belief.salience,
                .status = belief.lifecycle.status,
            };
        }
    }
    return model;
}

fn selfTrustModel(entries: []const schema.SelfTrustEntry) SelfTrustModel {
    var model = SelfTrustModel{ .entry_count = entries.len };
    for (entries) |entry| {
        if (model.strongest == null or entry.confidence > model.strongest.?.confidence) {
            model.strongest = .{
                .self_trust_id = entry.self_trust_id,
                .faculty = entry.faculty,
                .context_pattern = entry.context_pattern,
                .confidence = entry.confidence,
            };
        }
    }
    return model;
}

fn dispositionModel(dispositions: []const schema.Disposition) DispositionModel {
    var model = DispositionModel{ .disposition_count = dispositions.len };
    for (dispositions) |disposition| {
        if (model.strongest == null or disposition.strength > model.strongest.?.strength) {
            model.strongest = .{
                .disposition_id = disposition.disposition_id,
                .context_pattern = disposition.context_pattern,
                .action_tendency = disposition.action_tendency,
                .strength = disposition.strength,
            };
        }
    }
    return model;
}

fn hostCapabilityModel(capabilities: []const schema.CapabilityStatus, host_id: ?[]const u8) HostCapabilityModel {
    var model = HostCapabilityModel{ .host_id = host_id };
    for (capabilities) |status| {
        switch (status.availability) {
            .available => model.available_count += 1,
            .unavailable => model.unavailable_count += 1,
            .degraded => model.degraded_count += 1,
            else => {},
        }
    }
    return model;
}

fn latestSummary(summaries: []const schema.ConversationSummary) ?schema.ConversationSummary {
    if (summaries.len == 0) return null;
    var latest = summaries[0];
    for (summaries[1..]) |summary| {
        if (std.mem.order(u8, summary.time, latest.time) == .gt) latest = summary;
    }
    return latest;
}

fn hasTag(tags: []const []const u8, expected: []const u8) bool {
    for (tags) |tag| {
        if (std.mem.eql(u8, tag, expected)) return true;
    }
    return false;
}
