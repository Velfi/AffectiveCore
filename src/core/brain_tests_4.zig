const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const schema = @import("../storage/schema.zig");
const chat_mod = @import("../api/chat_client.zig");
const openai = @import("../api/openai_client.zig");
const audio_mod = @import("../api/audio_client.zig");
const autonomy_mod = @import("../api/autonomy_client.zig");
const image_mod = @import("../api/image_client.zig");
const email_mod = @import("../api/email_client.zig");
const want_achievement_mod = @import("../api/want_achievement_client.zig");
const psyche_client = @import("../api/psyche_client.zig");
const input_mod = @import("../platform/common/input.zig");
const facial_expression = @import("../platform/common/facial_expression.zig");
const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const interrupt_mod = @import("interrupt.zig");
const seed_mod = @import("seed.zig");
const greeting = @import("greeting_policy.zig");
const facts = @import("facts.zig");
const vector_index = @import("vector_index.zig");
const time_mod = @import("time.zig");
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;
const TestStore = store_support.TestStore;
const TestInput = support.TestInput;
const TestIdMonitor = support.TestIdMonitor;
const TestInterruptSource = support.TestInterruptSource;
const TestCommandLog = support.TestCommandLog;
const TestFacialExpressionOutput = support.TestFacialExpressionOutput;
const ScriptedDreamChatService = support.ScriptedDreamChatService;
const ScriptedRememberPersonChatService = support.ScriptedRememberPersonChatService;
const ScriptedRecallChatService = support.ScriptedRecallChatService;
const ScriptedClarificationChatService = support.ScriptedClarificationChatService;
const ScriptedHardErrorRecoveryChatService = support.ScriptedHardErrorRecoveryChatService;
const HeardSpeechObservationChatService = support.HeardSpeechObservationChatService;
const FailingIdentityClaimIntentService = support.FailingIdentityClaimIntentService;
const makeBrain = support.makeBrain;
const addMara = support.addMara;
const addZelda = support.addZelda;
const countOccurrences = support.countOccurrences;
const findMemoryById = helpers.findMemoryById;
const findMemoryWithTagForTest = helpers.findMemoryWithTagForTest;
const runtimeEventsContain = helpers.runtimeEventsContain;
const tagInSlice = helpers.tagInSlice;
const wantReinforcementStrength = helpers.wantReinforcementStrength;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;

test "uploaded image conversation does not capture or recognize speaker first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    const text = "Please look at this uploaded image.\n[uploaded_image path=\"data/test/image.png\" source=\"drop\"]";
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{text}, &store, &desc);

    try brain.handleConversationTurn();

    try std.testing.expectEqual(@as(usize, 0), store.people.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.sightings.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.conversation_summaries.items.len);
    try std.testing.expectEqualStrings("data/test/image.png", brain.last_visual_observation_path.?);
    try std.testing.expect(brain.last_visual_observation_uploaded);
}

test "describe image prefers uploaded visual observation over live camera" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.last_visual_observation_path = "data/test/image.png";
    brain.last_visual_observation_uploaded = true;

    const text = try brain.describeImageForObservation("colors");

    try std.testing.expect(std.mem.indexOf(u8, text, "image: data/test/image.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Focus: colors") != null);
    try std.testing.expect(brain.last_visual_observation_uploaded);
}

test "describe image uses uploaded visual observation when live camera is unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.capabilities.live_camera = false;
    brain.last_visual_observation_path = "data/test/image.png";

    const text = try brain.describeImageForObservation("colors");

    try std.testing.expect(std.mem.indexOf(u8, text, "image: data/test/image.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Focus: colors") != null);
}

test "missing remembered image is reported as not remembered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{ .missing_image_path = "data/test/missing_recalled_image.png" };
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.capabilities.live_camera = false;
    brain.last_visual_observation_path = "data/test/missing_recalled_image.png";
    brain.last_visual_observation_uploaded = true;
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .describe_image, .query = "colors" }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "image_description:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "remembered: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "reason: missing_file") != null);
    try std.testing.expect(brain.last_visual_observation_path == null);
    try std.testing.expect(!brain.last_visual_observation_uploaded);
}

