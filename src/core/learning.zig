const std = @import("std");
const brain_mod = @import("brain.zig");
const capability_registry = @import("capability_registry.zig");
const experience_kinds = @import("experience_kinds.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

fn findPressureById(pressures: []const schema.ActionPressure, pressure_id: []const u8) ?schema.ActionPressure {
    for (pressures) |pressure| {
        if (std.mem.eql(u8, pressure.pressure_id, pressure_id)) return pressure;
    }
    return null;
}

fn outcomeMatchesResultCapability(
    outcome: schema.ActionOutcome,
    pressure: ?schema.ActionPressure,
    result_capability_id: []const u8,
) bool {
    const result_canonical = capability_registry.canonicalId(result_capability_id);
    if (pressure) |entry| {
        if (std.mem.eql(u8, capability_registry.canonicalId(entry.capability_id), result_canonical)) return true;
    }
    return std.mem.eql(u8, capability_registry.canonicalId(outcome.selected_action), result_canonical);
}

const Brain = brain_mod.Brain;

fn cloneEventIds(allocator: std.mem.Allocator, parents: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, parents.len);
    for (parents, 0..) |parent, i| out[i] = try allocator.dupe(u8, parent);
    return out;
}

const self_trust_failure_delta: f32 = 0.08;
const self_trust_success_delta: f32 = 0.03;
const conversation_speech_success_delta: f32 = 0.05;
const self_trust_min: f32 = 0.10;
const self_trust_max: f32 = 0.95;
pub const identity_risk_trust_threshold: f32 = 0.45;

pub const CapabilityLearningContext = struct {
    source_event_ids: []const []const u8 = &.{},
    pressure_id: []const u8 = "",
    outcome_id: []const u8 = "",
};

pub fn facultyForCapability(capability_id: []const u8) []const u8 {
    const canonical = capability_registry.canonicalId(capability_id);
    if (std.mem.eql(u8, canonical, "recognize")) return "recognition";
    if (std.mem.eql(u8, canonical, "recall_fact")) return "memory_recall";
    if (std.mem.eql(u8, canonical, "remember_person")) return "recognition";
    if (std.mem.eql(u8, canonical, "describe_image")) return "visual_description";
    if (std.mem.eql(u8, canonical, "say")) return "social_expression";
    if (std.mem.eql(u8, canonical, "think_about")) return "private_reflection";
    return "general_capability";
}

pub fn selfTrustForFaculty(self: *Brain, faculty: []const u8, context_pattern: []const u8) !f32 {
    const entries = try self.deps.store.loadSelfTrust(self.allocator);
    var best: ?f32 = null;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.faculty, faculty)) continue;
        if (context_pattern.len > 0 and entry.context_pattern.len > 0 and !std.mem.eql(u8, entry.context_pattern, context_pattern)) continue;
        if (best == null or entry.confidence > best.?) best = entry.confidence;
    }
    return best orelse 0.50;
}

pub fn recordCapabilityLearning(self: *Brain, result: schema.CapabilityResult, context: CapabilityLearningContext) !void {
    const faculty = facultyForCapability(result.capability_id);
    const context_pattern = try std.fmt.allocPrint(self.allocator, "capability:{s}", .{result.capability_id});
    defer self.allocator.free(context_pattern);

    const delta: f32 = switch (result.state) {
        .completed => self_trust_success_delta,
        .failed, .unavailable, .refused => -self_trust_failure_delta,
        else => 0.0,
    };
    if (delta == 0.0) return;

    const prior = try selfTrustForFaculty(self, faculty, context_pattern);
    const updated = @min(self_trust_max, @max(self_trust_min, prior + delta));

    var evidence_ids = std.ArrayList([]const u8).empty;
    defer evidence_ids.deinit(self.allocator);
    if (result.outcome_event_id.len > 0) try evidence_ids.append(self.allocator, result.outcome_event_id);
    for (context.source_event_ids) |parent| try evidence_ids.append(self.allocator, parent);

    const self_trust_id = try std.fmt.allocPrint(self.allocator, "self_trust_{s}_{s}", .{ faculty, result.capability_id });
    try self.deps.store.upsertSelfTrust(.{
        .self_trust_id = self_trust_id,
        .faculty = faculty,
        .context_pattern = context_pattern,
        .confidence = updated,
        .evidence_event_ids = if (delta > 0)
            try evidence_ids.toOwnedSlice(self.allocator)
        else
            &.{},
        .counterevidence_event_ids = if (delta < 0)
            try evidence_ids.toOwnedSlice(self.allocator)
        else
            &.{},
        .updated_at_ms = self.now_seconds * 1000,
    });
}

fn existingSelfTrustId(self: *Brain, faculty: []const u8, context_pattern: []const u8) !?[]const u8 {
    const entries = try self.deps.store.loadSelfTrust(self.allocator);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.faculty, faculty) and std.mem.eql(u8, entry.context_pattern, context_pattern)) {
            return entry.self_trust_id;
        }
    }
    return null;
}

