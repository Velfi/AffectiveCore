const std = @import("std");
const json_store = @import("json_store.zig");
const persistence = @import("json_store_persistence.zig");
const schema = @import("schema.zig");

const JsonMemoryStore = json_store.JsonMemoryStore;
const readFileAllocPath = persistence.readFileAllocPath;
const writeRawCognitiveJsonForTest = persistence.writeRawCognitiveJsonForTest;

fn lifecycle() schema.CognitiveLifecycle {
    return .{ .created_at = "1000", .updated_at = "1000" };
}

fn integrityFixture() schema.CognitiveFile {
    return .{
        .brain_id = "default",
        .host_bindings = @constCast(&[_]schema.HostBinding{.{
            .host_id = "core",
            .platform = "test",
            .attached_at_ms = 1000,
        }}),
        .events = @constCast(&[_]schema.ExperienceEvent{.{
            .id = "evt_root",
            .brain_id = "default",
            .host_id = "core",
            .timestamp_ms = 1000,
            .source = .user,
            .kind = "User.TextReceived",
            .payload = "hello",
        }}),
        .memories = @constCast(&[_]schema.MemoryRecord{.{
            .memory_id = "memory_root",
            .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .scope = .long_term,
            .text = "hello",
            .tags = @constCast(&[_][]const u8{"test"}),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
        }}),
        .beliefs = @constCast(&[_]schema.Belief{.{
            .belief_id = "belief_root",
            .evidence_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .key = "test",
            .proposition = "The test event happened.",
            .lifecycle = lifecycle(),
        }}),
        .self_trust = @constCast(&[_]schema.SelfTrustEntry{.{
            .self_trust_id = "trust_root",
            .faculty = "memory",
            .evidence_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .updated_at_ms = 1000,
        }}),
        .dispositions = @constCast(&[_]schema.Disposition{.{
            .disposition_id = "disp_root",
            .context_pattern = "test",
            .action_tendency = "keep validating references",
            .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .updated_at_ms = 1000,
        }}),
        .action_pressures = @constCast(&[_]schema.ActionPressure{.{
            .pressure_id = "pressure_root",
            .subsystem = "Test",
            .proposed_action = "say",
            .causal_parent_ids = @constCast(&[_][]const u8{"evt_root"}),
            .created_at_ms = 1000,
        }}),
        .action_outcomes = @constCast(&[_]schema.ActionOutcome{.{
            .outcome_id = "outcome_root",
            .pressure_id = "pressure_root",
            .result_event_id = "evt_root",
            .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .created_at_ms = 1000,
        }}),
        .artifacts = @constCast(&[_]schema.Artifact{.{
            .artifact_id = "artifact_root",
            .kind = .image,
            .path = "generated/test.png",
            .mime_type = "image/png",
            .provenance = "test",
            .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .lifecycle = lifecycle(),
        }}),
        .dream_time_records = @constCast(&[_]schema.DreamTimeRecord{.{
            .dream_id = "dream_root",
            .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .source_memory_ids = @constCast(&[_][]const u8{"memory_root"}),
            .updated_belief_ids = @constCast(&[_][]const u8{"belief_root"}),
            .self_trust_change_ids = @constCast(&[_][]const u8{"trust_root"}),
            .disposition_change_ids = @constCast(&[_][]const u8{"disp_root"}),
            .title = "Test Dream",
            .text = "A test dream.",
            .created_at_ms = 1000,
        }}),
        .mailbox_items = @constCast(&[_]schema.MailboxItem{.{
            .mailbox_id = "mail_root",
            .kind = .DreamMail,
            .title = "Test Dream",
            .text = "A test dream.",
            .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .created_at_ms = 1000,
        }}),
        .identity_hypotheses = @constCast(&[_]schema.IdentityHypothesis{.{
            .hypothesis_id = "hyp_root",
            .decision = .recognized,
            .evidence_event_ids = @constCast(&[_][]const u8{"evt_root"}),
            .confidence = 0.8,
            .created_at_ms = 1000,
        }}),
    };
}

test "sqlite memory store creates empty v2 cognitive store when missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_v2_empty.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path);
    const events = try impl.store().loadExperienceEvents(allocator);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}

test "cognitive integrity validator accepts complete reference graph" {
    try persistence.validateCognitiveFile(integrityFixture());
}

test "cognitive integrity validator rejects unknown host binding references" {
    var data = integrityFixture();
    data.events = @constCast(&[_]schema.ExperienceEvent{.{
        .id = "evt_root",
        .brain_id = "default",
        .host_id = "missing_host",
        .timestamp_ms = 1000,
        .source = .user,
        .kind = "User.TextReceived",
        .payload = "hello",
    }});
    try std.testing.expectError(error.UnknownExperienceEventHostId, persistence.validateCognitiveFile(data));
}