test "compare image command requires stored visual observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .compare_images, .query = "desk" }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: compare_images: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "no previous retained visual observation") != null);
}

test "get_time reports date time only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .get_time }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "time:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "datetime: 2026-06-23T12:30:00-05:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "battery_BAT0") == null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "external_power") == null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "storage_/") == null);
}

test "get_power reports battery and plugged in state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .get_power }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "power:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "battery_BAT0: 42% Discharging") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "external_power: plugged_in") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "storage_/") == null);
}

test "get_storage reports storage fullness only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .get_storage }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "storage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "storage_/: 75% used") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "battery_BAT0") == null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "external_power") == null);
}

test "get_database_stats reports sqlite database stats only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .get_database_stats }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "database:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "database_memory: total_bytes=40960") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "database_relationship_graph: total_bytes=49152") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "battery_BAT0") == null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "storage_/") == null);
}

test "facial expression is unavailable without output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .facial_expression, .eyes = "unfocused", .mouth = "smirk" }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: facial_expression: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "facial expression output is not configured") != null);
}

test "facial expression shows valid sprites with default duration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var expression_output = TestFacialExpressionOutput{};
    brain.deps.facial_expression_output = expression_output.output();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .facial_expression, .eyes = "unfocused", .mouth = "smirk" }};

    const result = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expectEqual(@as(usize, 1), expression_output.calls);
    try std.testing.expectEqualStrings("unfocused", expression_output.eyes.?);
    try std.testing.expectEqualStrings("smirk", expression_output.mouth.?);
    try std.testing.expectEqual(@as(u32, facial_expression.default_duration_ms), expression_output.duration_ms);
    try std.testing.expect(result.spoken_text == null);
    try std.testing.expect(!result.ended_with_speech);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "facial_expression_shown: eyes=unfocused mouth=smirk duration_ms=3000") != null);
}

test "facial expression fails loudly for invalid sprites and long duration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var expression_output = TestFacialExpressionOutput{};
    brain.deps.facial_expression_output = expression_output.output();
    var observations = std.ArrayList(u8).empty;
    var bad_sprite = [_]chat_mod.ChatCommand{.{ .command = .facial_expression, .eyes = "nope", .mouth = "smirk" }};
    try std.testing.expectError(error.UnknownFacialExpressionEyes, brain.executeChatCommands(bad_sprite[0..], &observations));

    var long_duration = [_]chat_mod.ChatCommand{.{ .command = .facial_expression, .eyes = "unfocused", .mouth = "smirk", .duration_ms = facial_expression.max_duration_ms + 1 }};
    try std.testing.expectError(error.FacialExpressionDurationTooLong, brain.executeChatCommands(long_duration[0..], &observations));
}

test "introspection reports autonomy energy state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_introspect_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "on";
    brain.cfg.autonomy_daily_energy = 20;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    try maintenance.saveAutonomyState(allocator, std.testing.io, state_path, .{
        .sleeping = false,
        .energy_remaining = 13,
        .energy_day_key = try brain.localDayKey(std.testing.io),
    });

    const text = try brain.introspect();
    try std.testing.expect(std.mem.indexOf(u8, text, "autonomy: enabled=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "energy_remaining=13") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "daily_energy_allowance=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "autonomy_energy_costs") != null);
}

fn seedDueAutonomyState(allocator: std.mem.Allocator, brain: *Brain, state_path: []const u8, energy_remaining: u32) !void {
    const day_key = try brain.localDayKey(std.testing.io);
    try maintenance.saveAutonomyState(allocator, std.testing.io, state_path, .{
        .sleeping = false,
        .energy_remaining = energy_remaining,
        .energy_day_key = day_key,
        .last_autonomy_tick_at = brain.now_seconds - @as(i64, @intCast(brain.cfg.autonomy_interval_seconds)),
    });
}

