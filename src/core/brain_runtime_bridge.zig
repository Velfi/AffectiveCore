const std = @import("std");
const brain_mod = @import("brain.zig");
const brain_actor = @import("brain_actor.zig");
const brain_event = @import("brain_event.zig");
const maintenance = @import("maintenance.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const autonomy_governor = @import("autonomy_governor.zig");
const capability_registry = @import("capability_registry.zig");
const learning = @import("learning.zig");
const belief_updates = @import("belief_updates.zig");
const actors = @import("actors/mod.zig");
const memory_extraction_actor = @import("actors/memory/memory_extraction_actor.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const memory_extraction_port = ports.memory_extraction;

const Brain = brain_mod.Brain;
const ActionPressureBatchResult = brain_mod.ActionPressureBatchResult;
const ProposalEventPayload = actors.payloads.ProposalEventPayload;
const GovernanceDecision = actors.payloads.GovernanceDecision;
const GovernanceDecisionPayload = actors.payloads.GovernanceDecisionPayload;
const LearningCapabilityRecordedPayload = actors.payloads.LearningCapabilityRecordedPayload;
const LearningCorrectionRecordedPayload = actors.payloads.LearningCorrectionRecordedPayload;
const memory_types = actors.memory.types;
const context_composition = @import("context_composition.zig");
const vector_index = @import("vector_index.zig");
const process_goal_resolver = @import("process_goal_resolver.zig");
const process_runtime_mod = @import("process_runtime.zig");

const no_events = [_]brain_event.BrainEvent{};

pub const ConversationPassResult = struct {
    turn: chat_mod.ChatTurn,
    batch: ActionPressureBatchResult,
    awaiting_host_sense: bool = false,
    execution_error: ?anyerror = null,
};

const RuntimeSource = enum {
    conversation,
    autonomy,
    direct_batch,
};

const RuntimeProposalState = struct {
    proposal_id: []const u8,
    proposal: chat_mod.ActionProposal,
    payload: ProposalEventPayload,
    policy_decision: ?GovernanceDecision = null,
    autonomy_decision: ?GovernanceDecision = null,
    final_decision: ?GovernanceDecision = null,
};

const RuntimeTurnContext = struct {
    source: RuntimeSource,
    memory: []const u8,
    memory_sections: []const context_composition.SectionStat,
    user_text: []const u8,
    observations: *std.ArrayList(u8),
    now_ms: i64,
    turn_index: usize = 0,
    seed_proposals: []const chat_mod.ActionProposal,
    proposals: std.ArrayList(RuntimeProposalState) = .empty,
    chat_turn: ?chat_mod.ChatTurn = null,
    batch_result: ActionPressureBatchResult = .{},
    executed: bool = false,
    autonomy_state: maintenance.AutonomyState,

    fn deinit(self: *RuntimeTurnContext, allocator: std.mem.Allocator) void {
        for (self.proposals.items) |proposal_state| allocator.free(proposal_state.proposal_id);
        self.proposals.deinit(allocator);
    }

    fn findProposal(self: *RuntimeTurnContext, proposal_id: []const u8) ?*RuntimeProposalState {
        for (self.proposals.items) |*proposal| {
            if (std.mem.eql(u8, proposal.proposal_id, proposal_id)) return proposal;
        }
        return null;
    }

    fn allDecided(self: *const RuntimeTurnContext) bool {
        for (self.proposals.items) |proposal| {
            if (proposal.final_decision == null) return false;
        }
        return true;
    }
};

const EmitCollector = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(brain_event.BrainEvent) = .empty,
    override_event_kind: ?[]const u8 = null,

    fn sink(self: *EmitCollector) brain_actor.EventSink {
        return .{
            .ctx = self,
            .emitFn = emit,
        };
    }

    fn emit(ctx: *anyopaque, event_kind: []const u8, payload_json: []const u8) !void {
        const self: *EmitCollector = @ptrCast(@alignCast(ctx));
        const mapped_kind = self.override_event_kind orelse event_kind;
        try self.events.append(self.allocator, .{
            .id = "",
            .event_type = try self.allocator.dupe(u8, mapped_kind),
            .timestamp = 0,
            .source_actor = "",
            .activity_id = null,
            .correlation_id = "",
            .causation_id = null,
            .priority = .normal,
            .ttl = 0,
            .depth = 0,
            .payload = try self.allocator.dupe(u8, payload_json),
        });
    }

    fn finish(self: *EmitCollector) ![]const brain_event.BrainEvent {
        return self.events.toOwnedSlice(self.allocator);
    }
};

pub fn bootstrap(self: *Brain) !void {
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeActivityActorId,
        .subscribesToFn = runtimeActivityActorSubscribesTo,
        .handleFn = runtimeActivityActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeAppraisalActorId,
        .subscribesToFn = runtimeAppraisalActorSubscribesTo,
        .handleFn = runtimeAppraisalActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeLanguageMindActorId,
        .subscribesToFn = runtimeLanguageMindActorSubscribesTo,
        .handleFn = runtimeLanguageMindActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeThriftActorId,
        .subscribesToFn = runtimeThriftActorSubscribesTo,
        .handleFn = runtimeThriftActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimePolicyActorId,
        .subscribesToFn = runtimePolicyActorSubscribesTo,
        .handleFn = runtimePolicyActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeAutonomyActorId,
        .subscribesToFn = runtimeAutonomyActorSubscribesTo,
        .handleFn = runtimeAutonomyActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeGovernanceMergeActorId,
        .subscribesToFn = runtimeGovernanceMergeActorSubscribesTo,
        .handleFn = runtimeGovernanceMergeActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeSchedulerActorId,
        .subscribesToFn = runtimeSchedulerActorSubscribesTo,
        .handleFn = runtimeSchedulerActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeExecutorActorId,
        .subscribesToFn = runtimeExecutorActorSubscribesTo,
        .handleFn = runtimeExecutorActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeLearningActorId,
        .subscribesToFn = runtimeLearningActorSubscribesTo,
        .handleFn = runtimeLearningActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeMemoryIngestActorId,
        .subscribesToFn = runtimeMemoryIngestActorSubscribesTo,
        .handleFn = runtimeMemoryIngestActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeMemoryCandidateActorId,
        .subscribesToFn = runtimeMemoryCandidateActorSubscribesTo,
        .handleFn = runtimeMemoryCandidateActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeMemoryReconciliationActorId,
        .subscribesToFn = runtimeMemoryReconciliationActorSubscribesTo,
        .handleFn = runtimeMemoryReconciliationActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeMemoryConsolidationActorId,
        .subscribesToFn = runtimeMemoryConsolidationActorSubscribesTo,
        .handleFn = runtimeMemoryConsolidationActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeMemoryExtractionActorId,
        .subscribesToFn = runtimeMemoryExtractionActorSubscribesTo,
        .handleFn = runtimeMemoryExtractionActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeMemoryRetrievalActorId,
        .subscribesToFn = runtimeMemoryRetrievalActorSubscribesTo,
        .handleFn = runtimeMemoryRetrievalActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeMemoryDecayActorId,
        .subscribesToFn = runtimeMemoryDecayActorSubscribesTo,
        .handleFn = runtimeMemoryDecayActorHandle,
    });
    try self.runtime.registerActor(.{
        .ctx = self,
        .idFn = runtimeMemoryAuditActorId,
        .subscribesToFn = runtimeMemoryAuditActorSubscribesTo,
        .handleFn = runtimeMemoryAuditActorHandle,
    });
}

