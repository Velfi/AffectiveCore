const std = @import("std");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const openai = ports.openai;
const input_mod = ports.input;
const json_store = @import("../storage/json_store.zig");
const conversation_context = @import("conversation_context.zig");

const TestStore = store_support.TestStore;
const JsonMemoryStore = json_store.JsonMemoryStore;
const makeBrainWithMemoryStore = support.makeBrainWithMemoryStore;

const scale_memory_count: usize = 1000;
const scale_event_count: usize = 2000;
const scale_test_root = "data/test/crash_prevention_scale";
const slice_test_root = "data/test/crash_prevention_slice_lifetime";

fn prepareJsonStoreTestDir(io: std.Io, root: []const u8, memory_path: []const u8) !void {
    _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    std.Io.Dir.cwd().deleteFile(io, memory_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn seedScaledCognitiveStore(allocator: std.mem.Allocator, store: ports.store.MemoryStore) !void {
    try store.upsertHostBinding(.{
        .host_id = "core",
        .platform = "test",
        .attached_at_ms = 1_000,
    });
    try store.beginDeferredPersist();
    defer store.endDeferredPersist() catch unreachable;

    var i: usize = 0;
    while (i < scale_event_count) : (i += 1) {
        const event_id = try std.fmt.allocPrint(allocator, "evt_scale_{d}", .{i});
        defer allocator.free(event_id);
        try store.addExperienceEvent(.{
            .id = event_id,
            .host_id = "core",
            .timestamp_ms = @intCast(1_000_000 + i),
            .source = .user,
            .kind = "User.TextReceived",
            .payload = "seed event",
        });
    }

    i = 0;
    while (i < scale_memory_count) : (i += 1) {
        const memory_id = try std.fmt.allocPrint(allocator, "mem_scale_{d}", .{i});
        defer allocator.free(memory_id);
        const text = try std.fmt.allocPrint(allocator, "Memory topic {d} about greetings and Geisha recognition", .{i});
        defer allocator.free(text);
        try store.saveMemoryRecord(.{
            .memory_id = memory_id,
            .scope = .long_term,
            .text = text,
            .interpretation = text,
            .tags = &.{},
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = @intCast(i % 16 + 1),
        });
    }
}

fn seedSliceLifetimeStore(allocator: std.mem.Allocator, store: ports.store.MemoryStore) !void {
    try store.upsertHostBinding(.{
        .host_id = "core",
        .platform = "test",
        .attached_at_ms = 1_000,
    });
    try store.beginDeferredPersist();
    defer store.endDeferredPersist() catch unreachable;

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const event_id = try std.fmt.allocPrint(allocator, "evt_slice_{d}", .{i});
        defer allocator.free(event_id);
        try store.addExperienceEvent(.{
            .id = event_id,
            .host_id = "core",
            .timestamp_ms = @intCast(2_000_000 + i),
            .source = .user,
            .kind = "User.TextReceived",
            .payload = "slice lifetime seed",
        });
    }

    i = 0;
    while (i < 64) : (i += 1) {
        const memory_id = try std.fmt.allocPrint(allocator, "mem_slice_{d}", .{i});
        defer allocator.free(memory_id);
        const text = try std.fmt.allocPrint(allocator, "Geisha greeting memory {d} with recognition context", .{i});
        defer allocator.free(text);
        try store.saveMemoryRecord(.{
            .memory_id = memory_id,
            .scope = .long_term,
            .text = text,
            .interpretation = text,
            .tags = &.{},
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = @intCast(i % 8 + 1),
        });
    }
}

test "scale sqlite user_text compose path survives heavy memory store" {
    const io = std.testing.io;
    const memory_path = scale_test_root ++ "/memory/people.sqlite";
    try prepareJsonStoreTestDir(io, scale_test_root, memory_path);
    defer _ = std.Io.Dir.cwd().deleteTree(io, scale_test_root) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var json_impl = JsonMemoryStore.init(allocator, io, memory_path);
    const store = json_impl.store();
    try seedScaledCognitiveStore(allocator, store);

    const loaded = try store.loadMemoryRecords(allocator);
    try std.testing.expect(loaded.len >= scale_memory_count);

    var aux = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrainWithMemoryStore(allocator, "fixtures/visitors/known_01.jpg", &.{}, store, &aux, &desc, null);

    const selection = try brain.selectConversationMemories("Hello Geisha");
    defer {
        brain.allocator.free(selection.summary);
        for (selection.entries) |entry| {
            brain.allocator.free(entry.memory_id);
            brain.allocator.free(entry.reason);
            brain.allocator.free(entry.interpretation);
        }
        brain.allocator.free(selection.entries);
    }
    try std.testing.expect(selection.entries.len > 0);

    const memory_blocks = try brain.buildConversationMemoryBlocks(null, selection, .heard_speech);
    defer conversation_context.freeMemoryBlocks(brain.allocator, memory_blocks);
    try std.testing.expect(memory_blocks.len > 0);

    const turn_event = try brain.recordSimpleExperienceEvent("User.TextReceived", .user, "Hello Geisha");
    brain.current_turn_event_id = turn_event.id;
    defer brain.current_turn_event_id = null;

    const observation_blocks = try conversation_context.composeObservations(
        &brain,
        conversation_context.heardSpeechComposeOptions(
            &brain,
            try input_mod.HeardSpeech.typed(allocator, "Hello Geisha"),
            null,
            selection,
            false,
            false,
        ),
    );
    defer conversation_context.freeObservationBlocks(brain.allocator, observation_blocks);
    try std.testing.expect(observation_blocks.len > 0);
}

test "sqlite store slice lifetime survives touchSelectedMemory selections" {
    const io = std.testing.io;
    const memory_path = slice_test_root ++ "/memory/people.sqlite";
    try prepareJsonStoreTestDir(io, slice_test_root, memory_path);
    defer _ = std.Io.Dir.cwd().deleteTree(io, slice_test_root) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var json_impl = JsonMemoryStore.init(allocator, io, memory_path);
    const store = json_impl.store();
    try seedSliceLifetimeStore(allocator, store);

    const memories = try store.loadMemoryRecords(allocator);
    try std.testing.expect(memories.len >= 64);
    const memory_count_before_append = memories.len;

    var pre_touch_copies = std.ArrayList([]const u8).empty;
    defer {
        for (pre_touch_copies.items) |copy| allocator.free(copy);
        pre_touch_copies.deinit(allocator);
    }
    for (memories) |memory| {
        const copy = try allocator.dupe(u8, memory.interpretation);
        try pre_touch_copies.append(allocator, copy);
    }

    var aux = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrainWithMemoryStore(allocator, "fixtures/visitors/known_01.jpg", &.{}, store, &aux, &desc, null);

    const selection = try brain.selectConversationMemories("Hello Geisha");
    defer {
        brain.allocator.free(selection.summary);
        for (selection.entries) |entry| {
            brain.allocator.free(entry.memory_id);
            brain.allocator.free(entry.reason);
            brain.allocator.free(entry.interpretation);
        }
        brain.allocator.free(selection.entries);
    }
    try std.testing.expect(selection.entries.len > 0);

    for (pre_touch_copies.items, memories) |copy, memory| {
        try std.testing.expectEqualStrings(copy, memory.interpretation);
    }

    for (selection.entries) |entry| {
        try std.testing.expect(entry.interpretation.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, entry.interpretation, "Geisha") != null or
            std.mem.indexOf(u8, entry.interpretation, "greeting") != null or
            std.mem.indexOf(u8, entry.interpretation, "recognition") != null);
    }

    const append_text = try allocator.dupe(u8, "append path invalidates prior loadMemoryRecords borrow");
    try store.saveMemoryRecord(.{
        .memory_id = "mem_slice_append_only",
        .scope = .long_term,
        .text = append_text,
        .interpretation = append_text,
        .tags = &.{},
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
    });
    const reloaded = try store.loadMemoryRecords(allocator);
    try std.testing.expect(reloaded.len == memory_count_before_append + 1);
}

