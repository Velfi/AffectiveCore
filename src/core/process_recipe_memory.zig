const std = @import("std");
const brain_mod = @import("brain.zig");
const chat_mod = @import("port_chat.zig");
const process_goal_mod = @import("port_process_goal.zig");
const process_runtime_mod = @import("process_runtime.zig");
const skill_tree = @import("skill_tree.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const vector_index = @import("vector_index.zig");
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;
const ProcessComposition = process_goal_mod.ProcessComposition;

pub const recipe_tag = "process_recipe";
pub const outcome_success = "success";
pub const outcome_failed = "failed";
pub const outcome_aborted = "aborted";
pub const outcome_draft = "draft";

pub const ProcessOutcome = enum {
    success,
    failed,
    aborted,
    draft,

    pub fn tagName(self: ProcessOutcome) []const u8 {
        return switch (self) {
            .success => outcome_success,
            .failed => outcome_failed,
            .aborted => outcome_aborted,
            .draft => outcome_draft,
        };
    }

    pub fn parse(text: []const u8) ?ProcessOutcome {
        if (std.mem.eql(u8, text, outcome_success)) return .success;
        if (std.mem.eql(u8, text, outcome_failed)) return .failed;
        if (std.mem.eql(u8, text, outcome_aborted)) return .aborted;
        if (std.mem.eql(u8, text, outcome_draft)) return .draft;
        return null;
    }
};

pub const ProcessRecipe = struct {
    goal: []const u8,
    mode: []const u8,
    memory_id: []const u8,
    composition: ProcessComposition,
    outcome: ProcessOutcome,
    success_count: u32,
    failure_count: u32,
    last_outcome_at_seconds: i64,
    last_failure_detail: ?[]const u8 = null,
};

const PressureWire = struct {
    action: []const u8,
    origin: ?[]const u8 = null,
    delay_ms: ?u32 = null,
    scale: ?[]const u8 = null,
    text: ?[]const u8 = null,
    query: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
};

const RecipeWire = struct {
    goal: []const u8,
    mode: []const u8,
    reason: []const u8,
    success_count: u32,
    failure_count: u32,
    last_outcome_at_seconds: i64,
    last_failure_detail: ?[]const u8 = null,
    action_pressures: []PressureWire,
    step_kinds: []?[]const u8,
};

pub fn modeText(mode: process_goal_mod.ComposeMode) []const u8 {
    return switch (mode) {
        .autonomy => "autonomy",
        .interaction => "interaction",
    };
}

pub fn memoryId(allocator: std.mem.Allocator, goal: []const u8, mode: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "process_{s}_{s}", .{ goal, mode });
}

pub fn processGoalTag(allocator: std.mem.Allocator, goal: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "process:{s}", .{goal});
}

fn hasTag(tags: []const []const u8, needle: []const u8) bool {
    for (tags) |tag| {
        if (std.mem.eql(u8, tag, needle)) return true;
    }
    return false;
}

pub fn isProcessRecipeMemory(memory: schema.MemoryRecord) bool {
    return hasTag(memory.tags, recipe_tag) and std.mem.startsWith(u8, memory.memory_id, "process_");
}

pub fn recipeIsProvenWorking(recipe: ProcessRecipe) bool {
    return recipe.outcome == .success and recipe.success_count > 0;
}

pub fn recipeIsRetryCandidate(recipe: ProcessRecipe) bool {
    return (recipe.outcome == .failed or recipe.outcome == .aborted) and recipe.failure_count > 0;
}

pub fn contextSupportsProcessRetry(brain: *Brain, recipe: ProcessRecipe, context: []const u8) bool {
    if (!recipeIsRetryCandidate(recipe)) return false;
    const detail = recipe.last_failure_detail orelse return false;

    if (compositionHasHostPull(recipe.composition) and failureLooksHostRelated(detail)) {
        if (std.mem.indexOf(u8, context, "host_sense_delivered:") != null) return true;
    }

    if (compositionHasTimerWait(recipe.composition) and failureLooksTimerRelated(detail)) {
        if (std.mem.indexOf(u8, context, "timer_fired:") != null) return true;
    }

    if (failureLooksSkillUnavailable(detail)) {
        for (recipe.composition.action_pressures) |pressure| {
            if (!brain.actionIsAvailable(pressure.action)) continue;
            if (detailMentionsAction(detail, pressure.action)) return true;
        }
        if (std.mem.indexOf(u8, detail, "unavailable") != null) {
            for (recipe.composition.action_pressures) |pressure| {
                if (!brain.actionIsAvailable(pressure.action)) return false;
            }
            return recipe.composition.action_pressures.len > 0;
        }
    }

    if (failureLooksTimeout(detail)) {
        if (compositionHasHostPull(recipe.composition) and std.mem.indexOf(u8, context, "host_sense_delivered:") != null) return true;
    }

    if (recipe.outcome == .aborted and std.mem.indexOf(u8, detail, "waiting=host_sense") != null) {
        if (std.mem.indexOf(u8, context, "host_sense_delivered:") != null) return true;
    }

    return false;
}

