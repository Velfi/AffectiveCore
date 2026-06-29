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
const interrupt_mod = @import("interrupt.zig");
const helpers = @import("brain_helpers.zig");
const activity_mod = @import("activity.zig");
const brain_process = @import("brain_process.zig");
const read_models = @import("read_models.zig");
const awaited_host_request = @import("awaited_host_request.zig");
const host_capability_activation = @import("host_capability_activation.zig");
const process_runtime = @import("process_runtime.zig");
const experience_kinds = @import("experience_kinds.zig");

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

test "simple conversation turn opens and keeps activity across turns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{ "follow up", "done" }, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-simple-1" });
    try std.testing.expect(brain.active_activity != null);
    const activity_id = try allocator.dupe(u8, brain.active_activity.?.id);
    try std.testing.expectEqual(activity_mod.Status.active, brain.active_activity.?.status);

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello there"), .{ .request_id = "req-simple-2" });
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings(activity_id, brain.active_activity.?.id);
    try std.testing.expectEqual(activity_mod.Status.active, brain.active_activity.?.status);
    try std.testing.expectEqual(@as(usize, 0), store.activity_history.items.len);
}

test "turn_complete keeps activity open across user messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = 1 };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-done-1" });
    const activity_id = try allocator.dupe(u8, brain.active_activity.?.id);

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello there"), .{ .request_id = "req-done-2" });
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings(activity_id, brain.active_activity.?.id);
    try std.testing.expectEqual(@as(usize, 0), store.activity_history.items.len);
}

test "quit closes and archives activity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-quit-1" });
    const activity_id = try allocator.dupe(u8, brain.active_activity.?.id);

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "quit"), .{ .request_id = "req-quit-2" });
    try std.testing.expect(brain.active_activity == null);
    try std.testing.expectEqual(@as(usize, 1), store.activity_history.items.len);
    try std.testing.expectEqual(schema.ActivityStatus.complete, store.activity_history.items[0].status);
    try std.testing.expectEqualStrings(activity_id, store.activity_history.items[0].id);
}

test "idle timeout pauses activity without archiving" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-idle" });
    const activity_id = try allocator.dupe(u8, brain.active_activity.?.id);
    brain.now_seconds += @as(i64, @intCast(brain.cfg.conversation_idle_timeout_seconds)) + 1;
    try brain.expireConversationIfIdle();

    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings(activity_id, brain.active_activity.?.id);
    try std.testing.expectEqual(activity_mod.Status.paused, brain.active_activity.?.status);
    try std.testing.expectEqual(@as(usize, 0), store.activity_history.items.len);
}

test "conversation follow-ups under continue-existing focus do not grow activity stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();
    brain.current_focus = .{
        .text = "Continue existing.",
        .source = .self_set,
        .set_at = brain.now_seconds,
        .base_attention = 0.8,
    };

    const follow_ups = [_][]const u8{
        "Where did we leave off?",
        "sorry, I didn't catch that",
        "Yes, where were we",
        "yes, summarize",
        "...",
        "continue",
        "Never mind. You seem a little confused today",
    };

    _ = try brain.handleConversationText(
        try input_mod.HeardSpeech.typed(allocator, follow_ups[0]),
        .{ .request_id = "req-follow-1" },
    );
    const activity_id = try allocator.dupe(u8, brain.active_activity.?.id);

    for (follow_ups[1..]) |text| {
        _ = try brain.handleConversationText(
            try input_mod.HeardSpeech.typed(allocator, text),
            .{ .request_id = "req-follow-next" },
        );
    }

    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings(activity_id, brain.active_activity.?.id);
    try std.testing.expectEqual(@as(usize, 0), brain.activity_stack.items.len);
}

test "unrelated user message replaces goal without stacking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-topic-1" });
    const activity_id = try allocator.dupe(u8, brain.active_activity.?.id);

    _ = try brain.handleConversationText(
        try input_mod.HeardSpeech.typed(allocator, "explain quantum entanglement experiments"),
        .{ .request_id = "req-topic-2" },
    );
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings(activity_id, brain.active_activity.?.id);
    try std.testing.expectEqual(activity_mod.Status.active, brain.active_activity.?.status);
    try std.testing.expect(std.mem.indexOf(u8, brain.active_activity.?.goal, "quantum") != null);
    try std.testing.expectEqual(@as(usize, 0), brain.activity_stack.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.activity_history.items.len);
}

