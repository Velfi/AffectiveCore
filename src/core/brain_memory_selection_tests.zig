const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const memory_selection_mod = @import("memory_selection.zig");
const helpers = @import("brain_helpers.zig");

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

test "conversation memory selection adds relevant_memories and observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "want_recognition",
        .scope = .long_term,
        .text = "Do you recognize me?",
        .interpretation = "self-defined want: Do you recognize me?",
        .tags = @constCast(&[_][]const u8{ "self_want", "recognition" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 8,
    });

    const selection = try brain.selectConversationMemories("Do you recognize me?");
    const memory = try brain.buildConversationMemoryWithSpeaker(null, null, selection, .heard_speech);
    var observations = std.ArrayList(u8).empty;
    try memory_selection_mod.appendMemorySelectionObservation(allocator, &observations, selection);

    try std.testing.expect(std.mem.indexOf(u8, memory, "relevant_memories:") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "feel relevant") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "memory_selection:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "want_recognition") != null);
}

test "conversation memory selection uses vector search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "mem_a",
        .scope = .long_term,
        .text = "hello world",
        .interpretation = "hello world",
        .tags = &.{},
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
    });
    const selection = try brain.selectConversationMemories("hello");
    try std.testing.expect(selection.entries.len >= 1);
}

test "conversation memory selection ranks by vector without llm filtering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "want_recognition",
        .scope = .long_term,
        .text = "Do you recognize me?",
        .interpretation = "self-defined want: Do you recognize me?",
        .tags = @constCast(&[_][]const u8{ "self_want", "recognition" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 8,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "unrelated",
        .scope = .long_term,
        .text = "Garden soil pH levels",
        .interpretation = "Garden soil pH levels",
        .tags = &.{},
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
    });

    const selection = try brain.selectConversationMemories("Do you recognize me?");
    try std.testing.expect(selection.entries.len >= 1);
    try std.testing.expectEqualStrings("want_recognition", selection.entries[0].memory_id);
}

