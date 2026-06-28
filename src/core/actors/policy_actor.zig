const std = @import("std");
const brain_actor = @import("brain_actor.zig");
const payloads = @import("payloads.zig");

pub const Input = struct {
    proposal: payloads.ProposalEventPayload,
    host_allows: bool = true,
    safety_blocked: bool = false,
    privacy_blocked: bool = false,
    identity_trust: ?f32 = null,
    min_identity_trust: f32 = 0.45,
    replacement_proposal_id: ?[]const u8 = null,
};

pub const PolicyActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink) PolicyActor {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn decide(self: *const PolicyActor, input: Input) !payloads.GovernanceDecisionPayload {
        const decision = if (!input.host_allows)
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .deny,
                .reason = "host constraint denied capability",
                .replacement_proposal_id = input.replacement_proposal_id,
            }
        else if (input.safety_blocked)
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .deny,
                .reason = "hard safety policy blocked action",
                .replacement_proposal_id = input.replacement_proposal_id,
            }
        else if (input.privacy_blocked)
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .deny,
                .reason = "privacy policy blocked action",
                .replacement_proposal_id = input.replacement_proposal_id,
            }
        else if (requiresIdentityApproval(input))
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .require_approval,
                .reason = "identity risk requires user confirmation",
                .replacement_proposal_id = input.replacement_proposal_id,
            }
        else
            payloads.GovernanceDecisionPayload{
                .proposal_id = input.proposal.proposal_id,
                .decision = .allow,
                .reason = "policy checks passed",
                .replacement_proposal_id = input.replacement_proposal_id,
            };
        try self.sink.emitStruct(self.allocator, "governance.decision", decision);
        return decision;
    }
};

fn requiresIdentityApproval(input: Input) bool {
    const trust = input.identity_trust orelse return false;
    if (!isIdentitySensitive(input.proposal.kind)) return false;
    return trust < input.min_identity_trust;
}

fn isIdentitySensitive(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "recognize") or
        std.mem.eql(u8, kind, "remember_person") or
        std.mem.eql(u8, kind, "update_face_picture");
}

