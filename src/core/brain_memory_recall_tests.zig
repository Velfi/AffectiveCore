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
const id_monitor = @import("id_monitor.zig");
const interrupt_mod = @import("interrupt.zig");
const seed_mod = @import("seed.zig");
const facts = @import("facts.zig");
const vector_index = @import("vector_index.zig");
const time_mod = @import("time.zig");
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

test "conversation memory avoids fixed bounded context presentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.now_seconds = facts.test_first_turned_on_at_unix_seconds + 12345;
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_one",
        .scope = .short_term,
        .text = "First note",
        .tags = @constCast(&[_][]const u8{ "alpha", "beta" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_two",
        .scope = .long_term,
        .text = "Second note",
        .tags = @constCast(&[_][]const u8{ "gamma", "alpha" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });
    for (0..10) |i| {
        try brain.deps.store.addConversationSummary(.{
            .summary_id = try std.fmt.allocPrint(allocator, "summary_{d}", .{i}),
            .time = "1000",
            .user_summary = try std.fmt.allocPrint(allocator, "user_{d}", .{i}),
            .brain_summary = try std.fmt.allocPrint(allocator, "brain_{d}", .{i}),
        });
    }

    const text = try brain.buildConversationMemory();
    try std.testing.expect(std.mem.indexOf(u8, text, "Memory index: 1 long-term, 1 short-term.") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fixed ordering") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Recent conversation summaries (chronological):") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user_9") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gamma") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "USER: \"user_9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "BRAIN: \"brain_9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "day_arc:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "User:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Brain:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "First note") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second note") == null);
    try std.testing.expectEqual(@as(usize, 8), countOccurrences(text, "USER: \"user_"));
    try std.testing.expectEqualStrings(
        "You just heard USER say \"asked about soldering\"\nI just said \"answered from memory\"",
        try Brain.formatConversationSummaryForMemory(allocator, "asked about soldering", "answered from memory"),
    );
}

test "conversation memory caps available tags at thirty two" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    for (0..40) |i| {
        const tag = try std.fmt.allocPrint(allocator, "tag_{d}", .{i});
        const tags = try allocator.alloc([]const u8, 1);
        tags[0] = tag;
        try brain.deps.store.saveMemoryRecord(.{
            .memory_id = try std.fmt.allocPrint(allocator, "memory_{d}", .{i}),
            .scope = .long_term,
            .text = try std.fmt.allocPrint(allocator, "private memory body {d}", .{i}),
            .tags = tags,
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
        });
    }

    const text = try brain.buildConversationMemory();
    const tags_line_start = std.mem.indexOf(u8, text, "Available memory tags:") orelse return error.MissingMemoryTagsLine;
    const tags_line_end = std.mem.indexOfScalarPos(u8, text, tags_line_start, '\n') orelse text.len;
    const tags_line = text[tags_line_start..tags_line_end];

    try std.testing.expectEqual(@as(usize, 32), countOccurrences(tags_line, " tag_"));
    try std.testing.expect(std.mem.indexOf(u8, text, "private memory body") == null);
}

test "conversation memory includes speaker context only when supplied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const without_speaker = try brain.buildConversationMemory();
    const with_speaker = try brain.buildConversationMemoryWithSpeaker("Current speaker recognition: known; name=Mara; person_id=person_mara.\n", null, null);

    try std.testing.expect(std.mem.indexOf(u8, without_speaker, "Current speaker recognition:") == null);
    try std.testing.expect(std.mem.indexOf(u8, with_speaker, "Current speaker recognition: known; name=Mara") != null);
}

test "dry run conversation prompt is sectioned and non mutating" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_hidden",
        .scope = .long_term,
        .text = "Hidden detail should require recall",
        .tags = @constCast(&[_][]const u8{"hidden_tag"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });
    try brain.deps.store.addConversationSummary(.{
        .summary_id = "summary_one",
        .time = "1000",
        .user_summary = "talked about context",
        .brain_summary = "kept it compact",
    });
    const memory_count = store.memories.items.len;
    const summary_count = store.conversation_summaries.items.len;
    const event_count = store.experience_events.items.len;

    const prompt = try brain.dryRunConversationPrompt("what should you remember?");

    try std.testing.expectEqual(memory_count, store.memories.items.len);
    try std.testing.expectEqual(summary_count, store.conversation_summaries.items.len);
    try std.testing.expectEqual(event_count, store.experience_events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, prompt.user_prompt, "# Compact Memory\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.user_prompt, "# User Input\nStimulus: \"what should you remember?\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.user_prompt, "# Observations\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.user_prompt, "Memory index: 1 long-term, 0 short-term.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.user_prompt, "hidden_tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.user_prompt, "Hidden detail should require recall") == null);
}