test "cognitive integrity validator rejects unknown memory source event references" {
    var data = integrityFixture();
    data.memories = @constCast(&[_]schema.MemoryRecord{.{
        .memory_id = "memory_root",
        .source_event_ids = @constCast(&[_][]const u8{"missing_event"}),
        .scope = .long_term,
        .text = "hello",
        .tags = @constCast(&[_][]const u8{"test"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    }});
    try std.testing.expectError(error.UnknownMemorySourceEventId, persistence.validateCognitiveFile(data));
}

test "cognitive integrity validator rejects unknown action outcome event references" {
    var data = integrityFixture();
    data.action_outcomes = @constCast(&[_]schema.ActionOutcome{.{
        .outcome_id = "outcome_root",
        .pressure_id = "pressure_root",
        .result_event_id = "evt_root",
        .source_event_ids = @constCast(&[_][]const u8{"missing_event"}),
        .created_at_ms = 1000,
    }});
    try std.testing.expectError(error.UnknownActionOutcomeSourceEventId, persistence.validateCognitiveFile(data));

    data = integrityFixture();
    data.action_outcomes = @constCast(&[_]schema.ActionOutcome{.{
        .outcome_id = "outcome_root",
        .pressure_id = "pressure_root",
        .result_event_id = "missing_event",
        .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
        .created_at_ms = 1000,
    }});
    try std.testing.expectError(error.UnknownActionOutcomeResultEventId, persistence.validateCognitiveFile(data));
}

test "cognitive integrity validator rejects unknown artifact references" {
    var data = integrityFixture();
    data.dream_time_records = @constCast(&[_]schema.DreamTimeRecord{.{
        .dream_id = "dream_root",
        .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
        .source_memory_ids = @constCast(&[_][]const u8{"memory_root"}),
        .updated_belief_ids = @constCast(&[_][]const u8{"belief_root"}),
        .self_trust_change_ids = @constCast(&[_][]const u8{"trust_root"}),
        .disposition_change_ids = @constCast(&[_][]const u8{"disp_root"}),
        .generated_artifact_id = "missing_artifact",
        .title = "Test Dream",
        .text = "A test dream.",
        .created_at_ms = 1000,
    }});
    try std.testing.expectError(error.UnknownDreamTimeArtifactId, persistence.validateCognitiveFile(data));

    data = integrityFixture();
    data.mailbox_items = @constCast(&[_]schema.MailboxItem{.{
        .mailbox_id = "mail_root",
        .kind = .DreamMail,
        .title = "Test Dream",
        .text = "A test dream.",
        .image_artifact_id = "missing_artifact",
        .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
        .created_at_ms = 1000,
    }});
    try std.testing.expectError(error.UnknownMailboxArtifactId, persistence.validateCognitiveFile(data));
}

test "cognitive integrity validator rejects unknown dream and mailbox references" {
    var data = integrityFixture();
    data.dream_time_records = @constCast(&[_]schema.DreamTimeRecord{.{
        .dream_id = "dream_root",
        .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
        .source_memory_ids = @constCast(&[_][]const u8{"memory_root"}),
        .updated_belief_ids = @constCast(&[_][]const u8{"belief_root"}),
        .self_trust_change_ids = @constCast(&[_][]const u8{"trust_root"}),
        .disposition_change_ids = @constCast(&[_][]const u8{"disp_root"}),
        .delivered_mailbox_id = "missing_mail",
        .title = "Test Dream",
        .text = "A test dream.",
        .created_at_ms = 1000,
    }});
    try std.testing.expectError(error.UnknownDreamTimeMailboxId, persistence.validateCognitiveFile(data));

    data = integrityFixture();
    data.mailbox_items = @constCast(&[_]schema.MailboxItem{.{
        .mailbox_id = "mail_root",
        .kind = .DreamMail,
        .title = "Test Dream",
        .text = "A test dream.",
        .source_event_ids = @constCast(&[_][]const u8{"evt_root"}),
        .source_dream_id = "missing_dream",
        .created_at_ms = 1000,
    }});
    try std.testing.expectError(error.UnknownMailboxDreamId, persistence.validateCognitiveFile(data));
}

test "cognitive enum diagnostic reports invalid tag path and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diagnostic = (try json_store.cognitiveEnumDiagnosticAlloc(allocator,
        \\{
        \\  "traces": [
        \\    {
        \\      "trace_id": "trace_bad_kind",
        \\      "source": "human",
        \\      "kind": "legacy_feeling",
        \\      "text": "hello",
        \\      "lifecycle": {
        \\        "created_at": "1",
        \\        "updated_at": "1"
        \\      }
        \\    }
        \\  ],
        \\  "beliefs": [],
        \\  "subjects": [],
        \\  "artifacts": [],
        \\  "dreams": []
        \\}
    )).?;
    defer diagnostic.deinit(allocator);

    try std.testing.expectEqualStrings("traces[0].kind", diagnostic.path);
    try std.testing.expectEqualStrings("legacy_feeling", diagnostic.value);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.allowed, "perception") != null);
}

