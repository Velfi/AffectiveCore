const std = @import("std");
const app_core = @import("app_core.zig");
const host_profiles = @import("host_profiles.zig");
const chat = @import("../api/chat_client.zig");
const http_transport_mod = @import("../api/http_transport.zig");
const input_mod = @import("../platform/common/input.zig");
const want_achievement_mod = @import("../core/port_want_achievement.zig");
const memory_extraction_mod = @import("../core/port_memory_extraction.zig");
const brain_mod = @import("../core/brain.zig");

const AppCore = app_core.AppCore;

fn wireBrainHost(host: *host_profiles.HeadlessMcpBrainHost) void {
    brain_mod.wireLlmStatsRecorder(&host.brain, host.llm_provider_clients);
}

const FailingHttpTransport = struct {
    fn client(self: *FailingHttpTransport) http_transport_mod.Client {
        return .{ .ctx = self, .postJsonFn = postJson };
    }

    fn postJson(_: *anyopaque, _: std.mem.Allocator, _: http_transport_mod.JsonPostRequest) ![]u8 {
        return error.HostHttpTransportRequired;
    }
};

fn testBrainHost(
    allocator: std.mem.Allocator,
    brain_id: []const u8,
    memory_path: []const u8,
    graph_path: []const u8,
    schedule_path: []const u8,
    state_path: []const u8,
) !host_profiles.HeadlessMcpBrainHost {
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    inline for (.{ memory_path, graph_path, schedule_path, state_path }) |path| {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    const failing_http = try allocator.create(FailingHttpTransport);
    failing_http.* = .{};
    var host = try host_profiles.initHeadlessMcpBrainHost(allocator, std.testing.io, failing_http.client(), .{
        .brain_id = brain_id,
        .memory_path = memory_path,
        .graph_path = graph_path,
        .conversation_models = "openai:gpt-4.1-nano",
        .maintenance_schedule_path = schedule_path,
        .maintenance_state_path = state_path,
    });
    const scripted_want = try allocator.create(want_achievement_mod.ScriptedWantAchievementDetector);
    scripted_want.* = .{};
    host.brain.deps.want_achievement_detector = scripted_want.detector();
    const scripted_extraction = try allocator.create(memory_extraction_mod.ScriptedMemoryExtractionService);
    scripted_extraction.* = .{ .candidates = &[_]memory_extraction_mod.ExtractionCandidate{
        .{
            .key = "test.host.extraction",
            .proposition = "Conversation summary indicates a durable interaction memory.",
            .evidence = "summary captured user interaction context",
            .kind = .belief,
            .confidence = 0.7,
            .salience = 0.6,
            .tags = &[_][]const u8{ "test", "memory" },
            .source_references = &[_][]const u8{"summary captured user interaction context"},
        },
    } };
    host.brain.deps.memory_extraction_service = scripted_extraction.service();
    return host;
}

fn cleanupBrainHostTestFiles(memory_path: []const u8, graph_path: []const u8, schedule_path: []const u8, state_path: []const u8) void {
    inline for (.{ memory_path, graph_path, schedule_path, state_path }) |path| {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    }
}

test "brain host conversation turn mutates summaries through central brain path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cleanupBrainHostTestFiles(
        "data/test/brain_host_conversation_memory.sqlite",
        "data/test/brain_host_conversation_graph.sqlite",
        "data/test/brain_host_conversation_schedule.md",
        "data/test/brain_host_conversation_maintenance_state.json",
    );
    var brain_host = try testBrainHost(
        allocator,
        "default",
        "data/test/brain_host_conversation_memory.sqlite",
        "data/test/brain_host_conversation_graph.sqlite",
        "data/test/brain_host_conversation_schedule.md",
        "data/test/brain_host_conversation_maintenance_state.json",
    );
    wireBrainHost(&brain_host);
    const brain = &brain_host.brain;
    defer cleanupBrainHostTestFiles(
        "data/test/brain_host_conversation_memory.sqlite",
        "data/test/brain_host_conversation_graph.sqlite",
        "data/test/brain_host_conversation_schedule.md",
        "data/test/brain_host_conversation_maintenance_state.json",
    );
    defer brain_host.deinit(allocator);

    const before = try brain.deps.store.loadConversationSummaries(allocator);
    try std.testing.expectEqual(@as(usize, 0), before.len);

    const test_chat_service = try allocator.create(chat.TestChatService);
    test_chat_service.* = .{};
    brain.deps.chat_service = test_chat_service.service();

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello from Affective"), .{});
    try std.testing.expectEqualStrings("hello from Affective", result.user_text);
    try std.testing.expect(std.mem.indexOf(u8, result.spoken_text, "I heard you say: hello from Affective") != null);
    try std.testing.expectEqualStrings("hello from Affective", result.user_summary);

    const after = try brain.deps.store.loadConversationSummaries(allocator);
    try std.testing.expect(after.len > before.len);
    try std.testing.expectEqualStrings("hello from Affective", after[after.len - 1].user_summary);
}

