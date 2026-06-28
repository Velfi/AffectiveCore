const std = @import("std");
const brain_context_stats = @import("brain_context_stats.zig");
const context_composition = @import("context_composition.zig");
const read_models = @import("read_models.zig");
const brain_test_support = @import("brain_test_support.zig");
const brain_mod = @import("brain.zig");
const llm_routing = @import("llm_routing.zig");
const random_provider_client = @import("../api/random_provider_client.zig");
const http_transport = @import("../api/http_transport.zig");
const ports = @import("ports.zig");
const openai = ports.openai;
const files = ports.files;
const brain_test_store = @import("brain_test_store.zig");

const TestStore = brain_test_store.TestStore;

const TestFileSystem = struct {
    const max_files = 4;

    allocator: std.mem.Allocator,
    files: [max_files]File = [_]File{.{}} ** max_files,

    const File = struct {
        path: []const u8 = "",
        data: []const u8 = "",
    };

    fn deinit(self: *TestFileSystem) void {
        for (&self.files) |*file| {
            if (file.path.len == 0) continue;
            self.allocator.free(file.path);
            self.allocator.free(file.data);
            file.* = .{};
        }
    }

    fn find(self: *TestFileSystem, path: []const u8) ?*File {
        for (&self.files) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }

    fn emptySlot(self: *TestFileSystem) !*File {
        for (&self.files) |*file| {
            if (file.path.len == 0) return file;
        }
        return error.TestFileSystemFull;
    }

    fn filesystem(self: *TestFileSystem) files.FileSystem {
        return .{
            .ctx = self,
            .ensureParentDirFn = ensureParentDir,
            .readFileAllocPathFn = readFileAllocPath,
            .writeFilePathFn = writeFilePath,
            .ensureDirFn = ensureDir,
            .sweepSpeechArtifactsFn = sweepSpeechArtifacts,
        };
    }

    fn ensureParentDir(_: *anyopaque, _: std.Io, _: []const u8) !void {}

    fn readFileAllocPath(ctx: *anyopaque, _: std.Io, path: []const u8, allocator: std.mem.Allocator, _: std.Io.Limit) ![]u8 {
        const self: *TestFileSystem = @ptrCast(@alignCast(ctx));
        const file = self.find(path) orelse return error.FileNotFound;
        return try allocator.dupe(u8, file.data);
    }

    fn writeFilePath(ctx: *anyopaque, _: std.Io, path: []const u8, data: []const u8) !void {
        const self: *TestFileSystem = @ptrCast(@alignCast(ctx));
        const file = self.find(path) orelse try self.emptySlot();
        if (file.path.len == 0) file.path = try self.allocator.dupe(u8, path);
        if (file.data.len > 0) self.allocator.free(file.data);
        file.data = try self.allocator.dupe(u8, data);
    }

    fn ensureDir(_: *anyopaque, _: std.Io, _: []const u8) !void {}

    fn sweepSpeechArtifacts(_: *anyopaque, _: std.Io, _: files.SpeechArtifactSweepRequest) !files.SpeechArtifactSweepResult {
        return .{};
    }
};

test "recordComposition updates operation and section totals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();

    const sections = [_]context_composition.SectionStat{
        .{ .name = "compact_memory.focus", .bytes = 12 },
        .{ .name = "observations.user_text", .bytes = 24 },
    };
    const report = context_composition.ContextCompositionReport{
        .operation = "conversation_chat",
        .total_bytes = 1200,
        .user_prompt_tokens = 300,
        .sections = &sections,
    };

    try brain_context_stats.recordComposition(&state, report, 100);
    try std.testing.expectEqual(@as(u64, 1), state.total_composition_count);
    try std.testing.expectEqual(@as(usize, 1200), state.last_conversation_bytes.?);
    try std.testing.expectEqual(@as(usize, 300), state.last_conversation_tokens.?);
    try std.testing.expectEqual(@as(i64, 100), state.last_conversation_at_seconds.?);

    const op = state.operations.get("conversation_chat").?;
    try std.testing.expectEqual(@as(u64, 1), op.call_count);
    try std.testing.expectEqual(@as(u64, 1200), op.total_bytes);
    try std.testing.expectEqual(@as(u64, 300), op.total_tokens);

    const focus = state.sections.get("compact_memory.focus").?;
    try std.testing.expectEqual(@as(u64, 12), focus.total_bytes);
    try std.testing.expectEqual(@as(u64, 1), focus.appearance_count);
}