pub fn lookupRecipe(brain: *Brain, goal: []const u8, mode: process_goal_mod.ComposeMode) !?ProcessRecipe {
    const mode_text = modeText(mode);
    const expected_id = try memoryId(brain.allocator, goal, mode_text);
    defer brain.allocator.free(expected_id);
    const memories = try brain.deps.store.loadMemoryRecords(brain.allocator);
    for (memories) |memory| {
        if (!std.mem.eql(u8, memory.memory_id, expected_id)) continue;
        return try recipeFromMemory(brain.allocator, memory);
    }
    return null;
}

pub fn recipeFromMemory(allocator: std.mem.Allocator, memory: schema.MemoryRecord) !ProcessRecipe {
    const wire = try parseRecipeWire(allocator, memory.interpretation);
    defer freeRecipeWire(allocator, wire);
    const goal = try allocator.dupe(u8, wire.goal);
    errdefer allocator.free(goal);
    const mode = try allocator.dupe(u8, wire.mode);
    errdefer allocator.free(mode);
    const reason = try allocator.dupe(u8, wire.reason);
    errdefer allocator.free(reason);
    const composition = try compositionFromWire(allocator, wire, reason);
    errdefer freeComposition(allocator, composition);
    const outcome = ProcessOutcome.parse(memory.outcome) orelse return error.InvalidProcessRecipeOutcome;
    const last_failure_detail = if (wire.last_failure_detail) |value| try allocator.dupe(u8, value) else null;
    return .{
        .goal = goal,
        .mode = mode,
        .memory_id = try allocator.dupe(u8, memory.memory_id),
        .composition = composition,
        .outcome = outcome,
        .success_count = wire.success_count,
        .failure_count = wire.failure_count,
        .last_outcome_at_seconds = wire.last_outcome_at_seconds,
        .last_failure_detail = last_failure_detail,
    };
}

pub fn freeRecipe(allocator: std.mem.Allocator, recipe: ProcessRecipe) void {
    allocator.free(recipe.goal);
    allocator.free(recipe.mode);
    allocator.free(recipe.memory_id);
    if (recipe.last_failure_detail) |detail| allocator.free(detail);
    freeComposition(allocator, recipe.composition);
}

pub fn deserializeComposition(allocator: std.mem.Allocator, recipe: ProcessRecipe) !ProcessComposition {
    const pressures = try allocator.alloc(chat_mod.ActionProposal, recipe.composition.action_pressures.len);
    errdefer allocator.free(pressures);
    for (recipe.composition.action_pressures, 0..) |source, index| {
        pressures[index] = try chat_mod.cloneActionProposal(allocator, source);
    }
    const reason = try allocator.dupe(u8, recipe.composition.reason);
    errdefer allocator.free(reason);
    const step_kinds = try allocator.alloc(?[]const u8, recipe.composition.step_kinds.len);
    errdefer {
        for (step_kinds) |kind| if (kind) |value| allocator.free(value);
        allocator.free(step_kinds);
    }
    for (recipe.composition.step_kinds, 0..) |kind, index| {
        step_kinds[index] = if (kind) |value| try allocator.dupe(u8, value) else null;
    }
    return .{
        .action_pressures = pressures,
        .reason = reason,
        .step_kinds = step_kinds,
    };
}

pub fn saveDraftRecipe(
    brain: *Brain,
    goal: []const u8,
    mode: process_goal_mod.ComposeMode,
    composition: ProcessComposition,
) !void {
    const mode_text = modeText(mode);
    var success_count: u32 = 0;
    var failure_count: u32 = 0;
    var preserved_failure_detail: ?[]const u8 = null;
    if (try lookupRecipe(brain, goal, mode)) |recipe| {
        success_count = recipe.success_count;
        failure_count = recipe.failure_count;
        if (recipe.last_failure_detail) |detail| preserved_failure_detail = try brain.allocator.dupe(u8, detail);
        freeRecipe(brain.allocator, recipe);
    }
    try upsertRecipeMemory(brain, goal, mode_text, composition, .draft, success_count, failure_count, false, preserved_failure_detail);
}

