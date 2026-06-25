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

test "autonomy sleeps when energy is exhausted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_exhausted_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "on";
    brain.cfg.autonomy_daily_energy = 0;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{} };
    brain.deps.autonomy_planner = scripted.planner();

    try brain.runAutonomyTick(std.testing.io);
    const day_key = try brain.localDayKey(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 0, day_key);
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(state.sleeping);
    try std.testing.expect(state.energy_exhausted);
}

test "dream can save optional dream memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var image_gen = image_mod.TestImageGenerationService{ .path = "data/test/dream.png" };
    brain.deps.image_generation_service = image_gen.service();
    const text = try brain.dream("Connect plant reminders with morning greetings", &[_][]const u8{"dream"}, "mixed");
    try std.testing.expect(std.mem.indexOf(u8, text, "memory_saved") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "heat:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "image_path: data/test/dream.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, image_gen.last_prompt.?, "Connect plant reminders with morning greetings") != null);
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.dreams.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.cognitive_dreams.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.artifacts.items.len);
    try std.testing.expectEqualStrings(store.artifacts.items[0].artifact_id, store.cognitive_dreams.items[0].generated_artifact_id.?);
    try std.testing.expectEqualStrings("data/test/dream.png", store.artifacts.items[0].path);
    try std.testing.expectEqualStrings("Connect plant reminders with morning greetings", store.memories.items[0].text);
}

test "conversation can use dream skill end to end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var scripted_chat = ScriptedDreamChatService{};
    var image_gen = image_mod.TestImageGenerationService{ .path = "data/test/e2e_dream.png" };
    brain.deps.chat_service = scripted_chat.service();
    brain.deps.image_generation_service = image_gen.service();

    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_e2e_seed",
        .scope = .long_term,
        .text = "The pothos needed water this morning.",
        .interpretation = "The pothos needed water this morning.",
        .tags = @constCast(&[_][]const u8{"plants"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 4,
        .salience = 0.75,
    });

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "use the dream skill"));

    try std.testing.expectEqual(@as(usize, 2), scripted_chat.calls);
    try std.testing.expect(std.mem.indexOf(u8, image_gen.last_prompt.?, "Connect today's room note with older plant memories.") != null);
    try std.testing.expectEqual(@as(usize, 1), store.cognitive_dreams.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.artifacts.items.len);
    try std.testing.expectEqualStrings("data/test/e2e_dream.png", store.artifacts.items[0].path);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
}

test "appraisal allows ambivalence and structured affect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const text = try brain.appraiseEvent("I feel ambivalent but curious about this memory plan?", &[_][]const u8{"design"});
    try std.testing.expect(std.mem.indexOf(u8, text, "uncertainty") != null);
    try std.testing.expectEqual(@as(usize, 1), store.impressions.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.appraisals.items.len);
    try std.testing.expect(store.appraisals.items[0].uncertainty > 0.50);
}

test "feel_about can answer self-directed questions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const text = try brain.feelAbout("how do you feel about yourself?", &[_][]const u8{"self"});
    try std.testing.expect(std.mem.indexOf(u8, text, "feeling:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "how do you feel about yourself?") != null);
    try std.testing.expectEqual(@as(usize, 1), store.appraisals.items.len);
}

test "think_about reflects and saves a short term thought" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_context",
        .scope = .long_term,
        .text = "Zelda values careful answers",
        .interpretation = "Zelda values careful answers",
        .tags = @constCast(&[_][]const u8{"preference"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 4,
    });

    const text = try brain.thinkAbout("how careful should I be?", &[_][]const u8{"preference"});
    try std.testing.expect(std.mem.indexOf(u8, text, "thought:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "memory_saved") != null);
    try std.testing.expectEqual(@as(usize, 2), store.memories.items.len);
    try std.testing.expectEqual(schema.MemoryScope.short_term, store.memories.items[1].scope);
    try std.testing.expectEqual(@as(usize, 1), store.appraisals.items.len);
    try std.testing.expectEqual(@as(u32, 1), store.memories.items[0].access_count);
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

test "imagine_image command calls image generation service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    var image_gen = image_mod.TestImageGenerationService{ .path = "data/test/moonflowers.png" };
    brain.deps.image_generation_service = image_gen.service();

    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .imagine_image, .text = "a brass automaton tending moonflowers" }};
    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expectEqualStrings("a brass automaton tending moonflowers", image_gen.last_prompt.?);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "imagined_image:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "data/test/moonflowers.png") != null);
}

test "choose_attention prioritizes unresolved appraisal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try store.conversation_summaries.append(allocator, .{
        .summary_id = "recent_summary",
        .time = try time_mod.nowTimestamp(allocator),
        .user_summary = "recent interaction",
        .brain_summary = "daily interaction need was met",
    });
    _ = try brain.feelAbout("I may need help with a broken reminder?", &[_][]const u8{"help"});
    const text = try brain.chooseAttention();
    try std.testing.expect(std.mem.indexOf(u8, text, "unresolved_appraisal") != null);
}

test "choose_attention prioritizes high intensity current stimulus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    _ = try brain.observeSenseStimulus(.{
        .kind = .power,
        .source = "test",
        .signature = "battery_critical_unplugged",
        .raw_magnitude = 0.90,
        .threat = 0.90,
        .safety_relevant = true,
        .metadata = "test critical power stimulus",
    });

    const text = try brain.chooseAttention();
    try std.testing.expect(std.mem.indexOf(u8, text, "current_stimulus") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "sense_stimulus kind=power") != null);
}

