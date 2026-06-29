const std = @import("std");
const brain_mod = @import("brain.zig");
const chat_mod = @import("port_chat.zig");
const autonomy_mod = @import("port_autonomy.zig");
const process_goal_mod = @import("port_process_goal.zig");
const process_runtime_mod = @import("process_runtime.zig");
const process_recipe_memory = @import("process_recipe_memory.zig");
const skills_mod = @import("port_skills.zig");

const Brain = brain_mod.Brain;
const ComposeMode = process_goal_mod.ComposeMode;
const ProcessComposer = process_goal_mod.ProcessComposer;

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
    if (mode == .autonomy) {
        var process_goal_count: usize = 0;
        for (proposals) |proposal| {
            if (proposal.process_goal != null) process_goal_count += 1;
        }
        if (process_goal_count > 1) return try expandAutonomyProcessGoalsBatch(brain, proposals, context);
    }

    var out = std.ArrayList(chat_mod.ActionProposal).empty;
    errdefer {
        for (out.items) |proposal| chat_mod.freeActionProposal(brain.allocator, proposal);
        out.deinit(brain.allocator);
    }
    var interaction_process_goal_started = false;
    for (proposals) |proposal| {
        if (proposal.process_goal) |goal| {
            if (mode == .interaction and interaction_process_goal_started) {
                brain.traceText("process_goal.compose.rejected", goal);
                return error.NestedProcessGoal;
            }
            const composed = try composeProcessGoal(brain, goal, context, mode, proposal.origin);
            errdefer freeProcessComposition(brain.allocator, composed);
            if (mode == .interaction) {
                const anchor = brain.conversation_user_text orelse goal;
                try process_runtime_mod.startFromProcessGoal(brain, goal, anchor, proposal.origin, composed);
                releaseProcessCompositionContainer(brain.allocator, composed);
                interaction_process_goal_started = true;
                continue;
            }
            if (try startAutonomyProcessFromComposition(brain, goal, composed, proposal.origin)) {
                releaseProcessCompositionContainer(brain.allocator, composed);
                continue;
            }
            try out.appendSlice(brain.allocator, composed.action_pressures);
            releaseProcessCompositionContainer(brain.allocator, composed);
            continue;
        }
        if (proposal.action == .unknown) return error.InvalidProcessCompositionAction;
        try out.append(brain.allocator, try chat_mod.cloneActionProposal(brain.allocator, proposal));
    }
    return out.toOwnedSlice(brain.allocator);
}

fn expandAutonomyProcessGoalsBatch(
    brain: *Brain,
    proposals: []const chat_mod.ActionProposal,
    context: []const u8,
) ![]chat_mod.ActionProposal {
    const composer = brain.deps.process_composer orelse return error.MissingProcessComposer;

    var batch_items = std.ArrayList(process_goal_mod.ComposeBatchItem).empty;
    defer batch_items.deinit(brain.allocator);
    var batch_goals = std.ArrayList([]const u8).empty;
    defer batch_goals.deinit(brain.allocator);
    var batch_origins = std.ArrayList(chat_mod.ActionOrigin).empty;
    defer batch_origins.deinit(brain.allocator);

    var out = std.ArrayList(chat_mod.ActionProposal).empty;
    errdefer {
        for (out.items) |proposal| chat_mod.freeActionProposal(brain.allocator, proposal);
        out.deinit(brain.allocator);
    }

    for (proposals) |proposal| {
        if (proposal.process_goal) |goal| {
            if (try tryResolveStoredProcessGoal(brain, goal, context, .autonomy, proposal.origin)) |composed| {
                try appendAutonomyComposedGoal(brain, goal, composed, proposal.origin, &out);
                continue;
            }
            try batch_items.append(brain.allocator, .{ .goal = goal, .context = context, .mode = .autonomy });
            try batch_goals.append(brain.allocator, goal);
            try batch_origins.append(brain.allocator, proposal.origin);
            continue;
        }
        if (proposal.action == .unknown) return error.InvalidProcessCompositionAction;
        try out.append(brain.allocator, try chat_mod.cloneActionProposal(brain.allocator, proposal));
    }

    if (batch_items.items.len == 0) return out.toOwnedSlice(brain.allocator);

    const compositions = try composer.composeBatch(brain.allocator, batch_items.items);
    defer brain.allocator.free(compositions);

    for (batch_goals.items, compositions, batch_origins.items) |goal, composed, origin| {
        var mutable = composed;
        brain.traceText("process_goal.compose.start", goal);
        try process_recipe_memory.saveDraftRecipe(brain, goal, .autonomy, mutable);
        try finalizeAutonomyComposition(brain, goal, &mutable, origin, context.len);
        try appendAutonomyComposedGoal(brain, goal, mutable, origin, &out);
    }
    return out.toOwnedSlice(brain.allocator);
}

