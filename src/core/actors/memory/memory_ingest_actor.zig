const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;
const ctx_mod = @import("context.zig");

pub const MemoryIngestActor = struct {
    pub fn ingest(context: *const ctx_mod.ActorContext, event: schema.ExperienceEvent) !schema.MemoryRecord {
        if (event.id.len == 0) return error.MissingExperienceEventId;
        if (event.kind.len == 0) return error.MissingExperienceEventKind;
        if (event.payload.len == 0) return error.MissingExperienceEventPayload;

        const memory_id = try std.fmt.allocPrint(context.allocator, "ingest_{s}", .{event.id});
        const existing = try context.store.loadMemoryRecords(context.allocator);
        const now = try context.timestampNow();
        for (existing) |record| {
            if (!std.mem.eql(u8, record.memory_id, memory_id)) continue;
            var updated = record;
            updated.status = .candidate;
            updated.source_event_ids = try context.cloneEventIds(&[_][]const u8{event.id});
            updated.text = try context.allocator.dupe(u8, event.payload);
            updated.original_text = try context.allocator.dupe(u8, event.payload);
            updated.interpretation = try std.fmt.allocPrint(context.allocator, "ingested {s}", .{event.kind});
            updated.last_accessed_at = now;
            updated.tags = try context.cloneEventIds(&[_][]const u8{ "memory_ingest", event.kind });
            try context.store.saveMemoryRecord(updated);
            return updated;
        }

        const created: schema.MemoryRecord = .{
            .memory_id = memory_id,
            .status = .candidate,
            .source_event_ids = try context.cloneEventIds(&[_][]const u8{event.id}),
            .scope = .short_term,
            .text = try context.allocator.dupe(u8, event.payload),
            .original_text = try context.allocator.dupe(u8, event.payload),
            .interpretation = try std.fmt.allocPrint(context.allocator, "ingested {s}", .{event.kind}),
            .confidence = event.confidence,
            .valence = event.valence,
            .salience = event.salience,
            .tags = try context.cloneEventIds(&[_][]const u8{ "memory_ingest", event.kind }),
            .created_at = now,
            .last_accessed_at = null,
            .access_count = 0,
            .score = 1,
        };
        try context.store.saveMemoryRecord(created);
        return created;
    }
};
