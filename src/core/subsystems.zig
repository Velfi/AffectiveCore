const std = @import("std");
const brain_mod = @import("brain.zig");
const action_selection = @import("action_selection.zig");
const learning = @import("learning.zig");
const capability_registry = @import("capability_registry.zig");
const needs_mod = @import("needs.zig");
const dream_time_mod = @import("dream_time.zig");
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
    .{ .name = "IdleConsolidation", .proposeFn = observeIdleConsolidation },
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

    var selected = try allocator.alloc(bool, pressures.len);
    defer allocator.free(selected);
    @memset(selected, false);

    var best_cognitive_index: ?usize = null;
    var best_cognitive_score: f32 = -1.0;
    var best_say_index: ?usize = null;
    var best_say_score: f32 = -1.0;
    var best_overall_index: usize = 0;
    var best_overall_score: f32 = pressureScore(pressures[0]);

    for (pressures, 0..) |pressure, index| {
        const score = pressureScore(pressure);
        if (score > best_overall_score) {
            best_overall_score = score;
            best_overall_index = index;
        }
        if (isSayCapability(pressure.capability_id)) {
            if (best_say_index == null or score > best_say_score) {
                best_say_index = index;
                best_say_score = score;
            }
        }
        if (isCognitiveCapability(pressure.capability_id)) {
            if (best_cognitive_index == null or score > best_cognitive_score) {
                best_cognitive_index = index;
                best_cognitive_score = score;
            }
        }
    }

    if (best_cognitive_index) |index| {
        selected[index] = true;
    } else {
        selected[best_overall_index] = true;
    }

    if (best_say_index) |say_index| {
        if (!selected[say_index]) selected[say_index] = true;
    }

    for (pressures, 0..) |pressure, index| {
        if (selected[index]) {
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
    var owned_source_event_ids = std.ArrayList([]const u8).empty;
    defer {
        for (owned_source_event_ids.items) |id| allocator.free(id);
        owned_source_event_ids.deinit(allocator);
    }
    for (context.source_event_ids) |id| {
        try owned_source_event_ids.append(allocator, try allocator.dupe(u8, id));
    }
    var local_context = context;
    local_context.source_event_ids = owned_source_event_ids.items;
    const outcomes = try arbitrateSubsystemPressures(self, allocator, local_context);
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
    const io = brain.deps.io orelse return null;
    if (try dream_time_mod.dreamedToday(brain, io)) return null;
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

fn observeIdleConsolidation(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const mode = brain.deps.store.loadBrainMode() catch .waking;
    if (mode != .waking) return null;
    const memories = try brain.deps.store.loadMemoryRecords(brain.allocator);
    var short_term: usize = 0;
    for (memories) |memory| {
        if (memory.scope == .short_term) short_term += 1;
    }
    if (short_term < 3 and brain.host_received_during == null) return null;
    const idle = brain.host_idle_seconds orelse 0;
    if (idle < 120 and short_term < 5) return null;
    return try brain.proposeActionPressure(
        "IdleConsolidation",
        "consolidate_idle_memory",
        "consolidate_memory",
        "idle memory backlog",
        0.34,
        0.18,
        0.02,
        context.source_event_ids,
    );
}

fn observeHostBinding(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const statuses = try brain.deps.store.loadCapabilityStatuses(brain.allocator);
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
    const memories = try brain.deps.store.loadMemoryRecords(allocator);
    const needs = try needs_mod.evaluate(allocator, .{
        .memory_records = memories,
    });
    defer needs_mod.freeNeeds(allocator, needs);

    for (needs) |need| {
        if (need.urgency != .urgent and need.urgency != .need) continue;
        const capability_id = if (needMapsToSay(need))
            "say"
        else
            capability_registry.canonicalId(need.desired_action);
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

fn proposeLanguageMindPressure(brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
    const event = try sourceOrLatestEvent(brain, context) orelse return null;
    if (event.source != .user and event.source != .sense) return null;

    var strength: f32 = if (event.source == .user) 0.55 else 0.48;
    var urgency: f32 = 0.50;

    const appraisals = try brain.deps.store.loadAppraisals(brain.allocator);
    if (appraisals.len > 0) {
        const latest = appraisals[appraisals.len - 1];
        strength += cap(latest.arousal * 0.15, 0.15);
        strength += cap(latest.curiosity * 0.12, 0.12);
        if (latest.valence > 0.0) strength += cap(latest.valence * 0.10, 0.10);
        urgency += cap(latest.arousal * 0.20, 0.20);
    }

    const memories = try brain.deps.store.loadMemoryRecords(brain.allocator);
    for (memories) |memory| {
        if (!memoryHasTag(memory.tags, "self_want") and !memoryHasTag(memory.tags, "self_goal")) continue;
        const interpretation = if (memory.interpretation.len > 0) memory.interpretation else memory.text;
        if (!textImpliesExpressiveSharing(interpretation)) continue;
        strength += cap(memory.salience * 0.20, 0.20);
    }

    const dispositions = try brain.deps.store.loadDispositions(brain.allocator);
    for (dispositions) |disposition| {
        if (!dispositionMatchesFocus(context.focus, disposition)) continue;
        if (!textImpliesExpressiveSharing(disposition.action_tendency)) continue;
        strength += cap(disposition.strength * 0.15, 0.15);
    }

    strength = std.math.clamp(strength, 0.0, 1.0);
    urgency = std.math.clamp(urgency, 0.0, 1.0);

    const rationale = if (event.payload.len > 0)
        event.payload
    else
        "express verbally in response to current stimulus";

    return try brain.proposeActionPressure(
        "LanguageMind",
        "verbal_self_expression",
        "say",
        rationale,
        strength,
        urgency,
        0.10,
        parentsForEvent(context, event),
    );
}

fn memoryHasTag(tags: []const []const u8, needle: []const u8) bool {
    for (tags) |tag| {
        if (std.mem.eql(u8, tag, needle)) return true;
    }
    return false;
}

fn dispositionMatchesFocus(focus: ?[]const u8, disposition: schema.Disposition) bool {
    if (focus) |focus_text| {
        if (disposition.context_pattern.len > 0 and std.mem.indexOf(u8, focus_text, disposition.context_pattern) == null) return false;
    }
    return true;
}

fn pressureScore(pressure: schema.ActionPressure) f32 {
    return pressure.strength + 0.35 * pressure.urgency - pressure.risk;
}

fn isSayCapability(capability_id: []const u8) bool {
    return std.mem.eql(u8, capability_registry.canonicalId(capability_id), "say");
}

fn isCognitiveCapability(capability_id: []const u8) bool {
    const canonical = capability_registry.canonicalId(capability_id);
    return std.mem.eql(u8, canonical, "appraise_event")
        or std.mem.eql(u8, canonical, "think_about")
        or std.mem.eql(u8, canonical, "consolidate_memory")
        or std.mem.eql(u8, canonical, "choose_attention")
        or std.mem.eql(u8, canonical, "read_models_snapshot");
}

fn needMapsToSay(need: needs_mod.Need) bool {
    if (std.mem.eql(u8, need.desired_action, "say")) return true;
    return needExpressiveSharing(need);
}

fn needExpressiveSharing(need: needs_mod.Need) bool {
    if (std.mem.startsWith(u8, need.need_id, "self_defined_want:") or std.mem.startsWith(u8, need.need_id, "self_defined_goal:")) {
        return textImpliesExpressiveSharing(need.text);
    }
    return false;
}

fn textImpliesExpressiveSharing(text: []const u8) bool {
    return containsInsensitive(text, "share")
        or containsInsensitive(text, "express")
        or containsInsensitive(text, "speak")
        or containsInsensitive(text, "connect")
        or containsInsensitive(text, "talk");
}

fn containsInsensitive(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > text.len) return false;
    var i: usize = 0;
    while (i + needle.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i..i + needle.len], needle)) return true;
    }
    return false;
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
        "IdleConsolidation",
        "HostBinding",
        "SelfTrust",
        "Disposition",
    };
    try std.testing.expectEqual(expected.len, registered_subsystems.len);
    for (expected, 0..) |name, index| {
        try std.testing.expectEqualStrings(name, registered_subsystems[index].name);
    }
}