pub fn recordOutcome(
    brain: *Brain,
    goal: []const u8,
    origin: chat_mod.ActionOrigin,
    composition: ProcessComposition,
    outcome: ProcessOutcome,
    source_event_ids: []const []const u8,
    failure_detail: ?[]const u8,
) !void {
    const mode_text: []const u8 = switch (origin) {
        .interaction => "interaction",
        .autonomy => "autonomy",
    };
    const existing = try lookupRecipe(brain, goal, if (std.mem.eql(u8, mode_text, "autonomy")) .autonomy else .interaction);
    var success_count: u32 = 0;
    var failure_count: u32 = 0;
    if (existing) |recipe| {
        success_count = recipe.success_count;
        failure_count = recipe.failure_count;
        freeRecipe(brain.allocator, recipe);
    }
    switch (outcome) {
        .success => success_count += 1,
        .failed, .aborted => failure_count += 1,
        .draft => {},
    }
    try upsertRecipeMemory(brain, goal, mode_text, composition, outcome, success_count, failure_count, true, failure_detail);
    _ = source_event_ids;
    try @import("learning.zig").recordProcessLearning(brain, goal, mode_text, composition, outcome);
    const interpretation = try std.fmt.allocPrint(
        brain.allocator,
        "process {s} ({s}) {s}",
        .{ goal, mode_text, outcome.tagName() },
    );
    defer brain.allocator.free(interpretation);
    _ = try brain.recordExperienceLogEvent(.{
        .kind = .memory_mutation,
        .source = "brain",
        .title = "process_recipe_outcome",
        .body = interpretation,
        .subject = goal,
        .raw = outcome.tagName(),
        .interpretation = interpretation,
        .experience_source = .brain,
        .experience_kind = .memory_update,
        .experience_retention = .keep_episode,
        .tags = @constCast(&[_][]const u8{"process_outcome"}),
    });
}

fn upsertRecipeMemory(
    brain: *Brain,
    goal: []const u8,
    mode: []const u8,
    composition: ProcessComposition,
    outcome: ProcessOutcome,
    success_count: u32,
    failure_count: u32,
    bump_access: bool,
    failure_detail: ?[]const u8,
) !void {
    const allocator = brain.allocator;
    const id = try memoryId(allocator, goal, mode);
    defer allocator.free(id);
    const memories = try brain.deps.store.loadMemoryRecords(allocator);
    var prior: ?schema.MemoryRecord = null;
    for (memories) |memory| {
        if (std.mem.eql(u8, memory.memory_id, id)) {
            prior = memory;
            break;
        }
    }

    const stored_failure_detail: ?[]const u8 = switch (outcome) {
        .success => null,
        .failed, .aborted, .draft => failure_detail,
    };
    const interpretation_json = try serializeRecipeWire(allocator, .{
        .goal = goal,
        .mode = mode,
        .reason = composition.reason,
        .success_count = success_count,
        .failure_count = failure_count,
        .last_outcome_at_seconds = brain.now_seconds,
        .last_failure_detail = stored_failure_detail,
        .composition = composition,
    });
    defer allocator.free(interpretation_json);

    const summary = try formatRecipeLine(allocator, goal, mode, composition, outcome, success_count);
    defer allocator.free(summary);

    var tags = std.ArrayList([]const u8).empty;
    defer {
        for (tags.items) |tag| allocator.free(tag);
        tags.deinit(allocator);
    }
    try tags.append(allocator, try allocator.dupe(u8, recipe_tag));
    try tags.append(allocator, try processGoalTag(allocator, goal));
    try tags.append(allocator, try allocator.dupe(u8, mode));
    try tags.append(allocator, try std.fmt.allocPrint(allocator, "outcome:{s}", .{outcome.tagName()}));
    for (composition.action_pressures) |pressure| {
        const action_tag = @tagName(pressure.action);
        if (!helpers.tagInSlice(tags.items, action_tag)) {
            try tags.append(allocator, try allocator.dupe(u8, action_tag));
        }
    }

    const now = try brain.timestampNow();
    const owned_summary = try allocator.dupe(u8, summary);
    errdefer allocator.free(owned_summary);
    const owned_interpretation = try allocator.dupe(u8, interpretation_json);
    errdefer allocator.free(owned_interpretation);
    const vector = try vector_index.embedQuery(allocator, brain.deps.embedding_service, owned_summary, tags.items);
    const memory = schema.MemoryRecord{
        .memory_id = try allocator.dupe(u8, id),
        .scope = .long_term,
        .internal_synthesis = true,
        .text = owned_summary,
        .original_text = try allocator.dupe(u8, owned_summary),
        .interpretation = owned_interpretation,
        .outcome = try allocator.dupe(u8, outcome.tagName()),
        .vector = vector,
        .confidence = if (outcome == .success and success_count > 0) @min(0.95, 0.70 + @as(f32, @floatFromInt(success_count)) * 0.05) else 0.55,
        .salience = if (outcome == .success and success_count > 0) 0.55 else 0.35,
        .tags = try tags.toOwnedSlice(allocator),
        .revisions = &.{},
        .created_at = if (prior) |existing| existing.created_at else now,
        .last_accessed_at = now,
        .access_count = if (prior) |existing| existing.access_count + if (bump_access) @as(u32, 1) else 0 else if (bump_access) 1 else 0,
        .score = if (prior) |existing| existing.score + @as(i32, @intCast(success_count)) else @as(i32, @intCast(success_count + 1)),
    };
    try brain.deps.store.saveMemoryRecord(memory);
}