test "brain host executes memory action pressures through central brain path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var brain_host = try testBrainHost(
        allocator,
        "default",
        "data/test/brain_host_memory.sqlite",
        "data/test/brain_host_graph.sqlite",
        "data/test/brain_host_schedule.md",
        "data/test/brain_host_maintenance_state.json",
    );
    wireBrainHost(&brain_host);
    const brain = &brain_host.brain;
    defer cleanupBrainHostTestFiles(
        "data/test/brain_host_memory.sqlite",
        "data/test/brain_host_graph.sqlite",
        "data/test/brain_host_schedule.md",
        "data/test/brain_host_maintenance_state.json",
    );
    defer brain_host.deinit(allocator);

    const remembered = try app_core.executeBrainActionProposal(allocator, brain, .{
        .action = .unknown,
        .text = "The shared brain owns memory actions.",
        .tags = &[_][]const u8{"architecture"},
    });
    try std.testing.expect(std.mem.indexOf(u8, remembered.observation, "skill_failed: unknown: unavailable") != null);

    const recalled = try app_core.executeBrainActionProposal(allocator, brain, .{
        .action = .unknown,
        .query = "shared brain",
        .tags = &[_][]const u8{"architecture"},
    });
    try std.testing.expect(std.mem.indexOf(u8, recalled.observation, "skill_failed: unknown: unavailable") != null);

    const swept = try app_core.executeBrainActionProposal(allocator, brain, .{ .action = .sweep_memory });
    try std.testing.expect(std.mem.indexOf(u8, swept.observation, "memory_sweep:") != null);
}

test "brain host executes reminders and exposes capability availability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var brain_host = try testBrainHost(
        allocator,
        "default",
        "data/test/brain_host_reminder_memory.sqlite",
        "data/test/brain_host_reminder_graph.sqlite",
        "data/test/brain_host_reminder_schedule.md",
        "data/test/brain_host_reminder_maintenance_state.json",
    );
    wireBrainHost(&brain_host);
    const brain = &brain_host.brain;
    defer cleanupBrainHostTestFiles(
        "data/test/brain_host_reminder_memory.sqlite",
        "data/test/brain_host_reminder_graph.sqlite",
        "data/test/brain_host_reminder_schedule.md",
        "data/test/brain_host_reminder_maintenance_state.json",
    );
    defer brain_host.deinit(allocator);

    const reminder = try app_core.executeBrainActionProposal(allocator, brain, .{
        .action = .schedule_reminder,
        .schedule = "in 5 minutes",
        .text = "check the shared brain",
    });
    try std.testing.expect(std.mem.indexOf(u8, reminder.observation, "reminder_set:") != null);

    const introspection = try app_core.executeBrainActionProposal(allocator, brain, .{ .action = .introspect });
    try std.testing.expect(std.mem.indexOf(u8, introspection.observation, "skill_failed: introspect: unavailable") != null);

    const commands = try app_core.availableBrainCapabilities(allocator, brain);
    var found_recall = false;
    var found_take_picture = false;
    var found_introspect = false;
    for (commands) |info| {
        if (info.capability == .unknown) found_recall = true;
        if (info.capability == .introspect) {
            found_introspect = true;
            try std.testing.expect(!info.available);
        }
        if (info.capability == .take_picture) {
            found_take_picture = true;
            try std.testing.expect(!info.available);
        }
    }
    try std.testing.expect(!found_recall);
    try std.testing.expect(found_take_picture);
    try std.testing.expect(found_introspect);
}

