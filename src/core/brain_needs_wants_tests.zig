const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const facts = @import("facts.zig");
const want_achievement_mod = ports.want_achievement;
const helpers = @import("brain_helpers.zig");
const wantReinforcementStrength = helpers.wantReinforcementStrength;

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

test "edit_need updates stored self need" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "need_rest",
        .scope = .long_term,
        .text = "I need occasional rest.",
        .interpretation = "self-defined need: I need occasional rest.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_need" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
    });
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .edit_need, .memory_id = "need_rest", .text = "I need quiet recovery time after long conversations." }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "self_definition_edited:") != null);
    try std.testing.expectEqualStrings("I need quiet recovery time after long conversations.", store.memories.items[0].text);
    try std.testing.expect(std.mem.indexOf(u8, store.memories.items[0].interpretation, "quiet recovery time") != null);
    try std.testing.expectEqual(@as(usize, 1), store.memories.items[0].revisions.len);
}

test "edit_want rejects need memory id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "need_rest",
        .scope = .long_term,
        .text = "I need occasional rest.",
        .interpretation = "self-defined need: I need occasional rest.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_need" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
    });
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .edit_want, .memory_id = "need_rest", .text = "I want more color." }};

    try std.testing.expectError(error.SelfDefinitionKindMismatch, brain.executeActionProposals(commands[0..], &observations));
}

test "want achievement reinforcement strengthens want and posts flexible identity box item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "want_garden",
        .scope = .long_term,
        .text = "I want to maintain a living map of the garden.",
        .interpretation = "self-defined want: I want to maintain a living map of the garden.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_want" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
        .salience = 0.80,
    });
    store.want_detector.matches = &[_]want_achievement_mod.WantAchievementMatch{.{
        .memory_id = "want_garden",
        .confidence = 0.86,
        .evidence = "the garden map is complete",
    }};

    const count = try brain.detectWantAchievements("The garden map is complete now.");
    try std.testing.expectEqual(@as(usize, 1), count);
    const updated = findMemoryById(store.memories.items, "want_garden") orelse return error.MissingWant;
    try std.testing.expect(updated.score > 5);
    try std.testing.expectEqual(@as(u32, 1), updated.access_count);
    try std.testing.expectEqual(@as(usize, 2), store.memories.items.len);
    const pending = findMemoryWithTagForTest(store.memories.items, "pending_dream_reconciliation") orelse return error.MissingPendingFlexibleIdentity;
    try std.testing.expect(tagInSlice(pending.tags, "pending_dream_reconciliation"));
    try std.testing.expect(tagInSlice(pending.tags, "flexible_identity"));
    try std.testing.expect(store.appraisals.items[0].valence > 0.60);
}

test "want achievement reinforcement is proportional to want salience and score" {
    const low = schema.MemoryRecord{
        .memory_id = "want_low",
        .scope = .long_term,
        .text = "low want",
        .interpretation = "low want",
        .tags = @constCast(&[_][]const u8{"self_want"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
        .salience = 0.30,
    };
    const high = schema.MemoryRecord{
        .memory_id = "want_high",
        .scope = .long_term,
        .text = "high want",
        .interpretation = "high want",
        .tags = @constCast(&[_][]const u8{"self_want"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 10,
        .salience = 0.95,
    };
    try std.testing.expect(wantReinforcementStrength(high) > wantReinforcementStrength(low));
}

test "want achievement rejects unknown want id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "want_music",
        .scope = .long_term,
        .text = "I want music.",
        .interpretation = "self-defined want: I want music.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_want" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
        .salience = 0.70,
    });
    store.want_detector.matches = &[_]want_achievement_mod.WantAchievementMatch{.{
        .memory_id = "want_missing",
        .confidence = 0.90,
        .evidence = "done",
    }};
    try std.testing.expectError(error.UnknownWantAchievementMemoryId, brain.detectWantAchievements("done"));
}

test "want achievement no match leaves memory and appraisals unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "want_music",
        .scope = .long_term,
        .text = "I want music.",
        .interpretation = "self-defined want: I want music.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_want" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
        .salience = 0.70,
    });

    const count = try brain.detectWantAchievements("nothing relevant happened");
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.appraisals.items.len);
}

