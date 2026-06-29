const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const files_mod = ports.files;
const maintenance = @import("maintenance.zig");
const interrupt_mod = @import("interrupt.zig");
const greeting = @import("greeting_policy.zig");
const helpers = @import("brain_helpers.zig");
const activity_mod = @import("activity.zig");
const brain_process = @import("brain_process.zig");
const read_models = @import("read_models.zig");
const recognition_composite = @import("recognition_composite.zig");
const experience_kinds = @import("experience_kinds.zig");

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

test "recognize action identifies known person and clears awaited host request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const line = try brain.recognizeForObservation();

    try std.testing.expect(std.mem.indexOf(u8, line, "Mara") != null);
    try std.testing.expect(!brain.awaitedHostRequestActive());
    try std.testing.expect(store.sightings.items.len >= 1);
    try std.testing.expectEqual(@as(usize, 1), store.identity_hypotheses.items.len);
    try std.testing.expectEqual(schema.IdentityDecision.recognized, store.identity_hypotheses.items[0].decision);
    try std.testing.expect(std.mem.indexOf(u8, store.identity_hypotheses.items[0].candidates_json, "Mara") != null);
    try std.testing.expect(store.identity_hypotheses.items[0].evidence_event_ids.len >= 4);
    var found_hypothesis_event = false;
    var found_visual_evidence_event = false;
    var found_context_evidence_event = false;
    var found_memory_evidence_event = false;
    for (store.experience_events.items) |event| {
        for (store.identity_hypotheses.items[0].evidence_event_ids) |evidence_event_id| {
            if (!std.mem.eql(u8, event.id, evidence_event_id)) continue;
            if (std.mem.eql(u8, event.kind, "Recognition.IdentityHypothesis")) found_hypothesis_event = true;
            if (std.mem.eql(u8, event.kind, "Recognition.VisualEvidence")) found_visual_evidence_event = true;
            if (std.mem.eql(u8, event.kind, "Recognition.ContextEvidence")) found_context_evidence_event = true;
            if (std.mem.eql(u8, event.kind, "Recognition.MemoryEvidence")) found_memory_evidence_event = true;
        }
    }
    try std.testing.expect(found_hypothesis_event);
    try std.testing.expect(found_visual_evidence_event);
    try std.testing.expect(found_context_evidence_event);
    try std.testing.expect(found_memory_evidence_event);
}

test "recognition observation warns when no face is detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);

    const line = try brain.recognizeFromCapturedPath("fixtures/empty/empty_room_01.jpg");

    try std.testing.expect(std.mem.indexOf(u8, line, "interpretation=no_face_in_frame") != null);
}

test "recognition observation warns when face is present but unknown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{}, &store, &desc);

    const line = try brain.recognizeFromCapturedPath("fixtures/visitors/unknown_01.jpg");

    try std.testing.expect(std.mem.indexOf(u8, line, "interpretation=face_unmatched") != null);
}

test "recognize skips re-identify when current frame is already in observations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{}, &store, &desc);

    const path = "fixtures/visitors/unknown_01.jpg";
    const recognition_line = try brain.recognizeFromCapturedPath(path);
    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(allocator);
    try observations.appendSlice(allocator, recognition_line);

    try std.testing.expect(brain.recognitionAlreadyInObservations(observations.items));

    var proposals = [_]chat_mod.ActionProposal{
        .{ .action = .recognize },
    };
    const batch = try brain.executeActionProposals(&proposals, &observations);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "recognition_dedup:") != null);
    try std.testing.expect(batch.spoken_text == null);
}

test "frontend camera pull observation completes the awaited recognition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    // The camera frame the brain starts with is irrelevant: recognition runs on
    // the frame the frontend pull delivered, mirroring the embedded handler which
    // calls recognizeFromCapturedPath once the awaited observation arrives.
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    try brain.setAwaitedHostRequest("camera", "recognize");

    const line = try brain.recognizeFromCapturedPath("fixtures/visitors/known_01.jpg");

    try std.testing.expect(std.mem.indexOf(u8, line, "Mara") != null);
    try std.testing.expect(store.sightings.items.len >= 1);
}

test "camera pull mid-conversation records pending host sense without pausing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    // Frontend camera: capture is an awaited pull, so recognize raises mid-turn.
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeThenSayChatService{};
    brain.deps.chat_service = chat.service();

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});

    // The bot looked and then paused for the observation. It should not invent a
    // reply or loop back through the chat service yet.
    try std.testing.expect(std.mem.indexOf(u8, result.spoken_text, "Something went wrong") == null);
    try std.testing.expectEqualStrings("", result.spoken_text);
    try std.testing.expectEqual(@as(usize, 1), chat.calls);
    try std.testing.expect(brain.conversationAwaitingHost());
}

