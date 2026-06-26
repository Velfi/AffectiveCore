const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const audio_mod = ports.audio;
const autonomy_mod = ports.autonomy;
const image_mod = ports.image;
const email_mod = ports.email;
const want_achievement_mod = ports.want_achievement;
const psyche_client = ports.psyche;
const input_mod = ports.input;
const facial_expression = ports.facial_expression;
const files_mod = ports.files;
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const interrupt_mod = @import("interrupt.zig");
const seed_mod = @import("seed.zig");
const greeting = @import("greeting_policy.zig");
const facts = @import("facts.zig");
const vector_index = @import("vector_index.zig");
const time_mod = @import("time.zig");
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;
const TestStore = store_support.TestStore;
const TestInput = support.TestInput;
const TestIdMonitor = support.TestIdMonitor;
const TestInterruptSource = support.TestInterruptSource;
const TestCommandLog = support.TestCommandLog;
const TestFacialExpressionOutput = support.TestFacialExpressionOutput;
const ScriptedDreamChatService = support.ScriptedDreamChatService;
const ScriptedRememberPersonChatService = support.ScriptedRememberPersonChatService;
const ScriptedRecallChatService = support.ScriptedRecallChatService;
const ScriptedClarificationChatService = support.ScriptedClarificationChatService;
const ScriptedHardErrorRecoveryChatService = support.ScriptedHardErrorRecoveryChatService;
const HeardSpeechObservationChatService = support.HeardSpeechObservationChatService;
const FailingIdentityClaimIntentService = support.FailingIdentityClaimIntentService;
const makeBrain = support.makeBrain;
const addMara = support.addMara;
const addZelda = support.addZelda;
const countOccurrences = support.countOccurrences;
const findMemoryById = helpers.findMemoryById;
const findMemoryWithTagForTest = helpers.findMemoryWithTagForTest;
const runtimeEventsContain = helpers.runtimeEventsContain;
const tagInSlice = helpers.tagInSlice;
const wantReinforcementStrength = helpers.wantReinforcementStrength;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;

test "touch with no recognition still starts curious conversation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    try brain.handleFaceMemoryActivation();
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
}

test "touch with fresh visual evidence does not force recognition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"I'm Ari"}, &store, &desc);
    brain.rememberVisualUpdate("fixtures/visitors/recent_01.jpg");

    try brain.handleFaceMemoryActivation();

    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.conversation_summaries.items.len);
    try std.testing.expect(std.mem.indexOf(u8, brain.current_stimulus_context.?, "sense_stimulus kind=touch") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.current_stimulus_context.?, "metadata=\"touch_stimulus") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.current_stimulus_context.?, "chosen_look=false") != null);
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"sense_stimulus\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "chosen_look=false"));
}

test "recognize command identifies known person and clears camera intent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const line = try brain.recognizeForObservation();

    try std.testing.expect(std.mem.indexOf(u8, line, "Mara") != null);
    try std.testing.expectEqual(Brain.CameraIntent.none, brain.pending_camera_intent);
    try std.testing.expect(store.sightings.items.len >= 1);
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
    brain.pending_camera_intent = .recognize;

    const line = try brain.recognizeFromCapturedPath("fixtures/visitors/known_01.jpg");

    try std.testing.expect(std.mem.indexOf(u8, line, "Mara") != null);
    try std.testing.expect(store.sightings.items.len >= 1);
}

test "camera pull mid-conversation pauses for awaited sense without a fallback reply" {
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

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"));

    // The bot looked and then paused for the observation. It should not invent a
    // reply or loop back through the chat service.
    try std.testing.expect(std.mem.indexOf(u8, result.spoken_text, "Something went wrong") == null);
    try std.testing.expectEqualStrings("", result.spoken_text);
    try std.testing.expectEqual(@as(usize, 1), chat.calls);
}