test "replace goal collapses a full activity stack without overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-full-stack-1" });

    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        const parent_id = if (brain.active_activity) |active| active.parent_id else null;
        const goal = try std.fmt.allocPrint(allocator, "stale goal {d}", .{depth});
        try brain_process.pushActiveOntoStack(&brain, "stale sibling");
        try brain_process.openActivity(&brain, goal, "req-full-stack-stale", .user_speech, parent_id);
    }
    try std.testing.expectEqual(@as(usize, 8), brain.activity_stack.items.len);

    _ = try brain.handleConversationText(
        try input_mod.HeardSpeech.typed(allocator, "Hello! What was your name again?"),
        .{ .request_id = "req-full-stack-2" },
    );

    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqual(@as(usize, 0), brain.activity_stack.items.len);
}

test "child activity completion resumes parent from stack" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-stack-1" });
    const root_id = try allocator.dupe(u8, brain.active_activity.?.id);
    const parent_id = try allocator.dupe(u8, brain.active_activity.?.id);

    try brain_process.pushActiveOntoStack(&brain, "recognize visitor");
    try brain_process.openActivity(&brain, "look at who is here", "req-stack-2", .user_speech, parent_id);

    try brain_process.closeActiveActivity(&brain, .complete, "subtask complete");
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings(root_id, brain.active_activity.?.id);
    try std.testing.expectEqual(@as(usize, 0), brain.activity_stack.items.len);
}

test "begin_subtask and resume_parent restore parent activity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-subtask-1" });
    const root_id = try allocator.dupe(u8, brain.active_activity.?.id);

    const begun = try brain_process.beginSubtask(&brain, "look at who is here");
    defer allocator.free(begun);
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings("look at who is here", brain.active_activity.?.goal);
    try std.testing.expect(brain.active_activity.?.parent_id != null);
    try std.testing.expectEqualStrings(root_id, brain.active_activity.?.parent_id.?);
    try std.testing.expectEqual(@as(usize, 1), brain.activity_stack.items.len);
    try std.testing.expectEqualStrings(root_id, brain.activity_stack.items[0].id);

    const resumed = try brain_process.resumeParentTask(&brain);
    defer allocator.free(resumed);
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings(root_id, brain.active_activity.?.id);
    try std.testing.expectEqual(@as(usize, 0), brain.activity_stack.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.activity_history.items.len);
    try std.testing.expectEqualStrings("look at who is here", store.activity_history.items[0].goal);
}

test "activity stack persists across restore" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "main goal"), .{ .request_id = "req-stack-persist-1" });
    const root_id = try allocator.dupe(u8, brain.active_activity.?.id);
    const parent_id = try allocator.dupe(u8, brain.active_activity.?.id);
    try brain_process.pushActiveOntoStack(&brain, "subtask");
    try brain_process.openActivity(&brain, "subtask goal", "req-stack-persist-2", .user_speech, parent_id);

    var restored = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try restored.restorePersistedActivity();
    try std.testing.expect(restored.active_activity != null);
    try std.testing.expectEqualStrings("subtask goal", restored.active_activity.?.goal);
    try std.testing.expectEqual(@as(usize, 1), restored.activity_stack.items.len);
    try std.testing.expectEqualStrings(root_id, restored.activity_stack.items[0].id);
}

test "custom activity_stack_max enforces overflow at configured depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();
    brain.cfg.capacity.activity_stack_max = 2;

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-custom-stack-1" });

    var depth: usize = 0;
    while (depth < 2) : (depth += 1) {
        const parent_id = if (brain.active_activity) |active| active.parent_id else null;
        const goal = try std.fmt.allocPrint(allocator, "goal {d}", .{depth});
        try brain_process.pushActiveOntoStack(&brain, "pause");
        try brain_process.openActivity(&brain, goal, "req-custom-stack", .user_speech, parent_id);
    }
    try std.testing.expectEqual(@as(usize, 2), brain.activity_stack.items.len);
    const overflow = brain_process.pushActiveOntoStack(&brain, "overflow");
    try std.testing.expectError(error.ActivityStackOverflow, overflow);
}