fn appendAutonomyComposedGoal(
    brain: *Brain,
    goal: []const u8,
    composed: process_goal_mod.ProcessComposition,
    origin: chat_mod.ActionOrigin,
    out: *std.ArrayList(chat_mod.ActionProposal),
) !void {
    if (try startAutonomyProcessFromComposition(brain, goal, composed, origin)) {
        releaseProcessCompositionContainer(brain.allocator, composed);
        return;
    }
    try out.appendSlice(brain.allocator, composed.action_pressures);
    releaseProcessCompositionContainer(brain.allocator, composed);
}

fn tryResolveStoredProcessGoal(
    brain: *Brain,
    goal: []const u8,
    context: []const u8,
    mode: ComposeMode,
    origin: chat_mod.ActionOrigin,
) !?process_goal_mod.ProcessComposition {
    if (try process_recipe_memory.lookupRecipe(brain, goal, mode)) |recipe| {
        defer process_recipe_memory.freeRecipe(brain.allocator, recipe);
        if (process_recipe_memory.recipeIsProvenWorking(recipe)) {
            brain.traceText("process_goal.compose.cached", goal);
            var composition = try process_recipe_memory.deserializeComposition(brain.allocator, recipe);
            errdefer process_recipe_memory.freeCompositionMemory(brain.allocator, composition);
            try finalizeComposedProcessGoal(brain, goal, &composition, origin, mode, context.len, false);
            return composition;
        }
        if (process_recipe_memory.contextSupportsProcessRetry(brain, recipe, context)) {
            brain.traceText("process_goal.compose.retry", goal);
            var composition = try process_recipe_memory.deserializeComposition(brain.allocator, recipe);
            errdefer process_recipe_memory.freeCompositionMemory(brain.allocator, composition);
            try finalizeComposedProcessGoal(brain, goal, &composition, origin, mode, context.len, true);
            return composition;
        }
    }
    return null;
}

fn finalizeAutonomyComposition(
    brain: *Brain,
    goal: []const u8,
    composition: *process_goal_mod.ProcessComposition,
    origin: chat_mod.ActionOrigin,
    context_len: usize,
) !void {
    try finalizeComposedProcessGoal(brain, goal, composition, origin, .autonomy, context_len, true);
}

fn composeProcessGoal(
    brain: *Brain,
    goal: []const u8,
    context: []const u8,
    mode: ComposeMode,
    origin: chat_mod.ActionOrigin,
) !process_goal_mod.ProcessComposition {
    if (try tryResolveStoredProcessGoal(brain, goal, context, mode, origin)) |composition| return composition;

    const composer = brain.deps.process_composer orelse return error.MissingProcessComposer;
    brain.traceText("process_goal.compose.start", goal);
    var composition = try composer.compose(brain.allocator, goal, context, mode);
    errdefer freeProcessComposition(brain.allocator, composition);
    try process_recipe_memory.saveDraftRecipe(brain, goal, mode, composition);
    try finalizeComposedProcessGoal(brain, goal, &composition, origin, mode, context.len, true);
    return composition;
}

