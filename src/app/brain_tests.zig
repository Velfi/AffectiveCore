const std = @import("std");
const brain = @import("brain.zig");
const chat = @import("../api/chat_client.zig");
const http_transport_mod = @import("../api/http_transport.zig");

const BrainRuntime = brain.BrainRuntime;
const AppCore = brain.AppCore;

const FailingHttpTransport = struct {
    fn client(self: *FailingHttpTransport) http_transport_mod.Client {
        return .{ .ctx = self, .postJsonFn = postJson };
    }

    fn postJson(_: *anyopaque, _: std.mem.Allocator, _: http_transport_mod.JsonPostRequest) ![]u8 {
        return error.HostHttpTransportRequired;
    }
};

fn testRuntime(
    allocator: std.mem.Allocator,
    brain_id: []const u8,
    memory_path: []const u8,
    graph_path: []const u8,
    schedule_path: []const u8,
    events_path: []const u8,
    state_path: []const u8,
) !BrainRuntime {
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    inline for (.{ memory_path, graph_path, schedule_path, events_path, state_path }) |path| {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    var env = std.process.Environ.Map.init(allocator);
    const failing_http = try allocator.create(FailingHttpTransport);
    failing_http.* = .{};
    return BrainRuntime.initHeadlessMcp(allocator, std.testing.io, failing_http.client(), &env, .{
        .brain_id = brain_id,
        .memory_path = memory_path,
        .graph_path = graph_path,
        .events_path = events_path,
        .maintenance_schedule_path = schedule_path,
        .maintenance_state_path = state_path,
    });
}

fn cleanupRuntimeTestFiles(memory_path: []const u8, graph_path: []const u8, schedule_path: []const u8, events_path: []const u8, state_path: []const u8) void {
    inline for (.{ memory_path, graph_path, schedule_path, events_path, state_path }) |path| {
        std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    }
}

test "brain runtime conversation turn mutates summaries through central brain path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cleanupRuntimeTestFiles(
        "data/test/brain_runtime_conversation_memory.sqlite",
        "data/test/brain_runtime_conversation_graph.sqlite",
        "data/test/brain_runtime_conversation_schedule.md",
        "data/test/brain_runtime_conversation_events.jsonl",
        "data/test/brain_runtime_conversation_maintenance_state.json",
    );
    var runtime = try testRuntime(
        allocator,
        "default",
        "data/test/brain_runtime_conversation_memory.sqlite",
        "data/test/brain_runtime_conversation_graph.sqlite",
        "data/test/brain_runtime_conversation_schedule.md",
        "data/test/brain_runtime_conversation_events.jsonl",
        "data/test/brain_runtime_conversation_maintenance_state.json",
    );
    defer cleanupRuntimeTestFiles(
        "data/test/brain_runtime_conversation_memory.sqlite",
        "data/test/brain_runtime_conversation_graph.sqlite",
        "data/test/brain_runtime_conversation_schedule.md",
        "data/test/brain_runtime_conversation_events.jsonl",
        "data/test/brain_runtime_conversation_maintenance_state.json",
    );

    const before = try runtime.brain.deps.store.loadConversationSummaries(allocator);
    try std.testing.expectEqual(@as(usize, 0), before.len);

    const test_chat_service = try allocator.create(chat.TestChatService);
    test_chat_service.* = .{};
    runtime.brain.deps.chat_service = test_chat_service.service();

    const result = try runtime.conversationTurn("hello from Affective");
    try std.testing.expectEqualStrings("hello from Affective", result.user_text);
    try std.testing.expect(std.mem.indexOf(u8, result.spoken_text, "I heard you say: hello from Affective") != null);
    try std.testing.expectEqualStrings("hello from Affective", result.user_summary);

    const after = try runtime.brain.deps.store.loadConversationSummaries(allocator);
    try std.testing.expect(after.len > before.len);
    try std.testing.expectEqualStrings("hello from Affective", after[after.len - 1].user_summary);
}

test "brain runtime executes memory commands through central brain path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = try testRuntime(
        allocator,
        "default",
        "data/test/brain_runtime_memory.sqlite",
        "data/test/brain_runtime_graph.sqlite",
        "data/test/brain_runtime_schedule.md",
        "data/test/brain_runtime_events.jsonl",
        "data/test/brain_runtime_maintenance_state.json",
    );
    defer cleanupRuntimeTestFiles(
        "data/test/brain_runtime_memory.sqlite",
        "data/test/brain_runtime_graph.sqlite",
        "data/test/brain_runtime_schedule.md",
        "data/test/brain_runtime_events.jsonl",
        "data/test/brain_runtime_maintenance_state.json",
    );

    const remembered = try runtime.executeCommand(.{
        .command = .remember_memory,
        .text = "The shared brain owns memory commands.",
        .tags = &[_][]const u8{"architecture"},
    });
    try std.testing.expect(std.mem.indexOf(u8, remembered.observation, "memory_saved:") != null);

    const recalled = try runtime.executeCommand(.{
        .command = .recall_memory,
        .query = "shared brain",
        .tags = &[_][]const u8{"architecture"},
    });
    try std.testing.expect(std.mem.indexOf(u8, recalled.observation, "memory_recall:") != null);
    try std.testing.expect(std.mem.indexOf(u8, recalled.observation, "shared brain owns memory commands") != null);

    const swept = try runtime.executeCommand(.{ .command = .sweep_memory });
    try std.testing.expect(std.mem.indexOf(u8, swept.observation, "memory_sweep:") != null);
}

