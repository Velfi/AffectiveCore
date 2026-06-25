const std = @import("std");
const json_store = @import("json_store.zig");
const persistence = @import("json_store_persistence.zig");

const JsonMemoryStore = json_store.JsonMemoryStore;
const current_schema_version = persistence.current_schema_version;
const readFileAllocPath = persistence.readFileAllocPath;
const writeRawCognitiveJsonForTest = persistence.writeRawCognitiveJsonForTest;

test "sqlite memory store creates empty v2 cognitive store when missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_v2_empty.sqlite";
    const events_path = "data/test/json_store_v2_empty_events.jsonl";
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path, events_path);
    const traces = try impl.store().loadTraces(allocator);
    try std.testing.expectEqual(@as(usize, 0), traces.len);
}

test "json memory store appends runtime event without reading oversized event log" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/json_store_large_events_memory.sqlite";
    const events_path = "data/test/json_store_large_events.jsonl";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};

    const large = try allocator.alloc(u8, 1024 * 1024 + 64);
    @memset(large, 'x');
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = events_path, .data = large, .flags = .{ .truncate = true } });

    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path, events_path);
    try impl.store().logEvent("{\"kind\":\"command_sent\",\"title\":\"introspect\"}");

    const bytes = try readFileAllocPath(std.testing.io, events_path, allocator, .limited(1024 * 1024 + 4096));
    try std.testing.expect(std.mem.endsWith(u8, bytes, "{\"kind\":\"command_sent\",\"title\":\"introspect\"}\n"));
    try std.testing.expect(bytes.len > 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "events_compacted") == null);
}

test "json memory store sweep keeps important runtime events when compacting event log" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/json_store_important_events_memory.sqlite";
    const events_path = "data/test/json_store_important_events.jsonl";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};

    var seed = std.ArrayList(u8).empty;
    try seed.appendSlice(allocator, "{\"kind\":\"error\",\"severity\":\"critical\",\"title\":\"keep_me\"}\n");
    for (0..25_000) |i| {
        try seed.print(allocator, "{{\"kind\":\"developer_log\",\"severity\":\"debug\",\"title\":\"drop_{d}\"}}\n", .{i});
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = events_path, .data = seed.items, .flags = .{ .truncate = true } });

    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path, events_path);
    try impl.store().logEvent("{\"kind\":\"command_sent\",\"title\":\"latest\"}");
    const dropped = try impl.store().sweepRuntimeEvents();
    try std.testing.expect(dropped > 0);

    const bytes = try readFileAllocPath(std.testing.io, events_path, allocator, .limited(1024 * 1024 + 4096));
    try std.testing.expect(bytes.len <= 1024 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"title\":\"keep_me\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"title\":\"latest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"title\":\"drop_0\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "events_compacted") != null);
}

test "sqlite memory store rejects old unversioned shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory_path = "data/test/sqlite_memory_old_shape.sqlite";
    const events_path = "data/test/json_store_old_shape_events.jsonl";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    try writeRawCognitiveJsonForTest(arena.allocator(), std.testing.io, memory_path, current_schema_version, "{\"memories\":[]}");
    var impl = JsonMemoryStore.init(arena.allocator(), std.testing.io, memory_path, events_path);
    try std.testing.expectError(error.MissingCognitiveSchemaVersion, impl.store().loadTraces(arena.allocator()));
}

test "sqlite memory store rejects unsupported cognitive schema version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory_path = "data/test/sqlite_memory_v1_shape.sqlite";
    const events_path = "data/test/json_store_v1_shape_events.jsonl";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    try writeRawCognitiveJsonForTest(arena.allocator(), std.testing.io, memory_path, 1, "{\"schema_version\":1,\"traces\":[],\"beliefs\":[]}");
    var impl = JsonMemoryStore.init(arena.allocator(), std.testing.io, memory_path, events_path);
    try std.testing.expectError(error.UnsupportedCognitiveSchemaVersion, impl.store().loadTraces(arena.allocator()));
}

test "sqlite memory store rejects malformed cognitive confidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const memory_path = "data/test/sqlite_memory_bad_confidence.sqlite";
    const events_path = "data/test/json_store_bad_confidence_events.jsonl";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    try writeRawCognitiveJsonForTest(arena.allocator(), std.testing.io, memory_path, current_schema_version, "{\"schema_version\":2,\"traces\":[{\"trace_id\":\"trace_bad\",\"source\":\"human\",\"kind\":\"perception\",\"text\":\"bad\",\"confidence\":1.5,\"lifecycle\":{\"created_at\":\"1\",\"updated_at\":\"1\"}}]}");
    var impl = JsonMemoryStore.init(arena.allocator(), std.testing.io, memory_path, events_path);
    try std.testing.expectError(error.InvalidConfidence, impl.store().loadTraces(arena.allocator()));
}

