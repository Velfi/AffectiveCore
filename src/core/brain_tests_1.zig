const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const schema = @import("../storage/schema.zig");
const chat_mod = @import("../api/chat_client.zig");
const openai = @import("../api/openai_client.zig");
const audio_mod = @import("../api/audio_client.zig");
const autonomy_mod = @import("../api/autonomy_client.zig");
const image_mod = @import("../api/image_client.zig");
const email_mod = @import("../api/email_client.zig");
const want_achievement_mod = @import("../api/want_achievement_client.zig");
const psyche_client = @import("../api/psyche_client.zig");
const input_mod = @import("../platform/common/input.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
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
    try std.Io.Dir.cwd().createDirPath(std.testing.io, brain.cfg.audio_input_dir);

    const old_ms = (brain.now_seconds - speech_artifact_ttl_seconds - 1) * 1000;
    const recent_ms = (brain.now_seconds - speech_artifact_ttl_seconds + 1) * 1000;
    const old_audio = try std.fmt.allocPrint(allocator, "{s}/utterance_{d}.wav", .{ brain.cfg.audio_input_dir, old_ms });
    const old_json = try std.fmt.allocPrint(allocator, "{s}/utterance_{d}.wav.transcription.json", .{ brain.cfg.audio_input_dir, old_ms });
    const recent_audio = try std.fmt.allocPrint(allocator, "{s}/utterance_{d}.wav", .{ brain.cfg.audio_input_dir, recent_ms });
    const recent_json = try std.fmt.allocPrint(allocator, "{s}/utterance_{d}.wav.transcription.json", .{ brain.cfg.audio_input_dir, recent_ms });
    const unrelated = try std.fmt.allocPrint(allocator, "{s}/notes.txt", .{brain.cfg.audio_input_dir});

    inline for (.{ old_audio, old_json, recent_audio, recent_json, unrelated }) |path| {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "artifact", .flags = .{ .truncate = true } });
    }
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, old_audio) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, old_json) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, recent_audio) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, recent_json) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, unrelated) catch {};

    const result = try brain.sweepSpeechArtifacts();
    try std.testing.expectEqual(@as(usize, 1), result.audio_removed);
    try std.testing.expectEqual(@as(usize, 1), result.transcription_json_removed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, old_audio, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, old_json, .{}));
    try std.Io.Dir.cwd().access(std.testing.io, recent_audio, .{});
    try std.Io.Dir.cwd().access(std.testing.io, recent_json, .{});
    try std.Io.Dir.cwd().access(std.testing.io, unrelated, .{});
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
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, schedule_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, schedule_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.io = std.testing.io;
    brain.cfg.maintenance_schedule_path = schedule_path;
    brain.cfg.maintenance_state_path = state_path;
    brain.now_seconds = 101;
    _ = try maintenance.addReminder(allocator, std.testing.io, schedule_path, "in 1 seconds", "Stretch.", 100);
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
    const due_again = try maintenance.dueTasks(allocator, std.testing.io, schedule_path, state_path, 200);
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