test "awaited camera observation resumes paused conversation with speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeThenSayChatService{ .say_text = "Hi, I see you." };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());

    const visual_line = try brain.recognizeFromCapturedPath("fixtures/visitors/known_01.jpg");
    const resumed = try brain.continueConversationAfterAwaitedVisual(visual_line);
    try std.testing.expectEqualStrings("Hi, I see you.", resumed.spoken_text);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(!brain.conversationAwaitingHost());
}

test "awaited camera resume stops after one say when recognize and say arrive together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeAndSaySameBatchChatService{ .say_text = "Hello Celery." };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Hello celery"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());

    const visual_line = try brain.recognizeFromCapturedPath("fixtures/visitors/known_01.jpg");
    const resumed = try brain.continueConversationAfterAwaitedVisual(visual_line);
    try std.testing.expectEqualStrings("Hello Celery.", resumed.spoken_text);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(!brain.conversationAwaitingHost());
}

test "host sense delivery runs follow-up chat before next user turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeThenSayChatService{ .say_text = "Hi, I see you." };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());

    const visual_result = try brain.handleHostVisualObservation("fixtures/visitors/known_01.jpg", "affective_requested_capture", "image/jpeg");
    const resumed = switch (visual_result) {
        .conversation_resume => |conversation| conversation,
        else => return error.ExpectedConversationResume,
    };
    try std.testing.expectEqualStrings("Hi, I see you.", resumed.spoken_text);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(!brain.conversationAwaitingHost());
}

test "user turn while host pull pending does not auto-resume from stale visual path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.last_visual_observation_path = try allocator.dupe(u8, "fixtures/visitors/known_01.jpg");
    brain.last_visual_update_seconds = brain.now_seconds - 60;
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeThenSayChatService{};
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());
    const answered = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello again"), .{});
    try std.testing.expectEqualStrings("I still need the camera.", answered.spoken_text);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(brain.awaitedHostRequestActive());
}

test "host pull remains pending across idle timeout until delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeThenSayChatService{ .say_text = "Hi there." };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());
    brain.now_seconds += 46;

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello again"), .{});
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(brain.awaitedHostRequestActive());
}

test "awaited visual resume reuses delivered frame when recognize is requested again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRepeatedRecognizeThenSayChatService{ .say_text = "Yes, I recognize you." };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Do you recognize me?"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());

    brain.last_visual_observation_path = try allocator.dupe(u8, "fixtures/visitors/known_01.jpg");
    brain.last_visual_update_seconds = brain.now_seconds;
    brain.last_visual_observation_uploaded = false;

    const visual_line = try brain.recognizeFromCapturedPath("fixtures/visitors/known_01.jpg");
    const resumed = try brain.continueConversationAfterAwaitedVisual(visual_line);
    try std.testing.expectEqualStrings("Yes, I recognize you.", resumed.spoken_text);
    try std.testing.expect(!resumed.awaiting_host_sense);
    try std.testing.expect(!brain.conversationAwaitingHost());
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
}

test "no-face resume speaks without recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeTwiceThenSayChatService{ .say_text = "I could not see a face in the frame." };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Do you recognize me?"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());

    brain.last_visual_observation_path = try allocator.dupe(u8, "fixtures/empty/empty_room_01.jpg");
    brain.last_visual_update_seconds = brain.now_seconds;
    brain.last_visual_observation_uploaded = false;

    const visual_line = try brain.recognizeFromCapturedPath("fixtures/empty/empty_room_01.jpg");
    try std.testing.expect(std.mem.indexOf(u8, visual_line, "people_count=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, visual_line, "interpretation=no_face_in_frame") != null);

    const resumed = try brain.continueConversationAfterAwaitedVisual(visual_line);
    try std.testing.expect(resumed.spoken_text.len > 0);
    try std.testing.expectEqualStrings("I could not see a face in the frame.", resumed.spoken_text);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(!brain.conversationAwaitingHost());
}

test "host sense follow-up restores orchestration framing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = support.OrchestrationResumeObservingChatService{};
    brain.deps.chat_service = chat.service();

    const anchor = "self-defined want: Continue existing.";
    try brain_process.ensureActiveActivity(&brain, anchor, "req-orchestration", .salient_sense);
    try brain.setAwaitedHostRequest("camera", "recognize");

    const visual_line = try std.fmt.allocPrint(allocator, "sensed_image:\n- path: fixtures/visitors/known_01.jpg\n- note: host delivered frame\n", .{});
    const resumed = try brain.continueConversationAfterAwaitedVisual(visual_line);
    try std.testing.expectEqualStrings("Continuing the activity.", resumed.spoken_text);
    try std.testing.expectEqual(@as(usize, 1), chat.calls);
    try std.testing.expect(!brain.conversationAwaitingHost());
}

