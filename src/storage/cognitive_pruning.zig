const std = @import("std");
const schema = @import("schema.zig");

pub const Result = struct {
    tombstoned: usize = 0,
    purged: usize = 0,
};

/// Two-phase dreamtime pruning:
/// - Records already `pending_deletion` or `invalidated` are removed.
/// - Unreferenced artifacts/subjects/beliefs are marked `pending_deletion` for one grace period.
pub fn pruneCognitiveFile(allocator: std.mem.Allocator, data: *schema.CognitiveFile, now: []const u8) !Result {
    var referenced_beliefs = std.StringHashMap(void).init(allocator);
    defer referenced_beliefs.deinit();
    var referenced_artifacts = std.StringHashMap(void).init(allocator);
    defer referenced_artifacts.deinit();
    var referenced_subjects = std.StringHashMap(void).init(allocator);
    defer referenced_subjects.deinit();
    try collectReferences(allocator, data, &referenced_beliefs, &referenced_artifacts, &referenced_subjects);

    var result: Result = .{};
    try pruneBeliefs(allocator, data, now, &referenced_beliefs, &result);
    try pruneArtifacts(allocator, data, now, &referenced_artifacts, &result);
    try pruneSubjects(allocator, data, now, &referenced_subjects, &result);
    return result;
}

fn collectReferences(
    allocator: std.mem.Allocator,
    data: *const schema.CognitiveFile,
    referenced_beliefs: *std.StringHashMap(void),
    referenced_artifacts: *std.StringHashMap(void),
    referenced_subjects: *std.StringHashMap(void),
) !void {
    for (data.subjects) |subject| {
        for (subject.belief_ids) |id| try markReference(allocator, referenced_beliefs, id);
        for (subject.artifact_ids) |id| try markReference(allocator, referenced_artifacts, id);
        if (subject.representative_artifact_id) |id| try markReference(allocator, referenced_artifacts, id);
    }
    for (data.dream_time_records) |dream| {
        for (dream.updated_belief_ids) |id| try markReference(allocator, referenced_beliefs, id);
        if (dream.generated_artifact_id) |id| try markReference(allocator, referenced_artifacts, id);
    }
    for (data.mailbox_items) |item| {
        if (item.image_artifact_id) |id| try markReference(allocator, referenced_artifacts, id);
    }
    for (data.sightings) |sighting| {
        if (sighting.person_id) |id| try markReference(allocator, referenced_subjects, id);
    }
}

fn markReference(allocator: std.mem.Allocator, table: *std.StringHashMap(void), id: []const u8) !void {
    if (id.len == 0) return;
    try table.put(try allocator.dupe(u8, id), {});
}

fn pruneBeliefs(
    allocator: std.mem.Allocator,
    data: *schema.CognitiveFile,
    now: []const u8,
    referenced: *const std.StringHashMap(void),
    result: *Result,
) !void {
    var kept = std.ArrayList(schema.Belief).empty;
    errdefer {
        for (kept.items) |belief| freeBelief(allocator, belief);
        kept.deinit(allocator);
    }
    var index = data.beliefs.len;
    while (index > 0) {
        index -= 1;
        const belief = data.beliefs[index];
        if (shouldPurge(belief.lifecycle.status)) {
            freeBelief(allocator, belief);
            result.purged += 1;
            continue;
        }
        if (!referenced.contains(belief.belief_id) and !beliefProtected(belief)) {
            var updated = belief;
            updated.lifecycle = try tombstoneLifecycle(allocator, belief.lifecycle, now, "unreferenced belief");
            try kept.append(allocator, updated);
            result.tombstoned += 1;
            continue;
        }
        try kept.append(allocator, belief);
    }
    std.mem.reverse(schema.Belief, kept.items);
    allocator.free(data.beliefs);
    data.beliefs = try kept.toOwnedSlice(allocator);
}

fn pruneArtifacts(
    allocator: std.mem.Allocator,
    data: *schema.CognitiveFile,
    now: []const u8,
    referenced: *const std.StringHashMap(void),
    result: *Result,
) !void {
    var kept = std.ArrayList(schema.Artifact).empty;
    errdefer {
        for (kept.items) |artifact| freeArtifact(allocator, artifact);
        kept.deinit(allocator);
    }
    var index = data.artifacts.len;
    while (index > 0) {
        index -= 1;
        const artifact = data.artifacts[index];
        if (shouldPurge(artifact.lifecycle.status)) {
            freeArtifact(allocator, artifact);
            result.purged += 1;
            continue;
        }
        if (!referenced.contains(artifact.artifact_id) and !artifactProtected(artifact)) {
            var updated = artifact;
            updated.lifecycle = try tombstoneLifecycle(allocator, artifact.lifecycle, now, "unreferenced artifact");
            try kept.append(allocator, updated);
            result.tombstoned += 1;
            continue;
        }
        try kept.append(allocator, artifact);
    }
    std.mem.reverse(schema.Artifact, kept.items);
    allocator.free(data.artifacts);
    data.artifacts = try kept.toOwnedSlice(allocator);
}