test "unknown touch can register person through remember_person skill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"I'm Ari"}, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Ari" };
    brain.deps.chat_service = scripted_chat.service();
    try brain.handleFaceMemoryActivation();
    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);
    try std.testing.expectEqualStrings("Ari", store.people.items[0].display_name);
    try std.testing.expectEqual(schema.RelationshipStatus.creator, store.people.items[0].relationship_status);
    try std.testing.expect(store.people.items[0].recent_notes.len > 0);
    try std.testing.expectEqualStrings("Visible clothing and accessories only; no sensitive traits inferred.", store.people.items[0].recent_notes[0].text);
    try std.testing.expectEqualStrings("Visible clothing and accessories only; no sensitive traits inferred.", store.sightings.items[0].description.?);
    const graph_text = try brain.deps.graph.summary(allocator, 8);
    try std.testing.expect(std.mem.indexOf(u8, graph_text, "creator_of") != null);
    try std.testing.expect(std.mem.indexOf(u8, graph_text, "attached_to") != null);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
}

test "unknown person registration describes retained capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    store.retain_prefix = "retained";
    var desc = openai.TestDescriptionService{ .missing_image_path = "scratch/unknown_01.jpg" };
    var brain = makeBrain(allocator, "scratch/unknown_01.jpg", &.{"I'm Ari"}, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Ari" };
    brain.deps.chat_service = scripted_chat.service();

    try brain.handleFaceMemoryActivation();

    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);
    try std.testing.expectEqualStrings("retained/unknown_01.jpg", brain.last_visual_observation_path.?);
    try std.testing.expectEqualStrings("retained/unknown_01.jpg", store.sightings.items[0].image_path.?);
}

test "second remembered person does not replace existing creator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try store.people.append(allocator, .{
        .person_id = "person_creator",
        .display_name = "Zelda",
        .relationship_status = .creator,
        .created_at = "1000",
        .last_seen_at = "1000",
        .sighting_count = 1,
        .greeting_style = .warm,
        .stable_notes = &.{},
        .recent_notes = &.{},
        .embeddings = &.{},
    });
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"I'm Ari"}, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Ari" };
    brain.deps.chat_service = scripted_chat.service();
    try brain.handleFaceMemoryActivation();
    try std.testing.expectEqual(@as(usize, 2), store.people.items.len);
    try std.testing.expectEqual(schema.RelationshipStatus.creator, store.people.items[0].relationship_status);
    try std.testing.expectEqual(schema.RelationshipStatus.visitor, store.people.items[1].relationship_status);
}

test "unknown person non-name reply continues as conversation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"I'm someone you've met before"}, &store, &desc);
    try brain.handleFaceMemoryActivation();
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
    try std.testing.expectEqualStrings("I'm someone you've met before", store.conversation_summaries.items[0].user_summary);
}

test "known person gets warm greeting and sighting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.handleFaceMemoryActivation();
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
    var brain = makeBrain(allocator, "fixtures/visitors/known_changed_01.jpg", &.{ "Mara", "yes" }, &store, &desc);
    try brain.handleFaceMemoryActivation();
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
    var brain = makeBrain(allocator, "fixtures/visitors/known_changed_01.jpg", &.{ "Mara", "yes" }, &store, &desc);
    try brain.handleFaceMemoryActivation();
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
    var brain = makeBrain(allocator, "fixtures/visitors/known_changed_01.jpg", &.{ "Mara", "no", "I'm Mara Other" }, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Mara Other" };
    brain.deps.chat_service = scripted_chat.service();
    try brain.handleFaceMemoryActivation();
    try std.testing.expectEqual(@as(usize, 2), store.people.items.len);
}

test "forget me command marks profile forgotten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"forget me"}, &store, &desc);
    _ = try brain.forgetByNameOrId("Mara");
    try std.testing.expectEqual(schema.RelationshipStatus.forgotten, store.people.items[0].relationship_status);
    try std.testing.expectEqual(@as(usize, 0), store.people.items[0].embeddings.len);
}

test "conversation turn stores summary without forcing speaker recognition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{"Tell me something cheerful"}, &store, &desc);
    try brain.handleConversationTurn();
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
    try std.testing.expectEqualStrings("Tell me something cheerful", store.conversation_summaries.items[0].user_summary);
    try std.testing.expectEqual(@as(usize, 1), store.impressions.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.appraisals.items.len);
}