test "restore collapses stale conversation stack with duplicate goal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "shared goal"), .{ .request_id = "req-stale-restore-1" });
    const parent_id = try allocator.dupe(u8, brain.active_activity.?.id);
    try brain_process.pushActiveOntoStack(&brain, "paused parent");
    try brain_process.openActivity(&brain, "shared goal", "req-stale-restore-2", .user_speech, parent_id);
    try std.testing.expectEqual(@as(usize, 1), brain.activity_stack.items.len);

    var restored = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try restored.restorePersistedActivity();
    try std.testing.expect(restored.active_activity != null);
    try std.testing.expectEqualStrings("shared goal", restored.active_activity.?.goal);
    try std.testing.expectEqual(@as(usize, 0), restored.activity_stack.items.len);
}

test "read models snapshot reflects custom capacity limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.capacity.activity_stack_max = 5;
    brain.cfg.capacity.memory_selected_max = 3;

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-capacity-model" });
    const snapshot = try read_models.readModelsSnapshot(&brain, allocator);
    try std.testing.expectEqual(@as(usize, 5), snapshot.capacity_model.configured.activity_stack_max);
    try std.testing.expectEqual(@as(usize, 3), snapshot.capacity_model.configured.memory_selected_max);
    try std.testing.expectEqual(@as(usize, 5), snapshot.activity_model.stack_max);
}

test "user speech collapses stale stack even without active activity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedContinuingChatService{ .done_after_call = null };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-stack-clear-1" });
    const parent_id = try allocator.dupe(u8, brain.active_activity.?.id);
    try brain_process.pushActiveOntoStack(&brain, "stale frame");
    try brain_process.openActivity(&brain, "stale child", "req-stack-clear-2", .user_speech, parent_id);
    try brain_process.archiveActiveActivity(&brain, .abandoned, "test cleared active without popping stack");
    try std.testing.expectEqual(@as(usize, 1), brain.activity_stack.items.len);
    try std.testing.expect(brain.active_activity == null);

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello again"), .{ .request_id = "req-stack-clear-3" });
    try std.testing.expectEqual(@as(usize, 0), brain.activity_stack.items.len);
    try std.testing.expect(brain.active_activity != null);
}

test "timeline append grows across candidate action recording" {
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

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-timeline" });
    const timeline_len = brain.active_activity.?.timeline.len;
    try std.testing.expect(timeline_len >= 3);
    try std.testing.expect(brain.active_activity.?.recent_candidate_actions.len >= 1);
}

test "conversation turn awaiting host sense exposes activity id" {
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

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-conv-1" });

    try std.testing.expect(brain.conversationAwaitingHost());
    try std.testing.expect(result.awaiting_host_sense);
    try std.testing.expectEqualStrings("camera", result.awaited_host_sense.?);
    try std.testing.expectEqualStrings("recognize", result.awaited_host_purpose.?);
    try std.testing.expectEqual(@as(u32, host_capability_activation.cold_start_pull_timeout_ms), result.awaited_host_timeout_ms.?);
    try std.testing.expect(result.activity_id != null);
    try std.testing.expectEqualStrings("active", result.activity_state.?);
    try std.testing.expectEqualStrings("hello", result.activity_goal.?);
    try std.testing.expect(result.activity_kind != null);
    try std.testing.expectEqualStrings("conversation", result.activity_kind.?);
    try std.testing.expect(result.awaiting_host_sense);
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqualStrings(result.activity_id.?, brain.active_activity.?.id);
    const snapshot = try read_models.readModelsSnapshot(&brain, allocator);
    try std.testing.expect(snapshot.activity_model.activity_id != null);
    try std.testing.expectEqualStrings("hello", snapshot.activity_model.goal.?);
    try std.testing.expectEqualStrings("active", snapshot.activity_model.status.?);
    try std.testing.expect(snapshot.activity_model.open_loop_count >= 1);
}

test "activity observation is included in orchestration prompts" {
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

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-activity-obs" });

    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(allocator);
    try brain_process.appendActivityObservation(&brain, &observations);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "active_activity:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "hello") != null);
}

