const std = @import("std");
const brain_mod = @import("brain.zig");
const action_selection = @import("action_selection.zig");
const learning = @import("learning.zig");
const capability_registry = @import("capability_registry.zig");
const needs_mod = @import("needs.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;
const Subsystem = action_selection.Subsystem;
const SubsystemContext = action_selection.SubsystemContext;

pub const registered_subsystems = [_]Subsystem{
    .{ .name = "ExperiencePipeline", .proposeFn = observeExperiencePipeline },
    .{ .name = "Appraisal", .proposeFn = observeAppraisal },
    .{ .name = "Belief", .proposeFn = observeBelief },
    .{ .name = "Memory", .proposeFn = observeMemory },
    .{ .name = "Focus", .proposeFn = observeFocus },
    .{ .name = "Needs", .proposeFn = proposeNeedsPressure },
    .{ .name = "LanguageMind", .proposeFn = proposeLanguageMindPressure },
    .{ .name = "Recognition", .proposeFn = observeRecognition },
    .{ .name = "ActionSelection", .proposeFn = proposePolicyPressure },
    .{ .name = "OutcomeLearning", .proposeFn = observeOutcomeLearning },
    .{ .name = "DreamTime", .proposeFn = observeDreamTime },
    .{ .name = "HostBinding", .proposeFn = observeHostBinding },
    .{ .name = "SelfTrust", .proposeFn = proposeSelfTrustPressure },
    .{ .name = "Disposition", .proposeFn = proposeDispositionPressure },
};

pub fn collectSubsystemPressures(
    self: *Brain,
    allocator: std.mem.Allocator,
    context: SubsystemContext,
) ![]schema.ActionPressure {
    var out = std.ArrayList(schema.ActionPressure).empty;
    for (registered_subsystems) |subsystem| {
        if (try subsystem.propose(self, context)) |pressure| {
            try out.append(allocator, pressure);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn arbitrateSubsystemPressures(
    self: *Brain,
    allocator: std.mem.Allocator,
    context: SubsystemContext,
) ![]schema.ActionOutcome {
    const pressures = try collectSubsystemPressures(self, allocator, context);
    defer allocator.free(pressures);

    var outcomes = std.ArrayList(schema.ActionOutcome).empty;
    if (pressures.len == 0) return try outcomes.toOwnedSlice(allocator);

    var best_index: usize = 0;
    var best_score: f32 = pressures[0].strength - pressures[0].risk;
    for (pressures[1..], 1..) |pressure, index| {
        const score = pressure.strength - pressure.risk;
        if (score > best_score) {
            best_score = score;
            best_index = index;
        }
    }

    for (pressures, 0..) |pressure, index| {
        if (index == best_index) {
            try outcomes.append(allocator, try self.selectActionPressure(pressure));
        } else {
            try outcomes.append(allocator, try self.suppressActionPressure(pressure, "lower priority than selected pressure"));
        }
    }
    return try outcomes.toOwnedSlice(allocator);
}

pub fn appendSubsystemObservations(
    self: *Brain,
    allocator: std.mem.Allocator,
    observations: *std.ArrayList(u8),
    context: SubsystemContext,
) !void {
    const outcomes = try arbitrateSubsystemPressures(self, allocator, context);
    defer allocator.free(outcomes);
    for (outcomes) |outcome| {
        if (outcome.suppressed) {
            const line = try std.fmt.allocPrint(allocator, "subsystem_pressure_suppressed: {s}\n", .{outcome.selected_action});
            defer allocator.free(line);
            try observations.appendSlice(allocator, line);
        } else if (outcome.selected_action.len > 0) {
            const line = try std.fmt.allocPrint(allocator, "subsystem_pressure_selected: {s}\n", .{outcome.selected_action});
            defer allocator.free(line);
            try observations.appendSlice(allocator, line);
        }
    }
}

fn observeExperiencePipeline(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const event = try sourceOrLatestEvent(brain, context) orelse return null;
    return try brain.proposeActionPressure(
        "ExperiencePipeline",
        "integrate_experience_event",
        "read_models_snapshot",
        event.kind,
        0.30 + cap(event.salience, 0.40),
        0.25 + cap(event.arousal, 0.30),
        0.05,
        parentsForEvent(context, event),
    );
}

fn observeAppraisal(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const event = try sourceOrLatestEvent(brain, context) orelse return null;
    if (event.source == .subsystem or event.source == .memory) return null;
    if (event.salience < 0.55 and event.arousal < 0.35 and event.valence > -0.35 and event.valence < 0.35) return null;
    return try brain.proposeActionPressure(
        "Appraisal",
        "appraise_current_experience",
        "appraise_event",
        event.payload,
        0.55 + cap(event.salience * 0.30, 0.25),
        0.40 + cap(event.arousal * 0.30, 0.25),
        0.08,
        parentsForEvent(context, event),
    );
}

fn observeBelief(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const event = try sourceOrLatestEvent(brain, context) orelse return null;
    if (event.uncertainty < 0.55) return null;
    return try brain.proposeActionPressure(
        "Belief",
        "reconcile_uncertain_proposition",
        "think_about",
        event.payload,
        0.45 + cap(event.uncertainty * 0.35, 0.35),
        0.35 + cap(event.salience * 0.20, 0.20),
        0.12,
        parentsForEvent(context, event),
    );
}

fn observeMemory(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const event = try sourceOrLatestEvent(brain, context) orelse return null;
    if (event.retention == .discard or event.retention == .ephemeral) return null;
    if (event.salience < 0.60 and event.confidence < 0.75) return null;
    return try brain.proposeActionPressure(
        "Memory",
        "consolidate_salient_experience",
        "consolidate_memory",
        event.kind,
        0.50 + cap(event.salience * 0.25, 0.25),
        0.30,
        0.05,
        parentsForEvent(context, event),
    );
}

fn observeFocus(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    if (context.focus != null and context.focus.?.len > 0) return null;
    const event = try sourceOrLatestEvent(brain, context) orelse return null;
    if (event.source != .user and event.source != .sense) return null;
    return try brain.proposeActionPressure(
        "Focus",
        "choose_focus_from_stimulus",
        "choose_attention",
        event.payload,
        0.42,
        0.35,
        0.04,
        parentsForEvent(context, event),
    );
}

fn observeRecognition(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const event = try sourceOrLatestEvent(brain, context) orelse return null;
    if (!isVisualOrIdentityEvent(event)) return null;
    return try brain.proposeActionPressure(
        "Recognition",
        "recognize_subject_from_evidence",
        "recognize",
        event.payload,
        0.58 + cap(event.salience * 0.20, 0.20),
        0.45,
        0.18 + cap(event.uncertainty * 0.20, 0.20),
        parentsForEvent(context, event),
    );
}

fn observeOutcomeLearning(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const result = try latestCapabilityResult(brain) orelse return null;
    if (result.state == .completed and result.error_message.len == 0) return null;
    return try brain.proposeActionPressure(
        "OutcomeLearning",
        "learn_from_capability_outcome",
        "think_about",
        result.capability_id,
        0.62,
        0.42,
        0.10,
        context.source_event_ids,
    );
}

fn observeDreamTime(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const mode = brain.deps.store.loadBrainMode() catch .waking;
    if (mode != .waking) return null;
    const events = try brain.deps.store.loadExperienceEvents(brain.allocator);
    if (events.len < 6) return null;
    return try brain.proposeActionPressure(
        "DreamTime",
        "schedule_dream_time_consolidation",
        "request_dream_time",
        "day residue is accumulating",
        0.36,
        0.20,
        0.03,
        context.source_event_ids,
    );
}

fn observeHostBinding(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const statuses = try brain.deps.store.loadCapabilityStatuses(brain.allocator);
    defer brain.allocator.free(statuses);
    if (statuses.len > 0) return null;
    return try brain.proposeActionPressure(
        "HostBinding",
        "refresh_host_capability_manifest",
        "host_capability_manifest",
        brain.currentHostId(),
        0.50,
        0.45,
        0.02,
        context.source_event_ids,
    );
}

fn cap(value: f32, maximum: f32) f32 {
    return if (value > maximum) maximum else value;
}

fn sourceOrLatestEvent(brain: *Brain, context: SubsystemContext) !?schema.ExperienceEvent {
    const events = try brain.deps.store.loadExperienceEvents(brain.allocator);
    if (events.len == 0) return null;
    if (context.source_event_ids.len > 0) {
        for (context.source_event_ids) |id| {
            for (events) |event| {
                if (std.mem.eql(u8, event.id, id)) return event;
            }
        }
    }
    return events[events.len - 1];
}

fn latestCapabilityResult(brain: *Brain) !?schema.CapabilityResult {
    const results = try brain.deps.store.loadCapabilityResults(brain.allocator);
    if (results.len == 0) return null;
    return results[results.len - 1];
}

fn parentsForEvent(context: SubsystemContext, event: schema.ExperienceEvent) []const []const u8 {
    if (context.source_event_ids.len > 0) return context.source_event_ids;
    return event.causal_parent_ids;
}

fn isVisualOrIdentityEvent(event: schema.ExperienceEvent) bool {
    return std.mem.indexOf(u8, event.kind, "MediaUploaded") != null
        or std.mem.indexOf(u8, event.kind, "Visual") != null
        or std.mem.indexOf(u8, event.kind, "Camera") != null
        or std.mem.indexOf(u8, event.kind, "Identity") != null
        or std.mem.indexOf(u8, event.payload, "image") != null
        or std.mem.indexOf(u8, event.payload, "camera") != null;
}

fn proposeNeedsPressure(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const allocator = brain.allocator;
    const summaries = try brain.deps.store.loadConversationSummaries(allocator);
    const memories = try brain.deps.store.loadMemoryRecords(allocator);
    const needs = try needs_mod.evaluate(allocator, .{
        .now_seconds = brain.now_seconds,
        .conversation_summaries = summaries,
        .memory_records = memories,
        .power = .{ .supplies = &.{} },
        .autonomy_control_capacity = null,
        .autonomy_max_capacity = brain.cfg.autonomy_full_max_capacity,
        .autonomy_sleeping = null,
    });
    defer needs_mod.freeNeeds(allocator, needs);

    for (needs) |need| {
        if (need.urgency != .urgent and need.urgency != .need) continue;
        const capability_id = capability_registry.canonicalId(need.desired_action);
        return try brain.proposeActionPressure(
            "Needs",
            need.need_id,
            capability_id,
            need.text,
            switch (need.urgency) {
                .urgent => 0.85,
                .need => 0.65,
                else => 0.40,
            },
            switch (need.urgency) {
                .urgent => 0.80,
                .need => 0.55,
                else => 0.20,
            },
            0.20,
            context.source_event_ids,
        );
    }
    return null;
}

fn proposePolicyPressure(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const brain_mode = brain.deps.store.loadBrainMode() catch .waking;
    if (brain_mode != .waking) return null;
    if (context.focus == null or context.focus.?.len == 0) return null;
    return try brain.proposeActionPressure(
        "ActionSelection",
        "honor_focus",
        "read_models_snapshot",
        context.focus.?,
        0.35,
        0.25,
        0.05,
        context.source_event_ids,
    );
}

fn proposeSelfTrustPressure(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const trust = try learning.selfTrustForFaculty(brain, "recognition", "recognition uncertainty or user correction");
    if (trust >= learning.identity_risk_trust_threshold) return null;
    return try brain.proposeActionPressure(
        "SelfTrust",
        "ask_clarifying_question",
        "say",
        "recognition self-trust is low; ask before acting certain",
        0.70 - trust,
        0.55,
        0.10,
        context.source_event_ids,
    );
}

fn proposeDispositionPressure(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const dispositions = try brain.deps.store.loadDispositions(brain.allocator);
    defer brain.allocator.free(dispositions);
    var best: ?schema.Disposition = null;
    for (dispositions) |disposition| {
        if (best == null or disposition.strength > best.?.strength) best = disposition;
    }
    const chosen = best orelse return null;
    if (context.focus) |focus| {
        if (chosen.context_pattern.len > 0 and std.mem.indexOf(u8, focus, chosen.context_pattern) == null) return null;
    }
    return try brain.proposeActionPressure(
        "Disposition",
        chosen.action_tendency,
        "say",
        chosen.action_tendency,
        chosen.strength,
        0.40,
        0.05,
        context.source_event_ids,
    );
}

fn proposeLanguageMindPressure(_: *Brain, _: SubsystemContext) !?schema.ActionPressure {
    return null;
}

test "registered subsystems include complete initial brain architecture" {
    _ = @import("actors/mod.zig");
    const expected = [_][]const u8{
        "ExperiencePipeline",
        "Appraisal",
        "Belief",
        "Memory",
        "Focus",
        "Needs",
        "LanguageMind",
        "Recognition",
        "ActionSelection",
        "OutcomeLearning",
        "DreamTime",
        "HostBinding",
        "SelfTrust",
        "Disposition",
    };
    try std.testing.expectEqual(expected.len, registered_subsystems.len);
    for (expected, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, registered_subsystems[index].name);
    }
}
