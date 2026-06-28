const std = @import("std");
const chat = @import("../port_chat.zig");
const schema = @import("../ports.zig").schema;
const autonomy_governor = @import("../autonomy_governor.zig");
const brain_actor = @import("brain_actor.zig");
const payloads = @import("payloads.zig");

pub const ThriftActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink) ThriftActor {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn rankAndCompress(
        self: *const ThriftActor,
        proposals: []const chat.ActionProposal,
        pressures: []const schema.ActionPressure,
        state: @import("../maintenance.zig").AutonomyState,
        settings: autonomy_governor.Settings,
    ) ![]autonomy_governor.Evaluation {
        const evaluated = try autonomy_governor.evaluateBatch(self.allocator, proposals, pressures, state, settings);
        std.mem.sort(autonomy_governor.Evaluation, evaluated, {}, compareEvaluationDesc);
        for (evaluated, 0..) |entry, rank| {
            const proposal_payload = toProposalPayload(entry);
            try self.sink.emitStruct(self.allocator, "proposal.ranked", .{
                .rank = rank,
                .passed = entry.passed,
                .proposal = proposal_payload,
            });
            if (entry.compressed) {
                try self.sink.emitStruct(self.allocator, "proposal.compressed", proposal_payload);
            }
        }
        return evaluated;
    }
};

fn compareEvaluationDesc(_: void, a: autonomy_governor.Evaluation, b: autonomy_governor.Evaluation) bool {
    if (a.passed != b.passed) return a.passed and !b.passed;
    return a.net_value > b.net_value;
}

fn toProposalPayload(evaluation: autonomy_governor.Evaluation) payloads.ProposalEventPayload {
    const body_text = evaluation.proposal.text orelse evaluation.proposal.query orelse evaluation.proposal.name orelse @tagName(evaluation.proposal.action);
    const strength = std.math.clamp(evaluation.pressure.strength, 0.0, 1.0);
    const urgency = std.math.clamp(evaluation.pressure.urgency, 0.0, 1.0);
    const risk = std.math.clamp(evaluation.pressure.risk, 0.0, 1.0);
    return .{
        .proposal_id = evaluation.pressure.pressure_id,
        .kind = @tagName(evaluation.proposal.action),
        .strength = strength,
        .urgency = urgency,
        .expected_value = payloads.expectedValue(strength, urgency, risk),
        .risk = risk,
        .alternatives = .{
            .full = body_text,
            .short = payloads.boundedSlice(body_text, 96),
            .tiny = payloads.boundedSlice(body_text, 32),
            .noop = "noop",
        },
    };
}