test "recordProcessGoalComposition updates operation and goal sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();

    try brain_context_stats.recordProcessGoalComposition(&state, .{
        .goal = "investigate_touch",
        .mode = "autonomy",
        .context_bytes = 2400,
        .step_count = 2,
    }, 300);
    try std.testing.expectEqual(@as(u64, 1), state.total_process_goal_count);
    try std.testing.expectEqual(@as(u64, 2), state.total_composed_steps);
    const op = state.operations.get("process_composition.autonomy").?;
    try std.testing.expectEqual(@as(u64, 1), op.call_count);
    try std.testing.expectEqual(@as(u64, 2400), op.total_bytes);
    const goal = state.sections.get("process_goal.investigate_touch").?;
    try std.testing.expectEqual(@as(u64, 2400), goal.total_bytes);
    try std.testing.expectEqual(@as(u64, 1), goal.appearance_count);
    const steps = state.sections.get("composed_steps").?;
    try std.testing.expectEqual(@as(u64, 2), steps.total_bytes);
}

test "recordBudgetExceeded increments counter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();

    brain_context_stats.recordBudgetExceeded(&state, 200);
    brain_context_stats.recordBudgetExceeded(&state, 201);
    try std.testing.expectEqual(@as(u64, 2), state.budget_exceeded_count);
    try std.testing.expectEqual(@as(i64, 201), state.updated_at_seconds);
}

test "save and load round trip preserves aggregates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fs_state = TestFileSystem{ .allocator = allocator };
    defer fs_state.deinit();
    const fs = fs_state.filesystem();
    const path = "data/test/context_stats_roundtrip.json";

    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();
    const sections = [_]context_composition.SectionStat{
        .{ .name = "episode_text", .bytes = 42 },
    };
    try brain_context_stats.recordComposition(&state, .{
        .operation = "memory_extraction",
        .total_bytes = 42,
        .sections = &sections,
    }, 500);
    brain_context_stats.recordBudgetExceeded(&state, 500);
    try brain_context_stats.recordProcessGoalComposition(&state, .{
        .goal = "investigate_touch",
        .mode = "autonomy",
        .context_bytes = 1200,
        .step_count = 2,
    }, 500);
    try brain_context_stats.save(allocator, fs, std.testing.io, path, &state);

    var loaded = try brain_context_stats.load(allocator, fs, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 1), loaded.total_composition_count);
    try std.testing.expectEqual(@as(u64, 1), loaded.total_process_goal_count);
    try std.testing.expectEqual(@as(u64, 2), loaded.total_composed_steps);
    try std.testing.expectEqual(@as(u64, 1), loaded.budget_exceeded_count);
    try std.testing.expectEqual(@as(u64, 1), loaded.operations.get("memory_extraction").?.call_count);
    try std.testing.expectEqual(@as(u64, 42), loaded.sections.get("episode_text").?.total_bytes);
}

test "save leaves in-memory state intact for further recording" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fs_state = TestFileSystem{ .allocator = allocator };
    defer fs_state.deinit();
    const fs = fs_state.filesystem();
    const path = "data/test/context_stats_post_save.json";

    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();

    const first_sections = [_]context_composition.SectionStat{
        .{ .name = "compact_memory.focus", .bytes = 10 },
    };
    try brain_context_stats.recordComposition(&state, .{
        .operation = "conversation_chat",
        .total_bytes = 500,
        .user_prompt_tokens = 125,
        .sections = &first_sections,
    }, 100);
    try brain_context_stats.save(allocator, fs, std.testing.io, path, &state);

    try std.testing.expect(state.operations.get("conversation_chat") != null);
    const op_key = state.operations.getKey("conversation_chat").?;
    try std.testing.expectEqualStrings("conversation_chat", op_key);

    const second_sections = [_]context_composition.SectionStat{
        .{ .name = "utterance", .bytes = 8 },
    };
    try brain_context_stats.recordComposition(&state, .{
        .operation = "intent_classify",
        .total_bytes = 20,
        .sections = &second_sections,
    }, 101);

    try std.testing.expectEqual(@as(u64, 2), state.total_composition_count);
    try std.testing.expectEqual(@as(u64, 1), state.operations.get("conversation_chat").?.call_count);
    try std.testing.expectEqual(@as(u64, 500), state.operations.get("conversation_chat").?.total_bytes);
    try std.testing.expectEqual(@as(u64, 1), state.operations.get("intent_classify").?.call_count);
    try std.testing.expectEqual(@as(u64, 10), state.sections.get("compact_memory.focus").?.total_bytes);
}

