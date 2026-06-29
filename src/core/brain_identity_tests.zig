const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const maintenance = @import("maintenance.zig");
const learning = @import("learning.zig");
const belief_updates = @import("belief_updates.zig");
const subsystems = @import("subsystems.zig");
const identity = @import("identity.zig");
const helpers = @import("brain_helpers.zig");

const stringSliceContains = support.stringSliceContains;
const eventKindSeen = support.eventKindSeen;
const experience_kinds = @import("experience_kinds.zig");

const Brain = brain_mod.Brain;
const TestStore = store_support.TestStore;
const TestInput = support.TestInput;
const TestIdMonitor = support.TestIdMonitor;
const TestInterruptSource = support.TestInterruptSource;
const TestEventLog = support.TestEventLog;
const TestFacialExpressionOutput = support.TestFacialExpressionOutput;
const ScriptedRememberPersonChatService = support.ScriptedRememberPersonChatService;
const ScriptedIdentityClaimChatService = support.ScriptedIdentityClaimChatService;
const ScriptedForgetPersonChatService = support.ScriptedForgetPersonChatService;
const ScriptedRecallChatService = support.ScriptedRecallChatService;
const ScriptedClarificationChatService = support.ScriptedClarificationChatService;
const ScriptedHardErrorRecoveryChatService = support.ScriptedHardErrorRecoveryChatService;
const HeardSpeechObservationChatService = support.HeardSpeechObservationChatService;
const ScriptedContinuingChatService = support.ScriptedContinuingChatService;
const makeBrain = support.makeBrain;
const addMara = support.addMara;
const addZelda = support.addZelda;
const countOccurrences = support.countOccurrences;
const findMemoryById = helpers.findMemoryById;
const findMemoryWithTagForTest = helpers.findMemoryWithTagForTest;
const experienceEventsContain = helpers.experienceEventsContain;
const tagInSlice = helpers.tagInSlice;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;

test "identity mistake arc lowers self trust and proposes cautious disposition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain.deps.store.upsertSelfTrust(.{
        .self_trust_id = "self_trust_recognition",
        .faculty = "recognition",
        .context_pattern = "recognition uncertainty or user correction",
        .confidence = 0.80,
        .updated_at_ms = brain.now_seconds * 1000,
    });
    _ = try brain.recognizeFromCapturedPath("fixtures/visitors/known_01.jpg");
    try brain.recordIdentityCorrectionLearning("fixtures/visitors/known_01.jpg", "mara", "Mara", 0.95);

    const trust = try brain.selfTrustForFaculty("recognition", "recognition uncertainty or user correction");
    try std.testing.expect(trust < 0.80);
    try std.testing.expect(store.dispositions.items.len >= 1);
    try std.testing.expect(store.identity_hypotheses.items.len >= 2);
}

test "host change arc marks camera unavailable after detach" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    _ = try brain.recordManifestStatuses("test-host", &[_][]const u8{ "take_picture", "recognize" });
    try brain.deps.store.upsertCapabilityStatus(.{
        .capability_id = "live_camera",
        .host_id = "test-host",
        .permission = .granted,
        .availability = .available,
        .quality = 0.80,
        .reliability = 0.80,
        .updated_at_ms = brain.now_seconds * 1000,
    });
    try brain.deps.store.upsertCapabilityStatus(.{
        .capability_id = "live_camera",
        .host_id = "test-host",
        .permission = .granted,
        .availability = .unavailable,
        .unavailable_reason = "host detached",
        .updated_at_ms = brain.now_seconds * 1000,
    });

    try std.testing.expect(!brain.actionIsAvailable(.recognize));
    var observations = std.ArrayList(u8).empty;
    try brain.appendHostCapabilityObservationIfChanged(&observations);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "host_capability_summary") != null);
}

