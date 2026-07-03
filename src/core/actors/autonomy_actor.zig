const std = @import("std");
const brain_actor = @import("brain_actor.zig");
const payloads = @import("payloads.zig");

pub const Input = struct {
    proposal: payloads.ProposalEventPayload,
    control_capacity: f32,
    user_override_required: bool = false,
    autonomy_sleeping: bool = false,
};

pub const AutonomyActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink) AutonomyActor {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn decide(self: *const AutonomyActor, input: Input) !payloads.GovernanceDecisionPayload {
        const decision = if (input.autonomy_sleeping)
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .@"defer",
                .reason = "autonomy sleeping",
                .replacement_proposal_id = null,
            }
        else if (input.user_override_required)
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .require_approval,
                .reason = "user approval required",
                .replacement_proposal_id = null,
            }
        else if (input.control_capacity <= 0.0)
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .@"defer",
                .reason = "autonomy overdrawn",
                .replacement_proposal_id = null,
            }
        else if (input.proposal.risk >= 0.85)
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .deny,
                .reason = "risk exceeds autonomy budget",
                .replacement_proposal_id = null,
            }
        else
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .allow,
                .reason = "autonomy budget permits execution",
                .replacement_proposal_id = null,
            };
        try self.sink.emitStruct(self.allocator, "governance.decision", decision);
        return decision;
    }
};
