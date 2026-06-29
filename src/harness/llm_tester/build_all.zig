const std = @import("std");
const scenario_mod = @import("scenario.zig");
const chat_client = @import("../../api/chat_client.zig");
const autonomy_client = @import("../../api/autonomy_client.zig");
const extraction_client = @import("../../api/extraction_client.zig");
const psyche_client = @import("../../api/psyche_client.zig");
const want_achievement_client = @import("../../api/want_achievement_client.zig");
const persona_directive_client = @import("../../api/persona_directive_client.zig");
const process_composition_client = @import("../../api/process_composition_client.zig");
const openai_identity_client = @import("../../api/openai_identity_client.zig");

pub const Scenario = scenario_mod.Scenario;

const ScenarioSource = struct {
    name: []const u8,
    loadFn: *const fn (std.mem.Allocator) anyerror![]Scenario,
};

const sources = [_]ScenarioSource{
    .{ .name = "conversation", .loadFn = chat_client.llmTesterScenarios },
    .{ .name = "autonomy", .loadFn = autonomy_client.llmTesterScenarios },
    .{ .name = "memory_extraction", .loadFn = extraction_client.llmTesterScenarios },
    .{ .name = "psyche", .loadFn = psyche_client.llmTesterScenarios },
    .{ .name = "want_achievement", .loadFn = want_achievement_client.llmTesterScenarios },
    .{ .name = "persona_directive", .loadFn = persona_directive_client.llmTesterScenarios },
    .{ .name = "process_composition", .loadFn = process_composition_client.llmTesterScenarios },
    .{ .name = "identity_comparison", .loadFn = openai_identity_client.llmTesterScenarios },
};

const ScenarioWire = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    subsystem: []const u8,
    system_prompt: []const u8,
    user_prompt: []const u8,
    response_format: []const u8,
    json_schema: []const u8,
    max_tokens: u32,
    temperature: f32,
};

const ManifestWire = struct {
    generated_at: []const u8,
    scenarios: []ScenarioWire,
};

pub fn buildAllScenarios(allocator: std.mem.Allocator) ![]Scenario {
    var out = std.ArrayList(Scenario).empty;
    for (sources) |source| {
        const batch = try source.loadFn(allocator);
        try out.appendSlice(allocator, batch);
        allocator.free(batch);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn manifestJson(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const scenarios = try buildAllScenarios(allocator);
    defer scenario_mod.freeScenarios(allocator, scenarios);

    const generated_at = try generatedAtIso8601(allocator, io);
    defer allocator.free(generated_at);

    const wire_scenarios = try allocator.alloc(ScenarioWire, scenarios.len);
    defer allocator.free(wire_scenarios);
    for (scenarios, 0..) |item, index| {
        wire_scenarios[index] = .{
            .id = item.id,
            .label = item.label,
            .description = item.description,
            .subsystem = item.subsystem,
            .system_prompt = item.system_prompt,
            .user_prompt = item.user_prompt,
            .response_format = item.response_format.wireName(),
            .json_schema = item.json_schema,
            .max_tokens = item.max_tokens,
            .temperature = item.temperature,
        };
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(
        ManifestWire{
            .generated_at = generated_at,
            .scenarios = wire_scenarios,
        },
        .{},
        &out.writer,
    );
    return try allocator.dupe(u8, out.written());
}

fn generatedAtIso8601(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const unix_seconds = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
    const epoch_day = epoch.getEpochDay();
    const day_seconds = epoch.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

test "buildAllScenarios covers every text subsystem with non-empty prompts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scenarios = try buildAllScenarios(allocator);
    try std.testing.expect(scenarios.len >= 9);

    var ids = std.StringHashMap(void).init(allocator);
    for (scenarios) |item| {
        try std.testing.expect(item.id.len > 0);
        try std.testing.expect(item.label.len > 0);
        try std.testing.expect(item.description.len > 0);
        try std.testing.expect(item.subsystem.len > 0);
        try std.testing.expect(item.system_prompt.len > 0);
        try std.testing.expect(item.user_prompt.len > 0);
        try std.testing.expect(item.json_schema.len > 0);
        try ids.put(item.id, {});
    }
    try std.testing.expectEqual(scenarios.len, ids.count());
}

test "manifestJson emits parseable JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var io_threaded: std.Io.Threaded = .init_single_threaded;
    const json = try manifestJson(allocator, io_threaded.io());
    const parsed = try std.json.parseFromSlice(
        struct {
            generated_at: []const u8,
            scenarios: []struct {
                id: []const u8,
                label: []const u8,
                description: []const u8,
                subsystem: []const u8,
                system_prompt: []const u8,
                user_prompt: []const u8,
                response_format: []const u8,
                json_schema: []const u8,
                max_tokens: u32,
                temperature: f32,
            },
        },
        allocator,
        json,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.scenarios.len >= 12);
    try std.testing.expect(parsed.value.generated_at.len > 0);
    try std.testing.expect(parsed.value.scenarios[0].label.len > 0);
    try std.testing.expect(parsed.value.scenarios[0].description.len > 0);
}
