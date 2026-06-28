const std = @import("std");
const brain_mod = @import("brain.zig");
const chat_mod = @import("port_chat.zig");
const autonomy_mod = @import("port_autonomy.zig");
const process_goal_mod = @import("port_process_goal.zig");

const Brain = brain_mod.Brain;
const ComposeMode = process_goal_mod.ComposeMode;
const ProcessComposer = process_goal_mod.ProcessComposer;
const max_composed_steps = process_goal_mod.max_composed_steps;

pub fn buildChatCompositionContext(
    allocator: std.mem.Allocator,
    memory: []const u8,
    user_text: []const u8,
    observations: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "memory:\n{s}\n\nuser_text:\n{s}\n\nobservations:\n{s}",
        .{ memory, user_text, observations },
    );
}

pub fn buildAutonomyCompositionContext(
    allocator: std.mem.Allocator,
    ego_context: []const u8,
    reason: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\nego_reason:\n{s}",
        .{ ego_context, reason },
    );
}

pub fn expandAutonomyTurn(
    brain: *Brain,
    turn: autonomy_mod.AutonomyTurn,
    context: []const u8,
) !autonomy_mod.AutonomyTurn {
    return .{
        .action_pressures = try expandProposals(brain, turn.action_pressures, .autonomy, context),
        .salience = turn.salience,
        .reason = try brain.allocator.dupe(u8, turn.reason),
    };
}

pub fn expandChatTurn(
    brain: *Brain,
    turn: *chat_mod.ChatTurn,
    context: []const u8,
) !void {
    const previous = turn.action_pressures;
    turn.action_pressures = try expandProposals(brain, previous, .interaction, context);
    if (previous.len > 0) chat_mod.freeActionProposals(brain.allocator, previous);
}

pub fn expandProposals(
    brain: *Brain,
    proposals: []const chat_mod.ActionProposal,
    mode: ComposeMode,
    context: []const u8,
) ![]chat_mod.ActionProposal {
    var out = std.ArrayList(chat_mod.ActionProposal).empty;
    errdefer {
        for (out.items) |proposal| chat_mod.freeActionProposal(brain.allocator, proposal);
        out.deinit(brain.allocator);
    }
    for (proposals) |proposal| {
        if (proposal.process_goal) |goal| {
            const composed = try composeProcessGoal(brain, goal, context, mode, proposal.origin);
            errdefer freeProcessComposition(brain.allocator, composed);
            try out.appendSlice(brain.allocator, composed.action_pressures);
            releaseProcessCompositionContainer(brain.allocator, composed);
            continue;
        }
        if (proposal.action == .unknown) return error.InvalidProcessCompositionAction;
        try out.append(brain.allocator, try chat_mod.cloneActionProposal(brain.allocator, proposal));
    }
    return out.toOwnedSlice(brain.allocator);
}

fn composeProcessGoal(
    brain: *Brain,
    goal: []const u8,
    context: []const u8,
    mode: ComposeMode,
    origin: chat_mod.ActionOrigin,
) !process_goal_mod.ProcessComposition {
    const composer = brain.deps.process_composer orelse return error.MissingProcessComposer;
    brain.traceText("process_goal.compose.start", goal);
    const composition = try composer.compose(brain.allocator, goal, context, mode);
    errdefer freeProcessComposition(brain.allocator, composition);
    if (composition.action_pressures.len == 0) return error.EmptyProcessComposition;
    if (composition.action_pressures.len > max_composed_steps) return error.TooManyProcessCompositionSteps;
    for (composition.action_pressures) |*pressure| {
        if (pressure.process_goal != null) return error.NestedProcessGoal;
        if (pressure.action == .unknown) return error.InvalidProcessCompositionAction;
        if (mode == .autonomy and process_goal_mod.isForbiddenAutonomyAction(pressure.action)) return error.InvalidProcessCompositionAction;
        pressure.origin = origin;
        const merged_tags = try mergeProcessTags(brain.allocator, pressure.tags, goal);
        freeTags(brain.allocator, pressure.tags);
        pressure.tags = merged_tags;
    }
    try brain.recordProcessGoalComposition(
        goal,
        if (mode == .autonomy) "autonomy" else "interaction",
        context.len,
        composition.action_pressures.len,
    );
    brain.traceCount("process_goal.compose.done", composition.action_pressures.len);
    return composition;
}

fn freeTags(allocator: std.mem.Allocator, tags: []const []const u8) void {
    for (tags) |tag| allocator.free(tag);
    if (tags.len > 0) allocator.free(@constCast(tags));
}

fn freeProcessComposition(allocator: std.mem.Allocator, composition: process_goal_mod.ProcessComposition) void {
    chat_mod.freeActionProposals(allocator, composition.action_pressures);
    allocator.free(composition.reason);
}

fn releaseProcessCompositionContainer(allocator: std.mem.Allocator, composition: process_goal_mod.ProcessComposition) void {
    if (composition.action_pressures.len > 0) allocator.free(@constCast(composition.action_pressures));
    allocator.free(@constCast(composition.reason));
}

fn mergeProcessTags(allocator: std.mem.Allocator, tags: []const []const u8, goal: []const u8) ![]const []const u8 {
    const process_tag = try std.fmt.allocPrint(allocator, "process:{s}", .{goal});
    var out = try allocator.alloc([]const u8, tags.len + 1);
    for (tags, 0..) |tag, index| out[index] = try allocator.dupe(u8, tag);
    out[tags.len] = process_tag;
    return out;
}

test "expandProposals composes process goals with scripted composer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var composed_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .autonomy, .query = "touch" },
        .{ .action = .think_about, .origin = .autonomy, .query = "touch meaning", .delay_ms = 200 },
    };
    var scripted = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &composed_pressures,
            .reason = "reflect on touch",
        },
    };
    brain.deps.process_composer = scripted.composer();
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .autonomy, .process_goal = "investigate_touch" },
    };
    const expanded = try expandProposals(&brain, &proposals, .autonomy, "touch stimulus");
    defer chat_mod.freeActionProposals(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqualStrings("investigate_touch", scripted.last_goal);
    try std.testing.expectEqual(chat_mod.ActionProposalType.feel_about, expanded[0].action);
    try std.testing.expectEqual(chat_mod.ActionProposalType.think_about, expanded[1].action);
    try std.testing.expectEqual(@as(u64, 1), brain.context_stats.total_process_goal_count);
    try std.testing.expectEqual(@as(u64, 2), brain.context_stats.total_composed_steps);
}

test "expandProposals fails loudly without composer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .autonomy, .process_goal = "investigate_touch" },
    };
    try std.testing.expectError(error.MissingProcessComposer, expandProposals(&brain, &proposals, .autonomy, "context"));
}
