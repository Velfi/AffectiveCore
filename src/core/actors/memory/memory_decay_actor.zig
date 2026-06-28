const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;
const ctx_mod = @import("context.zig");

pub const DecayResult = struct {
    touched: usize = 0,
    dormant: usize = 0,
    retracted: usize = 0,
};

pub const MemoryDecayActor = struct {
    pub fn decay(context: *const ctx_mod.ActorContext, kind_tag: ?[]const u8) !DecayResult {
        const memories = try context.store.loadMemoryRecords(context.allocator);
        var result = DecayResult{};
        for (memories) |memory| {
            if (kind_tag) |tag| {
                if (!hasTag(memory.tags, tag)) continue;
            }
            var updated = memory;
            const decay_pair = decayRates(memory.status);
            updated.confidence = std.math.clamp(memory.confidence * decay_pair.confidence, 0.0, 1.0);
            updated.salience = std.math.clamp(memory.salience * decay_pair.salience, 0.0, 1.0);
            updated.status = transitionStatus(memory.status, updated.confidence, updated.salience);
            if (updated.status == .dormant and memory.status != .dormant) result.dormant += 1;
            if (updated.status == .retracted and memory.status != .retracted) result.retracted += 1;
            try context.store.saveMemoryRecord(updated);
            result.touched += 1;
        }
        return result;
    }

    fn decayRates(status: schema.MemoryRecordStatus) struct { confidence: f32, salience: f32 } {
        return switch (status) {
            .candidate => .{ .confidence = 0.94, .salience = 0.90 },
            .tentative => .{ .confidence = 0.96, .salience = 0.92 },
            .active => .{ .confidence = 0.98, .salience = 0.95 },
            .dormant => .{ .confidence = 0.97, .salience = 0.90 },
            .contradicted => .{ .confidence = 0.92, .salience = 0.88 },
            .corrected => .{ .confidence = 0.96, .salience = 0.92 },
            .retracted => .{ .confidence = 1.0, .salience = 1.0 },
        };
    }

    fn transitionStatus(status: schema.MemoryRecordStatus, confidence: f32, salience: f32) schema.MemoryRecordStatus {
        if (status == .retracted) return .retracted;
        if (confidence < 0.20 and salience < 0.20) return .retracted;
        if (salience < 0.28) return .dormant;
        if (status == .candidate and confidence >= 0.55) return .tentative;
        if (status == .tentative and confidence >= 0.75 and salience >= 0.45) return .active;
        return status;
    }

    fn hasTag(tags: []const []const u8, candidate: []const u8) bool {
        for (tags) |tag| {
            if (std.mem.eql(u8, tag, candidate)) return true;
        }
        return false;
    }
};
