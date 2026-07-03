const std = @import("std");
const brain_dream_memory = @import("../core/brain_dream_memory.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");

pub const dreamImagePrompt = brain_dream_memory.dreamImagePrompt;

fn joinSymbols(allocator: std.mem.Allocator, symbols: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, ", ", symbols);
}

fn llmTesterDreamImagePrompt(
    allocator: std.mem.Allocator,
    visual_style: []const u8,
    symbols: []const []const u8,
    seed: ?[]const u8,
) ![]const u8 {
    const connection = try joinSymbols(allocator, symbols);
    defer allocator.free(connection);
    return dreamImagePrompt(allocator, visual_style, connection, seed);
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const first_prompt = try llmTesterDreamImagePrompt(
        allocator,
        "soft cinematic illustration",
        &[_][]const u8{ "recognition", "threads", "windows", "small lanterns" },
        null,
    );
    errdefer allocator.free(first_prompt);

    const seeded_prompt = try llmTesterDreamImagePrompt(
        allocator,
        "moody cinematic illustration",
        &[_][]const u8{"recognition"},
        "dim hallway recognition uncertainty",
    );
    errdefer allocator.free(seeded_prompt);

    const failure_residue_prompt = try llmTesterDreamImagePrompt(
        allocator,
        "moody cinematic illustration",
        &[_][]const u8{ "recognize", "recognition" },
        null,
    );
    errdefer allocator.free(failure_residue_prompt);

    var out = try allocator.alloc(llm_tester_scenario.Scenario, 3);
    errdefer {
        for (out) |scenario| scenario.deinit(allocator);
        allocator.free(out);
    }

    out[0] = try llm_tester_scenario.Scenario.init(
        allocator,
        "dream_image_first_period",
        "Dream image after first waking period",
        "Expected: Gemini image generation succeeds for a soft-cinematic dream prompt built from day-residue symbols with no explicit dream seed.",
        "dream_image",
        "",
        first_prompt,
        .image_generation,
        "",
        0,
        0,
    );
    out[1] = try llm_tester_scenario.Scenario.init(
        allocator,
        "dream_image_with_seed",
        "Dream image with explicit dream seed",
        "Expected: Gemini image generation succeeds when the dream prompt includes an explicit seed plus associated memory symbols.",
        "dream_image",
        "",
        seeded_prompt,
        .image_generation,
        "",
        0,
        0,
    );
    out[2] = try llm_tester_scenario.Scenario.init(
        allocator,
        "dream_image_failure_residue",
        "Dream image after capability failure residue",
        "Expected: Gemini image generation succeeds for a moody prompt built from overnight capability failures and memory tags.",
        "dream_image",
        "",
        failure_residue_prompt,
        .image_generation,
        "",
        0,
        0,
    );
    return out;
}

test "dreamImagePrompt includes being framing and no-text constraint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prompt = try dreamImagePrompt(arena.allocator(), "soft cinematic illustration", "recognition, threads", null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "being") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "No text, captions, UI, or labels") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "recognition, threads") != null);
}

test "dreamImagePrompt includes dream seed when provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prompt = try dreamImagePrompt(
        arena.allocator(),
        "moody cinematic illustration",
        "recognition",
        "dim hallway recognition uncertainty",
    );
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Visualize this dream seed: dim hallway recognition uncertainty") != null);
}

test "llmTesterScenarios returns dream_image generation cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scenarios = try llmTesterScenarios(allocator);
    defer llm_tester_scenario.freeScenarios(allocator, scenarios);
    try std.testing.expectEqual(@as(usize, 3), scenarios.len);
    for (scenarios) |item| {
        try std.testing.expectEqualStrings("dream_image", item.subsystem);
        try std.testing.expectEqual(llm_tester_scenario.ResponseFormat.image_generation, item.response_format);
        try std.testing.expect(item.user_prompt.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, item.user_prompt, "being") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, scenarios[1].user_prompt, "Visualize this dream seed:") != null);
}
