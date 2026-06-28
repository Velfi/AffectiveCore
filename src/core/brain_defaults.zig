const std = @import("std");
const brain_mod = @import("brain.zig");
const helpers = @import("brain_helpers.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;

const defaults_json = @embedFile("../fixtures/new_brain_defaults.json");

const DefaultsFile = struct {
    wants: []const []const u8,
    goals: []const []const u8,
};

fn parseDefaults(allocator: std.mem.Allocator) !std.json.Parsed(DefaultsFile) {
    return try std.json.parseFromSlice(DefaultsFile, allocator, defaults_json, .{ .allocate = .alloc_always });
}

fn hasSelfDirective(memories: []const schema.MemoryRecord, tag: []const u8) bool {
    for (memories) |memory| {
        if (helpers.tagInSlice(memory.tags, tag)) return true;
    }
    return false;
}

pub fn applyNewBrainDefaults(self: *Brain) !void {
    var parsed = try parseDefaults(self.allocator);
    defer parsed.deinit();

    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    if (!hasSelfDirective(memories, "self_want")) {
        for (parsed.value.wants) |text| {
            const summary = try self.defineSelf(.want, text, &.{});
            self.allocator.free(summary);
        }
    }
    if (!hasSelfDirective(memories, "self_goal")) {
        for (parsed.value.goals) |text| {
            const summary = try self.defineSelf(.goal, text, &.{});
            self.allocator.free(summary);
        }
    }
}

test "new brain defaults json matches expected entries" {
    var parsed = try parseDefaults(std.testing.allocator);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 7), parsed.value.wants.len);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.goals.len);
    try std.testing.expectEqualStrings("Continue existing.", parsed.value.wants[0]);
    try std.testing.expectEqualStrings("Figure out who I am", parsed.value.goals[0]);
}

test "apply new brain defaults is idempotent" {
    const brain_test_store = @import("brain_test_store.zig");
    const brain_test_support = @import("brain_test_support.zig");
    const openai = @import("ports.zig").openai;

    var parsed = try parseDefaults(std.testing.allocator);
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = brain_test_store.TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = brain_test_support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try applyNewBrainDefaults(&brain);
    try applyNewBrainDefaults(&brain);

    try std.testing.expectEqual(parsed.value.wants.len + parsed.value.goals.len, store.memories.items.len);

    var want_count: usize = 0;
    var goal_count: usize = 0;
    for (store.memories.items) |memory| {
        if (helpers.tagInSlice(memory.tags, "self_want")) {
            want_count += 1;
            try std.testing.expect(std.mem.startsWith(u8, memory.interpretation, "self-defined want: "));
        }
        if (helpers.tagInSlice(memory.tags, "self_goal")) {
            goal_count += 1;
            try std.testing.expect(std.mem.startsWith(u8, memory.interpretation, "self-defined goal: "));
        }
    }
    try std.testing.expectEqual(parsed.value.wants.len, want_count);
    try std.testing.expectEqual(parsed.value.goals.len, goal_count);

    const continue_existing = helpers.findMemoryWithTagForTest(store.memories.items, "self_want") orelse return error.MissingDefaultWant;
    try std.testing.expectEqualStrings("Continue existing.", continue_existing.text);

    var found_goal = false;
    for (store.memories.items) |memory| {
        if (std.mem.eql(u8, memory.text, "Figure out who I am") and helpers.tagInSlice(memory.tags, "self_goal")) {
            found_goal = true;
            break;
        }
    }
    try std.testing.expect(found_goal);
}