test "readModelsSnapshot includes context usage after recording" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = brain_test_support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const sections = [_]context_composition.SectionStat{
        .{ .name = "utterance", .bytes = 11 },
    };
    try brain_context_stats.recordComposition(&brain.context_stats, .{
        .operation = "intent_classify",
        .total_bytes = 20,
        .sections = &sections,
    }, brain.now_seconds);
    try brain_context_stats.recordProcessGoalComposition(&brain.context_stats, .{
        .goal = "investigate_touch",
        .mode = "interaction",
        .context_bytes = 900,
        .step_count = 1,
    }, brain.now_seconds);
    brain.context_stats_loaded = true;

    const snapshot = try read_models.readModelsSnapshot(&brain, allocator);
    try std.testing.expectEqual(@as(u64, 1), snapshot.context_usage_model.total_composition_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.context_usage_model.total_process_goal_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.context_usage_model.total_composed_steps);
    try std.testing.expectEqual(@as(usize, 2), snapshot.context_usage_model.operations.len);
    try std.testing.expectEqualStrings("intent_classify", snapshot.context_usage_model.operations[0].operation);
    try std.testing.expectEqual(@as(u64, 20), snapshot.context_usage_model.operations[0].total_bytes);
    try std.testing.expectEqualStrings("process_composition.interaction", snapshot.context_usage_model.operations[1].operation);
    try std.testing.expectEqual(@as(u64, 900), snapshot.context_usage_model.operations[1].total_bytes);
    try std.testing.expect(snapshot.context_usage_model.top_sections.len >= 2);
    try std.testing.expectEqualStrings("process_goal.investigate_touch", snapshot.context_usage_model.top_sections[0].section);
    try std.testing.expectEqual(@as(u64, 900), snapshot.context_usage_model.top_sections[0].total_bytes);
}

test "recordLlmCompletion aggregates subsystem totals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();

    try brain_context_stats.recordLlmCompletion(&state, .{
        .subsystem = "conversation",
        .provider = "openai",
        .model = "gpt-4.1-nano",
        .effort_tier = "standard",
        .reasoning_effort = "medium",
        .request_bytes = 100,
        .response_bytes = 50,
        .outcome = .success,
    }, 1000);
    try brain_context_stats.recordLlmCompletion(&state, .{
        .subsystem = "conversation",
        .provider = "openai",
        .model = "gpt-4.1-nano",
        .effort_tier = "standard",
        .reasoning_effort = null,
        .request_bytes = 80,
        .response_bytes = 0,
        .outcome = .provider_error,
    }, 1001);

    try std.testing.expectEqual(@as(u64, 2), state.total_llm_calls);
    try std.testing.expectEqual(@as(u64, 1), state.total_llm_errors);
    const totals = state.llm_subsystems.get("conversation").?;
    try std.testing.expectEqual(@as(u64, 2), totals.call_count);
    try std.testing.expectEqual(@as(u64, 1), totals.success_count);
    try std.testing.expectEqual(@as(u64, 1), totals.error_count);
    try std.testing.expectEqual(@as(u64, 180), totals.request_bytes);
    try std.testing.expectEqual(@as(u64, 50), totals.response_bytes);
    try std.testing.expectEqual(@as(u64, 50), totals.max_response_bytes);
    try std.testing.expectEqualStrings("conversation", state.last_llm_call.?.subsystem);
    try std.testing.expectEqualStrings("openai", state.last_llm_call.?.provider);
    try std.testing.expectEqualStrings("gpt-4.1-nano", state.last_llm_call.?.model);
    try std.testing.expectEqualStrings("standard", state.last_llm_call.?.effort_tier.?);
}

