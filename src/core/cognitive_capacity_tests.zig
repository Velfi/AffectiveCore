const std = @import("std");
const config = @import("config.zig");
const config_files = @import("config_files.zig");
const cognitive_capacity = @import("cognitive_capacity.zig");
const read_models = @import("read_models.zig");
const files_mod = @import("port_files.zig");

const MemoryFileSystem = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMapUnmanaged([]const u8),

    fn init(allocator: std.mem.Allocator) MemoryFileSystem {
        return .{ .allocator = allocator, .files = .{} };
    }

    fn deinit(self: *MemoryFileSystem) void {
        var it = self.files.iterator();
        while (it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.files.deinit(self.allocator);
    }

    fn put(self: *MemoryFileSystem, path: []const u8, bytes: []const u8) !void {
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        const value = try self.allocator.dupe(u8, bytes);
        try self.files.put(self.allocator, key, value);
    }

    fn filesystem(self: *MemoryFileSystem) files_mod.FileSystem {
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
    fn ensureDir(_: *anyopaque, _: std.Io, _: []const u8) !void {}
    fn sweepSpeechArtifacts(_: *anyopaque, _: std.Io, _: files_mod.SpeechArtifactSweepRequest) !files_mod.SpeechArtifactSweepResult {
        return .{};
    }

    fn readFileAllocPath(ctx: *anyopaque, _: std.Io, path: []const u8, allocator: std.mem.Allocator, _: std.Io.Limit) ![]u8 {
        const self: *MemoryFileSystem = @ptrCast(@alignCast(ctx));
        const bytes = self.files.get(path) orelse return error.FileNotFound;
        return allocator.dupe(u8, bytes);
    }

    fn writeFilePath(ctx: *anyopaque, _: std.Io, path: []const u8, data: []const u8) !void {
        const self: *MemoryFileSystem = @ptrCast(@alignCast(ctx));
        if (self.files.getPtr(path)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, data);
            return;
        }
        try self.put(path, data);
    }
};

test "validateCapacityConfig rejects invalid memory selection bounds" {
    var cfg = config.CapacityConfig{};
    cfg.memory_selected_max = 20;
    try std.testing.expectError(error.MemorySelectedExceedsPrefilter, cognitive_capacity.validate(cfg));
}

test "parseRuntimeOptionsConfig round-trips capacity block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try config.parseRuntimeOptionsConfig(allocator, .{},
        \\{
        \\  "capacity": {
        \\    "activity_stack_max": 6,
        \\    "memory_selected_max": 4
        \\  }
        \\}
    );
    try std.testing.expectEqual(@as(usize, 6), parsed.capacity.activity_stack_max);
    try std.testing.expectEqual(@as(usize, 4), parsed.capacity.memory_selected_max);
    try std.testing.expectEqual(@as(usize, 15), parsed.capacity.memory_prefilter_max);
}

test "loadForBrain applies runtime llm_quality over llm providers file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fs_state = MemoryFileSystem.init(allocator);
    defer fs_state.deinit();
    const llm_json =
        \\{
        \\  "mode": "random",
        \\  "reasoning_effort": "low",
        \\  "models": [
        \\    {"provider": "openai", "model": "gpt-4.1-nano", "tier": "basic"},
        \\    {"provider": "openai", "model": "gpt-4.1-mini", "tier": "standard"},
        \\    {"provider": "openai", "model": "gpt-4.1", "tier": "complex"}
        \\  ]
        \\}
    ;
    try fs_state.put("/tmp/brain/llm_providers.json", llm_json);
    try fs_state.put("/tmp/brain/runtime_options.json",
        \\{"llm_quality":"best","reasoning_effort":"auto"}
    );
    const loaded = try (config.Config{
        .brain_root = "/tmp/brain",
        .llm_providers_path = "/tmp/brain/llm_providers.json",
        .runtime_options_path = "/tmp/brain/runtime_options.json",
    }).loadForBrain(allocator, fs_state.filesystem(), std.testing.io);
    try std.testing.expectEqualStrings("best", loaded.llm_quality);
    try std.testing.expectEqualStrings("low", loaded.conversation_reasoning_effort);
    try std.testing.expectEqual(@as(usize, 3), loaded.conversation_roster.entries.len);
}

