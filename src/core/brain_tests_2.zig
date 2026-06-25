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
    try std.testing.expect(std.mem.indexOf(u8, text, "Recent conversation summaries:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user_0") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user_1") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user_2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "user_9") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gamma") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "You just heard USER say \"user_9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "I just said \"brain_9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "User:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Brain:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "First note") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second note") == null);
    try std.testing.expectEqual(@as(usize, 8), countOccurrences(text, "- You just heard USER say"));
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
    const with_speaker = try brain.buildConversationMemoryWithSpeaker("Current speaker recognition: known; name=Mara; person_id=person_mara.\n");

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
    const trace_count = store.traces.items.len;

    const prompt = try brain.dryRunConversationPrompt("what should you remember?");

    try std.testing.expectEqual(memory_count, store.memories.items.len);
    try std.testing.expectEqual(summary_count, store.conversation_summaries.items.len);
    try std.testing.expectEqual(trace_count, store.traces.items.len);
    try std.testing.expect(std.mem.indexOf(u8, prompt.user_prompt, "# Compact Memory\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.user_prompt, "# User Input\nYou just heard USER say \"what should you remember?\"") != null);
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

test "memory sweep decays and removes low scoring short term memories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_low",
        .scope = .short_term,
        .text = "Temporary thought",
        .tags = @constCast(&[_][]const u8{"temp"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_long",
        .scope = .long_term,
        .text = "Durable thought",
        .tags = @constCast(&[_][]const u8{"durable"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 4,
        .score = 8,
    });

    _ = try brain.sweepShortTermMemories();
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    try std.testing.expectEqualStrings("memory_long", store.memories.items[0].memory_id);
}

test "introspection summarizes memory and senses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_one",
        .scope = .long_term,
        .text = "A durable note",
        .tags = @constCast(&[_][]const u8{"note"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 2,
        .score = 5,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "want_music",
        .scope = .long_term,
        .text = "I want quiet music during maintenance.",
        .interpretation = "self-defined want: I want quiet music during maintenance.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_want" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
    });
    const text = try brain.introspect();
    try std.testing.expect(std.mem.indexOf(u8, text, "senses: camera") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "battery level") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "plugged-in power state") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "database statistics") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "self_needs_and_wants:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "self_defined_want:want_music") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2 long-term") != null);
}

test "event readers log introspection without forming brain memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var log = TestCommandLog{};
    brain.deps.command_log = log.log();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .introspect }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "introspection:") != null);
    try std.testing.expectEqual(@as(usize, 2), store.runtime_events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, store.runtime_events.items[0], "\"kind\":\"command_sent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.runtime_events.items[1], "\"kind\":\"command_result\"") != null);
    try std.testing.expectEqualStrings("result", log.kind.?);
    try std.testing.expectEqualStrings("introspect", log.title.?);
    try std.testing.expectEqual(@as(usize, 0), store.experiences.items.len);
}

test "sweep memory performs runtime event compaction as dreamtime work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.io = std.testing.io;
    brain.cfg.audio_input_dir = "data/test/runtime_event_sweep_audio";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, brain.cfg.audio_input_dir);
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, brain.cfg.audio_input_dir) catch {};

    try std.testing.expectEqual(@as(usize, 0), store.runtime_event_sweep_count);
    try std.testing.expect(try brain.runMaintenanceCommand("sweep_memory"));
    try std.testing.expectEqual(@as(usize, 1), store.runtime_event_sweep_count);
}

test "event readers log forget memory without making a tombstone memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_to_forget",
        .scope = .short_term,
        .text = "temporary note",
        .tags = @constCast(&[_][]const u8{"temporary"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .forget_memory, .memory_id = "memory_to_forget" }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "memory_forgotten: memory_to_forget true") != null);
    try std.testing.expectEqual(@as(usize, 0), store.memories.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.experiences.items.len);
    try std.testing.expectEqual(@as(usize, 4), store.runtime_events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, store.runtime_events.items[1], "\"command\":\"forget_memory\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.runtime_events.items[1], "\"forgotten_memory_id\":\"memory_to_forget\"") != null);
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"superego_memory_boundary\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"psyche_role\":\"superego\""));
}

test "memory formation reader stores eligible perception command results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .describe_image, .query = "colors" }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "image_description:") != null);
    try std.testing.expectEqual(@as(usize, 4), store.runtime_events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, store.runtime_events.items[1], "\"kind\":\"developer_log\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.runtime_events.items[2], "\"title\":\"sense_stimulus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.runtime_events.items[2], "\"kind\":\"observation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.runtime_events.items[3], "\"kind\":\"command_result\"") != null);
    try std.testing.expectEqual(@as(usize, 1), store.experiences.items.len);
    try std.testing.expectEqual(schema.ExperienceSource.environment, store.experiences.items[0].source);
    try std.testing.expectEqual(schema.ExperienceKind.perception, store.experiences.items[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, store.experiences.items[0].interpretation, "Test image description") != null);
}

test "id monitor emits concern event to jsonl and developer log without memory by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var log = TestCommandLog{};
    brain.deps.command_log = log.log();
    var monitor = TestIdMonitor{ .event = .{
        .kind = .system,
        .source = "id",
        .title = "storage pressure",
        .body = "storage pressure crossed a concern threshold",
        .severity = .concern,
        .monitor_id = "storage_pressure",
        .pattern_id = "storage_high",
        .confidence = 0.90,
        .dedupe_key = "storage_high",
        .tags = @constCast(&[_][]const u8{ "id", "storage" }),
    } };
    const sources = [_]id_monitor.Source{monitor.source()};
    brain.deps.id_monitor_sources = sources[0..];

    try brain.runIdMonitors(std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), monitor.calls);
    try std.testing.expectEqual(@as(usize, 1), store.runtime_events.items.len);
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"monitor_id\":\"storage_pressure\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"severity\":\"concern\""));
    try std.testing.expectEqual(@as(usize, 0), store.experiences.items.len);
    try std.testing.expectEqualStrings("id", log.kind.?);
    try std.testing.expectEqualStrings("storage pressure", log.title.?);
}

test "id monitor eligible event forms memory only through memory formation reader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var monitor = TestIdMonitor{ .event = .{
        .kind = .perception,
        .source = "id",
        .title = "repeated unknown sighting",
        .body = "The Id noticed repeated unknown-person sightings.",
        .subject = "unknown_person_pattern",
        .raw = "unknown sightings repeated",
        .interpretation = "Repeated unknown-person sightings may need attention.",
        .experience_source = .environment,
        .experience_kind = .perception,
        .experience_retention = .summarize,
        .severity = .warning,
        .monitor_id = "unknown_sighting_pattern",
        .pattern_id = "unknown_repeated",
        .dedupe_key = "unknown_repeated",
        .tags = @constCast(&[_][]const u8{ "id", "recognition" }),
    } };
    const sources = [_]id_monitor.Source{monitor.source()};
    brain.deps.id_monitor_sources = sources[0..];

    try brain.runIdMonitors(std.testing.io);

    try std.testing.expectEqual(@as(usize, 7), store.runtime_events.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.experiences.items.len);
    try std.testing.expectEqual(schema.ExperienceSource.environment, store.experiences.items[0].source);
    try std.testing.expectEqualStrings("unknown_person_pattern", store.experiences.items[0].subject);
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"superego_concern\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"ego_attention_candidate\""));
}