pub fn runConversationPass(
    self: *Brain,
    memory: []const u8,
    memory_sections: []const context_composition.SectionStat,
    user_text: []const u8,
    observations: *std.ArrayList(u8),
    turn_index: usize,
) !ConversationPassResult {
    try ensureBootstrapped(self);
    const state = try runtimeAutonomyState(self);
    var turn_ctx = RuntimeTurnContext{
        .source = .conversation,
        .memory = memory,
        .memory_sections = memory_sections,
        .user_text = user_text,
        .observations = observations,
        .now_ms = runtimeNowMs(self),
        .turn_index = turn_index,
        .seed_proposals = &.{},
        .autonomy_state = state,
    };
    defer turn_ctx.deinit(self.allocator);
    runTurn(self, &turn_ctx, "ingest.user_text", user_text) catch |err| {
        if (turn_ctx.chat_turn) |failed_turn| {
            return .{
                .turn = failed_turn,
                .batch = turn_ctx.batch_result,
                .awaiting_host_sense = false,
                .execution_error = err,
            };
        }
        return err;
    };
    const turn = turn_ctx.chat_turn orelse return error.RuntimeMissingChatTurn;
    return .{
        .turn = turn,
        .batch = turn_ctx.batch_result,
        .awaiting_host_sense = false,
        .execution_error = null,
    };
}

pub fn executeProposalBatch(
    self: *Brain,
    proposals: []chat_mod.ActionProposal,
    observations: *std.ArrayList(u8),
) !ActionPressureBatchResult {
    try ensureBootstrapped(self);
    const state = try runtimeAutonomyState(self);
    var turn_ctx = RuntimeTurnContext{
        .source = .direct_batch,
        .memory = "",
        .memory_sections = &.{},
        .user_text = "",
        .observations = observations,
        .now_ms = runtimeNowMs(self),
        .seed_proposals = proposals,
        .autonomy_state = state,
    };
    defer turn_ctx.deinit(self.allocator);
    try registerTurnProposals(&turn_ctx, self.allocator, proposals);
    try runTurn(self, &turn_ctx, "ingest.action_batch", "direct_batch");
    return turn_ctx.batch_result;
}

pub fn executeAutonomyBatch(
    self: *Brain,
    proposals: []chat_mod.ActionProposal,
    observations: *std.ArrayList(u8),
) !ActionPressureBatchResult {
    try ensureBootstrapped(self);
    const state = try runtimeAutonomyState(self);
    var turn_ctx = RuntimeTurnContext{
        .source = .autonomy,
        .memory = "",
        .memory_sections = &.{},
        .user_text = "",
        .observations = observations,
        .now_ms = runtimeNowMs(self),
        .seed_proposals = proposals,
        .autonomy_state = state,
    };
    defer turn_ctx.deinit(self.allocator);
    try registerTurnProposals(&turn_ctx, self.allocator, proposals);
    try runTurn(self, &turn_ctx, "ingest.autonomy", "autonomy");
    return turn_ctx.batch_result;
}

pub fn publishMemoryCandidate(self: *Brain, payload_json: []const u8, source_actor: []const u8) !void {
    try ensureBootstrapped(self);
    _ = try enqueueRuntimeEvent(self, brain_event.EventTypes.memory_candidate, payload_json, source_actor, .normal, 6);
    try dispatchRuntimeIfStandalone(self);
}

pub fn publishMemoryConsolidation(self: *Brain, payload_json: []const u8, source_actor: []const u8) !void {
    try ensureBootstrapped(self);
    _ = try enqueueRuntimeEvent(self, brain_event.EventTypes.memory_consolidate, payload_json, source_actor, .normal, 6);
    try dispatchRuntimeIfStandalone(self);
}

pub fn publishLearningCapabilityRecorded(self: *Brain, payload: LearningCapabilityRecordedPayload, source_actor: []const u8) !void {
    try ensureBootstrapped(self);
    const payload_json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{ .whitespace = .minified });
    _ = try enqueueRuntimeEvent(self, brain_event.EventTypes.learning_capability_recorded, payload_json, source_actor, .normal, 6);
    try dispatchRuntimeIfStandalone(self);
}

pub fn publishLearningCorrectionRecorded(self: *Brain, payload: LearningCorrectionRecordedPayload, source_actor: []const u8) !void {
    try ensureBootstrapped(self);
    const payload_json = try std.json.Stringify.valueAlloc(self.allocator, payload, .{ .whitespace = .minified });
    _ = try enqueueRuntimeEvent(self, brain_event.EventTypes.learning_correction_recorded, payload_json, source_actor, .normal, 6);
    try dispatchRuntimeIfStandalone(self);
}