pub fn recordSocialCorrectionLearning(
    self: *Brain,
    image_path: []const u8,
    person_id: []const u8,
    name: []const u8,
    confidence: f32,
    hypothesis_event_id: []const u8,
) !void {
    _ = image_path;
    _ = confidence;
    const correction_event = try self.recordSimpleExperienceEvent(experience_kinds.recognition_identity_correction, .user, name);
    const faculty = facultyForCapability("recognize");
    const context_pattern = "recognition uncertainty or user correction";
    const prior = try selfTrustForFaculty(self, faculty, context_pattern);
    const updated = @min(self_trust_max, @max(self_trust_min, prior - self_trust_failure_delta));

    const self_trust_id = (try existingSelfTrustId(self, faculty, context_pattern)) orelse try std.fmt.allocPrint(
        self.allocator,
        "self_trust_{s}_correction_{s}",
        .{ faculty, person_id },
    );
    try self.deps.store.upsertSelfTrust(.{
        .self_trust_id = self_trust_id,
        .faculty = faculty,
        .context_pattern = context_pattern,
        .confidence = updated,
        .evidence_event_ids = &.{},
        .counterevidence_event_ids = try cloneEventIds(self.allocator, &[_][]const u8{ correction_event.id, hypothesis_event_id }),
        .updated_at_ms = self.now_seconds * 1000,
    });
    try self.deps.store.upsertDisposition(.{
        .disposition_id = try std.fmt.allocPrint(self.allocator, "disp_recognition_clarify_{s}", .{person_id}),
        .context_pattern = context_pattern,
        .action_tendency = "ask a clarifying identity question before acting as if recognition is certain",
        .strength = 0.65,
        .source_event_ids = try cloneEventIds(self.allocator, &[_][]const u8{ correction_event.id, hypothesis_event_id }),
        .updated_at_ms = self.now_seconds * 1000,
    });
}

pub fn recordProcessLearning(
    self: *Brain,
    goal: []const u8,
    mode: []const u8,
    composition: @import("port_process_goal.zig").ProcessComposition,
    outcome: @import("process_recipe_memory.zig").ProcessOutcome,
) !void {
    if (outcome == .draft) return;
    const context_pattern = try std.fmt.allocPrint(self.allocator, "process:{s}:{s}", .{ goal, mode });
    defer self.allocator.free(context_pattern);
    const delta: f32 = switch (outcome) {
        .success => self_trust_success_delta,
        .failed, .aborted => -self_trust_failure_delta,
        .draft => unreachable,
    };
    for (composition.action_pressures) |pressure| {
        const faculty = facultyForCapability(@tagName(pressure.action));
        const capability_pattern = try std.fmt.allocPrint(self.allocator, "capability:{s}", .{@tagName(pressure.action)});
        defer self.allocator.free(capability_pattern);
        const prior = try selfTrustForFaculty(self, faculty, capability_pattern);
        const updated = @min(self_trust_max, @max(self_trust_min, prior + delta));
        const self_trust_id = (try existingSelfTrustId(self, faculty, capability_pattern)) orelse try std.fmt.allocPrint(
            self.allocator,
            "self_trust_{s}_{s}_{s}",
            .{ faculty, goal, @tagName(pressure.action) },
        );
        try self.deps.store.upsertSelfTrust(.{
            .self_trust_id = self_trust_id,
            .faculty = faculty,
            .context_pattern = try self.allocator.dupe(u8, capability_pattern),
            .confidence = updated,
            .evidence_event_ids = if (delta > 0) &.{} else &.{},
            .counterevidence_event_ids = if (delta < 0) &.{} else &.{},
            .updated_at_ms = self.now_seconds * 1000,
        });
    }
    const disposition_id = try std.fmt.allocPrint(self.allocator, "disp_process_{s}_{s}", .{ goal, mode });
    const tendency = switch (outcome) {
        .success => try std.fmt.allocPrint(self.allocator, "reuse process goal {s} with its remembered skill chain", .{goal}),
        .failed => try std.fmt.allocPrint(self.allocator, "retry process goal {s} when conditions changed; otherwise revise the chain", .{goal}),
        .aborted => try std.fmt.allocPrint(self.allocator, "retry process goal {s} when the interrupt cause cleared; otherwise reconsider", .{goal}),
        .draft => unreachable,
    };
    defer self.allocator.free(tendency);
    try self.deps.store.upsertDisposition(.{
        .disposition_id = disposition_id,
        .context_pattern = try self.allocator.dupe(u8, context_pattern),
        .action_tendency = tendency,
        .strength = if (outcome == .success) 0.70 else 0.45,
        .source_event_ids = &.{},
        .updated_at_ms = self.now_seconds * 1000,
    });
}