test "sqlite memory store tolerates additive cognitive fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_additive_fields.sqlite";
    const events_path = "data/test/json_store_additive_fields_events.jsonl";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    try writeRawCognitiveJsonForTest(allocator, std.testing.io, memory_path, current_schema_version,
        \\{
        \\  "schema_version": 2,
        \\  "future_top_level": true,
        \\  "traces": [
        \\    {
        \\      "trace_id": "trace_additive",
        \\      "source": "human",
        \\      "kind": "perception",
        \\      "text": "hello",
        \\      "future_trace_field": "ignored",
        \\      "lifecycle": {
        \\        "created_at": "1",
        \\        "updated_at": "1",
        \\        "future_lifecycle_field": "ignored"
        \\      }
        \\    }
        \\  ],
        \\  "beliefs": [],
        \\  "subjects": [],
        \\  "artifacts": [],
        \\  "dreams": []
        \\}
    );
    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path, events_path);

    const traces = try impl.store().loadTraces(allocator);

    try std.testing.expectEqual(@as(usize, 1), traces.len);
    try std.testing.expectEqualStrings("trace_additive", traces[0].trace_id);
}

test "cognitive enum diagnostic reports invalid tag path and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diagnostic = (try json_store.cognitiveEnumDiagnosticAlloc(allocator,
        \\{
        \\  "schema_version": 2,
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

test "sqlite memory store accepts pending deletion cognitive lifecycle status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_pending_deletion.sqlite";
    const events_path = "data/test/sqlite_memory_pending_deletion_events.jsonl";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    try writeRawCognitiveJsonForTest(allocator, std.testing.io, memory_path, current_schema_version,
        \\{
        \\  "schema_version": 2,
        \\  "traces": [
        \\    {
        \\      "trace_id": "trace_pending",
        \\      "source": "human",
        \\      "kind": "perception",
        \\      "text": "pending deletion trace",
        \\      "lifecycle": {
        \\        "status": "pending_deletion",
        \\        "created_at": "1",
        \\        "updated_at": "1",
        \\        "pending_deletion_at": "1",
        \\        "pending_deletion_reason": "test",
        \\        "pending_deletion_source": "test"
        \\      }
        \\    }
        \\  ],
        \\  "beliefs": [],
        \\  "subjects": [],
        \\  "artifacts": [],
        \\  "dreams": []
        \\}
    );
    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path, events_path);

    const traces = try impl.store().loadTraces(allocator);
    const memories = try impl.store().loadMemoryRecords(allocator);
    const impressions = try impl.store().loadImpressions(allocator);
    const experiences = try impl.store().loadExperiences(allocator);

    try std.testing.expectEqual(@as(usize, 1), traces.len);
    try std.testing.expectEqualStrings("trace_pending", traces[0].trace_id);
    try std.testing.expectEqual(@as(usize, 0), memories.len);
    try std.testing.expectEqual(@as(usize, 0), impressions.len);
    try std.testing.expectEqual(@as(usize, 0), experiences.len);
}

test "sqlite memory store persists trace and belief through compatibility methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_cognitive_roundtrip.sqlite";
    const events_path = "data/test/json_store_cognitive_roundtrip_events.jsonl";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};

    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path, events_path);
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

    var reloaded_impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path, events_path);
    const memories = try reloaded_impl.store().loadMemoryRecords(allocator);
    const facts = try reloaded_impl.store().loadFactRecords(allocator);
    try std.testing.expectEqual(@as(usize, 1), memories.len);
    try std.testing.expectEqualStrings("memory_vector", memories[0].memory_id);
    try std.testing.expectEqual(@as(usize, 64), memories[0].vector.len);
    try std.testing.expectEqual(@as(usize, 1), facts.len);
    try std.testing.expect(!facts[0].active);
    try std.testing.expectEqualStrings("1001", facts[0].invalidated_at.?);
}

test "sqlite memory store creates retained capture directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/sqlite_memory_retain_capture.sqlite";
    const events_path = "data/test/json_store_retain_capture_events.jsonl";
    const source_path = "data/test/json_store_retain_capture.jpg";
    const test_capture_dir = "data/test/retain_capture/captures";
    const expected_path = try std.fmt.allocPrint(allocator, "{s}/activation_{s}", .{ test_capture_dir, std.fs.path.basename(source_path) });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, source_path) catch {};
    std.Io.Dir.cwd().deleteFile(std.testing.io, expected_path) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = source_path, .data = "capture-bytes", .flags = .{ .truncate = true } });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, source_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, expected_path) catch {};

    var impl = JsonMemoryStore.initWithCaptureDir(allocator, std.testing.io, memory_path, events_path, test_capture_dir);
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
    const events_path = "data/test/json_store_capture_sweep_events.jsonl";
    const test_capture_dir = "data/test/captures";
    const orphan_path = "data/test/captures/json_store_orphan.jpg";
    const orphan_marker = "data/test/captures/json_store_orphan.jpg.delete";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, test_capture_dir);
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch |err| switch (err) {
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
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, events_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, orphan_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, orphan_marker) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = orphan_path, .data = "orphan", .flags = .{ .truncate = true } });
    var impl = JsonMemoryStore.initWithCaptureDir(allocator, std.testing.io, memory_path, events_path, test_capture_dir);
    const store = impl.store();
    try std.testing.expectEqual(@as(usize, 0), try store.sweepUnreferencedCaptures());
    try std.testing.expectEqual(@as(usize, 1), try store.sweepUnreferencedCaptures());
}