test "paused activity persists across restore" {
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

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{ .request_id = "req-persist" });
    try std.testing.expect(brain.active_activity != null);
    const activity_id = try allocator.dupe(u8, brain.active_activity.?.id);

    var restored_brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    restored_brain.deps.camera = pull_camera.camera();
    restored_brain.deps.chat_service = chat.service();
    try restored_brain.restorePersistedActivity();
    try std.testing.expect(restored_brain.active_activity != null);
    try std.testing.expectEqualStrings(activity_id, restored_brain.active_activity.?.id);
    try std.testing.expectEqualStrings("hello", restored_brain.active_activity.?.goal);
    try std.testing.expect(restored_brain.active_activity.?.recent_candidate_actions.len >= 1);
    try std.testing.expect(restored_brain.active_activity.?.status == .active);
    try std.testing.expect(restored_brain.awaitedHostRequestActive());

    const visual_line = try restored_brain.recognizeFromCapturedPath("fixtures/visitors/known_01.jpg");
    const resumed = try restored_brain.continueConversationAfterAwaitedVisual(visual_line);
    try std.testing.expect(resumed.spoken_text.len > 0);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(!restored_brain.conversationAwaitingHost());
}

test "conversation accepts another user turn while host pull is pending" {
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

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());
    try std.testing.expect(brain.awaitedHostRequestMatches("camera", "recognize"));
    const answered = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "are you there?"), .{});
    try std.testing.expectEqualStrings("I still need the camera.", answered.spoken_text);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(brain.awaitedHostRequestActive());
}

test "user speech supersedes non-conversation activity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain_process.openActivity(&brain, "capture scene", "req-capture", .salient_sense, null);
    try std.testing.expect(brain.active_activity != null);
    brain.active_activity.?.kind_label = try allocator.dupe(u8, "Capture");
    try std.testing.expect(!std.ascii.eqlIgnoreCase(brain.active_activity.?.kind_label, "Conversation"));

    try brain_process.ensureActiveActivity(&brain, "Hello Geisha", "req-speech", .user_speech);
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqual(activity_mod.Kind.conversation, brain.active_activity.?.kind);
    try std.testing.expectEqualStrings("Hello Geisha", brain.active_activity.?.goal);
    try std.testing.expect(!std.mem.eql(u8, brain.active_activity.?.kind_label, "Capture"));
}

test "handleUserInterruptFromHost supersedes non-conversation activity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain_process.openActivity(&brain, "look at scene", "req-capture", .salient_sense, null);
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqual(activity_mod.Kind.generic, brain.active_activity.?.kind);

    try brain.handleUserInterruptFromHost(.{
        .reason = "user_requested_interrupt",
        .interrupted_action = "capture",
        .preview_text = "",
        .canceled_queued_action_count = 0,
    });
    try std.testing.expect(brain.active_activity == null);
    try std.testing.expect(brain.pending_user_interrupt_coalesce != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_user_interrupt_coalesce.?, "user_interrupt_coalesce:") != null);
}

test "handleUserInterruptFromHost aborts active process and clears awaited host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    var steps = [_]process_runtime.ProcessStep{
        .{
            .kind = .async_host_pull,
            .action = .recognize,
            .sense = try allocator.dupe(u8, "camera"),
            .purpose = try allocator.dupe(u8, "recognize"),
        },
        .{ .kind = .respond, .action = .say },
    };
    try process_runtime.startProcess(&brain, "search_memory", "Who was that?", .interaction, "test", steps[0..]);
    try brain.setAwaitedHostRequest("camera", "recognize");
    try std.testing.expect(brain.active_process != null);
    try std.testing.expect(brain.awaitedHostRequestActive());

    try brain.handleUserInterruptFromHost(.{
        .reason = "user_requested_interrupt",
        .interrupted_action = "recognize",
        .preview_text = "Hello Geisha",
        .canceled_queued_action_count = 1,
    });
    try std.testing.expect(brain.active_process == null);
    try std.testing.expect(!brain.awaitedHostRequestActive());
    try std.testing.expect(brain.pending_user_interrupt_coalesce != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_user_interrupt_coalesce.?, "search_memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_user_interrupt_coalesce.?, "Hello Geisha") != null);
}