test "choose_attention ignores stale current stimulus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    _ = try brain.observeSenseStimulus(.{
        .kind = .power,
        .source = "test",
        .signature = "battery_critical_unplugged",
        .raw_magnitude = 0.90,
        .threat = 0.90,
        .safety_relevant = true,
        .metadata = "test critical power stimulus",
    });
    brain.now_seconds += 121;

    const text = try brain.chooseAttention();
    try std.testing.expect(std.mem.indexOf(u8, text, "current_stimulus") == null);
}

test "consolidation promotes salient memories and decays weak short term memories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_salient",
        .scope = .short_term,
        .text = "Important preference",
        .interpretation = "Important preference",
        .tags = @constCast(&[_][]const u8{"preference"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 2,
        .salience = 0.90,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_weak",
        .scope = .short_term,
        .text = "Weak fragment",
        .interpretation = "Weak fragment",
        .tags = @constCast(&[_][]const u8{"temp"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 2,
        .salience = 0.35,
    });
    const text = try brain.consolidateMemory();
    try std.testing.expect(std.mem.indexOf(u8, text, "promoted=1") != null);
    try std.testing.expectEqual(schema.MemoryScope.long_term, store.memories.items[0].scope);
    try std.testing.expect(store.memories.items[1].score < 2);
}

test "dream consumes pending flexible identity want achievements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var image_gen = image_mod.TestImageGenerationService{ .path = "data/test/flexible_identity_dream.png" };
    brain.deps.image_generation_service = image_gen.service();
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_seed",
        .scope = .long_term,
        .text = "Plants need morning checks",
        .interpretation = "Plants need morning checks",
        .tags = @constCast(&[_][]const u8{"plants"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 1,
        .score = 5,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "pending_want_achievement_1",
        .scope = .short_term,
        .text = "A want was achieved: I mapped the garden.",
        .interpretation = "pending flexible identity from achieved want want_garden: garden map completed",
        .tags = @constCast(&[_][]const u8{ "want_achievement", "positive_reinforcement", "flexible_identity", "pending_dream_reconciliation" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 4,
        .salience = 0.90,
    });

    const text = try brain.dream(null, &[_][]const u8{}, "mixed");
    try std.testing.expect(std.mem.indexOf(u8, text, "pending_want_achievement_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, image_gen.last_prompt.?, "Flexible self-model material") != null);
    try std.testing.expectEqual(@as(usize, 1), store.cognitive_dreams.items.len);
    try std.testing.expect(tagInSlice(store.cognitive_dreams.items[0].selected_trace_ids, "pending_want_achievement_1"));
    try std.testing.expect(findMemoryById(store.memories.items, "pending_want_achievement_1") == null);
    const reconciled = findMemoryWithTagForTest(store.memories.items, "reconciled_want_achievement") orelse return error.MissingReconciledWantAchievement;
    try std.testing.expect(tagInSlice(reconciled.tags, "reconciled_want_achievement"));
    try std.testing.expectEqual(schema.MemoryScope.long_term, reconciled.scope);
}

test "high heat dream has lower confidence and records source ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var image_gen = image_mod.TestImageGenerationService{ .path = "data/test/high_heat_dream.png" };
    brain.deps.image_generation_service = image_gen.service();
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_seed",
        .scope = .long_term,
        .text = "Plants need morning checks",
        .interpretation = "Plants need morning checks",
        .tags = @constCast(&[_][]const u8{"plants"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 1,
        .score = 5,
    });
    const text = try brain.dream("A plant reminder becomes a morning ritual", &[_][]const u8{"dream"}, "high");
    try std.testing.expect(std.mem.indexOf(u8, text, "surreal_symbolic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "image_path: data/test/high_heat_dream.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, image_gen.last_prompt.?, "surreal_symbolic") != null);
    try std.testing.expectEqual(@as(usize, 1), store.cognitive_dreams.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.artifacts.items.len);
    try std.testing.expect(store.cognitive_dreams.items[0].heat >= 0.67);
    try std.testing.expectEqual(@as(usize, 1), store.cognitive_dreams.items[0].selected_trace_ids.len);
    try std.testing.expectEqualStrings("memory_seed", store.cognitive_dreams.items[0].selected_trace_ids[0]);
    try std.testing.expectEqualStrings(store.artifacts.items[0].artifact_id, store.cognitive_dreams.items[0].generated_artifact_id.?);
}

test "remote description service failure is a hard error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    try addMara(&store, allocator, "1000");
    var desc = openai.TestDescriptionService{ .fail = true };
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try std.testing.expectError(error.RemoteServiceFailed, brain.handleFaceMemoryActivation());
    try std.testing.expectEqual(@as(u32, 1), store.people.items[0].sighting_count);
}

test "exhausted remote action failure reports unable to continue thinking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var log = TestCommandLog{};
    brain.deps.command_log = log.log();

    try brain.reportRemoteThinkingFailure();

    try std.testing.expectEqualStrings("error", log.kind.?);
    try std.testing.expectEqualStrings("Brain", log.title.?);
    try std.testing.expectEqualStrings(remote_thinking_failure_message, log.body.?);
}

test "image comparison uses previous visual observation as baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.last_visual_observation_path = "fixtures/visitors/known_changed_01.jpg";
    const text = try brain.compareImagesForObservation("clothing");
    try std.testing.expect(std.mem.indexOf(u8, text, "before: fixtures/visitors/known_changed_01.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after: fixtures/visitors/known_01.jpg") != null);
    try std.testing.expectEqualStrings("fixtures/visitors/known_01.jpg", brain.last_visual_observation_path.?);
}
