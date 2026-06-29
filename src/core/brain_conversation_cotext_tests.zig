const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const openai = ports.openai;
const input_mod = ports.input;
const activity_mod = @import("activity.zig");
const brain_process = @import("brain_process.zig");
const chat_mod = ports.chat;

const Brain = brain_mod.Brain;
const TestStore = store_support.TestStore;
const makeBrain = support.makeBrain;

fn timelineHasStimulus(brain: *Brain) bool {
    const active = brain.active_activity orelse return false;
    for (active.timeline) |event| {
        if (event.kind == .stimulus) return true;
    }
    return false;
}

test "unsolicited camera during conversation records cotext without host follow-up chat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = support.SilentSalientSenseDuringConversationChatService{};
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "tell me about your trip"), .{});
    try std.testing.expect(brain.active_activity != null);
    try std.testing.expectEqual(activity_mod.Kind.conversation, brain.active_activity.?.kind);
    try std.testing.expectEqual(@as(usize, 1), chat.calls);

    const visual_result = try brain.handleHostVisualObservation("fixtures/visitors/known_01.jpg", "affective_camera", "image/jpeg");
    switch (visual_result) {
        .detail_only, .recognition_only => {},
        else => return error.ExpectedNonConversationOutcome,
    }
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expect(timelineHasStimulus(&brain));
    try std.testing.expect(!brain.awaitedHostRequestActive());
}

test "silent salient sense reconsider surfaces conversation_cotext on next user turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = support.ConversationCotextOnNextTurnChatService{};
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    _ = try brain.handleHostVisualObservation("fixtures/visitors/known_01.jpg", "affective_camera", "image/jpeg");
    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "what did you see?"), .{});

    try std.testing.expect(timelineHasStimulus(&brain));
    try std.testing.expectEqual(@as(usize, 3), chat.calls);
}

test "salient sense during conversation may speak while staying on conversation activity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = support.SpeakingSalientSenseDuringConversationChatService{};
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    const visual_result = try brain.handleHostVisualObservation("fixtures/visitors/known_01.jpg", "affective_camera", "image/jpeg");
    const conversation = switch (visual_result) {
        .salient_reaction => |value| value,
        else => return error.ExpectedSalientReaction,
    };
    try std.testing.expectEqualStrings("I see the photo.", conversation.spoken_text);
    try std.testing.expectEqual(activity_mod.Kind.conversation, brain.active_activity.?.kind);
}

test "cotemporal reconsider memory summary does not frame sense as user speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const summary = try Brain.formatTurnSummaryForMemory(allocator, .reconsideration, "a photo arrived", "kept quiet");
    defer allocator.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "You just heard USER say") == null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "While we were talking") != null);
}

test "awaited camera delivery still runs host sense follow-up chat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();
    var chat = support.ScriptedRecognizeThenSayChatService{ .say_text = "Hi, I see you." };
    brain.deps.chat_service = chat.service();

    _ = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    try std.testing.expect(brain.conversationAwaitingHost());

    const visual_result = try brain.handleHostVisualObservation("fixtures/visitors/known_01.jpg", "affective_requested_capture", "image/jpeg");
    const resumed = switch (visual_result) {
        .conversation_resume => |value| value,
        else => return error.ExpectedConversationResume,
    };
    try std.testing.expectEqualStrings("Hi, I see you.", resumed.spoken_text);
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
}