test "llm stats count each provider attempt not each logical completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();

    try brain_context_stats.recordLlmCompletion(&state, .{
        .subsystem = "conversation",
        .provider = "openai",
        .model = "gpt-4.1-nano",
        .effort_tier = "standard",
        .request_bytes = 50,
        .response_bytes = 10,
        .outcome = .validation_error,
    }, 100);
    try brain_context_stats.recordLlmCompletion(&state, .{
        .subsystem = "conversation",
        .provider = "anthropic",
        .model = "claude-haiku",
        .effort_tier = "standard",
        .request_bytes = 50,
        .response_bytes = 12,
        .outcome = .validation_error,
    }, 101);
    try brain_context_stats.recordLlmCompletion(&state, .{
        .subsystem = "conversation",
        .provider = "google",
        .model = "gemini-flash",
        .effort_tier = "standard",
        .request_bytes = 50,
        .response_bytes = 20,
        .outcome = .success,
    }, 102);

    try std.testing.expectEqual(@as(u64, 3), state.total_llm_calls);
    try std.testing.expectEqual(@as(u64, 2), state.total_llm_errors);
    const totals = state.llm_subsystems.get("conversation").?;
    try std.testing.expectEqual(@as(u64, 3), totals.call_count);
    try std.testing.expectEqual(@as(u64, 1), totals.success_count);
    try std.testing.expectEqual(@as(u64, 2), totals.error_count);
}

test "llm completion stats roundtrip through save and load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fs_state = TestFileSystem{ .allocator = allocator };
    defer fs_state.deinit();
    const fs = fs_state.filesystem();
    const path = "data/test/context_stats_llm_roundtrip.json";

    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();
    try brain_context_stats.recordLlmCompletion(&state, .{
        .subsystem = "memory_extraction",
        .provider = "anthropic",
        .model = "claude-haiku",
        .effort_tier = "standard",
        .request_bytes = 300,
        .response_bytes = 120,
        .outcome = .success,
    }, 500);
    try brain_context_stats.save(allocator, fs, std.testing.io, path, &state);

    var loaded = try brain_context_stats.load(allocator, fs, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u64, 1), loaded.total_llm_calls);
    try std.testing.expectEqual(@as(u64, 0), loaded.total_llm_errors);
    try std.testing.expectEqual(@as(u64, 1), loaded.llm_subsystems.get("memory_extraction").?.call_count);
    try std.testing.expectEqualStrings("memory_extraction", loaded.last_llm_call.?.subsystem);
    try std.testing.expectEqualStrings("anthropic", loaded.last_llm_call.?.provider);
    try std.testing.expectEqualStrings("standard", loaded.last_llm_call.?.effort_tier.?);
}

test "save leaves llm in-memory state intact for further recording" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fs_state = TestFileSystem{ .allocator = allocator };
    defer fs_state.deinit();
    const fs = fs_state.filesystem();
    const path = "data/test/context_stats_llm_post_save.json";

    var state = brain_context_stats.State.init(allocator);
    defer state.deinit();

    try brain_context_stats.recordLlmCompletion(&state, .{
        .subsystem = "conversation",
        .provider = "openai",
        .model = "gpt-4.1-nano",
        .effort_tier = "standard",
        .request_bytes = 100,
        .response_bytes = 40,
        .outcome = .success,
    }, 200);
    try brain_context_stats.save(allocator, fs, std.testing.io, path, &state);

    try std.testing.expect(state.llm_subsystems.get("conversation") != null);
    const sub_key = state.llm_subsystems.getKey("conversation").?;
    try std.testing.expectEqualStrings("conversation", sub_key);

    try brain_context_stats.recordLlmCompletion(&state, .{
        .subsystem = "greeting",
        .provider = "openai",
        .model = "gpt-4.1-nano",
        .effort_tier = "basic",
        .request_bytes = 30,
        .response_bytes = 8,
        .outcome = .success,
    }, 201);

    try std.testing.expectEqual(@as(u64, 2), state.total_llm_calls);
    try std.testing.expectEqual(@as(u64, 1), state.llm_subsystems.get("conversation").?.call_count);
    try std.testing.expectEqual(@as(u64, 1), state.llm_subsystems.get("greeting").?.call_count);
    try std.testing.expectEqualStrings("greeting", state.last_llm_call.?.subsystem);
}

