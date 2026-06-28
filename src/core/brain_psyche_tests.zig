const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const psyche_client = ports.psyche;
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

test "choose_attention prioritizes unresolved appraisal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try store.conversation_summaries.append(allocator, .{
        .summary_id = "recent_summary",
        .time = try std.fmt.allocPrint(allocator, "{d}", .{brain.now_seconds}),
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

test "focus derives from a high-attention stimulus and leads the context" {
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
    try brain.refreshFocus();

    try std.testing.expectEqual(Brain.FocusMode.focused, brain.focusMode());
    try std.testing.expect(brain.current_focus != null);
    try std.testing.expectEqual(Brain.FocusSource.derived, brain.current_focus.?.source);
    const memory = try brain.buildConversationMemory();
    try std.testing.expect(std.mem.indexOf(u8, memory, "CURRENT FOCUS:") != null);
}

test "a self-set focus overrides weaker derived attention until it decays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    _ = try brain.setFocus("finish the plant note");
    try std.testing.expectEqual(Brain.FocusSource.self_set, brain.current_focus.?.source);

    // A weak stimulus arrives; the deliberate plan should still win.
    _ = try brain.observeSenseStimulus(.{
        .kind = .speech,
        .source = "test",
        .signature = "weak_background",
        .raw_magnitude = 0.20,
        .threat = 0.0,
        .metadata = "weak background stimulus",
    });
    try brain.refreshFocus();

    try std.testing.expectEqual(Brain.FocusSource.self_set, brain.current_focus.?.source);
    try std.testing.expectEqualStrings("finish the plant note", brain.current_focus.?.text);
    const memory = try brain.buildConversationMemory();
    try std.testing.expect(std.mem.indexOf(u8, memory, "source: self_set") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "finish the plant note") != null);
}

test "a self-set focus decays past its TTL and re-derives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    _ = try brain.setFocus("finish the plant note");
    try std.testing.expect(brain.currentFocusAttention() != null);

    brain.now_seconds += 121; // past the 120s focus TTL
    try std.testing.expect(brain.currentFocusAttention() == null);

    try brain.refreshFocus();
    try std.testing.expectEqual(Brain.FocusSource.derived, brain.current_focus.?.source);
}

test "unfocused mode shows the low-key line, not a focus block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    // No fresh stimulus and only a weak derived focus: the gate stays unfocused.
    brain.current_stimulus_context = null;
    brain.current_stimulus_seconds = null;
    brain.current_focus = .{ .text = "wait for the next interaction", .source = .derived, .set_at = brain.now_seconds, .base_attention = 0.20 };

    try std.testing.expectEqual(Brain.FocusMode.unfocused, brain.focusMode());
    const memory = try brain.buildConversationMemory();
    try std.testing.expect(std.mem.indexOf(u8, memory, "unfocused") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory, "CURRENT FOCUS:") == null);
}

