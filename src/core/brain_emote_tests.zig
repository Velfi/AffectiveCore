const std = @import("std");
const brain_mod = @import("brain.zig");
const ports = @import("ports.zig");
const chat_mod = ports.chat;
const facial_expression = ports.facial_expression;
const display_budget = @import("display_budget.zig");
const support = @import("brain_test_support.zig");
const openai = ports.openai;

const Brain = brain_mod.Brain;
const TestStore = @import("brain_test_store.zig").TestStore;
const TestFacialExpressionOutput = support.TestFacialExpressionOutput;
const TestEmoteOutput = support.TestEmoteOutput;
const makeBrain = support.makeBrain;
const writeAndRefreshFacialExpressionCatalog = support.writeAndRefreshFacialExpressionCatalog;

const test_avatar_json_unfocused_smirk =
    \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"frame":0,"row":0,"column":0,"name":"unfocused"}],"mouthSprites":[{"frame":0,"row":0,"column":0,"name":"smirk"}]}
;

test {
    _ = @import("display_budget.zig");
    _ = @import("port_emote.zig");
}

test "emote is available without facial expression catalog" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try std.testing.expect(brain.actionIsAvailable(.emote));
    try std.testing.expect(!brain.actionIsAvailable(.facial_expression));
}

test "emote shows normalized text and respects default duration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var emote_output = TestEmoteOutput{};
    defer emote_output.deinit();
    brain.deps.emote_output = emote_output.output();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .emote, .text = "*waves*" }};

    const result = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expectEqual(@as(usize, 1), emote_output.calls);
    try std.testing.expectEqualStrings("waves", emote_output.text.?);
    try std.testing.expectEqualStrings("*waves*", emote_output.display_text.?);
    try std.testing.expectEqual(@as(u32, facial_expression.default_duration_ms), emote_output.duration_ms);
    try std.testing.expect(result.spoken_text == null);
    try std.testing.expect(!result.ended_with_speech);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "emote_shown: text=waves duration_ms=3000") != null);
}

test "emote fails without output port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .emote, .text = "sighs" }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: emote: MissingEmoteOutput") != null);
}

test "emote rejects missing text before execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var emote_output = TestEmoteOutput{};
    defer emote_output.deinit();
    brain.deps.emote_output = emote_output.output();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .emote }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: emote: incomplete: missing emote text") != null);
}

test "display budget throttles emote and facial expression together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var emote_output = TestEmoteOutput{};
    defer emote_output.deinit();
    brain.deps.emote_output = emote_output.output();
    var expression_output = TestFacialExpressionOutput{};
    defer expression_output.deinit();
    brain.deps.facial_expression_output = expression_output.output();
    try writeAndRefreshFacialExpressionCatalog(&brain, allocator, std.testing.io, "/tmp/test-brain-emote-budget", test_avatar_json_unfocused_smirk);
    var observations = std.ArrayList(u8).empty;
    var first = [_]chat_mod.ActionProposal{.{ .action = .emote, .text = "waves", .duration_ms = 4000 }};
    _ = try brain.executeActionProposals(first[0..], &observations);
    try std.testing.expectEqual(@as(usize, 1), emote_output.calls);

    var second = [_]chat_mod.ActionProposal{.{ .action = .facial_expression, .eyes = "unfocused", .mouth = "smirk", .duration_ms = 2000 }};
    _ = try brain.executeActionProposals(second[0..], &observations);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: facial_expression: DisplayBudgetExceeded") != null);
    try std.testing.expectEqual(@as(usize, 0), expression_output.calls);
}

test "throttled emote returns DisplayBudgetExceeded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var emote_output = TestEmoteOutput{};
    defer emote_output.deinit();
    brain.deps.emote_output = emote_output.output();
    var observations = std.ArrayList(u8).empty;
    var first = [_]chat_mod.ActionProposal{.{ .action = .emote, .text = "waves", .duration_ms = 5000 }};
    _ = try brain.executeActionProposals(first[0..], &observations);
    var second = [_]chat_mod.ActionProposal{.{ .action = .emote, .text = "nods", .duration_ms = 1000 }};
    _ = try brain.executeActionProposals(second[0..], &observations);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: emote: DisplayBudgetExceeded") != null);
    try std.testing.expectEqual(@as(usize, 1), emote_output.calls);
}
