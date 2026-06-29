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
const email_mod = ports.email;
const maintenance = @import("maintenance.zig");
const interrupt_mod = @import("interrupt.zig");
const seed_mod = @import("seed.zig");
const facts = @import("facts.zig");
const context_tokens = @import("context_tokens.zig");
const helpers = @import("brain_helpers.zig");
const activity_mod = @import("activity.zig");
const brain_process = @import("brain_process.zig");

const findExperienceEventByKind = support.findExperienceEventByKind;
const ReminderReconsiderChatService = support.ReminderReconsiderChatService;

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

test "unknown conversation can register person through remember_person skill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{}, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Ari" };
    brain.deps.chat_service = scripted_chat.service();
    _ = try brain.recognizeFromCapturedPath("fixtures/visitors/unknown_01.jpg");
    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "I'm Ari"), .{});
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
    var brain = makeBrain(allocator, "scratch/unknown_01.jpg", &.{}, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Ari" };
    brain.deps.chat_service = scripted_chat.service();

    var capture = try brain.deps.camera.capture(allocator);
    try brain.retainCaptureForPersonMemory(&capture);
    _ = try brain.recognizeFromCapturedPath(capture.path);
    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "I'm Ari"), .{});

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
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{}, &store, &desc);
    var scripted_chat = ScriptedRememberPersonChatService{ .remembered_name = "Ari" };
    brain.deps.chat_service = scripted_chat.service();
    _ = try brain.recognizeFromCapturedPath("fixtures/visitors/unknown_01.jpg");
    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "I'm Ari"), .{});
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
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{}, &store, &desc);
    _ = try brain.recognizeFromCapturedPath("fixtures/visitors/unknown_01.jpg");
    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "I'm someone you've met before"), .{});
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
    try std.testing.expectEqualStrings("I'm someone you've met before", store.conversation_summaries.items[0].user_summary);
}

test "forget me action marks profile forgotten" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"forget me"}, &store, &desc);
    var scripted_chat = ScriptedForgetPersonChatService{ .target_name = "Mara" };
    brain.deps.chat_service = scripted_chat.service();
    try brain.handleConversationTurn();
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
    _ = findExperienceEventByKind(store.experience_events.items, "User.TextReceived") orelse return error.MissingUserTextReceivedEvent;
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
    }, .{});

    try std.testing.expectEqual(@as(usize, 1), chat.calls);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    const event = findExperienceEventByKind(store.experience_events.items, "Memory.ExperienceRecorded.utterance") orelse return error.MissingUtteranceExperienceEvent;
    try std.testing.expect(std.mem.indexOf(u8, event.payload, "raw_provider_json_path:") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.payload, "summary_json:") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.payload, "avg_token_p") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.payload, "please remember the lamp") != null);
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

    try std.testing.expectEqual(@as(usize, 1), chat.calls);
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

test "action batch services due reminder at interrupt point and continues" {
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
    var commands = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .text = "first command" },
        .{ .action = .unknown, .text = "second command" },
    };

    const result = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(result.interrupted_by == null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "timer_fired:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "Stretch") != null);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"kind\":\"reminder\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "timer_fired"));
    try std.testing.expectEqual(@as(usize, 0), store.memories.items.len);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: unknown: unavailable") != null);
    const due_again = try maintenance.dueTasks(allocator, brain.deps.filesystem.?, std.testing.io, schedule_path, state_path, 200);
    try std.testing.expectEqual(@as(usize, 0), due_again.len);
}

test "action batch yields when touch stimulus arrives at interrupt point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var source = TestInterruptSource{ .stimulus = .{ .kind = .face_memory } };
    brain.deps.interrupt_source = source.source();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .text = "completed before interrupt" },
        .{ .action = .unknown, .text = "not started" },
    };

    const result = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(interrupt_mod.StimulusKind.face_memory, result.interrupted_by.?.kind);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "interrupt_stimulus: face_memory") != null);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"kind\":\"autonomy\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"interrupt_stimulus\""));
    try std.testing.expectEqual(@as(usize, 0), store.memories.items.len);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: unknown: unavailable") != null);
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

test "due speech reminder reconsiders through chat loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const schedule_path = "data/test/maintenance_reconsider_schedule.md";
    const state_path = "data/test/maintenance_reconsider_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ReminderReconsiderChatService{};
    brain.deps.chat_service = chat.service();
    brain.deps.io = std.testing.io;
    brain.cfg.maintenance_schedule_path = schedule_path;
    brain.cfg.maintenance_state_path = state_path;
    brain.now_seconds = 101;
    _ = try maintenance.addReminder(allocator, brain.deps.filesystem.?, std.testing.io, schedule_path, "in 1 seconds", "Stretch.", 100);

    _ = try brain.reconsiderFromReminder("Stretch.");

    try std.testing.expectEqual(@as(usize, 1), chat.calls);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "Reminder.Fired"));
}


