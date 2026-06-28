const std = @import("std");
const chat = @import("port_chat.zig");

pub const Salience = enum {
    low,
    medium,
    high,
};

pub const AutonomyTurn = struct {
    action_pressures: []const chat.ActionProposal = &.{},
    salience: Salience = .medium,
    reason: []const u8 = "",
};

pub const AutonomyPlanner = struct {
    ctx: *anyopaque,
    planFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!AutonomyTurn,

    pub fn plan(self: AutonomyPlanner, allocator: std.mem.Allocator, context: []const u8) !AutonomyTurn {
        return self.planFn(self.ctx, allocator, context);
    }
};

pub const ScriptedAutonomyPlanner = struct {
    turns: []const AutonomyTurn,
    index: usize = 0,
    calls: usize = 0,

    pub fn planner(self: *ScriptedAutonomyPlanner) AutonomyPlanner {
        return .{ .ctx = self, .planFn = plan };
    }

    fn plan(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) !AutonomyTurn {
        const self: *ScriptedAutonomyPlanner = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.index >= self.turns.len) return error.NoScriptedAutonomyTurn;
        const turn = self.turns[self.index];
        self.index += 1;
        return cloneAutonomyTurn(allocator, turn);
    }
};

pub fn cloneAutonomyTurn(allocator: std.mem.Allocator, turn: AutonomyTurn) !AutonomyTurn {
    const action_pressures = try allocator.alloc(chat.ActionProposal, turn.action_pressures.len);
    for (turn.action_pressures, 0..) |proposal, index| {
        action_pressures[index] = try chat.cloneActionProposal(allocator, proposal);
    }
    return .{
        .action_pressures = action_pressures,
        .salience = turn.salience,
        .reason = try allocator.dupe(u8, turn.reason),
    };
}

pub fn freeAutonomyTurn(allocator: std.mem.Allocator, turn: AutonomyTurn) void {
    chat.freeActionProposals(allocator, turn.action_pressures);
    if (turn.reason.len > 0) allocator.free(@constCast(turn.reason));
}
