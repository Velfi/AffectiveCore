const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const learning = @import("learning.zig");
const capability_registry = @import("capability_registry.zig");
const helpers = @import("brain_helpers.zig");

const eventKindSeen = support.eventKindSeen;

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

test "chat action execution records capability lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;

    var commands = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .text = "The desk lamp flickered during planning.", .tags = &[_][]const u8{"planning"} },
    };
    _ = try brain.executeActionProposals(&commands, &observations);

    try std.testing.expectEqual(@as(usize, 1), store.action_pressures.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.action_outcomes.items.len);
    try std.testing.expectEqualStrings("LanguageMind", store.action_pressures.items[0].subsystem);
    try std.testing.expectEqualStrings("unknown", store.action_pressures.items[0].capability_id);
    try std.testing.expect(!store.action_outcomes.items[0].suppressed);
    try std.testing.expectEqual(@as(usize, 1), store.capability_requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.capability_results.items.len);
    try std.testing.expectEqualStrings("unknown", store.capability_requests.items[0].capability_id);
    try std.testing.expectEqual(schema.CapabilityRequestState.started, store.capability_requests.items[0].state);
    try std.testing.expectEqual(schema.CapabilityRequestState.unavailable, store.capability_results.items[0].state);
    try std.testing.expectEqualStrings(store.action_pressures.items[0].pressure_id, store.capability_results.items[0].pressure_id);
    try std.testing.expectEqualStrings(store.action_outcomes.items[0].outcome_id, store.capability_results.items[0].outcome_id);
    try std.testing.expect(std.mem.indexOf(u8, store.capability_results.items[0].error_message, "unknown skill") != null);
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Capability.Requested"));
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Capability.Started"));
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Capability.Unavailable"));
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Capability.Outcome"));
    try std.testing.expect(eventKindSeen(store.experience_events.items, "ActionPressure.Proposed"));
    try std.testing.expect(eventKindSeen(store.experience_events.items, "ActionSelection.Selected"));
    try std.testing.expectEqualStrings(brain.cfg.brain_id, store.experience_events.items[0].brain_id);
    const beliefs = try store.store().loadBeliefs(allocator);
    var failure_belief_cites_outcome = false;
    for (beliefs) |belief| {
        if (!std.mem.eql(u8, belief.provenance, "capability_learning")) continue;
        for (belief.counterevidence_event_ids) |event_id| {
            if (std.mem.eql(u8, event_id, store.capability_results.items[0].outcome_event_id)) {
                failure_belief_cites_outcome = true;
            }
        }
    }
    try std.testing.expect(failure_belief_cites_outcome);
}

test "host capability beliefs cite capability status events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain.recordCapabilityStatus(.{
        .capability_id = "text_reply",
        .host_id = "test-host",
        .permission = .granted,
        .availability = .available,
        .quality = 0.82,
        .reliability = 0.76,
        .updated_at_ms = brain.now_seconds * 1000,
    });

    var status_event_id: ?[]const u8 = null;
    for (store.experience_events.items) |event| {
        if (std.mem.eql(u8, event.kind, "Capability.StatusUpdated")) status_event_id = event.id;
    }
    const evidence_id = status_event_id orelse return error.MissingCapabilityStatusEvent;
    const beliefs = try store.store().loadBeliefs(allocator);
    var host_belief_cites_status = false;
    for (beliefs) |belief| {
        if (!std.mem.eql(u8, belief.provenance, "host_binding")) continue;
        for (belief.evidence_event_ids) |event_id| {
            if (std.mem.eql(u8, event_id, evidence_id)) host_belief_cites_status = true;
        }
    }
    try std.testing.expect(host_belief_cites_status);
}

test "remote description service failure is a hard error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{ .fail = true };
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.last_visual_observation_path = try allocator.dupe(u8, "fixtures/visitors/known_01.jpg");
    try std.testing.expectError(error.RemoteServiceFailed, brain.rememberPersonForObservation(.{ .action = .remember_person, .name = "Mara" }));
    try std.testing.expectEqual(@as(u32, 1), store.people.items[0].sighting_count);
}

test "exhausted remote action failure reports unable to continue thinking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var log = TestEventLog{};
    brain.deps.event_log = log.log();

    try brain.reportRemoteThinkingFailure();

    try std.testing.expectEqualStrings("error", log.kind.?);
    try std.testing.expectEqualStrings("Brain", log.title.?);
    try std.testing.expectEqualStrings(remote_thinking_failure_message, log.body.?);
}

test "capability registry canonicalizes aliases and manifest statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    _ = try brain.recordManifestStatuses("ios-host", &[_][]const u8{ "text_reply", "RecognizeSubject" });
    try std.testing.expectEqual(@as(usize, 2), store.capability_statuses.items.len);
    try std.testing.expectEqualStrings("say", store.capability_statuses.items[0].capability_id);
    try std.testing.expectEqualStrings("recognize", store.capability_statuses.items[1].capability_id);
    try std.testing.expect(capability_registry.lookup("speech") != null);
}