fn finalizeComposedProcessGoal(
    brain: *Brain,
    goal: []const u8,
    composition: *process_goal_mod.ProcessComposition,
    origin: chat_mod.ActionOrigin,
    mode: ComposeMode,
    context_len: usize,
    record_stats: bool,
) !void {
    if (composition.action_pressures.len == 0) return error.EmptyProcessComposition;
    for (composition.action_pressures) |*pressure| {
        if (pressure.process_goal != null) return error.NestedProcessGoal;
        if (pressure.action == .unknown) return error.InvalidProcessCompositionAction;
        if (mode == .autonomy and !skills_mod.autonomyAllowed(pressure.action, brain.cfg.autonomy_mode)) {
            return error.InvalidProcessCompositionAction;
        }
        pressure.origin = origin;
        const merged_tags = try mergeProcessTags(brain.allocator, pressure.tags, goal);
        freeTags(brain.allocator, pressure.tags);
        pressure.tags = merged_tags;
    }
    if (!record_stats) return;
    const mode_text = process_recipe_memory.modeText(mode);
    try brain.recordProcessGoalComposition(
        goal,
        mode_text,
        context_len,
        composition.action_pressures.len,
    );
    brain.traceCount("process_goal.compose.done", composition.action_pressures.len);
}

fn startAutonomyProcessFromComposition(
    brain: *Brain,
    goal: []const u8,
    composition: process_goal_mod.ProcessComposition,
    origin: chat_mod.ActionOrigin,
) !bool {
    if (!process_recipe_memory.compositionNeedsProcessRuntime(composition)) return false;
    const anchor = try brain.allocator.dupe(u8, goal);
    defer brain.allocator.free(anchor);
    try process_runtime_mod.startFromProcessGoal(brain, goal, anchor, origin, composition);
    return true;
}


fn freeTags(allocator: std.mem.Allocator, tags: []const []const u8) void {
    for (tags) |tag| allocator.free(tag);
    if (tags.len > 0) allocator.free(@constCast(tags));
}

fn freeProcessComposition(allocator: std.mem.Allocator, composition: process_goal_mod.ProcessComposition) void {
    chat_mod.freeActionProposals(allocator, composition.action_pressures);
    for (composition.step_kinds) |kind| {
        if (kind) |value| allocator.free(value);
    }
    if (composition.step_kinds.len > 0) allocator.free(@constCast(composition.step_kinds));
    allocator.free(composition.reason);
}

fn releaseProcessCompositionContainer(allocator: std.mem.Allocator, composition: process_goal_mod.ProcessComposition) void {
    if (composition.action_pressures.len > 0) allocator.free(@constCast(composition.action_pressures));
    if (composition.step_kinds.len > 0) allocator.free(@constCast(composition.step_kinds));
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

test "expandProposals batches multiple autonomy process goals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var composed_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .autonomy, .query = "touch" },
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
        .{ .action = .unknown, .origin = .autonomy, .process_goal = "check_energy" },
    };
    const expanded = try expandProposals(&brain, &proposals, .autonomy, "touch stimulus");
    defer chat_mod.freeActionProposals(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expectEqual(@as(usize, 1), scripted.batch_calls);
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
    try std.testing.expectEqual(@as(u64, 2), brain.context_stats.total_process_goal_count);
    try std.testing.expectEqual(@as(u64, 2), brain.context_stats.total_composed_steps);
}

test "expandProposals rejects second interaction process goal without composing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var composed_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .interaction, .query = "touch" },
    };
    var scripted = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &composed_pressures,
            .reason = "reflect on touch",
        },
    };
    brain.deps.process_composer = scripted.composer();
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .interaction, .process_goal = "investigate_touch" },
        .{ .action = .unknown, .origin = .interaction, .process_goal = "check_energy" },
    };
    try std.testing.expectError(error.NestedProcessGoal, expandProposals(&brain, &proposals, .interaction, "context"));
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(usize, 0), scripted.batch_calls);
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

test "expandProposals does not reuse draft recipe without proven success" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var cached_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .autonomy, .query = "touch" },
    };
    const composition = process_goal_mod.ProcessComposition{
        .action_pressures = &cached_pressures,
        .reason = "draft only",
        .step_kinds = &.{},
    };
    try process_recipe_memory.saveDraftRecipe(&brain, "investigate_touch", .autonomy, composition);
    var scripted = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &cached_pressures,
            .reason = "should run",
        },
    };
    brain.deps.process_composer = scripted.composer();
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .autonomy, .process_goal = "investigate_touch" },
    };
    const expanded = try expandProposals(&brain, &proposals, .autonomy, "context");
    defer chat_mod.freeActionProposals(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(usize, 1), expanded.len);
}

