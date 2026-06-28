const std = @import("std");
const brain_actor = @import("brain_actor.zig");
const payloads = @import("payloads.zig");

pub const ScheduledActionPayload = struct {
    proposal_id: []const u8,
    kind: []const u8,
    delay_ms: u32,
};

pub const SchedulerActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,
    sleeper: brain_actor.SleepPort,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink, sleeper: brain_actor.SleepPort) SchedulerActor {
        return .{
            .allocator = allocator,
            .sink = sink,
            .sleeper = sleeper,
        };
    }

    pub fn schedule(self: *const SchedulerActor, proposal: payloads.ProposalEventPayload, delay_ms: u32) !void {
        const scheduled = ScheduledActionPayload{
            .proposal_id = proposal.proposal_id,
            .kind = proposal.kind,
            .delay_ms = delay_ms,
        };
        try self.sink.emitStruct(self.allocator, "action.scheduled", scheduled);
        try self.sleeper.sleepMs(delay_ms);
    }
};