test "unknown face after hello skips follow-up deliberation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeThenSayChatService{ .say_text = "Hello." };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Hello Geisha"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());

    const visual_line = try brain.recognizeFromCapturedPath("fixtures/visitors/unknown_01.jpg");
    const resumed = brain.continueConversationAfterAwaitedVisual(visual_line);
    try std.testing.expectError(error.NoActiveActivity, resumed);
    try std.testing.expectEqual(@as(usize, 1), chat.calls);
}

test "overlap while recognize pending blocks duplicate pull" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeThenSayChatService{};
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Hello Geisha"), .{});
    try std.testing.expect(brain.awaitedHostRequestActive());
    const request_id = brain.awaited_host_request.?.request_id;

    const overlap_text = "Can you see who I am?";
    const overlap = @import("present_moment.zig").detectRequestOverlap(&brain, overlap_text);
    try std.testing.expect(overlap != null);
    try std.testing.expectEqualStrings("recognize", overlap.?.in_flight_kind);

    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(allocator);
    var proposals = [_]chat_mod.ActionProposal{.{ .action = .recognize }};
    const batch = try brain.executeActionProposals(&proposals, &observations);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "recognition_in_flight:") != null);
    try std.testing.expect(batch.spoken_text == null);
    try std.testing.expect(brain.awaitedHostRequestActive());
    try std.testing.expectEqualStrings(request_id, brain.awaited_host_request.?.request_id);
}

test "present moment observation includes last spoken text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain_process.ensureActiveActivity(&brain, "Hello Geisha", "req_test", .user_speech);
    if (brain.active_activity) |*active| {
        active.state.last_spoken_text = try allocator.dupe(u8, "Hello.");
    }
    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(allocator);
    try @import("present_moment.zig").appendObservation(&brain, &observations, "Hello Geisha", null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "Hello Geisha") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "Hello.") != null);
}

test "known person gets warm greeting and sighting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    _ = try brain.recognizeFromCapturedPath("fixtures/visitors/known_01.jpg");
    try std.testing.expectEqual(@as(u32, 2), store.people.items[0].sighting_count);
    try std.testing.expectEqual(@as(usize, 1), store.sightings.items.len);
    try std.testing.expectEqualStrings("fixtures/visitors/known_01.jpg", store.people.items[0].representative_image_path.?);
    try std.testing.expect(store.people.items[0].representative_quality_score > 0.80);
}

test "lower quality representative photo does not replace current best" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    store.people.items[0].representative_sighting_id = "sighting_best";
    store.people.items[0].representative_image_path = "fixtures/visitors/known_01.jpg";
    store.people.items[0].representative_quality_score = 0.91;
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_changed_01.jpg", &.{}, &store, &desc);
    _ = try brain.recognizeFromCapturedPath("fixtures/visitors/known_changed_01.jpg");
    try std.testing.expectEqualStrings("sighting_best", store.people.items[0].representative_sighting_id.?);
    try std.testing.expectEqualStrings("fixtures/visitors/known_01.jpg", store.people.items[0].representative_image_path.?);
    try std.testing.expectEqual(@as(f32, 0.91), store.people.items[0].representative_quality_score);
}

test "known person after long absence mentions duration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text = try greeting.knownGreeting(allocator, .{
        .person_id = "person_001",
        .display_name = "Mara",
        .relationship_status = .friend,
        .created_at = "0",
        .last_seen_at = "0",
        .sighting_count = 1,
        .greeting_style = .warm,
        .stable_notes = &.{},
        .recent_notes = &.{},
        .embeddings = &.{},
    }, null, 172800);
    try std.testing.expect(std.mem.indexOf(u8, text, "2 days") != null);
}

test "weak match asks confirmation and updates existing person on yes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_changed_01.jpg", &.{}, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Mara" };
    brain.deps.chat_service = scripted_chat.service();
    _ = try brain.recognizeFromCapturedPath("fixtures/visitors/known_changed_01.jpg");
    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Mara"), .{});
    try std.testing.expectEqual(@as(u32, 2), store.people.items[0].sighting_count);
    try std.testing.expect(store.people.items[0].embeddings.len > 0);
    try std.testing.expect(store.people.items[0].stable_notes.len > 0);
    try std.testing.expect(store.people.items[0].recent_notes.len > 0);
    try std.testing.expectEqualStrings("Wearing a blue jacket and carrying a small bag.", store.sightings.items[0].description.?);
}

