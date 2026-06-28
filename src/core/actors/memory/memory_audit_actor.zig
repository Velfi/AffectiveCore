const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;
const ctx_mod = @import("context.zig");
const types = @import("types.zig");

pub const MemoryAuditActor = struct {
    pub fn auditBelief(context: *const ctx_mod.ActorContext, belief_id: []const u8) !types.AuditReport {
        if (belief_id.len == 0) return error.MissingBeliefId;
        const beliefs = try context.store.loadBeliefs(context.allocator);
        for (beliefs) |belief| {
            if (!std.mem.eql(u8, belief.belief_id, belief_id)) continue;
            return .{
                .belief_id = belief.belief_id,
                .provenance = belief.provenance,
                .source_event_ids = belief.evidence_event_ids,
                .revision_history = belief.lifecycle.revisions,
            };
        }
        return error.BeliefNotFound;
    }

    pub fn formatAuditReport(allocator: std.mem.Allocator, report: types.AuditReport) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        try out.writer(allocator).print(
            "memory_audit:\n- belief_id: {s}\n- provenance: {s}\n",
            .{ report.belief_id, report.provenance },
        );
        try out.appendSlice(allocator, "- source_event_ids:\n");
        if (report.source_event_ids.len == 0) {
            try out.appendSlice(allocator, "  - none\n");
        } else {
            for (report.source_event_ids) |event_id| {
                try out.writer(allocator).print("  - {s}\n", .{event_id});
            }
        }
        try out.appendSlice(allocator, "- revision_history:\n");
        if (report.revision_history.len == 0) {
            try out.appendSlice(allocator, "  - none\n");
        } else {
            for (report.revision_history) |revision| {
                try out.writer(allocator).print(
                    "  - time={s} confidence={d:.2} text={s}\n",
                    .{ revision.time, revision.confidence, revision.text },
                );
            }
        }
        return out.toOwnedSlice(allocator);
    }
};
