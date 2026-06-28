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
const context_tokens = @import("context_tokens.zig");
const helpers = @import("brain_helpers.zig");
const activity_mod = @import("activity.zig");

const TouchObservationChatService = support.TouchObservationChatService;

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
const FailingIdentityClaimIntentService = support.FailingIdentityClaimIntentService;
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

test "touch records stimulus without forcing capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    _ = try brain.handleFaceMemoryActivation();
    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, brain.current_stimulus_context.?, "sense_stimulus kind=touch") != null);
}

test "touch with fresh visual evidence does not force recognition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/unknown_01.jpg", &.{"I'm Ari"}, &store, &desc);
    brain.rememberVisualUpdate("fixtures/visitors/recent_01.jpg");

    _ = try brain.handleFaceMemoryActivation();

    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expect(std.mem.indexOf(u8, brain.current_stimulus_context.?, "sense_stimulus kind=touch") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.current_stimulus_context.?, "metadata=\"touch_stimulus") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.current_stimulus_context.?, "chosen_look=false") != null);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"sense_stimulus\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "chosen_look=false"));
}

test "touch during awaiting host records stimulus without superseding pause" {
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

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Do you know me?"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());

    brain.last_visual_update_seconds = brain.now_seconds;
    _ = try brain.handleTouchStimulus("short_touch");
    try std.testing.expect(brain.conversationAwaitingHost());
    try std.testing.expect(brain.awaitedHostRequestMatches("camera", "recognize"));
    try std.testing.expect(std.mem.indexOf(u8, brain.current_stimulus_context.?, "sense_stimulus kind=touch") != null);
}

test "typed conversation includes recent touch in observations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = TouchObservationChatService{};
    brain.deps.chat_service = chat.service();
    brain.rememberVisualUpdate("fixtures/visitors/recent_01.jpg");
    _ = try brain.handleTouchStimulus("short_touch");

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "how many times did you poke me?"), .{});

    try std.testing.expect(chat.calls >= 1);
    try std.testing.expect(chat.calls <= 2);
}

test "salient touch skips orchestration when chat prompt exceeds budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    brain.last_conversation_turn_seconds = brain.now_seconds;
    const summary_size = context_tokens.minBytesExceedingTokenBudget(chat_mod.max_chat_context_tokens);
    const summary_text = try allocator.alloc(u8, summary_size);
    @memset(summary_text, 's');
    try brain.deps.store.addConversationSummary(.{
        .summary_id = try std.fmt.allocPrint(allocator, "summary_oversized", .{}),
        .time = try std.fmt.allocPrint(allocator, "{d}", .{brain.now_seconds}),
        .user_summary = summary_text,
        .brain_summary = try allocator.dupe(u8, "overflow"),
    });

    const before_summaries = store.conversation_summaries.items.len;
    const result = try brain.handleLongTouchActivation();
    try std.testing.expect(result == null);
    try std.testing.expectEqual(before_summaries, store.conversation_summaries.items.len);
}

