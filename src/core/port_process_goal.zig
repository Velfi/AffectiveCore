const std = @import("std");
const chat = @import("port_chat.zig");

pub fn isForbiddenAutonomyAction(action: chat.ActionProposalType, autonomy_mode: []const u8) bool {
    if (action == .unknown) return true;
    return !@import("port_skills.zig").autonomyAllowed(action, autonomy_mode);
}

pub const ComposeMode = enum {
    autonomy,
    interaction,
};

pub const ProcessComposition = struct {
    action_pressures: []chat.ActionProposal,
    reason: []const u8,
    /// Optional parallel step kinds from the planner (`sync_capability`, `async_host_pull`, etc.).
    step_kinds: []?[]const u8 = &.{},
};

pub const ComposeBatchItem = struct {
    goal: []const u8,
    context: []const u8,
    mode: ComposeMode,
};

pub const ProcessComposer = struct {
    ctx: *anyopaque,
    composeFn: *const fn (*anyopaque, std.mem.Allocator, goal: []const u8, context: []const u8, mode: ComposeMode) anyerror!ProcessComposition,
    composeBatchFn: ?*const fn (*anyopaque, std.mem.Allocator, items: []const ComposeBatchItem) anyerror![]ProcessComposition = null,

    pub fn compose(self: ProcessComposer, allocator: std.mem.Allocator, goal: []const u8, context: []const u8, mode: ComposeMode) !ProcessComposition {
        return self.composeFn(self.ctx, allocator, goal, context, mode);
    }

    pub fn composeBatch(self: ProcessComposer, allocator: std.mem.Allocator, items: []const ComposeBatchItem) ![]ProcessComposition {
        const batch_fn = self.composeBatchFn orelse return error.MissingProcessComposeBatch;
        return batch_fn(self.ctx, allocator, items);
    }
};

pub const ScriptedProcessComposer = struct {
    composition: ProcessComposition,
    fail: ?anyerror = null,
    calls: usize = 0,
    batch_calls: usize = 0,
    last_goal: []const u8 = "",
    last_mode: ?ComposeMode = null,

    pub fn composer(self: *ScriptedProcessComposer) ProcessComposer {
        return .{ .ctx = self, .composeFn = compose, .composeBatchFn = composeBatch };
    }

    fn compose(ctx: *anyopaque, allocator: std.mem.Allocator, goal: []const u8, context: []const u8, mode: ComposeMode) !ProcessComposition {
        _ = context;
        const self: *ScriptedProcessComposer = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_goal = try allocator.dupe(u8, goal);
        self.last_mode = mode;
        if (self.fail) |err| return err;
        const action_pressures = try allocator.alloc(chat.ActionProposal, self.composition.action_pressures.len);
        var initialized: usize = 0;
        errdefer {
            for (action_pressures[0..initialized]) |proposal| chat.freeActionProposal(allocator, proposal);
            allocator.free(action_pressures);
        }
        for (self.composition.action_pressures, 0..) |source, index| {
            action_pressures[index] = try chat.cloneActionProposal(allocator, source);
            initialized = index + 1;
        }
        const reason = try allocator.dupe(u8, self.composition.reason);
        errdefer allocator.free(reason);
        const step_kinds = try allocator.alloc(?[]const u8, self.composition.step_kinds.len);
        errdefer {
            for (step_kinds) |kind| if (kind) |value| allocator.free(value);
            allocator.free(step_kinds);
        }
        for (self.composition.step_kinds, 0..) |kind, index| {
            step_kinds[index] = if (kind) |value| try allocator.dupe(u8, value) else null;
        }
        return .{
            .action_pressures = action_pressures,
            .reason = reason,
            .step_kinds = step_kinds,
        };
    }

    fn composeBatch(ctx: *anyopaque, allocator: std.mem.Allocator, items: []const ComposeBatchItem) ![]ProcessComposition {
        const self: *ScriptedProcessComposer = @ptrCast(@alignCast(ctx));
        self.batch_calls += 1;
        const out = try allocator.alloc(ProcessComposition, items.len);
        errdefer allocator.free(out);
        for (items, 0..) |item, index| {
            out[index] = try compose(ctx, allocator, item.goal, item.context, item.mode);
        }
        return out;
    }
};