pub fn compositionFromActiveProcess(
    allocator: std.mem.Allocator,
    process: process_runtime_mod.ActiveProcess,
) !ProcessComposition {
    const pressures = try allocator.alloc(chat_mod.ActionProposal, process.steps.len);
    errdefer allocator.free(pressures);
    const step_kinds = try allocator.alloc(?[]const u8, process.steps.len);
    errdefer {
        for (step_kinds) |kind| if (kind) |value| allocator.free(value);
        allocator.free(step_kinds);
    }
    for (process.steps, 0..) |step, index| {
        pressures[index] = .{
            .action = step.action,
            .origin = process.origin,
            .text = if (step.respond_text) |text| try allocator.dupe(u8, text) else if (step.timer_intent) |intent| try allocator.dupe(u8, intent) else null,
        };
        step_kinds[index] = try allocator.dupe(u8, @tagName(step.kind));
    }
    const reason = if (process.composition_reason) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, process.goal);
    return .{
        .action_pressures = pressures,
        .reason = reason,
        .step_kinds = step_kinds,
    };
}

pub fn topWorkingRecipes(brain: *Brain, limit: usize) ![]ProcessRecipe {
    const memories = try brain.deps.store.loadMemoryRecords(brain.allocator);
    var out = std.ArrayList(ProcessRecipe).empty;
    errdefer {
        for (out.items) |recipe| freeRecipe(brain.allocator, recipe);
        out.deinit(brain.allocator);
    }
    for (memories) |memory| {
        if (!isProcessRecipeMemory(memory)) continue;
        if (!std.mem.eql(u8, memory.outcome, outcome_success)) continue;
        const recipe = try recipeFromMemory(brain.allocator, memory);
        if (!recipeIsProvenWorking(recipe)) {
            freeRecipe(brain.allocator, recipe);
            continue;
        }
        try out.append(brain.allocator, recipe);
    }
    std.mem.sort(ProcessRecipe, out.items, {}, recipeSortLess);
    if (out.items.len > limit) {
        for (out.items[limit..]) |recipe| freeRecipe(brain.allocator, recipe);
        const trimmed = try brain.allocator.realloc(out.items, limit);
        out.items = trimmed;
    }
    return out.toOwnedSlice(brain.allocator);
}

fn recipeSortLess(_: void, a: ProcessRecipe, b: ProcessRecipe) bool {
    if (a.success_count != b.success_count) return a.success_count > b.success_count;
    return a.last_outcome_at_seconds > b.last_outcome_at_seconds;
}

pub fn recipesForSkill(brain: *Brain, skill: skill_tree.SkillId, limit: usize) ![]ProcessRecipe {
    const skill_name = @tagName(skill);
    const memories = try brain.deps.store.loadMemoryRecords(brain.allocator);
    var out = std.ArrayList(ProcessRecipe).empty;
    errdefer {
        for (out.items) |recipe| freeRecipe(brain.allocator, recipe);
        out.deinit(brain.allocator);
    }
    for (memories) |memory| {
        if (!isProcessRecipeMemory(memory)) continue;
        if (!std.mem.eql(u8, memory.outcome, outcome_success)) continue;
        if (!hasTag(memory.tags, skill_name)) continue;
        const recipe = try recipeFromMemory(brain.allocator, memory);
        if (!recipeIsProvenWorking(recipe)) {
            freeRecipe(brain.allocator, recipe);
            continue;
        }
        try out.append(brain.allocator, recipe);
        if (out.items.len >= limit) break;
    }
    return out.toOwnedSlice(brain.allocator);
}

