const std = @import("std");
const llm_routing = @import("llm_routing.zig");
const chat = @import("port_chat.zig");
const chat_client = @import("../api/chat_client.zig");
const config_files = @import("config_files.zig");

test "parseLlmConfig loads tier-tagged roster" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{
        \\  "llm_quality": "best",
        \\  "models": [
        \\    {"provider": "openai", "model": "gpt-4.1-nano", "tier": "basic"},
        \\    {"provider": "openai", "model": "gpt-4.1-mini", "tier": "standard"},
        \\    {"provider": "openai", "model": "gpt-4.1", "tier": "complex"}
        \\  ]
        \\}
    ;
    var loaded = try config_files.parseLlmConfig(allocator, json);
    defer loaded.deinit(allocator);
    try std.testing.expectEqualStrings("best", loaded.llm_quality.?);
    try std.testing.expectEqual(@as(usize, 3), loaded.conversation_roster.entries.len);
    try std.testing.expectEqual(llm_routing.EffortTier.complex, loaded.conversation_roster.entries[2].tier);
}

test "legacy flat roster defaults every model to basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{
        \\  "models": [
        \\    {"provider": "openai", "model": "gpt-4.1-nano"},
        \\    {"provider": "anthropic", "model": "claude-haiku-4-5-20251001"}
        \\  ]
        \\}
    ;
    var loaded = try config_files.parseLlmConfig(allocator, json);
    defer loaded.deinit(allocator);
    for (loaded.conversation_roster.entries) |entry| {
        try std.testing.expectEqual(llm_routing.EffortTier.basic, entry.tier);
    }
}

test "applyQualityPolicy clamps frugal tier and reasoning" {
    const turn = chat_client.applyQualityPolicy(.frugal, .{
        .action_pressures = &.{},
        .user_summary = "u",
        .brain_summary = "b",
        .reasoning_effort = .high,
        .effort_tier = .complex,
        .turn_complete = true,
    });
    try std.testing.expectEqual(chat.EffortTier.basic, turn.effort_tier.?);
    try std.testing.expectEqual(chat.ReasoningEffort.low, turn.reasoning_effort.?);
}

test "tiered roster missing standard tier fails loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json =
        \\{
        \\  "models": [
        \\    {"provider": "openai", "model": "gpt-4.1-nano", "tier": "basic"},
        \\    {"provider": "openai", "model": "gpt-4.1", "tier": "complex"}
        \\  ]
        \\}
    ;
    const err = config_files.parseLlmConfig(allocator, json);
    try std.testing.expectError(error.MissingLlmTierModels, err);
}