fn pruneSubjects(
    allocator: std.mem.Allocator,
    data: *schema.CognitiveFile,
    now: []const u8,
    referenced: *const std.StringHashMap(void),
    result: *Result,
) !void {
    var kept = std.ArrayList(schema.Subject).empty;
    errdefer {
        for (kept.items) |subject| freeSubject(allocator, subject);
        kept.deinit(allocator);
    }
    var index = data.subjects.len;
    while (index > 0) {
        index -= 1;
        const subject = data.subjects[index];
        if (shouldPurge(subject.lifecycle.status)) {
            freeSubject(allocator, subject);
            result.purged += 1;
            continue;
        }
        if (!referenced.contains(subject.subject_id) and !subjectProtected(subject)) {
            var updated = subject;
            updated.lifecycle = try tombstoneLifecycle(allocator, subject.lifecycle, now, "unreferenced subject");
            try kept.append(allocator, updated);
            result.tombstoned += 1;
            continue;
        }
        try kept.append(allocator, subject);
    }
    std.mem.reverse(schema.Subject, kept.items);
    allocator.free(data.subjects);
    data.subjects = try kept.toOwnedSlice(allocator);
}

fn shouldPurge(status: schema.CognitiveStatus) bool {
    return status == .pending_deletion or status == .invalidated;
}

fn beliefProtected(belief: schema.Belief) bool {
    if (hasTag(belief.tags, "identity") or hasTag(belief.tags, "self")) return true;
    if (std.ascii.eqlIgnoreCase(belief.key, "name")) return true;
    if (std.ascii.eqlIgnoreCase(belief.key, "first_turned_on_at_unix_seconds")) return true;
    return false;
}

fn artifactProtected(artifact: schema.Artifact) bool {
    return artifact.retention == .durable or artifact.retention == .disposition;
}

fn subjectProtected(subject: schema.Subject) bool {
    return subject.relationship_status == .friend or subject.relationship_status == .creator;
}

fn hasTag(tags: []const []const u8, needle: []const u8) bool {
    for (tags) |tag| {
        if (std.ascii.eqlIgnoreCase(tag, needle)) return true;
    }
    return false;
}

fn tombstoneLifecycle(allocator: std.mem.Allocator, lifecycle: schema.CognitiveLifecycle, now: []const u8, reason: []const u8) !schema.CognitiveLifecycle {
    return .{
        .status = .pending_deletion,
        .created_at = try allocator.dupe(u8, lifecycle.created_at),
        .updated_at = try allocator.dupe(u8, now),
        .pending_deletion_at = try allocator.dupe(u8, now),
        .pending_deletion_reason = try allocator.dupe(u8, reason),
        .pending_deletion_source = try allocator.dupe(u8, "dream_time"),
        .revisions = lifecycle.revisions,
    };
}

fn freeBelief(allocator: std.mem.Allocator, belief: schema.Belief) void {
    _ = allocator;
    _ = belief;
}

fn freeArtifact(allocator: std.mem.Allocator, artifact: schema.Artifact) void {
    _ = allocator;
    _ = artifact;
}

fn freeSubject(allocator: std.mem.Allocator, subject: schema.Subject) void {
    _ = allocator;
    _ = subject;
}

test "dreamtime pruning tombstones unreferenced artifacts then purges on next pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var artifacts = try allocator.alloc(schema.Artifact, 1);
    artifacts[0] = .{
        .artifact_id = "artifact_orphan",
        .kind = .image,
        .path = "data/test/captures/orphan.jpg",
        .provenance = "test",
        .retention = .episode,
        .lifecycle = .{ .created_at = "1", .updated_at = "1" },
    };
    var data: schema.CognitiveFile = .{ .artifacts = artifacts };
    const first = try pruneCognitiveFile(allocator, &data, "2");
    try std.testing.expectEqual(@as(usize, 1), first.tombstoned);
    try std.testing.expectEqual(@as(usize, 0), first.purged);
    try std.testing.expectEqual(schema.CognitiveStatus.pending_deletion, data.artifacts[0].lifecycle.status);

    const second = try pruneCognitiveFile(allocator, &data, "3");
    try std.testing.expectEqual(@as(usize, 0), second.tombstoned);
    try std.testing.expectEqual(@as(usize, 1), second.purged);
    try std.testing.expectEqual(@as(usize, 0), data.artifacts.len);
}

test "identity beliefs are never tombstoned when unreferenced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var beliefs = try allocator.alloc(schema.Belief, 1);
    beliefs[0] = .{
        .belief_id = "belief_name",
        .key = "name",
        .proposition = "Otto",
        .tags = try allocator.alloc([]const u8, 1),
        .lifecycle = .{ .created_at = "1", .updated_at = "1" },
    };
    beliefs[0].tags[0] = "identity";
    var data: schema.CognitiveFile = .{ .beliefs = beliefs };
    const result = try pruneCognitiveFile(allocator, &data, "2");
    try std.testing.expectEqual(@as(usize, 0), result.tombstoned);
    try std.testing.expectEqual(@as(usize, 0), result.purged);
    try std.testing.expectEqual(schema.CognitiveStatus.active, data.beliefs[0].lifecycle.status);
}
