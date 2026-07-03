const std = @import("std");
const context_composition = @import("context_composition.zig");
const chat = @import("port_chat.zig");
const context_tokens = @import("context_tokens.zig");
const want_port = @import("port_want_achievement.zig");
const memory_types = @import("actors/memory/types.zig");

test "auditMarkedSections splits observation headers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const observations =
        \\user_text:
        \\- source: typed_text
        \\social_context:
        \\- already_in_conversation: true
        \\unlabeled tail
    ;
    const sections = try context_composition.auditMarkedSections(allocator, observations, &context_composition.observation_section_markers);
    try std.testing.expectEqual(@as(usize, 2), sections.len);
    try std.testing.expectEqualStrings("observations.user_text", sections[0].name);
    try std.testing.expectEqualStrings("observations.social_context", sections[1].name);
    try std.testing.expect(sections[1].bytes > 0);
    try std.testing.expectEqual(context_composition.sumSections(sections), observations.len);
}

test "auditConversationPrompt totals match auditChatPrompt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const memory = "focus block\nMemory index: 1 long-term, 0 short-term.";
    const memory_sections = [_]context_composition.SectionStat{
        .{ .name = "focus", .bytes = 11 },
        .{ .name = "memory_index", .bytes = memory.len - 11, .count = 1 },
    };
    const user_text = "hello";
    const observations = "user_text:\n- source: typed_text\nsocial_context:\n- already_in_conversation: false\n";

    const prompt_audit = try chat.auditChatPrompt(allocator, memory, user_text, observations, .heard_speech);
    const report = try context_composition.auditConversationPrompt(allocator, memory, &memory_sections, user_text, observations, 0);

    try std.testing.expectEqual(prompt_audit.system_prompt_bytes, report.system_prompt_bytes);
    try std.testing.expectEqual(prompt_audit.compact_memory_bytes, report.compact_memory_bytes);
    try std.testing.expectEqual(prompt_audit.observations_bytes, report.observations_bytes);
    try std.testing.expectEqual(prompt_audit.user_prompt_bytes, report.user_prompt_bytes);
    try std.testing.expectEqual(prompt_audit.user_prompt_bytes + prompt_audit.system_prompt_bytes, report.total_bytes);
}

test "auditConversationPrompt section names outlive prefixed memory frees" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const memory_sections = [_]context_composition.SectionStat{
        .{ .name = "focus", .bytes = 11 },
    };
    const report = try context_composition.auditConversationPrompt(
        allocator,
        "focus block",
        &memory_sections,
        "hi",
        "user_text:\n- source: typed_text\n",
        0,
    );

    var found_focus: bool = false;
    for (report.sections) |section| {
        if (std.mem.eql(u8, section.name, "compact_memory.focus")) found_focus = true;
    }
    try std.testing.expect(found_focus);
}

test "ownedTopSections caps and sorts by bytes" {
    const sections = [_]context_composition.SectionStat{
        .{ .name = "small", .bytes = 10 },
        .{ .name = "large", .bytes = 100 },
        .{ .name = "medium", .bytes = 50 },
    };
    const top = try context_composition.ownedTopSections(std.testing.allocator, &sections, 2);
    defer {
        for (top) |section| std.testing.allocator.free(section.name);
        std.testing.allocator.free(top);
    }
    try std.testing.expectEqual(@as(usize, 2), top.len);
    try std.testing.expectEqualStrings("large", top[0].name);
    try std.testing.expectEqualStrings("medium", top[1].name);
}

test "auditConversationPrompt succeeds when prompt exceeds budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const oversized = try allocator.alloc(u8, context_tokens.minBytesExceedingTokenBudget(chat.max_chat_context_tokens));
    @memset(oversized, 'x');

    const report = try context_composition.auditConversationPrompt(allocator, oversized, &.{}, "hello", "observations", 0);
    try std.testing.expectEqualStrings("conversation_chat", report.operation);
    try std.testing.expect(context_tokens.exceedsTokenBudget(oversized, chat.max_chat_context_tokens));
    try std.testing.expect(report.sections.len > 0);
}