test "language mind proposes say on user speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const support = @import("brain_test_support.zig");
    const openai = ports.openai;
    var store = support.TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const stimulus = try brain.recordSimpleExperienceEvent("User.TextReceived", .user, "tell me how you feel");
    const pressures = try collectSubsystemPressures(&brain, allocator, .{
        .source_event_ids = &[_][]const u8{stimulus.id},
    });
    defer allocator.free(pressures);

    var saw_language_mind = false;
    for (pressures) |pressure| {
        if (std.mem.eql(u8, pressure.subsystem, "LanguageMind")) {
            saw_language_mind = true;
            try std.testing.expectEqualStrings("say", pressure.capability_id);
            try std.testing.expectEqualStrings("verbal_self_expression", pressure.proposed_action);
        }
    }
    try std.testing.expect(saw_language_mind);
}

test "arbitration selects cognitive and say pressures together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const support = @import("brain_test_support.zig");
    const openai = ports.openai;
    var store = support.TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const event: schema.ExperienceEvent = .{
        .id = "evt_language_mind_dual",
        .brain_id = brain.cfg.brain_id,
        .host_id = brain.currentHostId(),
        .timestamp_ms = brain.now_seconds * 1000,
        .source = .user,
        .kind = "User.TextReceived",
        .payload = "something important happened today",
        .salience = 0.82,
        .confidence = 0.78,
        .valence = -0.20,
        .arousal = 0.62,
        .uncertainty = 0.30,
        .retention = .durable,
        .visibility = .internal,
    };
    try brain.recordExperienceEvent(event);

    const outcomes = try arbitrateSubsystemPressures(&brain, allocator, .{
        .source_event_ids = &[_][]const u8{event.id},
    });
    defer allocator.free(outcomes);

    var selected_appraisal = false;
    var selected_speech = false;
    for (outcomes) |outcome| {
        if (outcome.suppressed) continue;
        if (std.mem.eql(u8, outcome.selected_action, "appraise_current_experience")) selected_appraisal = true;
        if (std.mem.eql(u8, outcome.selected_action, "verbal_self_expression")) selected_speech = true;
    }
    try std.testing.expect(selected_appraisal);
    try std.testing.expect(selected_speech);
}

