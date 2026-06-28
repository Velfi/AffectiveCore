const std = @import("std");
const ctx_mod = @import("context.zig");
const types = @import("types.zig");

pub const ExtractedCandidate = struct {
    key: []const u8,
    proposition: []const u8,
    evidence: []const u8,
    kind: types.CandidateKind = .belief,
    confidence: f32 = 0.60,
    salience: f32 = 0.55,
    tags: []const []const u8 = &.{},
    source_references: []const []const u8 = &.{},
};

pub const ExtractionPort = struct {
    ctx: *anyopaque,
    extractFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]ExtractedCandidate,

    pub fn extract(self: ExtractionPort, allocator: std.mem.Allocator, episode_text: []const u8) ![]ExtractedCandidate {
        return self.extractFn(self.ctx, allocator, episode_text);
    }
};

pub const MemoryExtractionActor = struct {
    pub fn extractFromEpisode(
        context: *const ctx_mod.ActorContext,
        port: ?ExtractionPort,
        episode_id: []const u8,
        episode_summary: []const u8,
        source_event_ids: []const []const u8,
    ) ![]types.MemoryCandidate {
        const extraction_port = port orelse return error.MissingMemoryExtractionPort;
        if (episode_id.len == 0) return error.MissingEpisodeId;
        if (episode_summary.len == 0) return error.MissingEpisodeSummary;

        const extracted = try extraction_port.extract(context.allocator, episode_summary);
        var emitted = std.ArrayList(types.MemoryCandidate).empty;
        for (extracted, 0..) |item, index| {
            const tags = try context.allocator.alloc([]const u8, item.tags.len);
            for (item.tags, 0..) |tag, tag_index| {
                tags[tag_index] = try context.allocator.dupe(u8, tag);
            }
            const source_references = try context.allocator.alloc([]const u8, item.source_references.len);
            for (item.source_references, 0..) |reference, reference_index| {
                source_references[reference_index] = try context.allocator.dupe(u8, reference);
            }
            const event_ids = if (source_event_ids.len > 0)
                try context.cloneEventIds(source_event_ids)
            else
                try context.cloneEventIds(&[_][]const u8{episode_id});
            try emitted.append(context.allocator, .{
                .candidate_id = try std.fmt.allocPrint(context.allocator, "extract_{s}_{d}", .{ episode_id, index }),
                .key = try context.allocator.dupe(u8, item.key),
                .proposition = try context.allocator.dupe(u8, item.proposition),
                .evidence = try context.allocator.dupe(u8, item.evidence),
                .kind = item.kind,
                .confidence = item.confidence,
                .salience = item.salience,
                .status = .candidate,
                .source_event_ids = event_ids,
                .tags = tags,
                .source_references = source_references,
            });
        }
        return emitted.toOwnedSlice(context.allocator);
    }
};
