const std = @import("std");
const autonomy = @import("port_autonomy.zig");
const llm_voice = @import("llm_voice.zig");

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

pub const PsycheTurns = struct {
    id: IdTurn,
    superego: SuperegoTurn,
};

pub const PsycheService = struct {
    ctx: *anyopaque,
    idFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!IdTurn,
    superegoFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!SuperegoTurn,
    consultBothFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!PsycheTurns,

    pub fn consultId(self: PsycheService, allocator: std.mem.Allocator, shared_context: []const u8) !IdTurn {
        return self.idFn(self.ctx, allocator, shared_context);
    }

    pub fn consultSuperego(self: PsycheService, allocator: std.mem.Allocator, shared_context: []const u8) !SuperegoTurn {
        return self.superegoFn(self.ctx, allocator, shared_context);
    }

    pub fn consultBoth(self: PsycheService, allocator: std.mem.Allocator, shared_context: []const u8) !PsycheTurns {
        return self.consultBothFn(self.ctx, allocator, shared_context);
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
        return .{ .ctx = self, .idFn = consultId, .superegoFn = consultSuperego, .consultBothFn = consultBoth };
    }

    fn consultId(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !IdTurn {
        const self: *ScriptedPsycheService = @ptrCast(@alignCast(ctx));
        self.id_calls += 1;
        if (self.last_id_context.len > 0) allocator.free(self.last_id_context);
        self.last_id_context = try allocator.dupe(u8, shared_context);
        return self.id_turn;
    }

    fn consultSuperego(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !SuperegoTurn {
        const self: *ScriptedPsycheService = @ptrCast(@alignCast(ctx));
        self.superego_calls += 1;
        if (self.last_superego_context.len > 0) allocator.free(self.last_superego_context);
        self.last_superego_context = try allocator.dupe(u8, shared_context);
        return self.superego_turn;
    }

    fn consultBoth(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !PsycheTurns {
        return .{
            .id = try consultId(ctx, allocator, shared_context),
            .superego = try consultSuperego(ctx, allocator, shared_context),
        };
    }
};

fn joinList(allocator: std.mem.Allocator, values: []const []const u8, empty_phrase: []const u8) ![]const u8 {
    if (values.len == 0) return allocator.dupe(u8, empty_phrase);
    var out = std.ArrayList(u8).empty;
    for (values, 0..) |value, i| {
        if (i > 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

pub fn formatIdTurn(allocator: std.mem.Allocator, turn: IdTurn) ![]const u8 {
    const urges = try joinList(allocator, turn.urges, llm_voice.empty_inner_state);
    defer allocator.free(urges);
    const thoughts = try joinList(allocator, turn.random_thoughts, llm_voice.empty_inner_state);
    defer allocator.free(thoughts);
    return std.fmt.allocPrint(
        allocator,
        "Id:\n- What pulls at me most: {s}\n- Urges I feel: {s}\n- Random thoughts drifting through: {s}\n- I lean toward: {s}\n- This feels {s} to me right now\n- Because: {s}\n",
        .{ turn.top_need, urges, thoughts, turn.desired_action_bias, @tagName(turn.salience), turn.reason },
    );
}

pub fn formatSuperegoTurn(allocator: std.mem.Allocator, turn: SuperegoTurn) ![]const u8 {
    const concerns = try joinList(allocator, turn.concerns, llm_voice.empty_inner_state);
    defer allocator.free(concerns);
    const vetoes = try joinList(allocator, turn.vetoes, llm_voice.empty_inner_state);
    defer allocator.free(vetoes);
    const restraints = try joinList(allocator, turn.preferred_restraints, llm_voice.empty_inner_state);
    defer allocator.free(restraints);
    const values = try joinList(allocator, turn.values_to_preserve, llm_voice.empty_inner_state);
    defer allocator.free(values);
    return std.fmt.allocPrint(
        allocator,
        "Superego:\n- What worries me: {s}\n- What I refuse to do: {s}\n- Restraints I prefer: {s}\n- Values I want to preserve: {s}\n- This feels {s} to me right now\n- Because: {s}\n",
        .{ concerns, vetoes, restraints, values, @tagName(turn.salience), turn.reason },
    );
}