test "brain runtime executes reminders and introspection with host capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = try testRuntime(
        allocator,
        "default",
        "data/test/brain_runtime_reminder_memory.sqlite",
        "data/test/brain_runtime_reminder_graph.sqlite",
        "data/test/brain_runtime_reminder_schedule.md",
        "data/test/brain_runtime_reminder_events.jsonl",
        "data/test/brain_runtime_reminder_maintenance_state.json",
    );
    defer cleanupRuntimeTestFiles(
        "data/test/brain_runtime_reminder_memory.sqlite",
        "data/test/brain_runtime_reminder_graph.sqlite",
        "data/test/brain_runtime_reminder_schedule.md",
        "data/test/brain_runtime_reminder_events.jsonl",
        "data/test/brain_runtime_reminder_maintenance_state.json",
    );

    const reminder = try runtime.executeCommand(.{
        .command = .set_reminder,
        .schedule = "in 5 minutes",
        .text = "check the shared runtime",
    });
    try std.testing.expect(std.mem.indexOf(u8, reminder.observation, "reminder_set:") != null);

    const introspection = try runtime.executeCommand(.{ .command = .introspect });
    try std.testing.expect(std.mem.indexOf(u8, introspection.observation, "introspection:") != null);
    try std.testing.expect(std.mem.indexOf(u8, introspection.observation, "- take_picture:") == null);

    const commands = try runtime.availableCommands();
    var found_recall = false;
    var found_take_picture = false;
    for (commands) |info| {
        if (info.command == .recall_memory) {
            found_recall = true;
            try std.testing.expect(info.available);
        }
        if (info.command == .take_picture) {
            found_take_picture = true;
            try std.testing.expect(!info.available);
        }
    }
    try std.testing.expect(found_recall);
    try std.testing.expect(found_take_picture);
}

test "app core routes commands and settings to individually registered brains" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ada = try testRuntime(
        allocator,
        "ada",
        "data/test/brain_runtime_core_ada_memory.sqlite",
        "data/test/brain_runtime_core_ada_graph.sqlite",
        "data/test/brain_runtime_core_ada_schedule.md",
        "data/test/brain_runtime_core_ada_events.jsonl",
        "data/test/brain_runtime_core_ada_maintenance_state.json",
    );
    defer cleanupRuntimeTestFiles(
        "data/test/brain_runtime_core_ada_memory.sqlite",
        "data/test/brain_runtime_core_ada_graph.sqlite",
        "data/test/brain_runtime_core_ada_schedule.md",
        "data/test/brain_runtime_core_ada_events.jsonl",
        "data/test/brain_runtime_core_ada_maintenance_state.json",
    );
    var otto = try testRuntime(
        allocator,
        "otto",
        "data/test/brain_runtime_core_otto_memory.sqlite",
        "data/test/brain_runtime_core_otto_graph.sqlite",
        "data/test/brain_runtime_core_otto_schedule.md",
        "data/test/brain_runtime_core_otto_events.jsonl",
        "data/test/brain_runtime_core_otto_maintenance_state.json",
    );
    defer cleanupRuntimeTestFiles(
        "data/test/brain_runtime_core_otto_memory.sqlite",
        "data/test/brain_runtime_core_otto_graph.sqlite",
        "data/test/brain_runtime_core_otto_schedule.md",
        "data/test/brain_runtime_core_otto_events.jsonl",
        "data/test/brain_runtime_core_otto_maintenance_state.json",
    );

    var core = AppCore.init(allocator);
    try core.registerBrain("ada", &ada);
    try core.registerBrain("otto", &otto);

    const remembered = try core.executeCommand("ada", .{
        .command = .remember_memory,
        .text = "Ada owns this memory.",
        .tags = &[_][]const u8{"owner"},
    });
    try std.testing.expect(std.mem.indexOf(u8, remembered.observation, "memory_saved:") != null);

    const ada_recall = try core.executeCommand("ada", .{ .command = .recall_memory, .query = "Ada owns" });
    try std.testing.expect(std.mem.indexOf(u8, ada_recall.observation, "Ada owns this memory.") != null);

    const otto_recall = try core.executeCommand("otto", .{ .command = .recall_memory, .query = "Ada owns" });
    try std.testing.expect(std.mem.indexOf(u8, otto_recall.observation, "Ada owns this memory.") == null);

    try core.configureBrain("ada", .{
        .brain_id = "ada",
        .autonomy_mode = "on",
        .autonomy_interval_seconds = 42,
        .conversation_model = "gpt-4.1-mini",
    });

    const ada_settings = try core.brainSettings("ada");
    const otto_settings = try core.brainSettings("otto");
    try std.testing.expectEqualStrings("on", ada_settings.autonomy_mode);
    try std.testing.expectEqual(@as(?u64, 42), ada_settings.autonomy_interval_seconds);
    try std.testing.expectEqualStrings("gpt-4.1-mini", ada_settings.conversation_model);
    try std.testing.expectEqualStrings("off", otto_settings.autonomy_mode);
    try std.testing.expectEqualStrings("gpt-4.1-nano", otto_settings.conversation_model);
    try std.testing.expectError(error.UnknownBrainId, core.executeCommand("missing", .{ .command = .introspect }));
    try std.testing.expectError(error.BrainSettingsIdMismatch, core.configureBrain("ada", .{ .brain_id = "otto", .autonomy_mode = "on" }));
}
