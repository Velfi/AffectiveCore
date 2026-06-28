const std = @import("std");
const chat = @import("port_chat.zig");

pub const max_composed_steps: usize = 5;

pub fn isForbiddenAutonomyAction(action: chat.ActionProposalType) bool {
    return action == .take_picture or action == .describe_image or action == .compare_images or action == .recognize or action == .unknown;
}

pub const ComposeMode = enum {
    autonomy,
    interaction,
};

pub const ProcessComposition = struct {
    action_pressures: []chat.ActionProposal,
    reason: []const u8,
};

pub const ProcessComposer = struct {
    ctx: *anyopaque,
    composeFn: *const fn (*anyopaque, std.mem.Allocator, goal: []const u8, context: []const u8, mode: ComposeMode) anyerror!ProcessComposition,

    pub fn compose(self: ProcessComposer, allocator: std.mem.Allocator, goal: []const u8, context: []const u8, mode: ComposeMode) !ProcessComposition {
        return self.composeFn(self.ctx, allocator, goal, context, mode);
    }
};

pub const ScriptedProcessComposer = struct {
    composition: ProcessComposition,
    fail: ?anyerror = null,
    calls: usize = 0,
    last_goal: []const u8 = "",
    last_mode: ?ComposeMode = null,

    pub fn composer(self: *ScriptedProcessComposer) ProcessComposer {
        return .{ .ctx = self, .composeFn = compose };
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
        return .{
            .action_pressures = action_pressures,
            .reason = reason,
        };
    }
};