pub fn queryMemoryAuditFormatted(self: *Brain, belief_id: []const u8) ![]const u8 {
    try ensureBootstrapped(self);
    const payload_json = try std.json.Stringify.valueAlloc(self.allocator, memory_types.AuditRequest{
        .belief_id = belief_id,
    }, .{ .whitespace = .minified });
    const root = try enqueueRuntimeEvent(
        self,
        brain_event.EventTypes.memory_audit_query,
        payload_json,
        "belief_updates",
        .normal,
        6,
    );
    try dispatchRuntimeIfStandalone(self);
    const event = findLatestCorrelatedEvent(self.runtime.events(), root.correlation_id, brain_event.EventTypes.memory_audit) orelse return error.RuntimeMemoryAuditMissingResult;
    var parsed = try std.json.parseFromSlice(memory_types.AuditEvent, self.allocator, event.payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return actors.memory.MemoryAuditActor.formatAuditReport(self.allocator, parsed.value.report);
}

fn enqueueRuntimeEvent(
    self: *Brain,
    event_type: []const u8,
    payload_json: []const u8,
    source_actor: []const u8,
    priority: brain_event.Priority,
    ttl: u8,
) !brain_event.BrainEvent {
    return self.runtime.publishAutoPhase(.{
        .id = "",
        .event_type = event_type,
        .timestamp = runtimeNowMs(self),
        .source_actor = source_actor,
        .activity_id = null,
        .correlation_id = "",
        .causation_id = null,
        .priority = priority,
        .ttl = ttl,
        .depth = 0,
        .payload = payload_json,
    });
}

fn dispatchRuntimeIfStandalone(self: *Brain) !void {
    if (runtimeTurnContext(self) != null) return;
    _ = try self.runtime.dispatchTick();
}

fn findLatestCorrelatedEvent(
    events: []const brain_event.BrainEvent,
    correlation_id: []const u8,
    event_type: []const u8,
) ?brain_event.BrainEvent {
    var idx = events.len;
    while (idx > 0) {
        idx -= 1;
        const event = events[idx];
        if (!std.mem.eql(u8, event.correlation_id, correlation_id)) continue;
        if (!std.mem.eql(u8, event.event_type, event_type)) continue;
        return event;
    }
    return null;
}

fn ensureBootstrapped(self: *Brain) !void {
    if (self.runtime_bootstrapped) return;
    try bootstrap(self);
    self.runtime_bootstrapped = true;
}

fn runTurn(self: *Brain, turn_ctx: *RuntimeTurnContext, event_type: []const u8, payload: []const u8) !void {
    self.runtime_turn_ctx = turn_ctx;
    defer self.runtime_turn_ctx = null;
    _ = try self.runtime.publishAutoPhase(.{
        .id = "",
        .event_type = event_type,
        .timestamp = runtimeNowMs(self),
        .source_actor = "brain.runtime",
        .activity_id = null,
        .correlation_id = "",
        .causation_id = null,
        .priority = .high,
        .ttl = 8,
        .depth = 0,
        .payload = payload,
    });
    _ = try self.runtime.dispatchTick();
    if (!turn_ctx.executed and turn_ctx.proposals.items.len == 0) {
        turn_ctx.executed = true;
        turn_ctx.batch_result = .{};
        return;
    }
    if (!turn_ctx.executed) return error.RuntimeExecutionIncomplete;
}

fn runtimeNowMs(self: *Brain) i64 {
    return @max(@as(i64, 1), self.now_seconds * 1000);
}

fn runtimeAutonomyState(self: *Brain) !maintenance.AutonomyState {
    var state = maintenance.AutonomyState{
        .sleeping = false,
        .control_capacity = if (std.mem.eql(u8, self.cfg.autonomy_mode, "limited")) self.cfg.autonomy_limited_max_capacity else self.cfg.autonomy_full_max_capacity,
        .max_capacity = if (std.mem.eql(u8, self.cfg.autonomy_mode, "limited")) self.cfg.autonomy_limited_max_capacity else self.cfg.autonomy_full_max_capacity,
    };
    if (self.deps.io != null and self.deps.filesystem != null) {
        state = try maintenance.loadAutonomyState(
            self.allocator,
            self.deps.filesystem.?,
            self.deps.io.?,
            self.cfg.maintenance_state_path,
            self.defaultAutonomySleeping(),
            self.cfg.autonomy_mode,
            .{
                .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
                .full_max_capacity = self.cfg.autonomy_full_max_capacity,
            },
        );
    }
    return state;
}

fn runtimeTurnContext(self: *Brain) ?*RuntimeTurnContext {
    const raw = self.runtime_turn_ctx orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn coerceConversationOrigins(turn_ctx: *RuntimeTurnContext, proposals: []chat_mod.ActionProposal) void {
    if (turn_ctx.source != .conversation) return;
    for (proposals) |*proposal| proposal.origin = .interaction;
}

fn registerTurnProposals(turn_ctx: *RuntimeTurnContext, allocator: std.mem.Allocator, proposals: []const chat_mod.ActionProposal) !void {
    for (proposals, 0..) |proposal, index| {
        var registered = proposal;
        if (turn_ctx.source == .conversation) registered.origin = .interaction;
        const proposal_id = try std.fmt.allocPrint(allocator, "proposal_{d}_{d}", .{ turn_ctx.now_ms, index });
        try turn_ctx.proposals.append(allocator, .{
            .proposal_id = proposal_id,
            .proposal = registered,
            .payload = proposalPayload(proposal_id, registered, turn_ctx.source),
        });
    }
}

fn proposalPayload(proposal_id: []const u8, proposal: chat_mod.ActionProposal, source: RuntimeSource) ProposalEventPayload {
    const body_text = proposal.text orelse proposal.query orelse proposal.name orelse @tagName(proposal.action);
    const strength = proposalStrength(proposal, source);
    const urgency = proposalUrgency(proposal);
    const risk = proposalRisk(proposal);
    return .{
        .proposal_id = proposal_id,
        .kind = @tagName(proposal.action),
        .origin = @tagName(proposal.origin),
        .scale = @tagName(proposal.scale),
        .delay_ms = proposal.delay_ms,
        .strength = strength,
        .urgency = urgency,
        .expected_value = actors.payloads.expectedValue(strength, urgency, risk),
        .risk = risk,
        .alternatives = .{
            .full = body_text,
            .short = actors.payloads.boundedSlice(body_text, 96),
            .tiny = actors.payloads.boundedSlice(body_text, 32),
            .noop = "noop",
        },
        .text = proposal.text,
        .query = proposal.query,
        .memory_id = proposal.memory_id,
        .person_id = proposal.person_id,
        .name = proposal.name,
        .image_path = proposal.image_path,
        .schedule = proposal.schedule,
        .to = proposal.to,
        .subject = proposal.subject,
        .heat_bias = proposal.heat_bias,
        .eyes = proposal.eyes,
        .mouth = proposal.mouth,
        .duration_ms = proposal.duration_ms,
        .keep_existing = proposal.keep_existing,
        .tags = proposal.tags,
    };
}

fn proposalStrength(proposal: chat_mod.ActionProposal, source: RuntimeSource) f32 {
    var base: f32 = if (proposal.origin == .interaction) 0.80 else 0.62;
    if (source == .conversation and proposal.action == .say) base = 0.88;
    const multiplier: f32 = switch (proposal.scale) {
        .full => 1.0,
        .medium => 0.75,
        .tiny => 0.45,
    };
    return std.math.clamp(base * multiplier, 0.0, 1.0);
}

fn proposalUrgency(proposal: chat_mod.ActionProposal) f32 {
    var urgency: f32 = if (proposal.origin == .interaction) 0.72 else 0.48;
    if (proposal.delay_ms != null) urgency = @max(0.2, urgency - 0.15);
    return urgency;
}

fn proposalRisk(proposal: chat_mod.ActionProposal) f32 {
    return switch (proposal.action) {
        .send_email => 0.85,
        .remember_person, .update_face_picture, .recognize => 0.60,
        .take_picture, .request_orientation => 0.52,
        .forget_memory, .forget_person, .invalidate_fact => 0.58,
        .unknown => 0.95,
        else => 0.20,
    };
}

fn parseProposalPayload(allocator: std.mem.Allocator, payload_json: []const u8) !std.json.Parsed(ProposalEventPayload) {
    return std.json.parseFromSlice(ProposalEventPayload, allocator, payload_json, .{
        .ignore_unknown_fields = true,
    });
}

fn parseGovernancePayload(allocator: std.mem.Allocator, payload_json: []const u8) !std.json.Parsed(GovernanceDecisionPayload) {
    return std.json.parseFromSlice(GovernanceDecisionPayload, allocator, payload_json, .{
        .ignore_unknown_fields = true,
    });
}

fn actionFromKind(kind: []const u8) !chat_mod.ActionProposalType {
    return std.meta.stringToEnum(chat_mod.ActionProposalType, kind) orelse error.UnknownActionProposalKind;
}

fn proposalFromPayload(payload: ProposalEventPayload) !chat_mod.ActionProposal {
    return .{
        .action = try actionFromKind(payload.kind),
        .origin = std.meta.stringToEnum(chat_mod.ActionOrigin, payload.origin) orelse .interaction,
        .delay_ms = payload.delay_ms,
        .scale = std.meta.stringToEnum(chat_mod.ActionScale, payload.scale) orelse .full,
        .text = payload.text,
        .query = payload.query,
        .memory_id = payload.memory_id,
        .person_id = payload.person_id,
        .name = payload.name,
        .image_path = payload.image_path,
        .schedule = payload.schedule,
        .to = payload.to,
        .subject = payload.subject,
        .heat_bias = payload.heat_bias,
        .eyes = payload.eyes,
        .mouth = payload.mouth,
        .duration_ms = payload.duration_ms,
        .keep_existing = payload.keep_existing,
        .tags = payload.tags,
    };
}

fn governorSettings(self: *Brain) autonomy_governor.Settings {
    return .{
        .autonomy_mode = self.cfg.autonomy_mode,
        .limited_threshold_bias = self.cfg.autonomy_limited_threshold_bias,
        .full_threshold_bias = self.cfg.autonomy_full_threshold_bias,
        .social_reserve = self.cfg.autonomy_social_reserve,
        .safety_reserve = self.cfg.autonomy_safety_reserve,
        .opportunity_reserve = self.cfg.autonomy_opportunity_reserve,
        .quiet_hours_active = if (std.mem.eql(u8, self.cfg.autonomy_mode, "limited") and self.deps.io != null)
            brain_autonomy.inQuietHours(self, self.deps.io.?) catch false
        else
            false,
    };
}

fn mergeDecision(policy: GovernanceDecision, autonomy: GovernanceDecision) GovernanceDecision {
    if (policy == .deny or autonomy == .deny) return .deny;
    if (policy == .require_approval or autonomy == .require_approval) return .require_approval;
    if (policy == .@"defer" or autonomy == .@"defer") return .@"defer";
    if (policy == .downgrade or autonomy == .downgrade) return .downgrade;
    return .allow;
}

fn decisionReason(decision: GovernanceDecision) []const u8 {
    return switch (decision) {
        .allow => "policy and autonomy allowed execution",
        .deny => "policy/autonomy denied execution",
        .@"defer" => "policy/autonomy deferred execution",
        .require_approval => "policy/autonomy requires approval",
        .downgrade => "policy/autonomy requested downgrade",
    };
}

fn runtimeActivityActorId(_: *anyopaque) []const u8 {
    return "activity_actor";
}

fn runtimeActivityActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "activity.sync");
}

