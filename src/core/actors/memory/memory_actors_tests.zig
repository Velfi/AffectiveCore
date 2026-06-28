const std = @import("std");
const schema = @import("../../ports.zig").schema;
const TestStore = @import("../../brain_test_store.zig").TestStore;
const ctx_mod = @import("context.zig");
const MemoryIngestActor = @import("memory_ingest_actor.zig").MemoryIngestActor;
const MemoryCandidateActor = @import("memory_candidate_actor.zig").MemoryCandidateActor;
const MemoryConsolidationActor = @import("memory_consolidation_actor.zig").MemoryConsolidationActor;
const MemoryReconciliationActor = @import("memory_reconciliation_actor.zig").MemoryReconciliationActor;
const MemoryRetrievalActor = @import("memory_retrieval_actor.zig").MemoryRetrievalActor;
const MemoryExtractionActor = @import("memory_extraction_actor.zig").MemoryExtractionActor;
const memory_extraction_actor = @import("memory_extraction_actor.zig");
const MemoryAuditActor = @import("memory_audit_actor.zig").MemoryAuditActor;
const types = @import("types.zig");

fn makeContext(allocator: std.mem.Allocator, store: *TestStore) ctx_mod.ActorContext {
    return .{
        .allocator = allocator,
        .store = store.store(),
        .now_seconds = 1782529000,
        .brain_id = "test_brain",
        .host_id = "core",
    };
}

test "memory ingest stores experience event reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var context = makeContext(allocator, &store);

    const event: schema.ExperienceEvent = .{
        .id = "evt_ingest",
        .brain_id = "test_brain",
        .host_id = "core",
        .timestamp_ms = context.now_seconds * 1000,
        .source = .user,
        .kind = "User.TextReceived",
        .payload = "hello memory actor",
    };
    const memory = try MemoryIngestActor.ingest(&context, event);
    try std.testing.expectEqualStrings("candidate", @tagName(memory.status));
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    try std.testing.expectEqualStrings("evt_ingest", store.memories.items[0].source_event_ids[0]);
}

test "memory candidate validation rejects missing evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var context = makeContext(allocator, &store);

    const candidate: types.MemoryCandidate = .{
        .key = "self.name",
        .proposition = "name might be Otto",
        .evidence = "",
        .source_event_ids = &[_][]const u8{"evt_1"},
    };
    try std.testing.expectError(error.MissingCandidateEvidence, MemoryCandidateActor.receiveCandidate(&context, candidate));
}

test "memory reconciliation preserves revisions on correction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var context = makeContext(allocator, &store);

    try store.store().upsertBelief(.{
        .belief_id = "belief_name",
        .key = "self.name",
        .proposition = "name is Otto",
        .confidence = 0.82,
        .evidence_event_ids = @constCast(&[_][]const u8{"evt_old"}),
        .tags = @constCast(&[_][]const u8{"identity"}),
        .lifecycle = .{
            .status = .active,
            .created_at = "100",
            .updated_at = "100",
        },
    });

    const result = try MemoryReconciliationActor.reconcileCandidate(&context, .{
        .candidate_id = "cand_correct",
        .key = "self.name",
        .proposition = "name is Otto Prime",
        .evidence = "user corrected identity",
        .confidence = 0.90,
        .source_event_ids = &[_][]const u8{"evt_correction"},
        .tags = &[_][]const u8{"identity", "correction"},
    });
    try std.testing.expectEqual(types.ReconciliationAction.correct, result.action);
    try std.testing.expectEqual(@as(usize, 1), store.beliefs.items[0].lifecycle.revisions.len);
    try std.testing.expectEqualStrings("name is Otto", store.beliefs.items[0].lifecycle.revisions[0].text);
}