pub fn recipesForGroup(brain: *Brain, group: skill_tree.SkillGroup, limit: usize) ![]ProcessRecipe {
    const memories = try brain.deps.store.loadMemoryRecords(brain.allocator);
    var out = std.ArrayList(ProcessRecipe).empty;
    errdefer {
        for (out.items) |recipe| freeRecipe(brain.allocator, recipe);
        out.deinit(brain.allocator);
    }
    for (memories) |memory| {
        if (!isProcessRecipeMemory(memory)) continue;
        if (!std.mem.eql(u8, memory.outcome, outcome_success)) continue;
        var matched = false;
        for (memory.tags) |tag| {
            if (skill_tree.parseSkillName(tag)) |skill| {
                if (skill_tree.groupFor(skill) == group) {
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) continue;
        const recipe = try recipeFromMemory(brain.allocator, memory);
        if (!recipeIsProvenWorking(recipe)) {
            freeRecipe(brain.allocator, recipe);
            continue;
        }
        try out.append(brain.allocator, recipe);
        if (out.items.len >= limit) break;
    }
    return out.toOwnedSlice(brain.allocator);
}

pub fn appendRelatedProcessesHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "related_processes (known working):\n");
}

pub fn appendRecipeLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), recipe: ProcessRecipe) !void {
    const chain = try chainSummary(allocator, recipe.composition);
    defer allocator.free(chain);
    try out.print(allocator, "- {s} ({s}, success x{d}): {s}\n", .{
        recipe.goal,
        recipe.mode,
        recipe.success_count,
        chain,
    });
}

pub fn appendKnownWorkingProcessesBlock(brain: *Brain, out: *std.ArrayList(u8)) !void {
    const recipes = try topWorkingRecipes(brain, 5);
    defer {
        for (recipes) |recipe| freeRecipe(brain.allocator, recipe);
        brain.allocator.free(recipes);
    }
    if (recipes.len == 0) return;
    try out.appendSlice(brain.allocator, "known_working_processes:\n");
    for (recipes) |recipe| try appendRecipeLine(brain.allocator, out, recipe);
}

pub fn appendKnownProcessesMemoryBlock(brain: *Brain, out: *std.ArrayList(u8)) !void {
    const recipes = try topWorkingRecipes(brain, 5);
    defer {
        for (recipes) |recipe| freeRecipe(brain.allocator, recipe);
        brain.allocator.free(recipes);
    }
    if (recipes.len == 0) {
        try out.appendSlice(brain.allocator, "known_processes:\n- none yet\n");
        return;
    }
    try out.appendSlice(brain.allocator, "known_processes:\n");
    for (recipes) |recipe| try appendRecipeLine(brain.allocator, out, recipe);
}

fn formatRecipeLine(
    allocator: std.mem.Allocator,
    goal: []const u8,
    mode: []const u8,
    composition: ProcessComposition,
    outcome: ProcessOutcome,
    success_count: u32,
) ![]const u8 {
    const chain = try chainSummary(allocator, composition);
    defer allocator.free(chain);
    if (outcome == .success and success_count > 0) {
        return std.fmt.allocPrint(allocator, "Process {s} ({s}): {s}; succeeded {d}×", .{ goal, mode, chain, success_count });
    }
    return std.fmt.allocPrint(allocator, "Process {s} ({s}): {s}; last {s}", .{ goal, mode, chain, outcome.tagName() });
}

fn chainSummary(allocator: std.mem.Allocator, composition: ProcessComposition) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (composition.action_pressures, 0..) |pressure, index| {
        if (index > 0) try out.appendSlice(allocator, " → ");
        try out.appendSlice(allocator, @tagName(pressure.action));
    }
    return out.toOwnedSlice(allocator);
}