test "dream arc delivers residue-derived mailbox and dream provenance belief" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const failure_event = try brain.recordSimpleExperienceEvent("Capability.Outcome", .capability, "recognize failed in poor lighting");

    try store.store().addCapabilityResult(.{
        .request_id = "capreq_fail",
        .capability_id = "recognize",
        .state = .failed,
        .outcome_event_id = failure_event.id,
        .error_message = "poor lighting",
        .completed_at_ms = brain.now_seconds * 1000,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_day_residue",
        .text = "Recognition failed in dim hallway.",
        .scope = .short_term,
        .tags = @constCast(&[_][]const u8{"recognition"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });

    const item = try brain.requestDreamTime(null);
    try std.testing.expectEqual(@as(usize, 1), store.mailbox_items.items.len);
    try std.testing.expect(std.mem.indexOf(u8, item.text, "capability failures") != null);
    try std.testing.expect(stringSliceContains(store.dream_time_records.items[0].source_event_ids, failure_event.id));
    try std.testing.expect(std.mem.indexOf(u8, store.dream_time_records.items[0].maintenance_counts_json, "\"capability_failures_reviewed\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.dream_time_records.items[0].maintenance_counts_json, "\"source_events_linked\":1") != null);
    const beliefs = try store.store().loadBeliefs(allocator);
    var found_dream_belief = false;
    for (beliefs) |belief| {
        if (std.mem.eql(u8, belief.provenance, "dream_time")) found_dream_belief = true;
    }
    try std.testing.expect(found_dream_belief);
    try std.testing.expectEqual(schema.BrainMode.waking, try brain.deps.store.loadBrainMode());
}

test "self trust subsystem reads recognition faculty trust" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain.deps.store.upsertSelfTrust(.{
        .self_trust_id = "self_trust_recognition_low",
        .faculty = "recognition",
        .context_pattern = "recognition uncertainty or user correction",
        .confidence = 0.30,
        .updated_at_ms = brain.now_seconds * 1000,
    });

    const pressures = try subsystems.collectSubsystemPressures(&brain, allocator, .{
        .source_event_ids = &.{},
    });
    defer allocator.free(pressures);

    var found_self_trust = false;
    for (pressures) |pressure| {
        if (!std.mem.eql(u8, pressure.subsystem, "SelfTrust")) continue;
        found_self_trust = true;
        try std.testing.expectEqualStrings("ask_clarifying_question", pressure.proposed_action);
    }
    try std.testing.expect(found_self_trust);
}

test "identity correction contradicts mistaken identity belief" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const mistaken_result: identity.IdentityResult = .{
        .person_present = true,
        .match_status = .uncertain,
        .person_id = "person_alex",
        .confidence = 0.72,
        .candidate_name = "Alex",
        .people_count = 1,
    };
    const mistaken_hypothesis = try brain.recordIdentityHypothesis(
        "fixtures/visitors/known_01.jpg",
        mistaken_result,
        .suspected,
        &.{},
        null,
    );
    try belief_updates.onIdentityHypothesis(&brain, mistaken_hypothesis, "Alex");

    try brain.recordIdentityCorrectionLearning("fixtures/visitors/known_01.jpg", "mara", "Mara", 0.95);
    const corrected_hypothesis = store.identity_hypotheses.items[store.identity_hypotheses.items.len - 1];
    try std.testing.expectEqual(schema.IdentityDecision.corrected, corrected_hypothesis.decision);
    try std.testing.expect(stringSliceContains(corrected_hypothesis.evidence_event_ids, mistaken_hypothesis.evidence_event_ids[0]));

    const beliefs = try store.store().loadBeliefs(allocator);
    var alex_invalidated = false;
    for (beliefs) |belief| {
        if (std.mem.indexOf(u8, belief.key, "Alex") != null and belief.lifecycle.status == .invalidated) {
            alex_invalidated = true;
        }
    }
    try std.testing.expect(alex_invalidated);
    try std.testing.expect(eventKindSeen(store.experience_events.items, experience_kinds.belief_contradicted));
}