test "conversation with large self facts stays within chat budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    var chat = support.ScriptedEmptyThenFailChatService{};
    brain.deps.chat_service = chat.service();

    for (0..80) |i| {
        const value = try allocator.alloc(u8, 180);
        @memset(value, 'x');
        try store.facts.append(allocator, .{
            .fact_id = try std.fmt.allocPrint(allocator, "fact_{d}", .{i}),
            .key = try std.fmt.allocPrint(allocator, "note_{d}", .{i}),
            .value = value,
            .created_at = "1781222400",
            .updated_at = "1781222400",
        });
    }

    const memory = try brain.buildConversationMemory();
    try std.testing.expect(memory.len <= facts.conversation_self_facts_max_bytes + 4096);

    const result = try brain.handleConversationText(
        try input_mod.HeardSpeech.typed(allocator, "Hello there."),
        .{},
    );

    try std.testing.expect(chat.calls >= 1);
    try std.testing.expect(std.mem.indexOf(u8, result.brain_summary, "exceeded context budget") == null);
}

test "conversation trims low-salience context when prompt exceeds budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    var chat = support.ScriptedEmptyThenFailChatService{};
    brain.deps.chat_service = chat.service();
    const summary_size = context_tokens.minBytesExceedingTokenBudget(chat_mod.max_chat_context_tokens);
    const summary_text = try allocator.alloc(u8, summary_size);
    @memset(summary_text, 's');
    try brain.deps.store.addConversationSummary(.{
        .summary_id = try std.fmt.allocPrint(allocator, "summary_oversized", .{}),
        .time = try std.fmt.allocPrint(allocator, "{d}", .{brain.now_seconds}),
        .user_summary = summary_text,
        .brain_summary = try allocator.dupe(u8, "overflow"),
    });

    const result = try brain.handleConversationText(
        try input_mod.HeardSpeech.typed(allocator, "Do you recognize me?"),
        .{},
    );

    try std.testing.expect(chat.calls >= 1);
    try std.testing.expect(std.mem.indexOf(u8, result.brain_summary, "exceeded context budget") == null);
}

test "chat action batch continues after speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{
        .{ .action = .say, .text = "I can hold both names." },
        .{ .action = .unknown, .text = "My name is Otto, and Junior is also an appropriate name when Papa is present.", .tags = &[_][]const u8{ "identity", "name" } },
    };

    const spoken = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expectEqualStrings("I can hold both names.", spoken.spoken_text.?);
    try std.testing.expectEqual(@as(usize, 0), store.memories.items.len);
}

test "conversation hard error asks for user aided recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{ "send Mara the garden email", "nevermind" }, &store, &desc);
    var mailer = email_mod.TestEmailService{};
    brain.deps.email_service = mailer.service();
    var scripted_chat = ScriptedHardErrorRecoveryChatService{};
    brain.deps.chat_service = scripted_chat.service();

    try brain.handleConversationTurn();

    try std.testing.expectEqual(@as(usize, 1), scripted_chat.calls);
    try std.testing.expect(brain.pending_hard_error != null);
    try std.testing.expectEqualStrings("MissingEmailBody", brain.pending_hard_error.?.error_name);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_hard_error.?.action_pressure, "action=send_email") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_hard_error.?.action_pressure, "to=mara@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_hard_error.?.action_pressure, "subject=Garden") != null);

    try brain.handleConversationTurn();

    try std.testing.expectEqual(@as(usize, 2), scripted_chat.calls);
    try std.testing.expect(brain.pending_hard_error == null);
    try std.testing.expect(std.mem.indexOf(u8, scripted_chat.followup_observations, "pending_hard_error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, scripted_chat.followup_observations, "- error: MissingEmailBody") != null);
    try std.testing.expect(std.mem.indexOf(u8, scripted_chat.followup_observations, "action=send_email") != null);
    try std.testing.expect(std.mem.indexOf(u8, scripted_chat.followup_observations, "nevermind") != null);
}

test "conversation runtime failure before chat turn completes turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var failing_chat = support.FailingChatService{};
    brain.deps.chat_service = failing_chat.service();

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});

    try std.testing.expect(result.spoken_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.spoken_text, "Something went wrong") != null);
    try std.testing.expectEqualStrings("hello", result.user_summary);
    try std.testing.expect(std.mem.indexOf(u8, result.brain_summary, "Runtime failed before chat interpretation finished") != null);
}

test "empty chat response completes turn without retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var scripted_chat = support.ScriptedEmptyThenFailChatService{};
    brain.deps.chat_service = scripted_chat.service();

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});

    try std.testing.expectEqual(@as(usize, 1), scripted_chat.calls);
    try std.testing.expect(result.spoken_text.len == 0);
    try std.testing.expectEqualStrings("hello", result.user_summary);
    try std.testing.expectEqualStrings("Returned no outward actions.", result.brain_summary);
}
