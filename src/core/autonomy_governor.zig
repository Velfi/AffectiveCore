const std = @import("std");
const ports = @import("ports.zig");
const chat = ports.chat;
const schema = ports.schema;
const skills = ports.skills;
const maintenance = @import("maintenance.zig");

pub const Settings = struct {
    social_reserve: f32,
    safety_reserve: f32,
    opportunity_reserve: f32,
    quiet_hours_active: bool = false,
};

pub const Evaluation = struct {
    index: usize,
    proposal: chat.ActionProposal,
    pressure: schema.ActionPressure,
    passed: bool,
    suppressed_reason: ?[]const u8 = null,
    compressed: bool = false,
    net_value: f32 = 0.0,
    threshold: f32 = 0.0,
    effort_cost: f32 = 0.0,
};

pub fn evaluateBatch(
    allocator: std.mem.Allocator,
    proposals: []const chat.ActionProposal,
    pressures: []const schema.ActionPressure,
    state: maintenance.AutonomyState,
    settings: Settings,
) ![]Evaluation {
    if (proposals.len != pressures.len) return error.InvalidGovernorBatch;
    var out = try allocator.alloc(Evaluation, proposals.len);
    for (proposals, 0..) |proposal, i| {
        out[i] = try evaluateOne(i, proposal, pressures[i], state, settings);
    }
    return out;
}

pub fn applyExecutedProposal(state: *maintenance.AutonomyState, evaluation: Evaluation) void {
    maintenance.spendCapacity(state, evaluation.effort_cost);
    if (evaluation.proposal.origin == .autonomy and evaluation.proposal.action == .say) {
        state.consecutive_voluntary_speech += 1;
    } else if (evaluation.proposal.origin == .interaction) {
        state.consecutive_voluntary_speech = 0;
    }
    state.social_engagement = clamp01(state.social_engagement * 0.98);
}

fn evaluateOne(
    index: usize,
    proposal: chat.ActionProposal,
    pressure: schema.ActionPressure,
    state: maintenance.AutonomyState,
    settings: Settings,
) !Evaluation {
    _ = settings;
    if (proposal.origin == .interaction) {
        const effort = skills.actionPointCost(proposal.action) catch 0;
        return .{
            .index = index,
            .proposal = proposal,
            .pressure = pressure,
            .passed = true,
            .effort_cost = effort,
        };
    }
    const effort = try effortCost(proposal);
    if (!maintenance.autonomyBudgetAvailable(state)) {
        return .{
            .index = index,
            .proposal = proposal,
            .pressure = pressure,
            .passed = false,
            .suppressed_reason = "autonomy overdrawn",
            .effort_cost = effort,
        };
    }
    return .{
        .index = index,
        .proposal = proposal,
        .pressure = pressure,
        .passed = true,
        .effort_cost = effort,
    };
}

fn effortCost(proposal: chat.ActionProposal) !f32 {
    return skills.actionAutonomyPointCost(proposal.action);
}

fn clamp01(value: f32) f32 {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

test "governor ignores legacy off mode when capacity is available" {
    const allocator = std.testing.allocator;
    const proposals = [_]chat.ActionProposal{.{ .action = .say, .origin = .autonomy, .text = "hello" }};
    const pressures = [_]schema.ActionPressure{.{
        .pressure_id = "p1",
        .subsystem = "LanguageMind",
        .proposed_action = "say",
        .strength = 0.8,
        .urgency = 0.5,
        .risk = 0.1,
        .created_at_ms = 1,
    }};
    const evaluated = try evaluateBatch(allocator, &proposals, &pressures, .{
        .sleeping = false,
        .control_capacity = 40,
        .max_capacity = 50,
    }, .{
        .social_reserve = 0.1,
        .safety_reserve = 0.2,
        .opportunity_reserve = 0.15,
    });
    defer allocator.free(evaluated);
    try std.testing.expect(evaluated[0].passed);
    try std.testing.expectEqual(@as(f32, 3), evaluated[0].effort_cost);
}

test "governor suppresses autonomy when overdrawn" {
    const allocator = std.testing.allocator;
    const proposals = [_]chat.ActionProposal{.{ .action = .say, .origin = .autonomy, .text = "hello" }};
    const pressures = [_]schema.ActionPressure{.{
        .pressure_id = "p1",
        .subsystem = "LanguageMind",
        .proposed_action = "say",
        .strength = 0.8,
        .urgency = 0.5,
        .risk = 0.1,
        .created_at_ms = 1,
    }};
    const evaluated = try evaluateBatch(allocator, &proposals, &pressures, .{
        .sleeping = false,
        .control_capacity = -3,
        .max_capacity = 50,
    }, .{
        .social_reserve = 0.1,
        .safety_reserve = 0.2,
        .opportunity_reserve = 0.15,
    });
    defer allocator.free(evaluated);
    try std.testing.expect(!evaluated[0].passed);
    try std.testing.expectEqualStrings("autonomy overdrawn", evaluated[0].suppressed_reason.?);
}

test "governor suppresses autonomy at zero capacity" {
    const allocator = std.testing.allocator;
    const proposals = [_]chat.ActionProposal{.{ .action = .think_about, .origin = .autonomy, .query = "energy" }};
    const pressures = [_]schema.ActionPressure{.{
        .pressure_id = "p1",
        .subsystem = "LanguageMind",
        .proposed_action = "think_about",
        .strength = 0.8,
        .urgency = 0.5,
        .risk = 0.1,
        .created_at_ms = 1,
    }};
    const evaluated = try evaluateBatch(allocator, &proposals, &pressures, .{
        .sleeping = false,
        .control_capacity = 0,
        .max_capacity = 50,
    }, .{
        .social_reserve = 0.1,
        .safety_reserve = 0.2,
        .opportunity_reserve = 0.15,
    });
    defer allocator.free(evaluated);
    try std.testing.expect(!evaluated[0].passed);
    try std.testing.expectEqual(@as(f32, 1), evaluated[0].effort_cost);
}