test "memory consolidation builds episode candidate on activity close" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var context = makeContext(allocator, &store);

    const activity: schema.ActivityRecord = .{
        .id = "act_1",
        .kind = .conversation,
        .kind_label = "conversation",
        .status = .complete,
        .goal = "check in with user",
        .summary = "discussed battery",
        .started_at_ms = context.now_seconds * 1000,
        .updated_at_ms = context.now_seconds * 1000,
        .originating_request_id = "req_1",
        .interpretation = "conversation complete",
    };
    const candidate = try MemoryConsolidationActor.consolidateActivity(&context, activity, "turn_complete");
    try std.testing.expectEqual(types.CandidateKind.episode, candidate.kind);
    try std.testing.expect(std.mem.indexOf(u8, candidate.proposition, "discussed battery") != null);
    try std.testing.expectEqual(@as(usize, 0), store.memories.items.len);
}

test "memory extraction requires extraction port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var context = makeContext(allocator, &store);

    try std.testing.expectError(
        error.MissingMemoryExtractionPort,
        MemoryExtractionActor.extractFromEpisode(&context, null, "episode_1", "summary", &[_][]const u8{"evt_1"}),
    );
}

test "memory extraction emits candidates only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var context = makeContext(allocator, &store);
    var dummy: u8 = 0;
    const Harness = struct {
        fn extract(_: *anyopaque, alloc: std.mem.Allocator, episode_text: []const u8) ![]memory_extraction_actor.ExtractedCandidate {
            var out = std.ArrayList(memory_extraction_actor.ExtractedCandidate).empty;
            try out.append(alloc, .{
                .key = "episode.test",
                .proposition = episode_text,
                .evidence = episode_text,
                .kind = .belief,
                .confidence = 0.66,
                .salience = 0.57,
                .tags = &[_][]const u8{"episode"},
                .source_references = &[_][]const u8{"summary text"},
            });
            return out.toOwnedSlice(alloc);
        }
    };
    const emitted = try MemoryExtractionActor.extractFromEpisode(&context, .{
        .ctx = &dummy,
        .extractFn = Harness.extract,
    }, "episode_1", "summary text", &[_][]const u8{"evt_1"});
    try std.testing.expectEqual(@as(usize, 1), emitted.len);
    try std.testing.expectEqual(types.CandidateKind.belief, emitted[0].kind);
    try std.testing.expectEqual(@as(usize, 1), emitted[0].source_event_ids.len);
    try std.testing.expectEqual(@as(usize, 1), emitted[0].source_references.len);
    try std.testing.expectEqualStrings("summary text", emitted[0].source_references[0]);
    try std.testing.expectEqual(@as(usize, 0), store.memories.items.len);
}

test "memory retrieval and audit expose status and provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var context = makeContext(allocator, &store);

    try store.store().saveMemoryRecord(.{
        .memory_id = "memory_plan",
        .status = .tentative,
        .scope = .short_term,
        .text = "prepare daily plan",
        .interpretation = "prepare daily plan",
        .tags = @constCast(&[_][]const u8{"planning"}),
        .created_at = "100",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
        .confidence = 0.71,
    });
    try store.store().upsertBelief(.{
        .belief_id = "belief_plan",
        .key = "planning.daily",
        .proposition = "daily planning helps",
        .provenance = "memory_reconciliation",
        .evidence_event_ids = @constCast(&[_][]const u8{"evt_plan"}),
        .lifecycle = .{
            .status = .active,
            .created_at = "100",
            .updated_at = "100",
            .revisions = @constCast(&[_]schema.MemoryRevision{
                .{ .time = "101", .text = "daily planning might help", .confidence = 0.6 },
            }),
        },
    });

    const retrieved = try MemoryRetrievalActor.retrieve(&context, "plan", .tentative, 3);
    try std.testing.expectEqual(@as(usize, 1), retrieved.len);
    try std.testing.expectEqual(schema.MemoryRecordStatus.tentative, retrieved[0].status);

    const audit = try MemoryAuditActor.auditBelief(&context, "belief_plan");
    try std.testing.expectEqual(@as(usize, 1), audit.source_event_ids.len);
    try std.testing.expectEqual(@as(usize, 1), audit.revision_history.len);
}