pub fn recordConversationSpeechLearning(self: *Brain, user_text: []const u8, spoken_text: []const u8) !void {
    if (spoken_text.len == 0) return;
    const context_pattern = if (std.mem.trim(u8, user_text, " \r\n\t").len > 0) "user_speech" else "conversation";
    const faculty = facultyForCapability("say");
    const capability_pattern = "capability:say";
    const prior = try selfTrustForFaculty(self, faculty, capability_pattern);
    const updated = @min(self_trust_max, @max(self_trust_min, prior + conversation_speech_success_delta));
    const speech_event = try self.recordSimpleExperienceEvent("Conversation.SpeechExpressed", .user, spoken_text);
    const self_trust_id = (try existingSelfTrustId(self, faculty, capability_pattern)) orelse try std.fmt.allocPrint(
        self.allocator,
        "self_trust_{s}_conversation_{d}",
        .{ faculty, self.now_seconds },
    );
    try self.deps.store.upsertSelfTrust(.{
        .self_trust_id = self_trust_id,
        .faculty = faculty,
        .context_pattern = capability_pattern,
        .confidence = updated,
        .evidence_event_ids = try cloneEventIds(self.allocator, &[_][]const u8{speech_event.id}),
        .counterevidence_event_ids = &.{},
        .updated_at_ms = self.now_seconds * 1000,
    });
    try self.deps.store.upsertDisposition(.{
        .disposition_id = try std.fmt.allocPrint(self.allocator, "disp_verbal_expression_{s}", .{context_pattern}),
        .context_pattern = try self.allocator.dupe(u8, context_pattern),
        .action_tendency = try self.allocator.dupe(u8, "respond in concise speech that shares inner stance when addressed"),
        .strength = 0.62,
        .source_event_ids = try cloneEventIds(self.allocator, &[_][]const u8{speech_event.id}),
        .updated_at_ms = self.now_seconds * 1000,
    });
}

pub fn actionPressureExists(self: *Brain, pressure_id: []const u8) !bool {
    if (pressure_id.len == 0) return false;
    const pressures = try self.deps.store.loadActionPressures(self.allocator);
    return findPressureById(pressures, pressure_id) != null;
}

pub fn findOpenActionOutcomeForCapability(self: *Brain, capability_id: []const u8) !?schema.ActionOutcome {
    const outcomes = try self.deps.store.loadActionOutcomes(self.allocator);
    const pressures = try self.deps.store.loadActionPressures(self.allocator);

    var best_index: ?usize = null;
    var best_created_at_ms: i64 = -1;
    for (outcomes, 0..) |outcome, index| {
        if (outcome.suppressed) continue;
        if (outcome.capability_request_id.len > 0) continue;
        const pressure = if (outcome.pressure_id.len > 0)
            findPressureById(pressures, outcome.pressure_id)
        else
            null;
        if (outcome.pressure_id.len > 0 and pressure == null) continue;
        if (!outcomeMatchesResultCapability(outcome, pressure, capability_id)) continue;
        if (best_index == null or outcome.created_at_ms > best_created_at_ms) {
            best_index = index;
            best_created_at_ms = outcome.created_at_ms;
        }
    }

    const index = best_index orelse return null;
    return outcomes[index];
}

pub fn reconcileMatchingActionOutcome(self: *Brain, result: schema.CapabilityResult) !?schema.ActionOutcome {
    const outcome = try findOpenActionOutcomeForCapability(self, result.capability_id) orelse return null;
    return try reconcileOutcomeFromResult(self, outcome, result);
}

pub fn reconcileOutcomeFromResult(self: *Brain, outcome: schema.ActionOutcome, result: schema.CapabilityResult) !schema.ActionOutcome {
    const prediction_error: f32 = switch (result.state) {
        .completed => 0.0,
        .failed => 0.85,
        .unavailable => 0.70,
        .refused => 0.60,
        else => 0.50,
    };
    const reinforcement: f32 = switch (result.state) {
        .completed => 0.35,
        else => -0.40,
    };
    const updated: schema.ActionOutcome = .{
        .outcome_id = outcome.outcome_id,
        .pressure_id = outcome.pressure_id,
        .capability_request_id = result.request_id,
        .capability_result_id = result.request_id,
        .selected_action = outcome.selected_action,
        .suppressed = outcome.suppressed,
        .executed = result.state == .completed,
        .result_event_id = if (result.outcome_event_id.len > 0) result.outcome_event_id else outcome.result_event_id,
        .source_event_ids = outcome.source_event_ids,
        .prediction_error = prediction_error,
        .reinforcement_value = reinforcement,
        .created_at_ms = outcome.created_at_ms,
    };
    try self.deps.store.upsertActionOutcome(updated);
    return updated;
}

test "faculty mapping resolves recognize alias" {
    try std.testing.expectEqualStrings("recognition", facultyForCapability("RecognizeSubject"));
    try std.testing.expectEqualStrings("memory_recall", facultyForCapability("recall_fact"));
}

test "conversation speech learning records disposition and self trust" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const support = @import("brain_test_support.zig");
    const openai = ports.openai;
    var store = support.TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try recordConversationSpeechLearning(&brain, "Hello", "Hello back.");
    try std.testing.expectEqual(@as(usize, 1), store.dispositions.items.len);
    try std.testing.expectEqualStrings("user_speech", store.dispositions.items[0].context_pattern);
    try std.testing.expectEqual(@as(usize, 1), store.self_trust.items.len);
    try std.testing.expectEqualStrings("social_expression", store.self_trust.items[0].faculty);
}