test "disposition pressure after speech learning does not corrupt store" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const support = @import("brain_test_support.zig");
    const openai = ports.openai;
    var store = support.TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try learning.recordConversationSpeechLearning(&brain, "Hello", "Hello back.");
    try std.testing.expectEqual(@as(usize, 1), store.dispositions.items.len);

    for (0..2) |_| {
        const pressures = try collectSubsystemPressures(&brain, allocator, .{});
        defer allocator.free(pressures);
    }
    try std.testing.expectEqual(@as(usize, 1), store.dispositions.items.len);
    try std.testing.expectEqualStrings("user_speech", store.dispositions.items[0].context_pattern);
}

test "language mind strength gains from expression disposition after speech learning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const support = @import("brain_test_support.zig");
    const openai = ports.openai;
    var store = support.TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const stimulus = try brain.recordSimpleExperienceEvent("User.TextReceived", .user, "tell me more");
    const context: SubsystemContext = .{
        .source_event_ids = &[_][]const u8{stimulus.id},
    };

    const pressures_before = try collectSubsystemPressures(&brain, allocator, context);
    defer allocator.free(pressures_before);
    var strength_before: f32 = 0.0;
    for (pressures_before) |pressure| {
        if (std.mem.eql(u8, pressure.subsystem, "LanguageMind")) strength_before = pressure.strength;
    }

    try learning.recordConversationSpeechLearning(&brain, "tell me more", "Sure.");

    const pressures_after = try collectSubsystemPressures(&brain, allocator, context);
    defer allocator.free(pressures_after);
    var strength_after: f32 = 0.0;
    for (pressures_after) |pressure| {
        if (std.mem.eql(u8, pressure.subsystem, "LanguageMind")) strength_after = pressure.strength;
    }

    try std.testing.expect(strength_after > strength_before);
    try std.testing.expect(strength_after > 0.60);
}