test "autonomy first enabled poll arms interval without spending energy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_armed_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "on";
    brain.cfg.autonomy_daily_energy = 20;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{} };
    brain.deps.autonomy_planner = scripted.planner();

    try brain.runAutonomyTick(std.testing.io);
    const day_key = try brain.localDayKey(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 20, day_key);
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expectEqual(@as(u32, 20), state.energy_remaining);
    try std.testing.expectEqual(brain.now_seconds, state.last_autonomy_tick_at.?);
    try std.testing.expectEqualStrings("autonomy armed", state.last_reason.?);
}

test "waking autonomy starts interval without immediate planner spend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_wake_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "on";
    brain.cfg.autonomy_daily_energy = 20;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    const day_key = try brain.localDayKey(std.testing.io);
    try maintenance.saveAutonomyState(allocator, std.testing.io, state_path, .{
        .sleeping = true,
        .energy_remaining = 20,
        .energy_day_key = day_key,
        .last_autonomy_tick_at = brain.now_seconds - 3600,
    });
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{} };
    brain.deps.autonomy_planner = scripted.planner();

    try brain.setAutonomySleeping(false, "user requested wake");
    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 20, day_key);
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expectEqual(@as(u32, 20), state.energy_remaining);
    try std.testing.expectEqual(brain.now_seconds, state.last_autonomy_tick_at.?);
    try std.testing.expectEqualStrings("user requested wake", state.last_reason.?);
}

test "autonomy tick deducts planner and quiet action energy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_energy_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "on";
    brain.cfg.autonomy_daily_energy = 20;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .command = .{ .command = .think_about, .query = "energy", .tags = &[_][]const u8{"self"} },
        .salience = .medium,
        .reason = "energy self-check",
    }} };
    var psyche = psyche_client.ScriptedPsycheService{
        .id_turn = .{ .top_need = "preserve energy", .urges = &[_][]const u8{"check limits"}, .random_thoughts = &[_][]const u8{"battery"}, .desired_action_bias = "think_about energy", .salience = .medium, .reason = "energy matters" },
        .superego_turn = .{ .concerns = &[_][]const u8{"avoid waste"}, .vetoes = &[_][]const u8{"speech"}, .preferred_restraints = &[_][]const u8{"quiet self-work"}, .values_to_preserve = &[_][]const u8{"conservation"}, .salience = .medium, .reason = "stay within budget" },
    };
    brain.deps.autonomy_planner = scripted.planner();
    brain.deps.psyche_service = psyche.service();
    try seedDueAutonomyState(allocator, &brain, state_path, 20);

    try brain.runAutonomyTick(std.testing.io);
    const day_key = try brain.localDayKey(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 20, day_key);
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(usize, 1), psyche.id_calls);
    try std.testing.expectEqual(@as(usize, 1), psyche.superego_calls);
    try std.testing.expectEqualStrings(psyche.last_id_context, psyche.last_superego_context);
    try std.testing.expectEqual(@as(u32, 18), state.energy_remaining);
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
}

test "autonomy facial expression costs zero and respects cooldown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_expression_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var expression_output = TestFacialExpressionOutput{};
    brain.deps.facial_expression_output = expression_output.output();
    brain.cfg.autonomy_mode = "on";
    brain.cfg.psyche_mode = "off";
    brain.cfg.autonomy_interval_seconds = 1;
    brain.cfg.autonomy_daily_energy = 20;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{
        .{ .command = .{ .command = .facial_expression, .eyes = "neutral", .mouth = "open", .duration_ms = 5000 }, .salience = .low, .reason = "visible reaction" },
        .{ .command = .{ .command = .facial_expression, .eyes = "stern", .mouth = "frown", .duration_ms = 1000 }, .salience = .low, .reason = "too soon" },
    } };
    brain.deps.autonomy_planner = scripted.planner();
    try seedDueAutonomyState(allocator, &brain, state_path, 20);

    try brain.runAutonomyTick(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), expression_output.calls);
    try std.testing.expectEqualStrings("neutral", expression_output.eyes.?);
    const day_key = try brain.localDayKey(std.testing.io);
    var state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 20, day_key);
    try std.testing.expectEqual(@as(u32, 19), state.energy_remaining);

    brain.now_seconds += 1;
    try brain.runAutonomyTick(std.testing.io);
    state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 20, day_key);
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
    try std.testing.expectEqual(@as(usize, 1), expression_output.calls);
    try std.testing.expectEqual(@as(u32, 18), state.energy_remaining);
    try std.testing.expect(std.mem.indexOf(u8, state.last_reason.?, "facial expression suppressed: cooldown") != null);
}