fn serializeRecipeWire(allocator: std.mem.Allocator, input: struct {
    goal: []const u8,
    mode: []const u8,
    reason: []const u8,
    success_count: u32,
    failure_count: u32,
    last_outcome_at_seconds: i64,
    last_failure_detail: ?[]const u8 = null,
    composition: ProcessComposition,
}) ![]const u8 {
    var pressures = std.ArrayList(PressureWire).empty;
    defer pressures.deinit(allocator);
    for (input.composition.action_pressures) |pressure| {
        try pressures.append(allocator, .{
            .action = @tagName(pressure.action),
            .origin = @tagName(pressure.origin),
            .delay_ms = pressure.delay_ms,
            .scale = @tagName(pressure.scale),
            .text = pressure.text,
            .query = pressure.query,
            .tags = pressure.tags,
        });
    }
    const wire = RecipeWire{
        .goal = input.goal,
        .mode = input.mode,
        .reason = input.reason,
        .success_count = input.success_count,
        .failure_count = input.failure_count,
        .last_outcome_at_seconds = input.last_outcome_at_seconds,
        .last_failure_detail = input.last_failure_detail,
        .action_pressures = pressures.items,
        .step_kinds = input.composition.step_kinds,
    };
    return std.json.Stringify.valueAlloc(allocator, wire, .{});
}