fn runtimeActivityActorHandle(ctx: *anyopaque, _: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    const actor = actors.activity_actor.ActivityActor.init(handle_ctx.allocator, collector.sink());
    try actor.syncContext(self);
    return collector.finish();
}

fn runtimeAppraisalActorId(_: *anyopaque) []const u8 {
    return "appraisal_actor";
}

fn runtimeAppraisalActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created);
}

fn runtimeAppraisalActorHandle(_: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    var payload = try parseProposalPayload(handle_ctx.allocator, event.payload);
    defer payload.deinit();
    const actor = actors.appraisal_actor.AppraisalActor.init(handle_ctx.allocator, collector.sink());
    const appraisal = try actor.create(.{
        .salience = payload.value.strength,
        .affect = payload.value.expected_value,
        .risk = payload.value.risk,
        .social_value = if (std.mem.eql(u8, payload.value.kind, "say")) 0.5 else 0.0,
    });
    _ = try actor.annotateProposal(payload.value, appraisal);
    return collector.finish();
}

fn runtimeLanguageMindActorId(_: *anyopaque) []const u8 {
    return "language_mind_actor";
}

fn runtimeLanguageMindActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "ingest.user_text") or
        std.mem.eql(u8, event_type, "ingest.autonomy") or
        std.mem.eql(u8, event_type, "ingest.action_batch");
}

fn runtimeLanguageMindActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    const turn_ctx = runtimeTurnContext(self) orelse return no_events[0..];
    if (std.mem.eql(u8, event.event_type, "ingest.user_text")) {
        var audit_arena = std.heap.ArenaAllocator.init(handle_ctx.allocator);
        defer audit_arena.deinit();
        const composition_report = try context_composition.auditConversationPrompt(
            audit_arena.allocator(),
            turn_ctx.memory,
            turn_ctx.memory_sections,
            turn_ctx.user_text,
            turn_ctx.observations.items,
            turn_ctx.turn_index,
        );
        self.traceContextComposition(composition_report) catch |err| return err;

        const actor = actors.language_mind_actor.LanguageMindActor.init(handle_ctx.allocator, collector.sink());
        const turn = try actor.interpretTurn(self.deps.chat_service, .{
            .memory = turn_ctx.memory,
            .user_text = turn_ctx.user_text,
            .observations = turn_ctx.observations.items,
            .now_ms = turn_ctx.now_ms,
            .turn_index = turn_ctx.turn_index,
            .composition_sections = composition_report.sections,
            .system_prompt_bytes = composition_report.system_prompt_bytes,
            .compact_memory_bytes = composition_report.compact_memory_bytes,
            .observations_bytes = composition_report.observations_bytes,
            .user_prompt_bytes = composition_report.user_prompt_bytes,
            .user_prompt_tokens = composition_report.user_prompt_tokens,
        });
        const composition_context = try process_goal_resolver.buildChatCompositionContext(
            handle_ctx.allocator,
            turn_ctx.memory,
            turn_ctx.user_text,
            turn_ctx.observations.items,
        );
        defer handle_ctx.allocator.free(composition_context);
        var original_pressures = std.ArrayList(chat_mod.ActionProposal).empty;
        defer {
            for (original_pressures.items) |proposal| chat_mod.freeActionProposal(handle_ctx.allocator, proposal);
            original_pressures.deinit(handle_ctx.allocator);
        }
        for (turn.action_pressures) |proposal| {
            try original_pressures.append(handle_ctx.allocator, try chat_mod.cloneActionProposal(handle_ctx.allocator, proposal));
        }
        var expanded_turn = turn;
        try process_goal_resolver.expandChatTurn(self, &expanded_turn, composition_context);
        try process_runtime_mod.logTurnDebug(self, turn_ctx.turn_index, expanded_turn, original_pressures.items);
        coerceConversationOrigins(turn_ctx, expanded_turn.action_pressures);
        try actor.emitProposals(turn_ctx.now_ms, expanded_turn.action_pressures);
        turn_ctx.chat_turn = expanded_turn;
        try registerTurnProposals(turn_ctx, handle_ctx.allocator, expanded_turn.action_pressures);
        return collector.finish();
    }
    for (turn_ctx.proposals.items) |proposal_state| {
        try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.proposal_created, proposal_state.payload);
    }
    return collector.finish();
}