const manifest_capability_ids = [_][]const u8{
    "text_input",
    "speech_input",
    "speech_output",
    "take_picture",
    "microphone_capture",
    "orientation_read",
    "request_orientation",
    "motion_gesture_read",
    "recall_fact",
    "set_fact",
    "stored_memory_read",
    "stored_memory_write",
    "reminder_read",
    "reminder_write",
    "reminder_io",
    "notification_schedule",
    "uploaded_media_read",
    "stored_image_read",
    "face_identification",
    "identity_recognition",
    "face_enrollment",
    "update_face_picture",
    "facial_expression_output",
    "event_envelope",
    "event_drain",
    "sense_catalog",
    "sense_status",
    "sense_observation",
    "time_lookup",
    "power_status",
    "storage_fullness",
    "database_stats",
    "introspection",
    "local_process_io",
    "file_import",
    "file_export",
    "import_brain",
    "export_brain",
    "imagine_image",
    "provider_image_generation",
    "provider_vision_completion",
    "provider_text_completion",
};

test "host capability digest survives full manifest and re-upsert" {
    const io = std.testing.io;
    const root = "data/test/crash_prevention_manifest_digest";
    const memory_path = root ++ "/memory/people.sqlite";
    try prepareJsonStoreTestDir(io, root, memory_path);
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var json_impl = JsonMemoryStore.init(allocator, io, memory_path);
    const store = json_impl.store();
    try store.upsertHostBinding(.{
        .host_id = "macos-host",
        .platform = "macos",
        .attached_at_ms = 1_000,
    });

    var aux = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrainWithMemoryStore(allocator, "fixtures/visitors/known_01.jpg", &.{}, store, &aux, &desc, null);
    brain.now_seconds = 1_782_000_000;

    _ = try brain.recordManifestStatuses("macos-host", manifest_capability_ids[0..]);
    _ = try brain.recordManifestStatuses("macos-host", manifest_capability_ids[0..]);

    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(allocator);
    try brain.appendHostCapabilityObservationIfChanged(&observations);
    try std.testing.expect(observations.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "host_capability_summary:") != null);
}

