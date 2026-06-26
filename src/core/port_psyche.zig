const std = @import("std");
const autonomy = @import("port_autonomy.zig");

pub const IdTurn = struct {
    top_need: []const u8,
    urges: []const []const u8,
    random_thoughts: []const []const u8,
    desired_action_bias: []const u8,
    salience: autonomy.Salience,
    reason: []const u8,
};

pub const SuperegoTurn = struct {
    concerns: []const []const u8,
    vetoes: []const []const u8,
    preferred_restraints: []const []const u8,
    values_to_preserve: []const []const u8,
    salience: autonomy.Salience,
    reason: []const u8,
};

pub const PsycheService = struct {
    ctx: *anyopaque,
    idFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!IdTurn,
    superegoFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!SuperegoTurn,

    pub fn consultId(self: PsycheService, allocator: std.mem.Allocator, shared_context: []const u8) !IdTurn {
        return self.idFn(self.ctx, allocator, shared_context);
    }

    pub fn consultSuperego(self: PsycheService, allocator: std.mem.Allocator, shared_context: []const u8) !SuperegoTurn {
        return self.superegoFn(self.ctx, allocator, shared_context);
    }
};

pub const ScriptedPsycheService = struct {
    id_turn: IdTurn,
    superego_turn: SuperegoTurn,
    id_calls: usize = 0,
    superego_calls: usize = 0,
    last_id_context: []const u8 = "",
    last_superego_context: []const u8 = "",

    pub fn service(self: *ScriptedPsycheService) PsycheService {
        return .{ .ctx = self, .idFn = consultId, .superegoFn = consultSuperego };
    }

    fn consultId(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !IdTurn {
        _ = allocator;
        const self: *ScriptedPsycheService = @ptrCast(@alignCast(ctx));
        self.id_calls += 1;
        self.last_id_context = shared_context;
        return self.id_turn;
    }

    fn consultSuperego(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !SuperegoTurn {
        _ = allocator;
        const self: *ScriptedPsycheService = @ptrCast(@alignCast(ctx));
        self.superego_calls += 1;
        self.last_superego_context = shared_context;
        return self.superego_turn;
    }
};

fn joinList(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    if (values.len == 0) return allocator.dupe(u8, "none");
    var out = std.ArrayList(u8).empty;
    for (values, 0..) |value, i| {
        if (i > 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

pub fn formatIdTurn(allocator: std.mem.Allocator, turn: IdTurn) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Id:\n- top_need: {s}\n- urges: {s}\n- random_thoughts: {s}\n- desired_action_bias: {s}\n- salience: {s}\n- reason: {s}\n",
        .{ turn.top_need, try joinList(allocator, turn.urges), try joinList(allocator, turn.random_thoughts), turn.desired_action_bias, @tagName(turn.salience), turn.reason },
    );
}

pub fn formatSuperegoTurn(allocator: std.mem.Allocator, turn: SuperegoTurn) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Superego:\n- concerns: {s}\n- vetoes: {s}\n- preferred_restraints: {s}\n- values_to_preserve: {s}\n- salience: {s}\n- reason: {s}\n",
        .{ try joinList(allocator, turn.concerns), try joinList(allocator, turn.vetoes), try joinList(allocator, turn.preferred_restraints), try joinList(allocator, turn.values_to_preserve), @tagName(turn.salience), turn.reason },
    );
}