fn runtimeThriftActorId(_: *anyopaque) []const u8 {
    return "thrift_actor";
}

fn runtimeThriftActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created);
}

fn runtimeThriftActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    const turn_ctx = runtimeTurnContext(self) orelse return no_events[0..];
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    var parsed = try parseProposalPayload(handle_ctx.allocator, event.payload);
    defer parsed.deinit();
    const proposal = try proposalFromPayload(parsed.value);
    const proposals = [_]chat_mod.ActionProposal{proposal};
    const pressures = [_]schema.ActionPressure{
        .{
            .pressure_id = parsed.value.proposal_id,
            .subsystem = "language_mind",
            .proposed_action = parsed.value.kind,
            .capability_id = capability_registry.capabilityIdForAction(proposal.action),
            .rationale = parsed.value.alternatives.full,
            .strength = parsed.value.strength,
            .urgency = parsed.value.urgency,
            .risk = parsed.value.risk,
            .created_at_ms = turn_ctx.now_ms,
        },
    };
    const actor = actors.thrift_actor.ThriftActor.init(handle_ctx.allocator, collector.sink());
    const evaluated = try actor.rankAndCompress(&proposals, &pressures, turn_ctx.autonomy_state, governorSettings(self));
    defer handle_ctx.allocator.free(evaluated);
    return collector.finish();
}

fn runtimePolicyActorId(_: *anyopaque) []const u8 {
    return "policy_actor";
}

fn runtimePolicyActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created);
}

fn runtimePolicyActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    const turn_ctx = runtimeTurnContext(self) orelse return no_events[0..];
    var parsed = try parseProposalPayload(handle_ctx.allocator, event.payload);
    defer parsed.deinit();
    const action = try actionFromKind(parsed.value.kind);
    const host_allows = true;
    const identity_trust = if (action == .recognize or action == .remember_person or action == .update_face_picture)
        try learning.selfTrustForFaculty(self, "recognition", "recognition uncertainty or user correction")
    else
        null;
    var collector = EmitCollector{
        .allocator = handle_ctx.allocator,
        .override_event_kind = "governance.policy",
    };
    const actor = actors.policy_actor.PolicyActor.init(handle_ctx.allocator, collector.sink());
    const decision = try actor.decide(.{
        .proposal = parsed.value,
        .host_allows = host_allows,
        .identity_trust = identity_trust,
    });
    if (turn_ctx.findProposal(parsed.value.proposal_id)) |proposal_state| {
        proposal_state.policy_decision = decision.decision;
    }
    return collector.finish();
}

fn runtimeAutonomyActorId(_: *anyopaque) []const u8 {
    return "autonomy_actor";
}

fn runtimeAutonomyActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created);
}

fn runtimeAutonomyActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    const turn_ctx = runtimeTurnContext(self) orelse return no_events[0..];
    var parsed = try parseProposalPayload(handle_ctx.allocator, event.payload);
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.origin, "interaction") or turn_ctx.source == .conversation) {
        var interaction_collector = EmitCollector{
            .allocator = handle_ctx.allocator,
            .override_event_kind = "governance.autonomy",
        };
        try interaction_collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.governance_decision, GovernanceDecisionPayload{
            .proposal_id = parsed.value.proposal_id,
            .decision = .allow,
            .reason = "interaction proposal bypasses autonomy quota",
            .replacement_proposal_id = null,
        });
        if (turn_ctx.findProposal(parsed.value.proposal_id)) |proposal_state| {
            proposal_state.autonomy_decision = .allow;
        }
        return interaction_collector.finish();
    }
    var collector = EmitCollector{
        .allocator = handle_ctx.allocator,
        .override_event_kind = "governance.autonomy",
    };
    const actor = actors.autonomy_actor.AutonomyActor.init(handle_ctx.allocator, collector.sink());
    const decision = try actor.decide(.{
        .proposal = parsed.value,
        .autonomy_mode = self.cfg.autonomy_mode,
        .control_capacity = turn_ctx.autonomy_state.control_capacity,
        .autonomy_sleeping = turn_ctx.autonomy_state.sleeping,
    });
    if (turn_ctx.findProposal(parsed.value.proposal_id)) |proposal_state| {
        proposal_state.autonomy_decision = decision.decision;
    }
    return collector.finish();
}

fn runtimeGovernanceMergeActorId(_: *anyopaque) []const u8 {
    return "governance_merge_actor";
}

fn runtimeGovernanceMergeActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "governance.policy") or std.mem.eql(u8, event_type, "governance.autonomy");
}

fn runtimeGovernanceMergeActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    const turn_ctx = runtimeTurnContext(self) orelse return no_events[0..];
    var parsed = try parseGovernancePayload(handle_ctx.allocator, event.payload);
    defer parsed.deinit();
    const proposal_state = turn_ctx.findProposal(parsed.value.proposal_id) orelse return no_events[0..];
    if (std.mem.eql(u8, event.event_type, "governance.policy")) {
        proposal_state.policy_decision = parsed.value.decision;
    } else {
        proposal_state.autonomy_decision = parsed.value.decision;
    }
    if (proposal_state.policy_decision == null or proposal_state.autonomy_decision == null) return no_events[0..];
    if (proposal_state.final_decision != null) return no_events[0..];
    const final = mergeDecision(proposal_state.policy_decision.?, proposal_state.autonomy_decision.?);
    proposal_state.final_decision = final;
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.governance_decision, GovernanceDecisionPayload{
        .proposal_id = proposal_state.proposal_id,
        .decision = final,
        .reason = decisionReason(final),
        .replacement_proposal_id = null,
    });
    return collector.finish();
}

fn runtimeSchedulerActorId(_: *anyopaque) []const u8 {
    return "scheduler_actor";
}

fn runtimeSchedulerActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.governance_decision);
}

fn runtimeSchedulerActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    const turn_ctx = runtimeTurnContext(self) orelse return no_events[0..];
    var parsed = try parseGovernancePayload(handle_ctx.allocator, event.payload);
    defer parsed.deinit();
    const proposal_state = turn_ctx.findProposal(parsed.value.proposal_id) orelse return no_events[0..];
    const delay_ms = proposal_state.proposal.delay_ms orelse return no_events[0..];
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    var sleep_dummy: u8 = 0;
    const SleepHarness = struct {
        fn sleep(_: *anyopaque, _: u32) !void {}
    };
    const actor = actors.scheduler_actor.SchedulerActor.init(
        handle_ctx.allocator,
        collector.sink(),
        .{ .ctx = &sleep_dummy, .sleepMsFn = SleepHarness.sleep },
    );
    try actor.schedule(proposal_state.payload, delay_ms);
    return collector.finish();
}