test "expandProposals reuses successful process recipe without composer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var cached_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .autonomy, .query = "touch" },
    };
    try process_recipe_memory.recordOutcome(&brain, "investigate_touch", .autonomy, .{
        .action_pressures = &cached_pressures,
        .reason = "cached",
        .step_kinds = &.{},
    }, .success, &.{}, null);
    var scripted = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &cached_pressures,
            .reason = "should not run",
        },
    };
    brain.deps.process_composer = scripted.composer();
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .autonomy, .process_goal = "investigate_touch" },
    };
    const expanded = try expandProposals(&brain, &proposals, .autonomy, "context");
    defer chat_mod.freeActionProposals(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expectEqual(@as(usize, 1), expanded.len);
    try std.testing.expectEqual(chat_mod.ActionProposalType.feel_about, expanded[0].action);
}

test "expandProposals composes again after failed recipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var cached_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .autonomy, .query = "touch" },
    };
    try process_recipe_memory.recordOutcome(&brain, "investigate_touch", .autonomy, .{
        .action_pressures = &cached_pressures,
        .reason = "failed cache",
        .step_kinds = &.{},
    }, .failed, &.{}, "host timeout");
    var scripted = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &cached_pressures,
            .reason = "fresh compose",
        },
    };
    brain.deps.process_composer = scripted.composer();
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .autonomy, .process_goal = "investigate_touch" },
    };
    const expanded = try expandProposals(&brain, &proposals, .autonomy, "context");
    defer chat_mod.freeActionProposals(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(usize, 1), expanded.len);
}

test "expandProposals retries failed host process when delivery arrives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var cached_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .recognize, .origin = .interaction },
        .{ .action = .say, .origin = .interaction, .text = "Hello." },
    };
    try process_recipe_memory.recordOutcome(&brain, "answer_with_host_visual", .interaction, .{
        .action_pressures = &cached_pressures,
        .reason = "recognize then say",
        .step_kinds = &.{},
    }, .failed, &.{}, "process timeout elapsed waiting for host_sense");
    var scripted = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &cached_pressures,
            .reason = "should not run",
        },
    };
    brain.deps.process_composer = scripted.composer();
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .interaction, .process_goal = "answer_with_host_visual" },
    };
    const context = "memory:\n\nuser_text:\nhi\n\nobservations:\nhost_sense_delivered:\n- note: delivered\n";
    const expanded = try expandProposals(&brain, &proposals, .interaction, context);
    defer chat_mod.freeActionProposals(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(brain.active_process != null);
    try std.testing.expectEqualStrings("answer_with_host_visual", brain.active_process.?.goal);
}

test "expandProposals composes when failed recipe has no failure detail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var cached_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .autonomy, .query = "touch" },
    };
    try process_recipe_memory.recordOutcome(&brain, "investigate_touch", .autonomy, .{
        .action_pressures = &cached_pressures,
        .reason = "failed cache",
        .step_kinds = &.{},
    }, .failed, &.{}, null);
    var scripted = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &cached_pressures,
            .reason = "fresh compose",
        },
    };
    brain.deps.process_composer = scripted.composer();
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .autonomy, .process_goal = "investigate_touch" },
    };
    const expanded = try expandProposals(&brain, &proposals, .autonomy, "context");
    defer chat_mod.freeActionProposals(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
}

test "expandProposals starts autonomy process runtime for multi-step waits" {
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
    var step_kinds = [_]?[]const u8{ "sync_capability", "wait_timer" };
    var scripted = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &composed_pressures,
            .reason = "reflect on touch",
            .step_kinds = &step_kinds,
        },
    };
    brain.deps.process_composer = scripted.composer();
    const proposals = [_]chat_mod.ActionProposal{
        .{ .action = .unknown, .origin = .autonomy, .process_goal = "investigate_touch" },
    };
    const expanded = try expandProposals(&brain, &proposals, .autonomy, "context");
    defer chat_mod.freeActionProposals(allocator, expanded);
    try std.testing.expectEqual(@as(usize, 0), expanded.len);
    try std.testing.expect(brain.active_process != null);
    try std.testing.expectEqualStrings("investigate_touch", brain.active_process.?.goal);
    try std.testing.expect(brain.active_process.?.origin == .autonomy);
}