test "conversation intent syntax error stops after appraisal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{"That's you. Remember?"}, &store, &desc);
    var intent = FailingIdentityClaimIntentService{};
    brain.deps.intent_service = intent.service();

    try std.testing.expectError(error.SyntaxError, brain.handleConversationTurn());

    try std.testing.expectEqual(@as(usize, 1), intent.calls);
    try std.testing.expectEqual(@as(usize, 2), store.experiences.items.len);
    try std.testing.expectEqual(schema.ExperienceKind.utterance, store.experiences.items[0].kind);
    try std.testing.expectEqual(schema.ExperienceKind.appraisal, store.experiences.items[1].kind);
    try std.testing.expectEqual(@as(usize, 1), store.impressions.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.appraisals.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.conversation_summaries.items.len);
}

test "plain conversation turns do not force repeated speaker recognition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{ "First turn", "Second turn" }, &store, &desc);
    try brain.handleConversationTurn();
    try brain.handleConversationTurn();
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.conversation_summaries.items.len);
}

test "heard speech intake preserves full transcription provider data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = HeardSpeechObservationChatService{};
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(.{
        .text = "please remember the lamp",
        .source = .speech_transcription,
        .provider = "whisper.cpp/whisper-cli",
        .model_path = "models/ggml-base.en.bin",
        .audio_path = "data/audio/input/utterance_test.wav",
        .raw_provider_json_path = "data/audio/input/utterance_test.wav.transcription.json",
        .summary_json = "{\"language\":\"en\",\"segment_count\":1,\"segments\":[{\"from_ms\":0,\"to_ms\":1000,\"text\":\" please remember the lamp\",\"token_count\":1,\"avg_token_p\":0.420,\"min_token_p\":0.420,\"low_confidence_tokens\":[{\"text\":\" please\",\"p\":0.420}]}]}",
    });

    try std.testing.expectEqual(@as(usize, 1), chat.calls);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expect(store.experiences.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, store.experiences.items[0].raw, "raw_provider_json_path:") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.experiences.items[0].raw, "summary_json:") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.experiences.items[0].raw, "\"avg_token_p\":0.420") != null);
    try std.testing.expectEqualStrings("please remember the lamp", store.experiences.items[0].interpretation);
}

test "speech artifact sweep removes old audio and transcription json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.io = std.testing.io;
    brain.now_seconds = 2_000_000;
    brain.cfg.audio_input_dir = "data/test/speech_artifact_sweep";
    var filesystem = files_mod.TestFileSystem{
        .allocator = allocator,
        .sweep_result = .{
            .audio_removed = 1,
            .transcription_json_removed = 1,
        },
    };
    brain.deps.filesystem = filesystem.filesystem();

    const result = try brain.sweepSpeechArtifacts();
    try std.testing.expectEqual(@as(usize, 1), result.audio_removed);
    try std.testing.expectEqual(@as(usize, 1), result.transcription_json_removed);
}

test "conversation continues after spoken prelude followed by memory recall" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{"Any memories that involve the word papa?"}, &store, &desc);
    var chat = ScriptedRecallChatService{};
    brain.deps.chat_service = chat.service();
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_papa_solder",
        .scope = .long_term,
        .text = "Papa taught me to solder patiently.",
        .interpretation = "Papa taught me to solder patiently.",
        .tags = @constCast(&[_][]const u8{"family"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 4,
    });

    try brain.handleConversationTurn();

    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
    try std.testing.expectEqualStrings("Answered with the recalled papa memory.", store.conversation_summaries.items[0].brain_summary);
}

test "conversation stops after a clarifying spoken question" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{"add one"}, &store, &desc);
    var chat = ScriptedClarificationChatService{};
    brain.deps.chat_service = chat.service();

    try brain.handleConversationTurn();

    try std.testing.expectEqual(@as(usize, 1), chat.calls);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
    try std.testing.expectEqualStrings("Asked one clarifying question.", store.conversation_summaries.items[0].brain_summary);
}

