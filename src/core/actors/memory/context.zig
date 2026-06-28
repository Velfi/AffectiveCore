const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;
const store_mod = ports.store;

pub const ActorContext = struct {
    allocator: std.mem.Allocator,
    store: store_mod.MemoryStore,
    now_seconds: i64,
    brain_id: []const u8,
    host_id: []const u8,

    pub fn timestampNow(self: *const ActorContext) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{d}", .{self.now_seconds});
    }

    pub fn nextEventOrdinal(self: *const ActorContext) !usize {
        const events = try self.store.loadExperienceEvents(self.allocator);
        return events.len;
    }

    pub fn cloneEventIds(self: *const ActorContext, event_ids: []const []const u8) ![][]const u8 {
        var out = try self.allocator.alloc([]const u8, event_ids.len);
        for (event_ids, 0..) |event_id, index| {
            out[index] = try self.allocator.dupe(u8, event_id);
        }
        return out;
    }

    pub fn makeExperienceEvent(
        self: *const ActorContext,
        source: schema.ExperienceEventSource,
        kind: []const u8,
        payload: []const u8,
        parents: []const []const u8,
        retention: schema.ExperienceEventRetention,
    ) !schema.ExperienceEvent {
        return .{
            .id = try std.fmt.allocPrint(
                self.allocator,
                "evt_{d}_{d}_{s}_{d}",
                .{ self.now_seconds * 1000, try self.nextEventOrdinal(), kind, payload.len },
            ),
            .brain_id = try self.allocator.dupe(u8, self.brain_id),
            .host_id = try self.allocator.dupe(u8, self.host_id),
            .timestamp_ms = self.now_seconds * 1000,
            .source = source,
            .kind = try self.allocator.dupe(u8, kind),
            .payload = try self.allocator.dupe(u8, payload),
            .causal_parent_ids = try self.cloneEventIds(parents),
            .retention = retention,
            .visibility = .internal,
        };
    }
};