test "existing name but weak match with no creates separate profile path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_changed_01.jpg", &.{}, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Mara Other" };
    brain.deps.chat_service = scripted_chat.service();
    _ = try brain.recognizeFromCapturedPath("fixtures/visitors/known_changed_01.jpg");
    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "I'm Mara Other"), .{});
    try std.testing.expectEqual(@as(usize, 2), store.people.items.len);
}

test "conversation turn does not register unknown speaker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"Could you tell me the time?"}, &store, &desc);
    try brain.handleConversationTurn();
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
    try std.testing.expectEqualStrings("Could you tell me the time?", store.conversation_summaries.items[0].user_summary);
}

test "conversation identity claim updates existing person after missed recognition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addZelda(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"it's me, Zelda"}, &store, &desc);
    var scripted_chat = ScriptedIdentityClaimChatService{ .claimed_name = "Zelda" };
    brain.deps.chat_service = scripted_chat.service();
    brain.last_visual_observation_path = try allocator.dupe(u8, "fixtures/visitors/unknown_01.jpg");
    try brain.handleConversationTurn();
    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);
    try std.testing.expectEqualStrings("Zelda", store.people.items[0].display_name);
    try std.testing.expectEqual(@as(u32, 2), store.people.items[0].sighting_count);
    try std.testing.expect(store.people.items[0].embeddings.len > 0);
    try std.testing.expect(store.people.items[0].recent_notes.len > 0);
    try std.testing.expectEqual(@as(usize, 1), store.sightings.items.len);
    try std.testing.expectEqualStrings("person_zelda", store.sightings.items[0].person_id.?);
    try std.testing.expectEqualStrings("Visible clothing and accessories only; no sensitive traits inferred.", store.sightings.items[0].description.?);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
}

test "conversation identity claim can create missing profile after confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{ "it's me, Ari", "yes" }, &store, &desc);
    var scripted_chat = ScriptedIdentityClaimChatService{ .claimed_name = "Ari", .needs_confirmation = true };
    brain.deps.chat_service = scripted_chat.service();
    brain.last_visual_observation_path = try allocator.dupe(u8, "fixtures/visitors/unknown_01.jpg");
    try brain.handleConversationTurn();
    try brain.handleConversationTurn();
    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);
    try std.testing.expectEqualStrings("Ari", store.people.items[0].display_name);
    try std.testing.expectEqual(schema.RelationshipStatus.creator, store.people.items[0].relationship_status);
    try std.testing.expect(store.people.items[0].embeddings.len > 0);
    try std.testing.expectEqual(@as(usize, 1), store.sightings.items.len);
    try std.testing.expectEqualStrings(store.people.items[0].person_id, store.sightings.items[0].person_id.?);
    try std.testing.expectEqualStrings("Visible clothing and accessories only; no sensitive traits inferred.", store.sightings.items[0].description.?);
    try std.testing.expectEqual(@as(usize, 2), store.conversation_summaries.items.len);
}

test "remember person action creates profile from latest observed image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{}, &store, &desc);
    brain.last_visual_observation_path = "fixtures/visitors/unknown_01.jpg";
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{
        .{ .action = .remember_person, .name = "Ari" },
        .{ .action = .say, .text = "I will remember you as Ari." },
    };
    const spoken = try brain.executeActionProposals(&commands, &observations);
    try std.testing.expectEqualStrings("I will remember you as Ari.", spoken.spoken_text.?);
    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);
    try std.testing.expectEqualStrings("Ari", store.people.items[0].display_name);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "person_remembered:") != null);
}

test "recognition composite stores identity evidence confidence on hypothesis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain.deps.store.upsertSelfTrust(.{
        .self_trust_id = "self_trust_recognition_ambient",
        .faculty = "recognition",
        .context_pattern = "ambient recognition context",
        .confidence = 0.10,
        .updated_at_ms = brain.now_seconds * 1000,
    });

    const composite = try recognition_composite.recognizeSubject(&brain, "fixtures/visitors/known_01.jpg", &.{});
    try std.testing.expectEqual(composite.result.confidence, composite.fused_confidence);
    try std.testing.expectEqual(composite.fused_confidence, composite.hypothesis.confidence);
    try std.testing.expect(composite.hypothesis.evidence_event_ids.len >= 4);
    try std.testing.expect(eventKindSeen(store.experience_events.items, experience_kinds.recognition_visual_evidence));
    try std.testing.expect(eventKindSeen(store.experience_events.items, experience_kinds.recognition_context_evidence));
    try std.testing.expect(eventKindSeen(store.experience_events.items, experience_kinds.recognition_memory_evidence));
    try std.testing.expect(composite.decision == .suspected or composite.decision == .unknown);
}

