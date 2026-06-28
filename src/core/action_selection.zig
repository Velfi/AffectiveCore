const std = @import("std");
const brain_mod = @import("brain.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;

pub const SubsystemContext = struct {
    source_event_ids: []const []const u8 = &.{},
    focus: ?[]const u8 = null,
};

pub const Subsystem = struct {
    name: []const u8,
    proposeFn: *const fn (*Brain, SubsystemContext) anyerror!?schema.ActionPressure,

    pub fn propose(self: Subsystem, brain: *Brain, context: SubsystemContext) !?schema.ActionPressure {
        return self.proposeFn(brain, context);
    }
};

pub fn proposeActionPressure(
    self: *Brain,
    subsystem: []const u8,
    proposed_action: []const u8,
    capability_id: []const u8,
    rationale: []const u8,
    strength: f32,
    urgency: f32,
    risk: f32,
    parents: []const []const u8,
) !schema.ActionPressure {
    const pressure: schema.ActionPressure = .{
        .pressure_id = try std.fmt.allocPrint(self.allocator, "pressure_{d}_{s}", .{ self.now_seconds * 1000, proposed_action }),
        .subsystem = try self.allocator.dupe(u8, subsystem),
        .proposed_action = try self.allocator.dupe(u8, proposed_action),
        .capability_id = try self.allocator.dupe(u8, capability_id),
        .rationale = try self.allocator.dupe(u8, rationale),
        .strength = strength,
        .urgency = urgency,
        .risk = risk,
        .causal_parent_ids = try cloneParents(self.allocator, parents),
        .created_at_ms = self.now_seconds * 1000,
        .expires_at_ms = (self.now_seconds + 300) * 1000,
    };
    try self.deps.store.addActionPressure(pressure);
    _ = try self.recordSimpleExperienceEvent("ActionPressure.Proposed", .subsystem, pressure.proposed_action);
    return pressure;
}

pub fn selectActionPressure(self: *Brain, pressure: schema.ActionPressure) !schema.ActionOutcome {
    const selected_event = try self.recordSimpleExperienceEvent("ActionSelection.Selected", .subsystem, pressure.proposed_action);
    const outcome: schema.ActionOutcome = .{
        .outcome_id = try std.fmt.allocPrint(self.allocator, "outcome_{d}_{s}", .{ self.now_seconds * 1000, pressure.proposed_action }),
        .pressure_id = pressure.pressure_id,
        .selected_action = pressure.proposed_action,
        .suppressed = false,
        .result_event_id = selected_event.id,
        .prediction_error = 0.0,
        .reinforcement_value = @min(1.0, @max(0.0, pressure.strength - pressure.risk)),
        .created_at_ms = self.now_seconds * 1000,
    };
    try self.deps.store.addActionOutcome(outcome);
    return outcome;
}

pub fn suppressActionPressure(self: *Brain, pressure: schema.ActionPressure, reason: []const u8) !schema.ActionOutcome {
    const suppressed_event = try self.recordSimpleExperienceEvent("ActionSelection.Suppressed", .subsystem, reason);
    const outcome: schema.ActionOutcome = .{
        .outcome_id = try std.fmt.allocPrint(self.allocator, "outcome_suppressed_{d}_{s}", .{ self.now_seconds * 1000, pressure.proposed_action }),
        .pressure_id = pressure.pressure_id,
        .selected_action = pressure.proposed_action,
        .suppressed = true,
        .result_event_id = suppressed_event.id,
        .prediction_error = pressure.urgency,
        .reinforcement_value = -pressure.risk,
        .created_at_ms = self.now_seconds * 1000,
    };
    try self.deps.store.addActionOutcome(outcome);
    return outcome;
}

fn cloneParents(allocator: std.mem.Allocator, parents: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, parents.len);
    for (parents, 0..) |parent, i| out[i] = try allocator.dupe(u8, parent);
    return out;
}