test "mailbox mark read persists read_at_ms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try store.store().addMailboxItem(.{
        .mailbox_id = "mailbox_test_read",
        .kind = .DreamMail,
        .title = "Dream",
        .text = "A remembered corridor.",
        .created_at_ms = brain.now_seconds * 1000,
    });

    const item = try brain.markMailboxRead("mailbox_test_read");
    try std.testing.expect(item.read_at_ms != null);
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Mailbox.MarkedRead"));
    const items = try store.store().loadMailboxItems(allocator);
    try std.testing.expect(items[0].read_at_ms != null);
}

test "capability result reconciles matching action outcome" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const pressure = try brain.proposeActionPressure(
        "Test",
        "speak_greeting",
        "text_reply",
        "Selected speech should reconcile after capability completion.",
        0.70,
        0.50,
        0.10,
        &.{},
    );
    const selected = try brain.selectActionPressure(pressure);
    try std.testing.expect(!selected.executed);
    try std.testing.expect(selected.capability_request_id.len == 0);

    const request = try brain.recordCapabilityRequest("say", "hello there", &.{});
    const result = try brain.recordCapabilityResult(request, .completed, "hello there", "");
    try std.testing.expectEqualStrings(pressure.pressure_id, result.pressure_id);
    try std.testing.expectEqualStrings(selected.outcome_id, result.outcome_id);
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Capability.Completed"));
    var result_points_to_outcome_event = false;
    for (store.experience_events.items) |event| {
        if (std.mem.eql(u8, event.id, result.outcome_event_id) and std.mem.eql(u8, event.kind, "Capability.Outcome")) {
            result_points_to_outcome_event = true;
        }
    }
    try std.testing.expect(result_points_to_outcome_event);

    const outcomes = try store.store().loadActionOutcomes(allocator);
    var reconciled: ?schema.ActionOutcome = null;
    for (outcomes) |outcome| {
        if (std.mem.eql(u8, outcome.outcome_id, selected.outcome_id)) reconciled = outcome;
    }
    const updated = reconciled orelse return error.MissingReconciledActionOutcome;
    try std.testing.expect(updated.executed);
    try std.testing.expectEqualStrings(request.request_id, updated.capability_request_id);
    try std.testing.expectEqualStrings(request.request_id, updated.capability_result_id);
    try std.testing.expectEqual(@as(f32, 0.0), updated.prediction_error);
    try std.testing.expectEqual(@as(f32, 0.35), updated.reinforcement_value);
    try std.testing.expect(updated.result_event_id.len > 0);
    try std.testing.expect(store.self_trust.items.len >= 1);

    var saw_learning_recorded = false;
    var saw_learning_updated = false;
    var learning_payload_has_state = false;
    for (brain.runtime.events()) |event| {
        if (std.mem.eql(u8, event.event_type, brain_mod.BrainEventTypes.learning_capability_recorded)) {
            saw_learning_recorded = true;
        }
        if (std.mem.eql(u8, event.event_type, brain_mod.BrainEventTypes.learning_updated)) {
            saw_learning_updated = true;
            if (std.mem.indexOf(u8, event.payload, "\"state\":\"completed\"") != null and
                std.mem.indexOf(u8, event.payload, "\"pressure_id\"") != null)
            {
                learning_payload_has_state = true;
            }
        }
    }
    try std.testing.expect(saw_learning_recorded);
    try std.testing.expect(saw_learning_updated);
    try std.testing.expect(learning_payload_has_state);
}

test "schema linkage round trips action outcomes and capability results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);

    try store.store().addCapabilityRequest(.{
        .request_id = "capreq_test",
        .capability_id = "recognize",
        .state = .requested,
        .causal_parent_ids = @constCast(&[_][]const u8{"evt_turn"}),
        .created_at_ms = 1000,
    });
    try store.store().addCapabilityResult(.{
        .request_id = "capreq_test",
        .capability_id = "recognize",
        .state = .failed,
        .error_message = "recognizer unavailable",
        .pressure_id = "pressure_1",
        .outcome_id = "outcome_1",
        .completed_at_ms = 2000,
    });
    try store.store().upsertActionOutcome(.{
        .outcome_id = "outcome_1",
        .pressure_id = "pressure_1",
        .capability_request_id = "capreq_test",
        .capability_result_id = "capreq_test",
        .selected_action = "recognize",
        .executed = false,
        .source_event_ids = @constCast(&[_][]const u8{"evt_turn"}),
        .prediction_error = 0.85,
        .reinforcement_value = -0.40,
        .created_at_ms = 2000,
    });

    const requests = try store.store().loadCapabilityRequests(allocator);
    const results = try store.store().loadCapabilityResults(allocator);
    const outcomes = try store.store().loadActionOutcomes(allocator);
    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(@as(usize, 1), outcomes.len);
    try std.testing.expectEqualStrings("capreq_test", outcomes[0].capability_request_id);
    try std.testing.expect(outcomes[0].executed == false);
    try std.testing.expectEqualStrings("pressure_1", results[0].pressure_id);
}

