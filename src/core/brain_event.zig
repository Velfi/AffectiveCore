const std = @import("std");

pub const Priority = enum(u2) {
    high,
    normal,
    low,
};

pub const EventTypes = struct {
    pub const proposal_created = "proposal.created";
    pub const governance_decision = "governance.decision";
    pub const memory_candidate = "memory.candidate";
    pub const memory_consolidate = "memory.consolidate";
    pub const memory_consolidated = "memory.consolidated";
    pub const memory_extract = "memory.extract";
    pub const memory_retrieve = "memory.retrieve";
    pub const memory_retrieved = "memory.retrieved";
    pub const memory_decay = "memory.decay";
    pub const memory_decayed = "memory.decayed";
    pub const memory_audit_query = "memory.audit.query";
    pub const memory_audit = "memory.audit";
    pub const action_scheduled = "action.scheduled";
    pub const action_executed = "action.executed";
    pub const outcome_created = "outcome.created";
    pub const learning_capability_recorded = "learning.capability_recorded";
    pub const learning_correction_recorded = "learning.correction_recorded";
    pub const learning_updated = "learning.updated";
    pub const activity_updated = "activity.updated";
};

pub const BrainEvent = struct {
    id: []const u8,
    event_type: []const u8,
    timestamp: i64,
    source_actor: []const u8,
    activity_id: ?[]const u8 = null,
    correlation_id: []const u8,
    causation_id: ?[]const u8 = null,
    priority: Priority = .normal,
    ttl: u8,
    depth: u16,
    payload: []const u8,

    pub fn format(self: BrainEvent, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "id={s} type={s} source={s} corr={s} cause={s} depth={d} ttl={d}",
            .{
                self.id,
                self.event_type,
                self.source_actor,
                self.correlation_id,
                self.causation_id orelse "root",
                self.depth,
                self.ttl,
            },
        );
    }
};
