const std = @import("std");
const context_composition = @import("context_composition.zig");
const chat = @import("port_chat.zig");
const context_tokens = @import("context_tokens.zig");
const greeting_port = @import("port_greeting.zig");
const intent_port = @import("port_intent.zig");
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

    const prompt_audit = try chat.auditChatPrompt(allocator, memory, user_text, observations);
    const report = try context_composition.auditConversationPrompt(allocator, memory, &memory_sections, user_text, observations, 0);

    try std.testing.expectEqual(prompt_audit.system_prompt_bytes, report.system_prompt_bytes);
    try std.testing.expectEqual(prompt_audit.compact_memory_bytes, report.compact_memory_bytes);
    try std.testing.expectEqual(prompt_audit.observations_bytes, report.observations_bytes);
    try std.testing.expectEqual(prompt_audit.user_prompt_bytes, report.user_prompt_bytes);
    try std.testing.expectEqual(prompt_audit.user_prompt_bytes + prompt_audit.system_prompt_bytes, report.total_bytes);
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
    const greeting = context_composition.auditGreetingContext(.{
        .visual_description = "bright room",
        .change_summary = "new haircut",
        .senses = "camera ok",
        .interior_state = "calm",
        .stable_notes = &[_][]const u8{"note"},
        .recent_notes = &.{},
    });
    try std.testing.expectEqual(@as(usize, 7), greeting.sections.len);
    try std.testing.expectEqualStrings("greeting", greeting.operation);

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

    const intent_report = context_composition.auditIntent(.identity_claim, "it is me, Mara");
    try std.testing.expectEqualStrings("context_tag", intent_report.sections[0].name);
    try std.testing.expectEqualStrings("utterance", intent_report.sections[1].name);

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
