const std = @import("std");
const json_store = @import("json_store.zig");
const persistence = @import("json_store_persistence.zig");
const schema = @import("schema.zig");
const json_fuzz = @import("../harness/json_fuzz.zig");

const JsonMemoryStore = json_store.JsonMemoryStore;

fn loadFromRawJson(allocator: std.mem.Allocator, memory_path: []const u8, raw_json: []const u8) ![]schema.ExperienceEvent {
    std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};
    try persistence.writeRawCognitiveJsonForTest(allocator, std.testing.io, memory_path, raw_json);
    var impl = JsonMemoryStore.init(allocator, std.testing.io, memory_path);
    return impl.store().loadExperienceEvents(allocator);
}

test "cognitive store load rejects corrupted persisted json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory_path = "data/test/json_store_fuzz_corrupt.sqlite";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};

    const corpus = [_][]const u8{
        "",
        "\x00\xff\xfe",
        "not json at all",
        "null",
        "[]",
        "42",
        "\"cognitive\"",
        "{\"events\":42}",
        "{\"events\":[42]}",
        "{\"events\":[{\"id\":7}]}",
        "{\"events\":[{\"id\":\"evt\",\"brain_id\":\"b\",\"host_id\":\"h\",\"timestamp_ms\":\"soon\",\"source\":\"user\",\"kind\":\"k\",\"payload\":\"p\"}]}",
        "{\"events\":[{\"id\":\"evt\",\"brain_id\":\"b\",\"host_id\":\"h\",\"timestamp_ms\":1,\"source\":\"not_a_source\",\"kind\":\"k\",\"payload\":\"p\"}]}",
        "{\"memories\":[{\"memory_id\":\"m\",\"scope\":\"galactic\"}]}",
    };
    for (corpus) |raw_json| {
        const result = loadFromRawJson(allocator, memory_path, raw_json);
        try std.testing.expect(std.meta.isError(result));
    }
}

test "cognitive store load survives mutated persisted json" {
    var prng = std.Random.DefaultPrng.init(0x73746f7265);
    const random = prng.random();
    const memory_path = "data/test/json_store_fuzz_mutated.sqlite";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, memory_path) catch {};

    // Start from a real persisted document so mutations hit deep parse paths.
    var seed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer seed_arena.deinit();
    const seed_allocator = seed_arena.allocator();
    const valid_json = try std.json.Stringify.valueAlloc(seed_allocator, validCognitiveFile(), .{ .whitespace = .indent_2 });

    // The unmutated document must round-trip.
    {
        const events = try loadFromRawJson(seed_allocator, memory_path, valid_json);
        try std.testing.expectEqual(@as(usize, 1), events.len);
    }

    var iteration: usize = 0;
    while (iteration < 64) : (iteration += 1) {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const corrupted = try json_fuzz.mutate(allocator, random, valid_json);
        // Any outcome is fine except a crash; a load that still succeeds must
        // carry well-formed events.
        const events = loadFromRawJson(allocator, memory_path, corrupted) catch continue;
        for (events) |event| try std.testing.expect(event.id.len <= corrupted.len);
    }
}

fn validCognitiveFile() schema.CognitiveFile {
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
    };
}