fn runtimeExecutorActorId(_: *anyopaque) []const u8 {
    return "executor_actor";
}

fn runtimeExecutorActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.governance_decision);
}

fn runtimeExecutorActorHandle(ctx: *anyopaque, _: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    const turn_ctx = runtimeTurnContext(self) orelse return no_events[0..];
    if (turn_ctx.executed) return no_events[0..];
    if (!turn_ctx.allDecided()) return no_events[0..];

    var allowed = std.ArrayList(chat_mod.ActionProposal).empty;
    defer allowed.deinit(handle_ctx.allocator);
    for (turn_ctx.proposals.items) |proposal_state| {
        const decision = proposal_state.final_decision orelse return error.RuntimeMissingFinalDecision;
        if (decision == .allow or decision == .downgrade) {
            try allowed.append(handle_ctx.allocator, proposal_state.proposal);
        } else {
            const line = try std.fmt.allocPrint(
                handle_ctx.allocator,
                "action_suppressed: {s}: {s}\n",
                .{ proposal_state.payload.kind, decisionReason(decision) },
            );
            defer handle_ctx.allocator.free(line);
            try turn_ctx.observations.appendSlice(handle_ctx.allocator, line);
        }
    }

    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    if (allowed.items.len == 0) {
        turn_ctx.executed = true;
        turn_ctx.batch_result = .{};
        try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.outcome_created, .{
            .spoken_text = null,
            .interrupted = false,
            .ended_with_speech = false,
        });
        return collector.finish();
    }

    const actor = actors.executor_actor.ExecutorActor.init(handle_ctx.allocator, collector.sink());
    turn_ctx.batch_result = try actor.executeBatch(self, allowed.items, turn_ctx.observations);
    turn_ctx.executed = true;
    return collector.finish();
}

fn runtimeLearningActorId(_: *anyopaque) []const u8 {
    return "learning_actor";
}

fn runtimeLearningActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.outcome_created) or
        std.mem.eql(u8, event_type, brain_event.EventTypes.learning_capability_recorded) or
        std.mem.eql(u8, event_type, brain_event.EventTypes.learning_correction_recorded);
}

fn runtimeLearningActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    if (std.mem.eql(u8, event.event_type, brain_event.EventTypes.outcome_created)) {
        try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.memory_decay, memory_types.DecayRequest{
            .trigger = "feedback.phase_tick",
            .kind_tag = "runtime_decay_tick",
        });
        return collector.finish();
    }

    if (std.mem.eql(u8, event.event_type, brain_event.EventTypes.learning_capability_recorded)) {
        var parsed = try std.json.parseFromSlice(LearningCapabilityRecordedPayload, handle_ctx.allocator, event.payload, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        const payload = parsed.value;

        const actor = actors.learning_actor.LearningActor.init(handle_ctx.allocator, collector.sink());
        try actor.recordCapability(self, payload.result, .{
            .source_event_ids = payload.source_event_ids,
            .pressure_id = payload.result.pressure_id,
            .outcome_id = payload.result.outcome_id,
        });
        if (payload.result.outcome_id.len > 0) {
            const outcomes = try self.deps.store.loadActionOutcomes(handle_ctx.allocator);
            var matched: ?schema.ActionOutcome = null;
            for (outcomes) |outcome| {
                if (!std.mem.eql(u8, outcome.outcome_id, payload.result.outcome_id)) continue;
                matched = outcome;
                break;
            }
            if (matched) |outcome| {
                _ = try learning.reconcileOutcomeFromResult(self, outcome, payload.result);
            } else {
                _ = try learning.reconcileMatchingActionOutcome(self, payload.result);
            }
        } else {
            _ = try learning.reconcileMatchingActionOutcome(self, payload.result);
        }
        if (payload.result.state == .failed or payload.result.state == .unavailable) {
            var source_event_ids = std.ArrayList([]const u8).empty;
            defer source_event_ids.deinit(handle_ctx.allocator);
            if (payload.result.outcome_event_id.len > 0) try source_event_ids.append(handle_ctx.allocator, payload.result.outcome_event_id);
            if (payload.terminal_event_id.len > 0) try source_event_ids.append(handle_ctx.allocator, payload.terminal_event_id);
            try belief_updates.facultyFailureBeliefUpdate(self, payload.result.capability_id, source_event_ids.items);
        }
        return collector.finish();
    }

    var correction = try std.json.parseFromSlice(LearningCorrectionRecordedPayload, handle_ctx.allocator, event.payload, .{
        .ignore_unknown_fields = true,
    });
    defer correction.deinit();
    const actor = actors.learning_actor.LearningActor.init(handle_ctx.allocator, collector.sink());
    try actor.recordSocialCorrection(
        self,
        correction.value.image_path,
        correction.value.person_id,
        correction.value.name,
        correction.value.confidence,
        correction.value.hypothesis_event_id,
    );
    return collector.finish();
}

fn runtimeMemoryIngestActorId(_: *anyopaque) []const u8 {
    return "memory_ingest_actor";
}

fn runtimeMemoryIngestActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.memory_candidate);
}

fn runtimeMemoryIngestActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, _: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var actor_context: actors.memory.context.ActorContext = .{
        .allocator = self.allocator,
        .store = self.deps.store,
        .now_seconds = self.now_seconds,
        .brain_id = self.cfg.brain_id,
        .host_id = self.currentHostId(),
    };
    const CandidatePayload = struct {
        source_event_ids: []const []const u8 = &.{},
    };
    var parsed = try std.json.parseFromSlice(CandidatePayload, self.allocator, event.payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const source_event_ids = if (parsed.value.source_event_ids.len > 0)
        try cloneEventIdsSlice(self.allocator, parsed.value.source_event_ids)
    else if (event.causation_id) |id|
        try cloneSingleEventIdSlice(self.allocator, id)
    else
        return error.MemoryCandidateMissingSourceEventIds;
    const synthetic: schema.ExperienceEvent = .{
        .id = source_event_ids[0],
        .brain_id = self.cfg.brain_id,
        .host_id = self.currentHostId(),
        .timestamp_ms = event.timestamp,
        .source = .memory,
        .kind = brain_event.EventTypes.memory_candidate,
        .payload = event.payload,
        .causal_parent_ids = source_event_ids,
        .retention = .episode,
        .visibility = .internal,
    };
    _ = try actors.memory.MemoryIngestActor.ingest(&actor_context, synthetic);
    return no_events[0..];
}

fn runtimeMemoryCandidateActorId(_: *anyopaque) []const u8 {
    return "memory_candidate_actor";
}

fn runtimeMemoryCandidateActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.memory_candidate);
}

fn runtimeMemoryCandidateActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, _: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var actor_context: actors.memory.context.ActorContext = .{
        .allocator = self.allocator,
        .store = self.deps.store,
        .now_seconds = self.now_seconds,
        .brain_id = self.cfg.brain_id,
        .host_id = self.currentHostId(),
    };
    const CandidatePayload = struct {
        source_event_ids: []const []const u8 = &.{},
    };
    var parsed = try std.json.parseFromSlice(CandidatePayload, self.allocator, event.payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const source_event_ids = if (parsed.value.source_event_ids.len > 0)
        try cloneEventIdsSlice(self.allocator, parsed.value.source_event_ids)
    else if (event.causation_id) |id|
        try cloneSingleEventIdSlice(self.allocator, id)
    else
        return error.MemoryCandidateMissingSourceEventIds;
    const synthetic: schema.ExperienceEvent = .{
        .id = source_event_ids[0],
        .brain_id = self.cfg.brain_id,
        .host_id = self.currentHostId(),
        .timestamp_ms = event.timestamp,
        .source = .memory,
        .kind = brain_event.EventTypes.memory_candidate,
        .payload = event.payload,
        .causal_parent_ids = source_event_ids,
        .retention = .episode,
        .visibility = .internal,
    };
    _ = try actors.memory.MemoryCandidateActor.receiveCandidateEvent(&actor_context, synthetic);
    return no_events[0..];
}

fn runtimeMemoryReconciliationActorId(_: *anyopaque) []const u8 {
    return "memory_reconciliation_actor";
}

fn runtimeMemoryReconciliationActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.memory_candidate);
}

fn runtimeMemoryReconciliationActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, _: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var actor_context: actors.memory.context.ActorContext = .{
        .allocator = self.allocator,
        .store = self.deps.store,
        .now_seconds = self.now_seconds,
        .brain_id = self.cfg.brain_id,
        .host_id = self.currentHostId(),
    };
    const JsonCandidate = struct {
        candidate_id: []const u8 = "",
        key: []const u8 = "",
        proposition: []const u8 = "",
        evidence: []const u8 = "",
        kind: actors.memory.types.CandidateKind = .belief,
        confidence: f32 = 0.5,
        salience: f32 = 0.4,
        source_event_ids: []const []const u8 = &.{},
        tags: []const []const u8 = &.{},
        source_references: []const []const u8 = &.{},
    };
    var parsed = try std.json.parseFromSlice(JsonCandidate, self.allocator, event.payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.source_event_ids.len == 0) return error.MemoryCandidateMissingSourceEventIds;
    const candidate = actors.memory.types.MemoryCandidate{
        .candidate_id = parsed.value.candidate_id,
        .key = parsed.value.key,
        .proposition = parsed.value.proposition,
        .evidence = parsed.value.evidence,
        .kind = parsed.value.kind,
        .confidence = parsed.value.confidence,
        .salience = parsed.value.salience,
        .source_event_ids = parsed.value.source_event_ids,
        .tags = parsed.value.tags,
    };
    const reconciliation = try actors.memory.MemoryReconciliationActor.reconcileCandidate(&actor_context, candidate);
    try promoteReconciledCandidateToSearchableMemory(self, candidate, reconciliation);
    return no_events[0..];
}

fn promoteReconciledCandidateToSearchableMemory(
    self: *Brain,
    candidate: memory_types.MemoryCandidate,
    reconciliation: memory_types.ReconciliationResult,
) !void {
    switch (reconciliation.action) {
        .reject, .contradict => return,
        else => {},
    }
    const belief_id = reconciliation.belief_id orelse return;
    const memory_id = try std.fmt.allocPrint(self.allocator, "belief_mem_{s}", .{belief_id});
    defer self.allocator.free(memory_id);
    const existing = try self.deps.store.loadMemoryRecords(self.allocator);
    for (existing) |record| {
        if (std.mem.eql(u8, record.memory_id, memory_id)) return;
    }
    var record = try self.createMemoryRecord(candidate.proposition, candidate.tags);
    self.allocator.free(record.memory_id);
    record.memory_id = try self.allocator.dupe(u8, memory_id);
    record.status = .active;
    record.scope = if (std.mem.eql(u8, candidate.key, "thought")) .short_term else .long_term;
    record.confidence = candidate.confidence;
    record.salience = candidate.salience;
    record.interpretation = try std.fmt.allocPrint(
        self.allocator,
        "reconciled {s}: {s}",
        .{ @tagName(candidate.kind), candidate.proposition },
    );
    record.vector = try vector_index.embedQuery(self.allocator, self.deps.embedding_service, candidate.proposition, candidate.tags);
    try self.deps.store.saveMemoryRecord(record);
}

fn runtimeMemoryConsolidationActorId(_: *anyopaque) []const u8 {
    return "memory_consolidation_actor";
}

fn runtimeMemoryConsolidationActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.memory_consolidate);
}

fn runtimeMemoryConsolidationActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var parsed = try std.json.parseFromSlice(memory_types.ConsolidationRequest, handle_ctx.allocator, event.payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    var actor_context = runtimeMemoryActorContext(self);
    var candidate = try actors.memory.MemoryConsolidationActor.consolidateActivity(&actor_context, parsed.value.activity, parsed.value.reason);
    if (candidate.source_event_ids.len == 0) {
        const source_event = try self.recordSimpleExperienceEvent("Activity.Consolidated", .system, parsed.value.reason);
        candidate.source_event_ids = try cloneSingleEventIdSlice(handle_ctx.allocator, source_event.id);
    }
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.memory_consolidated, memory_types.ConsolidatedEvent{
        .activity_id = parsed.value.activity.id,
        .activity_status = @tagName(parsed.value.activity.status),
        .reason = parsed.value.reason,
        .episode_candidate = candidate,
    });
    try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.memory_candidate, candidate);
    return collector.finish();
}

fn runtimeMemoryExtractionActorId(_: *anyopaque) []const u8 {
    return "memory_extraction_actor";
}

fn runtimeMemoryExtractionActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.memory_consolidated) or
        std.mem.eql(u8, event_type, brain_event.EventTypes.memory_extract);
}

fn runtimeMemoryExtractionActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    if (self.deps.memory_extraction_service == null) return error.MissingMemoryExtractionService;
    var episode_id: []const u8 = "";
    var episode_summary: []const u8 = "";
    var source_event_ids: []const []const u8 = &.{};
    if (std.mem.eql(u8, event.event_type, brain_event.EventTypes.memory_consolidated)) {
        var consolidated = try std.json.parseFromSlice(memory_types.ConsolidatedEvent, handle_ctx.allocator, event.payload, .{
            .ignore_unknown_fields = true,
        });
        defer consolidated.deinit();
        episode_id = try handle_ctx.allocator.dupe(u8, consolidated.value.activity_id);
        episode_summary = try handle_ctx.allocator.dupe(u8, consolidated.value.episode_candidate.proposition);
        source_event_ids = if (consolidated.value.episode_candidate.source_event_ids.len > 0)
            try cloneEventIdsSlice(handle_ctx.allocator, consolidated.value.episode_candidate.source_event_ids)
        else
            try cloneSingleEventIdSlice(handle_ctx.allocator, event.id);
    } else {
        var parsed = try std.json.parseFromSlice(memory_types.ExtractionRequest, handle_ctx.allocator, event.payload, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        episode_id = try handle_ctx.allocator.dupe(u8, parsed.value.episode_id);
        episode_summary = try handle_ctx.allocator.dupe(u8, parsed.value.episode_summary);
        source_event_ids = if (parsed.value.source_event_ids.len > 0)
            try cloneEventIdsSlice(handle_ctx.allocator, parsed.value.source_event_ids)
        else
            try cloneSingleEventIdSlice(handle_ctx.allocator, episode_id);
    }
    var actor_context = runtimeMemoryActorContext(self);
    const candidates = try actors.memory.MemoryExtractionActor.extractFromEpisode(
        &actor_context,
        runtimeExtractionPort(self) orelse return error.MissingMemoryExtractionService,
        episode_id,
        episode_summary,
        source_event_ids,
    );
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    for (candidates) |candidate| {
        try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.memory_candidate, candidate);
    }
    return collector.finish();
}

fn runtimeMemoryRetrievalActorId(_: *anyopaque) []const u8 {
    return "memory_retrieval_actor";
}

fn runtimeMemoryRetrievalActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.memory_retrieve) or
        std.mem.eql(u8, event_type, "ingest.user_text");
}

fn runtimeMemoryRetrievalActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var query: []const u8 = "";
    var status: ?schema.MemoryRecordStatus = null;
    var limit: usize = 5;
    if (std.mem.eql(u8, event.event_type, "ingest.user_text")) {
        const trimmed = std.mem.trim(u8, event.payload, " \r\n\t");
        if (trimmed.len == 0) return no_events[0..];
        query = try handle_ctx.allocator.dupe(u8, trimmed);
    } else {
        var parsed = try std.json.parseFromSlice(memory_types.RetrievalRequest, handle_ctx.allocator, event.payload, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        query = try handle_ctx.allocator.dupe(u8, parsed.value.query);
        status = parsed.value.status;
        limit = parsed.value.limit;
    }
    var actor_context = runtimeMemoryActorContext(self);
    const matches = try actors.memory.MemoryRetrievalActor.retrieve(
        &actor_context,
        query,
        status,
        limit,
    );
    try self.traceContextComposition(context_composition.auditMemoryRetrieval(query, matches));
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.memory_retrieved, memory_types.RetrievalEvent{
        .query = query,
        .status = status,
        .matches = matches,
        .match_count = matches.len,
        .status_label = if (matches.len == 0) "empty" else "ok",
    });
    return collector.finish();
}

fn runtimeMemoryDecayActorId(_: *anyopaque) []const u8 {
    return "memory_decay_actor";
}

fn runtimeMemoryDecayActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.memory_decay);
}

fn runtimeMemoryDecayActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var parsed = try std.json.parseFromSlice(memory_types.DecayRequest, handle_ctx.allocator, event.payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    var actor_context = runtimeMemoryActorContext(self);
    const result = try actors.memory.MemoryDecayActor.decay(&actor_context, parsed.value.kind_tag);
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.memory_decayed, memory_types.DecayedEvent{
        .trigger = parsed.value.trigger,
        .kind_tag = parsed.value.kind_tag,
        .touched = result.touched,
        .dormant = result.dormant,
        .retracted = result.retracted,
    });
    return collector.finish();
}

fn runtimeMemoryAuditActorId(_: *anyopaque) []const u8 {
    return "memory_audit_actor";
}

fn runtimeMemoryAuditActorSubscribesTo(_: *anyopaque, event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, brain_event.EventTypes.memory_audit_query);
}

fn runtimeMemoryAuditActorHandle(ctx: *anyopaque, event: brain_event.BrainEvent, handle_ctx: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    var parsed = try std.json.parseFromSlice(memory_types.AuditRequest, handle_ctx.allocator, event.payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    var actor_context = runtimeMemoryActorContext(self);
    const report = try actors.memory.MemoryAuditActor.auditBelief(&actor_context, parsed.value.belief_id);
    var collector = EmitCollector{ .allocator = handle_ctx.allocator };
    try collector.sink().emitStruct(handle_ctx.allocator, brain_event.EventTypes.memory_audit, memory_types.AuditEvent{
        .report = report,
    });
    return collector.finish();
}

fn runtimeMemoryActorContext(self: *Brain) actors.memory.context.ActorContext {
    return .{
        .allocator = self.allocator,
        .store = self.deps.store,
        .now_seconds = self.now_seconds,
        .brain_id = self.cfg.brain_id,
        .host_id = self.currentHostId(),
    };
}

fn cloneSingleEventIdSlice(allocator: std.mem.Allocator, event_id: []const u8) ![][]const u8 {
    const ids = try allocator.alloc([]const u8, 1);
    ids[0] = try allocator.dupe(u8, event_id);
    return ids;
}

fn cloneEventIdsSlice(allocator: std.mem.Allocator, event_ids: []const []const u8) ![][]const u8 {
    const ids = try allocator.alloc([]const u8, event_ids.len);
    for (event_ids, 0..) |event_id, index| {
        ids[index] = try allocator.dupe(u8, event_id);
    }
    return ids;
}

fn runtimeExtractionPort(self: *Brain) ?memory_extraction_actor.ExtractionPort {
    if (self.deps.memory_extraction_service == null) return null;
    return .{ .ctx = self, .extractFn = runtimeExtractionPortExtract };
}

fn runtimeExtractionPortExtract(ctx: *anyopaque, allocator: std.mem.Allocator, episode_text: []const u8) ![]memory_extraction_actor.ExtractedCandidate {
    const self: *Brain = @ptrCast(@alignCast(ctx));
    const service = self.deps.memory_extraction_service orelse return error.MissingMemoryExtractionService;
    try self.traceContextComposition(context_composition.auditMemoryExtraction(episode_text));
    const extracted = try service.extract(allocator, episode_text);
    var out = std.ArrayList(memory_extraction_actor.ExtractedCandidate).empty;
    for (extracted) |item| {
        try out.append(allocator, .{
            .key = item.key,
            .proposition = item.proposition,
            .evidence = item.evidence,
            .kind = mapExtractionCandidateKind(item.kind),
            .confidence = item.confidence,
            .salience = item.salience,
            .tags = item.tags,
            .source_references = item.source_references,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn mapExtractionCandidateKind(kind: memory_extraction_port.CandidateKind) memory_types.CandidateKind {
    return switch (kind) {
        .belief => .belief,
        .preference => .preference,
        .relationship => .relationship,
    };
}