test "operation auditors report expected sections" {
    const wants = [_]want_port.WantCandidate{
        .{
            .memory_id = "want_1",
            .text = "finish map",
            .interpretation = "map done",
            .goal_kind = .achievement,
            .fulfillment_criterion = "the gap described by \"finish map\" is materially closed in this event",
            .salience = 0.8,
            .confidence = 0.75,
            .score = 3,
        },
    };
    const want_report = context_composition.auditWantAchievement("The map is done.", &wants);
    try std.testing.expectEqual(@as(?usize, 1), want_report.sections[1].count);

    const retrieval = context_composition.auditMemoryRetrieval("garden", &[_]memory_types.RetrievalMatch{
        .{ .memory_id = "mem_1", .status = .active, .confidence = 0.9, .salience = 0.8, .text = "garden map" },
    });
    try std.testing.expectEqual(@as(?usize, 1), retrieval.sections[1].count);
}

test "memory section stats sum to memory length" {
    const memory = "aaa-bbb-ccc";
    const sections = [_]context_composition.SectionStat{
        .{ .name = "focus", .bytes = 3 },
        .{ .name = "self_facts", .bytes = 4 },
        .{ .name = "needs", .bytes = 4 },
    };
    try std.testing.expectEqual(memory.len, context_composition.sumSections(&sections));
}

test "sortBlocks orders by rank descending" {
    var blocks = [_]context_composition.ContextBlock{
        .{ .kind = .{ .observation = .read_models_snapshot }, .text = "low", .rank = 20, .protected = false, .order_index = 0 },
        .{ .kind = .{ .observation = .present_moment }, .text = "high", .rank = 100, .protected = true, .order_index = 1 },
    };
    context_composition.sortBlocks(&blocks);
    try std.testing.expectEqual(@as(u16, 100), blocks[0].rank);
}

test "trimToTokenBudget drops low rank sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory_blocks = [_]context_composition.ContextBlock{
        .{ .kind = .{ .memory = .focus }, .text = "focus block\n", .rank = 95, .protected = true, .order_index = 0 },
        .{ .kind = .{ .memory = .conversation_summaries }, .text = "Recent conversation summaries (chronological):\n- (1s ago) USER: \"long summary text that consumes budget\"\n  BRAIN: \"reply\"\n", .rank = 15, .protected = false, .order_index = 1 },
    };
    var observation_blocks = [_]context_composition.ContextBlock{
        .{ .kind = .{ .observation = .present_moment }, .text = "present_moment:\n- now\n", .rank = 100, .protected = true, .order_index = 2 },
        .{ .kind = .{ .observation = .read_models_snapshot }, .text = "read_models_snapshot:\n- I feel awake and present.\n- nothing stands out to me right now\n- No faculty feels especially trustworthy to me right now.\n- nothing stands out to me right now\n- Nothing has captured my focus yet.\n- nothing stands out to me right now\n- On this host, 0 senses feel reachable; 0 feel dulled or blocked.\n", .rank = 30, .protected = false, .order_index = 3 },
    };
    const trimmed = try context_composition.trimToTokenBudget(allocator, &memory_blocks, &observation_blocks, "hello", .heard_speech, 40);
    defer trimmed.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, trimmed.memory, "focus block") != null);
    try std.testing.expect(std.mem.indexOf(u8, trimmed.observations, "present_moment:") != null);
    try std.testing.expect(trimmed.dropped.len >= 1);
}

test "trimToTokenBudget fails when protected sections exceed budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const oversized = try allocator.alloc(u8, context_tokens.minBytesExceedingTokenBudget(100));
    @memset(oversized, 'x');
    var memory_blocks = [_]context_composition.ContextBlock{
        .{ .kind = .{ .memory = .focus }, .text = oversized, .rank = 95, .protected = true, .order_index = 0 },
    };
    try std.testing.expectError(error.ContextBudgetExceeded, context_composition.trimToTokenBudget(allocator, &memory_blocks, &[_]context_composition.ContextBlock{}, "hello", .heard_speech, 100));
}