test "recalled short term memories track access and promote to long term" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_pref",
        .scope = .short_term,
        .text = "Zelda likes concise answers",
        .tags = @constCast(&[_][]const u8{"preference"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });

    _ = try brain.recallMemories("concise", &[_][]const u8{"preference"});
    try std.testing.expectEqual(@as(u32, 1), store.memories.items[0].access_count);
    try std.testing.expectEqual(schema.MemoryScope.short_term, store.memories.items[0].scope);
    _ = try brain.recallMemories("concise", &[_][]const u8{"preference"});
    _ = try brain.recallMemories("concise", &[_][]const u8{"preference"});
    try std.testing.expectEqual(@as(u32, 3), store.memories.items[0].access_count);
    try std.testing.expectEqual(schema.MemoryScope.long_term, store.memories.items[0].scope);
    var recalled_events: usize = 0;
    for (store.experience_events.items) |event| {
        if (std.mem.eql(u8, event.kind, "Memory.MemoryRecalled")) {
            recalled_events += 1;
            try std.testing.expect(std.mem.indexOf(u8, event.payload, "memory_id=memory_pref") != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), recalled_events);
}

test "recall ranks memories with vector similarity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_plants",
        .scope = .long_term,
        .text = "Plants need morning checks and water",
        .interpretation = "Plants need morning checks and water",
        .tags = @constCast(&[_][]const u8{"plants"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 4,
        .salience = 0.7,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_music",
        .scope = .long_term,
        .text = "Zelda likes quiet piano music",
        .interpretation = "Zelda likes quiet piano music",
        .tags = @constCast(&[_][]const u8{"music"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 4,
        .salience = 0.7,
    });

    const text = try brain.recallMemories("morning plant care", &[_][]const u8{});
    const plant_index = std.mem.indexOf(u8, text, "memory_plants") orelse return error.MissingPlantMemory;
    const music_index = std.mem.indexOf(u8, text, "memory_music") orelse text.len;
    try std.testing.expect(plant_index < music_index);
    try std.testing.expect(std.mem.indexOf(u8, text, "vector_score=") != null);
    try std.testing.expectEqual(@as(u32, 1), store.memories.items[0].access_count);
}

test "recall lazily indexes old vectorless memories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_old",
        .scope = .short_term,
        .text = "Zelda prefers concise answers",
        .interpretation = "Zelda prefers concise answers",
        .tags = @constCast(&[_][]const u8{"preference"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
    });
    try std.testing.expectEqual(@as(usize, 0), store.memories.items[0].vector.len);

    const text = try brain.recallMemories("concise preference", &[_][]const u8{"preference"});
    try std.testing.expect(std.mem.indexOf(u8, text, "memory_old") != null);
    try std.testing.expectEqual(vector_index.dimensions, store.memories.items[0].vector.len);
    try std.testing.expectEqual(@as(u32, 1), store.memories.items[0].access_count);
    try std.testing.expect(store.memories.items[0].score > 1);
    try std.testing.expect(store.impressions.items.len == 1);
}

test "recall with no query or tags does not access every memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_any",
        .scope = .long_term,
        .text = "Do not recall everything by default",
        .tags = @constCast(&[_][]const u8{"note"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });

    const text = try brain.recallMemories("  ", &[_][]const u8{});
    try std.testing.expect(std.mem.indexOf(u8, text, "- none") != null);
    try std.testing.expectEqual(@as(u32, 0), store.memories.items[0].access_count);
    try std.testing.expectEqual(@as(usize, 0), store.impressions.items.len);
}

test "recall respects explicit tag filters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_home",
        .scope = .long_term,
        .text = "Plants need morning checks at home",
        .interpretation = "Plants need morning checks at home",
        .tags = @constCast(&[_][]const u8{"home"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_work",
        .scope = .long_term,
        .text = "Plants need morning checks at work",
        .interpretation = "Plants need morning checks at work",
        .tags = @constCast(&[_][]const u8{"work"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });

    const text = try brain.recallMemories("plants morning", &[_][]const u8{"work"});
    try std.testing.expect(std.mem.indexOf(u8, text, "memory_work") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "memory_home") == null);
    try std.testing.expectEqual(@as(u32, 0), store.memories.items[0].access_count);
    try std.testing.expectEqual(@as(u32, 1), store.memories.items[1].access_count);
}