fn parseRecipeWire(allocator: std.mem.Allocator, body: []const u8) !RecipeWire {
    var parsed = try std.json.parseFromSlice(RecipeWire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return try cloneRecipeWire(allocator, parsed.value);
}

fn cloneRecipeWire(allocator: std.mem.Allocator, wire: RecipeWire) !RecipeWire {
    var pressures = try allocator.alloc(PressureWire, wire.action_pressures.len);
    errdefer allocator.free(pressures);
    for (wire.action_pressures, 0..) |pressure, index| {
        var tags = try allocator.alloc([]const u8, pressure.tags.len);
        errdefer allocator.free(tags);
        for (pressure.tags, 0..) |tag, tag_index| tags[tag_index] = try allocator.dupe(u8, tag);
        pressures[index] = .{
            .action = try allocator.dupe(u8, pressure.action),
            .origin = if (pressure.origin) |origin| try allocator.dupe(u8, origin) else null,
            .delay_ms = pressure.delay_ms,
            .scale = if (pressure.scale) |scale| try allocator.dupe(u8, scale) else null,
            .text = if (pressure.text) |text| try allocator.dupe(u8, text) else null,
            .query = if (pressure.query) |query| try allocator.dupe(u8, query) else null,
            .tags = tags,
        };
    }
    const step_kinds = try allocator.alloc(?[]const u8, wire.step_kinds.len);
    errdefer {
        for (step_kinds) |kind| if (kind) |value| allocator.free(value);
        allocator.free(step_kinds);
    }
    for (wire.step_kinds, 0..) |kind, index| {
        step_kinds[index] = if (kind) |value| try allocator.dupe(u8, value) else null;
    }
    return .{
        .goal = try allocator.dupe(u8, wire.goal),
        .mode = try allocator.dupe(u8, wire.mode),
        .reason = try allocator.dupe(u8, wire.reason),
        .success_count = wire.success_count,
        .failure_count = wire.failure_count,
        .last_outcome_at_seconds = wire.last_outcome_at_seconds,
        .last_failure_detail = if (wire.last_failure_detail) |detail| try allocator.dupe(u8, detail) else null,
        .action_pressures = pressures,
        .step_kinds = step_kinds,
    };
}

fn freeRecipeWire(allocator: std.mem.Allocator, wire: RecipeWire) void {
    allocator.free(wire.goal);
    allocator.free(wire.mode);
    allocator.free(wire.reason);
    if (wire.last_failure_detail) |detail| allocator.free(detail);
    for (wire.action_pressures) |pressure| {
        if (pressure.text) |text| allocator.free(text);
        if (pressure.query) |query| allocator.free(query);
        for (pressure.tags) |tag| allocator.free(tag);
    }
    if (wire.action_pressures.len > 0) allocator.free(wire.action_pressures);
    for (wire.step_kinds) |kind| if (kind) |value| allocator.free(value);
    if (wire.step_kinds.len > 0) allocator.free(wire.step_kinds);
}

fn compositionFromWire(allocator: std.mem.Allocator, wire: RecipeWire, reason: []const u8) !ProcessComposition {
    const pressures = try allocator.alloc(chat_mod.ActionProposal, wire.action_pressures.len);
    errdefer allocator.free(pressures);
    for (wire.action_pressures, 0..) |pressure, index| {
        const action = std.meta.stringToEnum(chat_mod.ActionProposalType, pressure.action) orelse return error.InvalidProcessRecipeAction;
        const origin = if (pressure.origin) |origin_text|
            std.meta.stringToEnum(chat_mod.ActionOrigin, origin_text) orelse return error.InvalidProcessRecipeOrigin
        else
            chat_mod.ActionOrigin.interaction;
        const scale = if (pressure.scale) |scale_text|
            std.meta.stringToEnum(chat_mod.ActionScale, scale_text) orelse return error.InvalidProcessRecipeScale
        else
            chat_mod.ActionScale.full;
        var tags = try allocator.alloc([]const u8, pressure.tags.len);
        for (pressure.tags, 0..) |tag, tag_index| tags[tag_index] = try allocator.dupe(u8, tag);
        pressures[index] = .{
            .action = action,
            .origin = origin,
            .delay_ms = pressure.delay_ms,
            .scale = scale,
            .text = if (pressure.text) |text| try allocator.dupe(u8, text) else null,
            .query = if (pressure.query) |query| try allocator.dupe(u8, query) else null,
            .tags = tags,
        };
    }
    const step_kinds = try allocator.alloc(?[]const u8, wire.step_kinds.len);
    for (wire.step_kinds, 0..) |kind, index| {
        step_kinds[index] = if (kind) |value| try allocator.dupe(u8, value) else null;
    }
    return .{
        .action_pressures = pressures,
        .reason = reason,
        .step_kinds = step_kinds,
    };
}

pub fn freeCompositionMemory(allocator: std.mem.Allocator, composition: ProcessComposition) void {
    freeComposition(allocator, composition);
}

fn freeComposition(allocator: std.mem.Allocator, composition: ProcessComposition) void {
    chat_mod.freeActionProposals(allocator, composition.action_pressures);
    for (composition.step_kinds) |kind| if (kind) |value| allocator.free(value);
    if (composition.step_kinds.len > 0) allocator.free(composition.step_kinds);
    allocator.free(composition.reason);
}

fn failureLooksHostRelated(detail: []const u8) bool {
    return std.mem.indexOf(u8, detail, "host_sense") != null or
        std.mem.indexOf(u8, detail, "async_host_pull") != null or
        std.mem.indexOf(u8, detail, "awaiting host") != null or
        std.mem.indexOf(u8, detail, "waiting_for=host") != null;
}

fn failureLooksTimerRelated(detail: []const u8) bool {
    return std.mem.indexOf(u8, detail, "timer") != null or
        std.mem.indexOf(u8, detail, "wait_timer") != null;
}

fn failureLooksTimeout(detail: []const u8) bool {
    return std.mem.indexOf(u8, detail, "timeout") != null or
        std.mem.indexOf(u8, detail, "timed out") != null;
}

fn failureLooksSkillUnavailable(detail: []const u8) bool {
    return std.mem.indexOf(u8, detail, "unavailable") != null;
}

fn detailMentionsAction(detail: []const u8, action: chat_mod.ActionProposalType) bool {
    return std.mem.indexOf(u8, detail, @tagName(action)) != null;
}

fn compositionHasHostPull(composition: ProcessComposition) bool {
    for (composition.step_kinds) |kind| {
        if (kind) |text| if (std.mem.eql(u8, text, "async_host_pull")) return true;
    }
    for (composition.action_pressures) |pressure| {
        switch (pressure.action) {
            .recognize, .take_picture, .describe_image, .request_orientation => return true,
            else => {},
        }
    }
    return false;
}

fn compositionHasTimerWait(composition: ProcessComposition) bool {
    for (composition.step_kinds) |kind| {
        if (kind) |text| if (std.mem.eql(u8, text, "wait_timer")) return true;
    }
    for (composition.action_pressures) |pressure| {
        if (pressure.action == .schedule_reminder) return true;
    }
    return false;
}

pub fn compositionNeedsProcessRuntime(composition: ProcessComposition) bool {
    for (composition.step_kinds) |kind| {
        if (kind) |text| {
            if (std.mem.eql(u8, text, "async_host_pull") or
                std.mem.eql(u8, text, "wait_timer") or
                std.mem.eql(u8, text, "wait_stimulus"))
                return true;
        }
    }
    for (composition.action_pressures) |pressure| {
        switch (pressure.action) {
            .recognize, .take_picture, .describe_image, .schedule_reminder => return true,
            else => {},
        }
    }
    return false;
}

test "memory id is stable per goal and mode" {
    const id = try memoryId(std.testing.allocator, "investigate_touch", "autonomy");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("process_investigate_touch_autonomy", id);
}

test "process recipe memory round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .autonomy, .query = "touch" },
        .{ .action = .think_about, .origin = .autonomy, .query = "touch meaning" },
    };
    const composition = ProcessComposition{
        .action_pressures = &pressures,
        .reason = "reflect on touch",
        .step_kinds = &.{},
    };
    try recordOutcome(&brain, "investigate_touch", .autonomy, composition, .success, &.{}, null);
    const memories = try store.store().loadMemoryRecords(allocator);
    try std.testing.expect(memories.len > 0);
    const loaded = try lookupRecipe(&brain, "investigate_touch", .autonomy);
    defer if (loaded) |recipe| freeRecipe(allocator, recipe);
    try std.testing.expect(loaded != null);
    try std.testing.expectEqual(@as(u32, 1), loaded.?.success_count);
    try std.testing.expectEqualStrings("success", loaded.?.outcome.tagName());
}

