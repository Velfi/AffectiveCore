const std = @import("std");
const embedded = @import("../affective_core_embedded.zig");
const support = @import("../core/brain_test_support.zig");
const want_achievement_mod = @import("../core/port_want_achievement.zig");
const memory_extraction_mod = @import("../core/port_memory_extraction.zig");
const memory_selection_mod = @import("../core/port_memory_selection.zig");
const recognition = @import("../api/recognition_client.zig");
const mock_host = @import("mock_host.zig");

pub fn parseMode(name: []const u8) !mock_host.Mode {
    if (std.mem.eql(u8, name, "default")) return .default;
    if (std.mem.eql(u8, name, "resume_invalid_llm")) return .resume_invalid_llm;
    if (std.mem.eql(u8, name, "enrollment_without_remember_person")) return .enrollment_without_remember_person;
    if (std.mem.eql(u8, name, "upstream_rejected")) return .upstream_rejected;
    if (std.mem.eql(u8, name, "scripted_recognize_resume")) return .default;
    if (std.mem.eql(u8, name, "unknown_want_achievement")) return .default;
    return error.UnknownMcpHostScenario;
}

pub fn apply(handle: *embedded.AffectiveCoreEmbedded, allocator: std.mem.Allocator, scenario_name: []const u8) !void {
    if (std.mem.eql(u8, scenario_name, "scripted_recognize_resume")) {
        const chat = try allocator.create(support.ScriptedRecognizeThenSayChatService);
        chat.* = .{ .say_text = "Hi after camera." };
        handle.brain.deps.chat_service = chat.service();

        const recognizer = try allocator.create(recognition.TestRecognitionClient);
        recognizer.* = .{};
        handle.brain.deps.recognizer = recognizer.recognizer();

        const extraction = try allocator.create(memory_extraction_mod.ScriptedMemoryExtractionService);
        extraction.* = .{ .candidates = &.{} };
        handle.brain.deps.memory_extraction_service = extraction.service();
        const selection = try allocator.create(memory_selection_mod.ScriptedMemorySelectionService);
        selection.* = .{ .summary = "Scenario test memory selection summary." };
        handle.brain.deps.memory_selection_service = selection.service();
        return;
    }
    if (std.mem.eql(u8, scenario_name, "unknown_want_achievement")) {
        const want_tags = [_][]const u8{ "self_model", "self_want" };
        try handle.brain.deps.store.saveMemoryRecord(.{
            .memory_id = "want_music",
            .scope = .long_term,
            .text = "I want music.",
            .interpretation = "self-defined want: I want music.",
            .tags = @constCast(&want_tags),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = 5,
            .salience = 0.70,
        });

        const detector = try allocator.create(want_achievement_mod.ScriptedWantAchievementDetector);
        detector.* = .{
            .matches = &[_]want_achievement_mod.WantAchievementMatch{.{
                .memory_id = "want_missing",
                .confidence = 0.90,
                .evidence = "done",
            }},
        };
        handle.brain.deps.want_achievement_detector = detector.detector();
    }
}