test "command batch services due reminder at interrupt point and continues" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schedule_path = "data/test/batch_interrupt_reminder.md";
    const state_path = "data/test/batch_interrupt_reminder_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.io = std.testing.io;
    brain.cfg.maintenance_schedule_path = schedule_path;
    brain.cfg.maintenance_state_path = state_path;
    brain.now_seconds = 101;
    _ = try maintenance.addReminder(allocator, brain.deps.filesystem.?, std.testing.io, schedule_path, "in 1 seconds", "Stretch.", 100);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{
        .{ .command = .remember_memory, .text = "first command" },
        .{ .command = .remember_memory, .text = "second command" },
    };

    const result = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(result.interrupted_by == null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "interrupt_reminder: say:Stretch") != null);
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"kind\":\"reminder\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"interrupt_reminder\""));
    try std.testing.expectEqual(@as(usize, 2), store.memories.items.len);
    const due_again = try maintenance.dueTasks(allocator, brain.deps.filesystem.?, std.testing.io, schedule_path, state_path, 200);
    try std.testing.expectEqual(@as(usize, 0), due_again.len);
}

test "command batch yields when touch stimulus arrives at interrupt point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var source = TestInterruptSource{ .stimulus = .{ .kind = .face_memory } };
    brain.deps.interrupt_source = source.source();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{
        .{ .command = .remember_memory, .text = "completed before interrupt" },
        .{ .command = .remember_memory, .text = "not started" },
    };

    const result = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(interrupt_mod.StimulusKind.face_memory, result.interrupted_by.?.kind);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "interrupt_stimulus: face_memory") != null);
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"kind\":\"autonomy\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"interrupt_stimulus\""));
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    try std.testing.expectEqualStrings("completed before interrupt", store.memories.items[0].text);
}

test "conversation idle timeout does not force speaker recognition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{ "First turn", "After timeout" }, &store, &desc);
    brain.now_seconds = facts.test_first_turned_on_at_unix_seconds + 1000;
    try brain.handleConversationTurn();
    brain.now_seconds = facts.test_first_turned_on_at_unix_seconds + 1000 + @as(i64, @intCast(brain.cfg.conversation_idle_timeout_seconds));
    try brain.handleConversationTurn();
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.conversation_summaries.items.len);
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
    try brain.handleConversationTurn();
    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);
    try std.testing.expectEqualStrings("Zelda", store.people.items[0].display_name);
    try std.testing.expectEqual(@as(u32, 2), store.people.items[0].sighting_count);
    try std.testing.expect(store.people.items[0].embeddings.len > 0);
    try std.testing.expect(store.people.items[0].recent_notes.len > 0);
    try std.testing.expectEqual(@as(usize, 1), store.sightings.items.len);
    try std.testing.expectEqualStrings("person_zelda", store.sightings.items[0].person_id.?);
    try std.testing.expectEqualStrings("Visible clothing and accessories only; no sensitive traits inferred.", store.sightings.items[0].description.?);
    try std.testing.expectEqual(@as(usize, 0), store.conversation_summaries.items.len);
}

test "conversation identity claim can create missing profile after confirmation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{ "it's me, Ari", "yes" }, &store, &desc);
    try brain.handleConversationTurn();
    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);
    try std.testing.expectEqualStrings("Ari", store.people.items[0].display_name);
    try std.testing.expectEqual(schema.RelationshipStatus.creator, store.people.items[0].relationship_status);
    try std.testing.expect(store.people.items[0].embeddings.len > 0);
    try std.testing.expectEqual(@as(usize, 1), store.sightings.items.len);
    try std.testing.expectEqualStrings(store.people.items[0].person_id, store.sightings.items[0].person_id.?);
    try std.testing.expectEqualStrings("Visible clothing and accessories only; no sensitive traits inferred.", store.sightings.items[0].description.?);
    try std.testing.expectEqual(@as(usize, 0), store.conversation_summaries.items.len);
}

test "remember person command creates profile from latest observed image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{}, &store, &desc);
    brain.last_visual_observation_path = "fixtures/visitors/unknown_01.jpg";
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{
        .{ .command = .remember_person, .name = "Ari" },
        .{ .command = .say, .text = "I will remember you as Ari." },
    };
    const spoken = try brain.executeChatCommands(&commands, &observations);
    try std.testing.expectEqualStrings("I will remember you as Ari.", spoken.spoken_text.?);
    try std.testing.expectEqual(@as(usize, 1), store.people.items.len);
    try std.testing.expectEqualStrings("Ari", store.people.items[0].display_name);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "person_remembered:") != null);
}
