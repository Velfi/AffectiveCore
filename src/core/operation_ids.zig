const std = @import("std");
const brain_mod = @import("brain.zig");

const Brain = brain_mod.Brain;

const max_goal_slug_len: usize = 48;

pub fn allocOperationId(self: *Brain, prefix: []const u8) ![]const u8 {
    self.operation_serial += 1;
    return std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ prefix, self.operation_serial });
}

pub fn allocProcessId(self: *Brain, goal: []const u8) ![]const u8 {
    self.operation_serial += 1;
    var slug_buf: [max_goal_slug_len]u8 = undefined;
    const slug = slugifyGoal(&slug_buf, goal);
    return std.fmt.allocPrint(self.allocator, "process_{d}_{s}", .{ self.operation_serial, slug });
}

pub fn allocStepIds(allocator: std.mem.Allocator, process_id: []const u8, step_count: usize) ![]const []const u8 {
    const ids = try allocator.alloc([]const u8, step_count);
    errdefer {
        for (ids[0..step_count]) |id| allocator.free(id);
        allocator.free(ids);
    }
    for (0..step_count) |index| {
        ids[index] = try std.fmt.allocPrint(allocator, "{s}_step_{d}", .{ process_id, index });
    }
    return ids;
}

fn slugifyGoal(dest: []u8, goal: []const u8) []const u8 {
    var len: usize = 0;
    var prev_underscore = false;
    for (goal) |ch| {
        if (len >= dest.len) break;
        const lower = std.ascii.toLower(ch);
        if (std.ascii.isAlphanumeric(lower)) {
            dest[len] = lower;
            len += 1;
            prev_underscore = false;
        } else if (!prev_underscore and len > 0 and len < dest.len) {
            dest[len] = '_';
            len += 1;
            prev_underscore = true;
        }
    }
    while (len > 0 and dest[len - 1] == '_') len -= 1;
    if (len == 0) {
        @memcpy(dest[0..7], "generic");
        return dest[0..7];
    }
    return dest[0..len];
}

test "allocProcessId slugifies goal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const id = try allocProcessId(&brain, "answer_with_host_visual");
    try std.testing.expect(std.mem.startsWith(u8, id, "process_1_answer_with_host_visual"));
}

test "allocStepIds" {
    const process_id = "process_1_answer_with_host_visual";
    const ids = try allocStepIds(std.testing.allocator, process_id, 2);
    defer {
        for (ids) |id| std.testing.allocator.free(id);
        std.testing.allocator.free(ids);
    }
    try std.testing.expectEqualStrings("process_1_answer_with_host_visual_step_0", ids[0]);
    try std.testing.expectEqualStrings("process_1_answer_with_host_visual_step_1", ids[1]);
}