test "topWorkingRecipes returns successful recipes only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var success_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .recognize, .origin = .interaction },
    };
    var failed_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .say, .origin = .interaction, .text = "oops" },
    };
    try recordOutcome(&brain, "answer_with_host_visual", .interaction, .{
        .action_pressures = &success_pressures,
        .reason = "recognize then say",
        .step_kinds = &.{},
    }, .success, &.{}, null);
    try recordOutcome(&brain, "broken_flow", .interaction, .{
        .action_pressures = &failed_pressures,
        .reason = "failed attempt",
        .step_kinds = &.{},
    }, .failed, &.{}, "host_sense delivery timed out");
    const recipes = try topWorkingRecipes(&brain, 10);
    defer {
        for (recipes) |recipe| freeRecipe(allocator, recipe);
        allocator.free(recipes);
    }
    try std.testing.expectEqual(@as(usize, 1), recipes.len);
    try std.testing.expectEqualStrings("answer_with_host_visual", recipes[0].goal);
}

test "failed recipe stores and clears failure detail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pressures = [_]chat_mod.ActionProposal{
        .{ .action = .recognize, .origin = .interaction },
        .{ .action = .say, .origin = .interaction, .text = "hello" },
    };
    const composition = ProcessComposition{
        .action_pressures = &pressures,
        .reason = "recognize then greet",
        .step_kinds = &.{},
    };
    try recordOutcome(&brain, "answer_with_host_visual", .interaction, composition, .failed, &.{}, "process timeout elapsed waiting for host_sense");
    const failed = try lookupRecipe(&brain, "answer_with_host_visual", .interaction);
    defer if (failed) |recipe| freeRecipe(allocator, recipe);
    try std.testing.expect(failed != null);
    try std.testing.expectEqualStrings("process timeout elapsed waiting for host_sense", failed.?.last_failure_detail.?);

    try recordOutcome(&brain, "answer_with_host_visual", .interaction, composition, .success, &.{}, null);
    const succeeded = try lookupRecipe(&brain, "answer_with_host_visual", .interaction);
    defer if (succeeded) |recipe| freeRecipe(allocator, recipe);
    try std.testing.expect(succeeded != null);
    try std.testing.expect(succeeded.?.last_failure_detail == null);
}

test "contextSupportsProcessRetry after host delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pressures = [_]chat_mod.ActionProposal{
        .{ .action = .recognize, .origin = .interaction },
    };
    const composition = ProcessComposition{
        .action_pressures = &pressures,
        .reason = "recognize visitor",
        .step_kinds = &.{},
    };
    try recordOutcome(&brain, "answer_with_host_visual", .interaction, composition, .failed, &.{}, "process timeout elapsed waiting for host_sense");
    const loaded = try lookupRecipe(&brain, "answer_with_host_visual", .interaction);
    defer if (loaded) |recipe| freeRecipe(allocator, recipe);
    const recipe = loaded.?;
    try std.testing.expect(!contextSupportsProcessRetry(&brain, recipe, "observations:\nwaiting\n"));
    try std.testing.expect(contextSupportsProcessRetry(&brain, recipe, "observations:\nhost_sense_delivered:\n- note: delivered\n"));
}

test "contextSupportsProcessRetry does not retry on elapsed time alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pressures = [_]chat_mod.ActionProposal{
        .{ .action = .recognize, .origin = .interaction },
    };
    const composition = ProcessComposition{
        .action_pressures = &pressures,
        .reason = "recognize visitor",
        .step_kinds = &.{},
    };
    try recordOutcome(&brain, "answer_with_host_visual", .interaction, composition, .failed, &.{}, "process timeout elapsed");
    const loaded = try lookupRecipe(&brain, "answer_with_host_visual", .interaction);
    defer if (loaded) |recipe| freeRecipe(allocator, recipe);
    const recipe = loaded.?;
    brain.now_seconds = recipe.last_outcome_at_seconds + 120;
    try std.testing.expect(!contextSupportsProcessRetry(&brain, recipe, "observations:\nquiet\n"));
}