test "autonomy suppresses low salience speech without spending speech energy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_speech_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "on";
    brain.cfg.autonomy_daily_energy = 20;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .command = .{ .command = .say, .text = "A small thought." },
        .salience = .medium,
        .reason = "not important enough",
    }} };
    var psyche = psyche_client.ScriptedPsycheService{
        .id_turn = .{ .top_need = "say something", .urges = &[_][]const u8{"speak"}, .random_thoughts = &[_][]const u8{"small thought"}, .desired_action_bias = "say", .salience = .medium, .reason = "wants contact" },
        .superego_turn = .{ .concerns = &[_][]const u8{"not urgent"}, .vetoes = &[_][]const u8{}, .preferred_restraints = &[_][]const u8{"do not spend speech"}, .values_to_preserve = &[_][]const u8{"restraint"}, .salience = .medium, .reason = "speech should be rare" },
    };
    brain.deps.autonomy_planner = scripted.planner();
    brain.deps.psyche_service = psyche.service();
    try seedDueAutonomyState(allocator, &brain, state_path, 20);

    try brain.runAutonomyTick(std.testing.io);
    const day_key = try brain.localDayKey(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 20, day_key);
    try std.testing.expectEqual(@as(u32, 19), state.energy_remaining);
    try std.testing.expect(state.last_autonomous_speech_at == null);
    try std.testing.expect(std.mem.indexOf(u8, state.last_reason.?, "salience") != null);
}

test "autonomy pauses while human input is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_input_active_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const input: *TestInput = @ptrCast(@alignCast(brain.deps.input.ctx));
    input.active = true;
    brain.cfg.autonomy_mode = "on";
    brain.cfg.autonomy_daily_energy = 20;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .command = .{ .command = .say, .text = "Can I interrupt?" },
        .salience = .high,
        .reason = "would like to speak",
    }} };
    brain.deps.autonomy_planner = scripted.planner();
    try seedDueAutonomyState(allocator, &brain, state_path, 20);

    try brain.runAutonomyTick(std.testing.io);
    const day_key = try brain.localDayKey(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 20, day_key);
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expectEqual(@as(u32, 20), state.energy_remaining);
    try std.testing.expect(std.mem.indexOf(u8, state.last_reason.?, "human input active") != null);
}

test "autonomy ask_human logs chat question and sleeps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_ask_human_state.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "on";
    brain.cfg.psyche_mode = "off";
    brain.cfg.autonomy_daily_energy = 20;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var log = TestCommandLog{};
    brain.deps.command_log = log.log();
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .command = .{ .command = .ask_human, .text = "Should I keep self-directed actions paused?" },
        .salience = .high,
        .reason = "needs human guidance",
    }} };
    brain.deps.autonomy_planner = scripted.planner();
    try seedDueAutonomyState(allocator, &brain, state_path, 20);

    try brain.runAutonomyTick(std.testing.io);
    const day_key = try brain.localDayKey(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, std.testing.io, state_path, false, 20, day_key);
    try std.testing.expect(state.sleeping);
    try std.testing.expectEqualStrings("Should I keep self-directed actions paused?", log.brain_body.?);
    try std.testing.expect(std.mem.indexOf(u8, state.last_reason.?, "waiting for a response") != null);
}