test "readModelsSnapshot includes llm usage after recording" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = brain_test_support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain_context_stats.recordLlmCompletion(&brain.context_stats, .{
        .subsystem = "conversation",
        .provider = "openai",
        .model = "gpt-4.1-nano",
        .effort_tier = "standard",
        .request_bytes = 42,
        .response_bytes = 17,
        .outcome = .success,
    }, brain.now_seconds);
    brain.context_stats_loaded = true;

    const snapshot = try read_models.readModelsSnapshot(&brain, allocator);
    try std.testing.expectEqual(@as(u64, 1), snapshot.llm_usage_model.total_llm_calls);
    try std.testing.expectEqual(@as(u64, 0), snapshot.llm_usage_model.total_llm_errors);
    try std.testing.expectEqual(@as(usize, 1), snapshot.llm_usage_model.subsystems.len);
    try std.testing.expectEqualStrings("conversation", snapshot.llm_usage_model.subsystems[0].subsystem);
    try std.testing.expectEqual(@as(u64, 17), snapshot.llm_usage_model.subsystems[0].response_bytes);
    try std.testing.expectEqualStrings("conversation", snapshot.llm_usage_model.last_call.?.subsystem);
    try std.testing.expectEqualStrings("openai", snapshot.llm_usage_model.last_call.?.provider);
    try std.testing.expectEqualStrings("gpt-4.1-nano", snapshot.llm_usage_model.last_call.?.model);
    try std.testing.expectEqualStrings("standard", snapshot.llm_usage_model.last_call.?.effort_tier.?);
    try std.testing.expectEqual(@as(usize, 17), snapshot.llm_usage_model.last_call.?.response_bytes);
}

const WiredLlmHttpTransport = struct {
    fn client(_: *WiredLlmHttpTransport) http_transport.Client {
        return .{ .ctx = @as(*anyopaque, @ptrFromInt(1)), .postJsonFn = postJson };
    }

    fn postJson(_: *anyopaque, allocator: std.mem.Allocator, _: http_transport.JsonPostRequest) ![]u8 {
        return try allocator.dupe(u8, "wired completion");
    }
};

test "wired provider client records llm usage in readModelsSnapshot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = brain_test_support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    var transport = WiredLlmHttpTransport{};
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = random_provider_client.RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);
    brain_mod.wireLlmStatsRecorder(&brain, &[_]*random_provider_client.RandomProviderClient{&client});

    const text = try client.completeText(allocator, .{
        .subsystem = "conversation",
        .system_prompt = "system rules",
        .user_prompt = "hello",
        .response_format = .text,
        .response_size = .small,
    });
    defer allocator.free(text);
    try std.testing.expectEqualStrings("wired completion", text);

    const snapshot = try read_models.readModelsSnapshot(&brain, allocator);
    try std.testing.expectEqual(@as(u64, 1), snapshot.llm_usage_model.total_llm_calls);
    try std.testing.expectEqual(@as(u64, 0), snapshot.llm_usage_model.total_llm_errors);
    try std.testing.expectEqual(@as(usize, 1), snapshot.llm_usage_model.subsystems.len);
    try std.testing.expectEqualStrings("conversation", snapshot.llm_usage_model.subsystems[0].subsystem);
    try std.testing.expectEqual(@as(u64, "wired completion".len), snapshot.llm_usage_model.subsystems[0].response_bytes);
    try std.testing.expectEqualStrings("conversation", snapshot.llm_usage_model.last_call.?.subsystem);
    try std.testing.expectEqualStrings("openai", snapshot.llm_usage_model.last_call.?.provider);
    try std.testing.expectEqualStrings("gpt-4.1-nano", snapshot.llm_usage_model.last_call.?.model);
    try std.testing.expectEqualStrings("standard", snapshot.llm_usage_model.last_call.?.effort_tier.?);
    try std.testing.expectEqual(@as(usize, "wired completion".len), snapshot.llm_usage_model.last_call.?.response_bytes);
}
