const std = @import("std");
const brain_mod = @import("../brain.zig");
const chat = @import("../port_chat.zig");
const interrupt_mod = @import("../interrupt.zig");
const capability_execution = @import("../capability_execution.zig");
const brain_action_execution = @import("../brain_action_execution.zig");
const brain_actor = @import("brain_actor.zig");

const Brain = brain_mod.Brain;

pub const ExecutorActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink) ExecutorActor {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn executeBatch(
        self: *const ExecutorActor,
        brain: *Brain,
        proposals: []chat.ActionProposal,
        observations: *std.ArrayList(u8),
    ) !brain_mod.ActionPressureBatchResult {
        const result = try brain_action_execution.executeActionProposalsDirect(brain, proposals, observations);
        if (result.selected_primary_action) |action| {
            try self.sink.emitStruct(self.allocator, "action.executed", .{
                .action = @tagName(action),
                .ended_with_speech = result.ended_with_speech,
            });
        }
        try self.sink.emitStruct(self.allocator, "outcome.created", .{
            .spoken_text = result.spoken_text,
            .interrupted = result.interrupted_by != null,
            .ended_with_speech = result.ended_with_speech,
        });
        return result;
    }

    pub fn executeCapability(
        self: *const ExecutorActor,
        brain: *Brain,
        proposal: chat.ActionProposal,
        proposal_index: usize,
        observations: *std.ArrayList(u8),
        spoken_text: *?[]const u8,
        check_interrupt: *const fn (*Brain, *std.ArrayList(u8)) anyerror!?interrupt_mod.Stimulus,
    ) !capability_execution.CapabilityActionFlow {
        const flow = try capability_execution.executeCapabilityAction(
            brain,
            proposal,
            proposal_index,
            observations,
            spoken_text,
            check_interrupt,
        );
        const flow_tag = std.meta.activeTag(flow);
        try self.sink.emitStruct(self.allocator, "action.executed", .{
            .action = @tagName(proposal.action),
            .index = proposal_index,
            .flow = @tagName(flow_tag),
        });
        try self.sink.emitStruct(self.allocator, "outcome.created", .{
            .action = @tagName(proposal.action),
            .ok = flow == .ok or flow == .next_action,
        });
        return flow;
    }
};