test "app core routes action requests and settings to individually registered brains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ada = try testBrainHost(
        allocator,
        "ada",
        "data/test/brain_host_core_ada_memory.sqlite",
        "data/test/brain_host_core_ada_graph.sqlite",
        "data/test/brain_host_core_ada_schedule.md",
        "data/test/brain_host_core_ada_maintenance_state.json",
    );
    wireBrainHost(&ada);
    var otto = try testBrainHost(
        allocator,
        "otto",
        "data/test/brain_host_core_otto_memory.sqlite",
        "data/test/brain_host_core_otto_graph.sqlite",
        "data/test/brain_host_core_otto_schedule.md",
        "data/test/brain_host_core_otto_maintenance_state.json",
    );
    wireBrainHost(&otto);
    defer cleanupBrainHostTestFiles(
        "data/test/brain_host_core_ada_memory.sqlite",
        "data/test/brain_host_core_ada_graph.sqlite",
        "data/test/brain_host_core_ada_schedule.md",
        "data/test/brain_host_core_ada_maintenance_state.json",
    );
    defer cleanupBrainHostTestFiles(
        "data/test/brain_host_core_otto_memory.sqlite",
        "data/test/brain_host_core_otto_graph.sqlite",
        "data/test/brain_host_core_otto_schedule.md",
        "data/test/brain_host_core_otto_maintenance_state.json",
    );
    defer ada.deinit(allocator);
    defer otto.deinit(allocator);

    var core = AppCore.init(allocator);
    try core.registerBrain("ada", &ada.brain);
    try core.registerBrain("otto", &otto.brain);

    const remembered = try core.executeActionProposal("ada", .{
        .action = .unknown,
        .text = "Ada owns this memory.",
        .tags = &[_][]const u8{"owner"},
    });
    try std.testing.expect(std.mem.indexOf(u8, remembered.observation, "skill_failed: unknown: unavailable") != null);

    const ada_recall = try core.executeActionProposal("ada", .{ .action = .unknown, .query = "Ada owns" });
    try std.testing.expect(std.mem.indexOf(u8, ada_recall.observation, "skill_failed: unknown: unavailable") != null);

    const otto_recall = try core.executeActionProposal("otto", .{ .action = .unknown, .query = "Ada owns" });
    try std.testing.expect(std.mem.indexOf(u8, otto_recall.observation, "Ada owns this memory.") == null);

    try core.configureBrain("ada", .{
        .brain_id = "ada",
        .autonomy_mode = "full",
        .autonomy_limited_replenish_actions_per_minute = 3,
        .autonomy_full_replenish_actions_per_minute = 9,
        .conversation_model = "gpt-4.1-mini",
    });

    const ada_settings = try core.brainSettings("ada");
    const otto_settings = try core.brainSettings("otto");
    try std.testing.expectEqualStrings("full", ada_settings.autonomy_mode);
    try std.testing.expectEqual(@as(?f32, 3), ada_settings.autonomy_limited_replenish_actions_per_minute);
    try std.testing.expectEqual(@as(?f32, 9), ada_settings.autonomy_full_replenish_actions_per_minute);
    try std.testing.expectEqualStrings("gpt-4.1-mini", ada_settings.conversation_model);
    try std.testing.expectEqualStrings("off", otto_settings.autonomy_mode);
    try std.testing.expectEqualStrings("gpt-4.1-nano", otto_settings.conversation_model);
    try std.testing.expectError(error.UnknownBrainId, core.executeActionProposal("missing", .{ .action = .introspect }));
    try std.testing.expectError(error.BrainSettingsIdMismatch, core.configureBrain("ada", .{ .brain_id = "otto", .autonomy_mode = "full" }));
}