test "sqlite memory store persists memory and fact through canonical methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_cognitive_roundtrip.sqlite";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};

    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path);
    const store = impl.store();
    try store.saveMemoryRecord(.{
        .memory_id = "memory_vector",
        .scope = .long_term,
        .text = "Plants need water",
        .interpretation = "Plants need water",
        .vector = @constCast(&[_]f32{0.25} ** 64),
        .tags = @constCast(&[_][]const u8{"plants"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 2,
        .score = 5,
    });
    try store.saveFactRecord(.{
        .fact_id = "fact_name",
        .key = "name",
        .value = "Otto",
        .confidence = 0.95,
        .source = "test",
        .tags = @constCast(&[_][]const u8{ "identity", "self" }),
        .created_at = "1000",
        .updated_at = "1000",
    });
    try std.testing.expect(try store.invalidateFactRecord("fact_name", "1001"));

    var reloaded_impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path);
    const memories = try reloaded_impl.store().loadMemoryRecords(allocator);
    const facts = try reloaded_impl.store().loadFactRecords(allocator);
    try std.testing.expectEqual(@as(usize, 1), memories.len);
    try std.testing.expectEqualStrings("memory_vector", memories[0].memory_id);
    try std.testing.expectEqual(@as(usize, 64), memories[0].vector.len);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    try std.testing.expect(!facts[0].active);
    try std.testing.expectEqualStrings("1001", facts[0].updated_at);
}

test "sqlite memory store creates retained capture directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_retain_capture.sqlite";
    const source_path = "data/test/json_store_retain_capture.jpg";
    const test_capture_dir = "data/test/retain_capture/captures";
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/activation_{s}", .{ test_capture_dir, std.fs.path.basename(source_path) });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, source_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, expected_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source_path, .data = "capture-bytes", .flags = .{ .truncate = true } });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, source_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, expected_path) catch {};

    var impl = JsonMemoryStore.initWithCaptureDir(allocator, std.testing.io, memory_path, test_capture_dir);
    const retained = try impl.store().retainCapture(allocator, source_path, "activation");
    try std.testing.expectEqualStrings(expected_path, retained);
    const bytes = try readFileAllocPath(std.testing.io, retained, allocator, .limited(1024));
    try std.testing.expectEqualStrings("capture-bytes", bytes);
}

test "sqlite memory store gives unreferenced captures one dream grace sweep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_capture_sweep.sqlite";
    const test_capture_dir = "data/test/captures";
    const orphan_path = "data/test/captures/json_store_orphan.jpg";
    const orphan_marker = "data/test/captures/json_store_orphan.jpg.delete";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, test_capture_dir);
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, orphan_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, orphan_marker) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, orphan_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, orphan_marker) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = orphan_path, .data = "orphan", .flags = .{ .truncate = true } });
    var impl = JsonMemoryStore.initWithCaptureDir(allocator, std.testing.io, memory_path, test_capture_dir);
    const store = impl.store();
    try std.testing.expectEqual(@as(usize, 0), try store.sweepUnreferencedCaptures());
    try std.testing.expectEqual(@as(usize, 1), try store.sweepUnreferencedCaptures());
}

test "sqlite memory store tombstones unreferenced cognitive records across dreamtime passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_cognitive_prune.sqlite";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path);
    const store = impl.store();
    try store.addArtifact(.{
        .artifact_id = "artifact_orphan",
        .kind = .image,
        .path = "data/test/captures/json_store_orphan_artifact.jpg",
        .mime_type = "image/jpeg",
        .provenance = "test",
        .retention = .episode,
        .lifecycle = .{ .created_at = "1", .updated_at = "1" },
    });
    const first = try store.pruneTombstonedCognitiveRecords("2");
    try std.testing.expectEqual(@as(usize, 1), first.tombstoned);
    try std.testing.expectEqual(@as(usize, 0), first.purged);
    const artifacts_after_first = try store.loadArtifacts(allocator);
    try std.testing.expectEqual(@as(usize, 1), artifacts_after_first.len);
    try std.testing.expectEqual(schema.CognitiveStatus.pending_deletion, artifacts_after_first[0].lifecycle.status);

    const second = try store.pruneTombstonedCognitiveRecords("3");
    try std.testing.expectEqual(@as(usize, 0), second.tombstoned);
    try std.testing.expectEqual(@as(usize, 1), second.purged);
    const artifacts_after_second = try store.loadArtifacts(allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts_after_second.len);
}

test "json memory store keeps one cached cognitive file across repeated mutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/json_store_cached_mutations.sqlite";
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};

    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path);
    const store = impl.store();
    try store.upsertHostBinding(.{
        .host_id = "core",
        .platform = "core",
        .attached_at_ms = 1,
    });
    var i: usize = 0;
    while (i < 48) : (i += 1) {
        const id = try std.fmt.allocPrint(allocator, "cached_event_{d}", .{i});
        try store.addExperienceEvent(.{
            .id = id,
            .brain_id = "default",
            .host_id = "core",
            .timestamp_ms = @intCast(i),
            .source = .system,
            .kind = "Test.CachedMutation",
            .payload = id,
            .salience = 0.1,
            .confidence = 0.9,
            .retention = .episode,
            .visibility = .internal,
        });
    }
    const events = try store.loadExperienceEvents(allocator);
    try std.testing.expectEqual(@as(usize, 48), events.len);
}