test "second interrupt replaces pending coalesce from first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain.handleUserInterruptFromHost(.{
        .reason = "user_requested_interrupt",
        .interrupted_action = "first",
        .preview_text = "first preview",
        .canceled_queued_action_count = 0,
    });
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_user_interrupt_coalesce.?, "first preview") != null);

    try brain.handleUserInterruptFromHost(.{
        .reason = "user_requested_interrupt",
        .interrupted_action = "second",
        .preview_text = "second preview",
        .canceled_queued_action_count = 0,
    });
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_user_interrupt_coalesce.?, "first preview") == null);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_user_interrupt_coalesce.?, "second preview") != null);
}

test "handleUserInterruptFromHost clears pending deferred speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    brain.pending_deferred_heard_speech = try input_mod.HeardSpeech.typed(allocator, "stale while waiting");
    try brain.handleUserInterruptFromHost(.{
        .reason = "user_requested_interrupt",
        .interrupted_action = "recognize",
        .preview_text = "Hello",
        .canceled_queued_action_count = 0,
    });
    try std.testing.expect(brain.pending_deferred_heard_speech == null);
}

test "handleUserInterruptFromHost keeps owned stimulus context after return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain.handleUserInterruptFromHost(.{
        .reason = "user_requested_interrupt",
        .interrupted_action = "capture",
        .preview_text = "Hello Geisha",
        .canceled_queued_action_count = 0,
    });
    try std.testing.expect(brain.owned_current_stimulus_context != null);
    try std.testing.expectEqualStrings("user interrupt: Hello Geisha", brain.current_stimulus_context.?);
}

test "interrupt clears deferred speech so it is not replayed on next user turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = support.ScriptedContinuingChatService{ .done_after_call = 1 };
    brain.deps.chat_service = chat.service();

    brain.pending_deferred_heard_speech = try input_mod.HeardSpeech.typed(allocator, "stale while waiting");
    try brain.handleUserInterruptFromHost(.{
        .reason = "user_requested_interrupt",
        .interrupted_action = "recognize",
        .preview_text = "fresh",
        .canceled_queued_action_count = 0,
    });

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "fresh"), .{});
    try std.testing.expectEqual(@as(usize, 1), chat.calls);
}

test "direct user turn nudges verbal reply after silent non-verbal action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = support.ScriptedNonVerbalThenNudgedSayChatService{ .say_text = "Hello Geisha." };
    brain.deps.chat_service = chat.service();

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Hello Geisha"), .{});
    try std.testing.expectEqualStrings("Hello Geisha.", result.spoken_text);
    try std.testing.expectEqual(@as(usize, 1), chat.calls);
    try std.testing.expectEqual(support.ScriptedNonVerbalThenNudgedSayChatService.NudgeKind.initial, chat.last_nudge_kind);
}

test "heard speech nudge retries when turn is not complete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = support.ScriptedAlwaysNonVerbalChatService{};
    brain.deps.chat_service = chat.service();

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Hello"), .{});
    try std.testing.expectEqualStrings("Hello.", result.spoken_text);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
}

test "pending interrupt coalesce injects observation on next user turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = support.ScriptedInterruptCoalesceSayChatService{};
    brain.deps.chat_service = chat.service();

    try brain.handleUserInterruptFromHost(.{
        .reason = "user_requested_interrupt",
        .interrupted_action = "capture",
        .preview_text = "Hello",
        .canceled_queued_action_count = 0,
    });
    try std.testing.expect(brain.pending_user_interrupt_coalesce != null);

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "Hello"), .{});
    try std.testing.expectEqualStrings("Hello.", result.spoken_text);
    try std.testing.expect(brain.pending_user_interrupt_coalesce == null);
}

test "handleEmojiReaction records formatted stimulus when idle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const result = try brain.handleEmojiReaction(.{
        .emoji = "👍",
        .utterance_text = "Hello back.",
        .speaker_label = "You",
        .utterance_event_id = "evt_brain_123",
    });
    try std.testing.expectEqualStrings("", result.spoken_text);
    var found_reaction = false;
    for (store.experience_events.items) |event| {
        if (!std.mem.eql(u8, event.kind, experience_kinds.user_emoji_reaction)) continue;
        found_reaction = true;
        try std.testing.expectEqualStrings("You reacted 👍 to your utterance Hello back.", event.payload);
        try std.testing.expectEqual(@as(usize, 1), event.causal_parent_ids.len);
        try std.testing.expectEqualStrings("evt_brain_123", event.causal_parent_ids[0]);
    }
    try std.testing.expect(found_reaction);
}
