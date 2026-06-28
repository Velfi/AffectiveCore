const std = @import("std");
const brain_actor = @import("brain_actor.zig");
const payloads = @import("payloads.zig");

pub const AppraisalInput = struct {
    salience: f32,
    affect: f32,
    risk: f32,
    social_value: f32,
};

pub const Appraisal = struct {
    salience: f32,
    affect: f32,
    risk: f32,
    social_value: f32,
    urgency: f32,
    expected_value: f32,
};

pub const AppraisalActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink) AppraisalActor {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn create(self: *const AppraisalActor, input: AppraisalInput) !Appraisal {
        const salience = clamp01(input.salience);
        const affect = std.math.clamp(input.affect, -1.0, 1.0);
        const risk = clamp01(input.risk);
        const social_value = std.math.clamp(input.social_value, -1.0, 1.0);
        const urgency = clamp01(salience * 0.65 + @max(0.0, affect) * 0.20 + risk * 0.15);
        const expected_value = std.math.clamp(affect * 0.45 + social_value * 0.35 + salience * 0.20 - risk * 0.40, -1.0, 1.0);
        const appraisal = Appraisal{
            .salience = salience,
            .affect = affect,
            .risk = risk,
            .social_value = social_value,
            .urgency = urgency,
            .expected_value = expected_value,
        };
        try self.sink.emitStruct(self.allocator, "appraisal.created", appraisal);
        return appraisal;
    }

    pub fn annotateProposal(
        self: *const AppraisalActor,
        proposal: payloads.ProposalEventPayload,
        appraisal: Appraisal,
    ) !payloads.ProposalEventPayload {
        const annotated = payloads.ProposalEventPayload{
            .proposal_id = proposal.proposal_id,
            .kind = proposal.kind,
            .strength = clamp01(proposal.strength * 0.60 + appraisal.salience * 0.25 + @max(0.0, appraisal.affect) * 0.15),
            .urgency = clamp01(proposal.urgency * 0.55 + appraisal.urgency * 0.45),
            .expected_value = std.math.clamp(proposal.expected_value * 0.55 + appraisal.expected_value * 0.45, -1.0, 1.0),
            .risk = clamp01(proposal.risk * 0.60 + appraisal.risk * 0.40),
            .alternatives = proposal.alternatives,
        };
        try self.sink.emitStruct(self.allocator, "proposal.annotated", annotated);
        return annotated;
    }
};

fn clamp01(value: f32) f32 {
    return std.math.clamp(value, 0.0, 1.0);
}