test "full compose observations after double manifest on json store" {
    const io = std.testing.io;
    const root = "data/test/crash_prevention_compose_manifest";
    const memory_path = root ++ "/memory/people.sqlite";
    try prepareJsonStoreTestDir(io, root, memory_path);
    defer _ = std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var json_impl = JsonMemoryStore.init(allocator, io, memory_path);
    const store = json_impl.store();
    try seedSliceLifetimeStore(allocator, store);
    try store.upsertHostBinding(.{
        .host_id = "macos-host",
        .platform = "macos",
        .attached_at_ms = 1_000,
    });

    var aux = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrainWithMemoryStore(allocator, "fixtures/visitors/known_01.jpg", &.{}, store, &aux, &desc, null);
    brain.now_seconds = 1_782_000_000;

    _ = try brain.recordManifestStatuses("macos-host", manifest_capability_ids[0..]);
    _ = try brain.recordManifestStatuses("macos-host", manifest_capability_ids[0..]);

    const selection = try brain.selectConversationMemories("Hello Geisha");
    defer {
        brain.allocator.free(selection.summary);
        for (selection.entries) |entry| {
            brain.allocator.free(entry.memory_id);
            brain.allocator.free(entry.reason);
            brain.allocator.free(entry.interpretation);
        }
        brain.allocator.free(selection.entries);
    }
    try std.testing.expect(selection.entries.len > 0);

    const memory_blocks = try brain.buildConversationMemoryBlocks(null, selection, .heard_speech);
    defer conversation_context.freeMemoryBlocks(brain.allocator, memory_blocks);

    const turn_event = try brain.recordSimpleExperienceEvent("User.TextReceived", .user, "Hello Geisha");
    brain.current_turn_event_id = turn_event.id;
    defer brain.current_turn_event_id = null;

    const observation_blocks = try conversation_context.composeObservations(
        &brain,
        conversation_context.heardSpeechComposeOptions(
            &brain,
            try input_mod.HeardSpeech.typed(allocator, "Hello Geisha"),
            null,
            selection,
            false,
            false,
        ),
    );
    defer conversation_context.freeObservationBlocks(brain.allocator, observation_blocks);
    try std.testing.expect(observation_blocks.len > 0);
}
