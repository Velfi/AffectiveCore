const std = @import("std");
const ports = @import("ports.zig");
const chat = ports.chat;
const schema = ports.schema;
const maintenance = @import("maintenance.zig");

pub const Settings = struct {
    autonomy_mode: []const u8,
    limited_threshold_bias: f32,
    full_threshold_bias: f32,
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
    const effort = effortCost(proposal, settings.autonomy_mode);
    if (proposal.origin == .interaction) {
        return .{
            .index = index,
            .proposal = proposal,
            .pressure = pressure,
            .passed = true,
            .effort_cost = effort,
        };
    }
    if (std.mem.eql(u8, settings.autonomy_mode, "off")) {
        return .{
            .index = index,
            .proposal = proposal,
            .pressure = pressure,
            .passed = false,
            .suppressed_reason = "autonomy mode off",
            .effort_cost = effort,
        };
    }
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

fn effortCost(proposal: chat.ActionProposal, autonomy_mode: []const u8) f32 {
    const base = switch (proposal.action) {
        .facial_expression => 0.01,
        .say => speechEffort(proposal.text orelse ""),
        .introspect, .appraise_event, .feel_about, .think_about, .choose_attention, .set_focus, .clear_focus, .begin_subtask, .resume_parent => 0.12,
        .schedule_reminder, .consolidate_memory, .imagine_image => 0.28,
        .send_email => 0.30,
        else => 0.16,
    };
    const origin_scale: f32 = if (proposal.origin == .interaction) 0.80 else 1.0;
    const mode_scale: f32 = if (proposal.origin == .autonomy and std.mem.eql(u8, autonomy_mode, "limited")) 1.10 else 1.0;
    return base * scaleMultiplier(proposal.scale) * origin_scale * mode_scale;
}

fn speechEffort(text: []const u8) f32 {
    const chars: f32 = @floatFromInt(text.len);
    if (chars <= 40.0) return 0.05;
    return 0.10 + @min(chars, 220.0) / 160.0;
}

fn scaleMultiplier(scale: chat.ActionScale) f32 {
    return switch (scale) {
        .full => 1.0,
        .medium => 0.5,
        .tiny => 0.15,
    };
}

fn clamp01(value: f32) f32 {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

test "governor suppresses autonomy when off" {
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
        .control_capacity = 0.7,
        .max_capacity = 0.8,
    }, .{
        .autonomy_mode = "off",
        .limited_threshold_bias = 0.2,
        .full_threshold_bias = 0.0,
        .social_reserve = 0.1,
        .safety_reserve = 0.2,
        .opportunity_reserve = 0.15,
    });
    defer allocator.free(evaluated);
    try std.testing.expect(!evaluated[0].passed);
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
        .control_capacity = -0.05,
        .max_capacity = 0.8,
    }, .{
        .autonomy_mode = "full",
        .limited_threshold_bias = 0.0,
        .full_threshold_bias = 0.0,
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
        .control_capacity = 0.0,
        .max_capacity = 0.8,
    }, .{
        .autonomy_mode = "full",
        .limited_threshold_bias = 0.0,
        .full_threshold_bias = 0.0,
        .social_reserve = 0.1,
        .safety_reserve = 0.2,
        .opportunity_reserve = 0.15,
    });
    defer allocator.free(evaluated);
    try std.testing.expect(!evaluated[0].passed);
    try std.testing.expectEqualStrings("autonomy overdrawn", evaluated[0].suppressed_reason.?);
}