test "missing llm_providers.json fails loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fs_state = MemoryFileSystem.init(allocator);
    defer fs_state.deinit();
    const err = (config.Config{
        .brain_root = "/tmp/missing",
        .llm_providers_path = "/tmp/missing/llm_providers.json",
        .runtime_options_path = "/tmp/missing/runtime_options.json",
    }).loadForBrain(allocator, fs_state.filesystem(), std.testing.io);
    try std.testing.expectError(error.FileNotFound, err);
}

test "saveLlmProviders round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fs_state = MemoryFileSystem.init(allocator);
    defer fs_state.deinit();
    try fs_state.put("/tmp/brain/llm_providers.json",
        \\{
        \\  "models": [
        \\    {"provider": "openai", "model": "gpt-4.1-nano", "tier": "basic"},
        \\    {"provider": "openai", "model": "gpt-4.1-mini", "tier": "standard"},
        \\    {"provider": "openai", "model": "gpt-4.1", "tier": "complex"}
        \\  ]
        \\}
    );
    var cfg = try (config.Config{
        .brain_root = "/tmp/brain",
        .llm_providers_path = "/tmp/brain/llm_providers.json",
    }).loadForBrain(allocator, fs_state.filesystem(), std.testing.io);
    cfg.ai_mode = "random";
    cfg.conversation_reasoning_effort = "medium";
    cfg.psyche_reasoning_effort = "low";
    try config.saveLlmProviders(allocator, fs_state.filesystem(), std.testing.io, cfg);
    var reloaded = try config_files.loadLlmConfigFromPath(allocator, fs_state.filesystem(), std.testing.io, cfg.llm_providers_path);
    defer reloaded.deinit(allocator);
    try std.testing.expectEqualStrings("random", reloaded.mode.?);
    try std.testing.expectEqualStrings("medium", reloaded.reasoning_effort.?);
    try std.testing.expectEqual(@as(usize, 3), reloaded.conversation_roster.entries.len);
}

test "withBrainSettings rejects invalid capacity" {
    const cfg = config.Config{};
    const err = cfg.withBrainSettings(.{
        .capacity = .{
            .memory_selected_max = 20,
            .memory_prefilter_max = 10,
        },
    });
    try std.testing.expectError(error.MemorySelectedExceedsPrefilter, err);
}

test "provisionBrainConfigFiles seeds missing llm_providers.json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fs_state = MemoryFileSystem.init(allocator);
    defer fs_state.deinit();
    const cfg = config.Config{
        .brain_root = "/tmp/new-brain",
        .llm_providers_path = "/tmp/new-brain/llm_providers.json",
    };
    try config.provisionBrainConfigFiles(allocator, fs_state.filesystem(), std.testing.io, cfg);
    const seeded = fs_state.files.get("/tmp/new-brain/llm_providers.json") orelse return error.TestExpectedEqual;
    try std.testing.expect(seeded.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, seeded, "\"mode\": \"random\"") != null);
}

test "saveRuntimeOptions round-trips capacity block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fs_state = MemoryFileSystem.init(allocator);
    defer fs_state.deinit();
    var cfg = config.Config{
        .brain_root = "/tmp/brain",
        .runtime_options_path = "/tmp/brain/runtime_options.json",
        .llm_quality = "best",
    };
    cfg.capacity.activity_stack_max = 6;
    cfg.capacity.memory_selected_max = 4;
    try config.saveRuntimeOptions(allocator, fs_state.filesystem(), std.testing.io, cfg);
    const parsed = try config.parseRuntimeOptionsConfig(allocator, .{}, fs_state.files.get("/tmp/brain/runtime_options.json").?);
    try std.testing.expectEqual(@as(usize, 6), parsed.capacity.activity_stack_max);
    try std.testing.expectEqual(@as(usize, 4), parsed.capacity.memory_selected_max);
}

test "appendCapacityObservation includes attention_capacity header" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    const cfg = config.CapacityConfig{};
    const model = read_models.CapacityModel{
        .configured = cfg,
        .focus_in_use = true,
        .activity_stack_depth = 2,
        .activity_active = true,
        .memory_total = 42,
        .open_loop_count = 1,
        .candidate_action_count = 0,
        .last_chat_tokens = 1200,
        .budget_exceeded_count = 0,
        .under_pressure = false,
    };
    try cognitive_capacity.appendCapacityObservation(std.testing.allocator, cfg, model, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "attention_capacity:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "stack=2/8") != null);
}
