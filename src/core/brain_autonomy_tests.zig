const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const autonomy_mod = ports.autonomy;
const process_goal_mod = ports.process_goal;
const psyche_client = ports.psyche;
const maintenance = @import("maintenance.zig");
const config_mod = @import("config.zig");
const time_mod = @import("time.zig");
const experience_kinds = @import("experience_kinds.zig");
const brain_autonomy = @import("brain_autonomy.zig");
const process_goal_resolver = @import("process_goal_resolver.zig");
const process_recipe_memory = @import("process_recipe_memory.zig");
const helpers = @import("brain_helpers.zig");
const read_models = @import("read_models.zig");
const subsystems = @import("subsystems.zig");

const seedDueAutonomyState = support.seedDueAutonomyState;
const eventKindSeen = support.eventKindSeen;
const stringSliceContains = support.stringSliceContains;
const ScriptedProcessGoalChatService = support.ScriptedProcessGoalChatService;

const Brain = brain_mod.Brain;
const TestStore = store_support.TestStore;
const TestInput = support.TestInput;
const TestIdMonitor = support.TestIdMonitor;
const TestInterruptSource = support.TestInterruptSource;
const TestEventLog = support.TestEventLog;
const TestFacialExpressionOutput = support.TestFacialExpressionOutput;
const TestClock = support.TestClock;
const ScriptedRememberPersonChatService = support.ScriptedRememberPersonChatService;
const ScriptedIdentityClaimChatService = support.ScriptedIdentityClaimChatService;
const ScriptedForgetPersonChatService = support.ScriptedForgetPersonChatService;
const ScriptedRecallChatService = support.ScriptedRecallChatService;
const ScriptedClarificationChatService = support.ScriptedClarificationChatService;
const ScriptedHardErrorRecoveryChatService = support.ScriptedHardErrorRecoveryChatService;
const HeardSpeechObservationChatService = support.HeardSpeechObservationChatService;
const ScriptedContinuingChatService = support.ScriptedContinuingChatService;
const makeBrain = support.makeBrain;
const writeAndRefreshFacialExpressionCatalog = support.writeAndRefreshFacialExpressionCatalog;

const test_avatar_json_autonomy_expressions =
    \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"frame":0,"row":0,"column":0,"name":"neutral"},{"frame":0,"row":0,"column":1,"name":"stern"}],"mouthSprites":[{"frame":0,"row":0,"column":0,"name":"open"},{"frame":0,"row":0,"column":1,"name":"frown"}]}
;
const addMara = support.addMara;
const addZelda = support.addZelda;
const countOccurrences = support.countOccurrences;
const findMemoryById = helpers.findMemoryById;
const findMemoryWithTagForTest = helpers.findMemoryWithTagForTest;
const experienceEventsContain = helpers.experienceEventsContain;
const tagInSlice = helpers.tagInSlice;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;

test "introspection reports autonomy control state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_introspect_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = false,
        .control_capacity = 40,
        .max_capacity = 50,
        .social_engagement = 0.30,
        .consecutive_voluntary_speech = 2,
    });

    const text = try brain.introspect("autonomy");
    try std.testing.expect(std.mem.indexOf(u8, text, "attention_agency: background_mode=full") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "agency_capacity=40.00/50.00") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "voluntary_speech_streak=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "agency_effort_catalog") != null);
}

test "autonomy replenish bootstraps timestamp without immediate gain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_armed_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;

    try brain.runAutonomyReplenish(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expectEqual(brain.now_seconds, state.last_capacity_replenish_at.?);
    try std.testing.expectEqual(state.max_capacity, state.control_capacity);
}

test "autonomy replenishes control capacity over time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_replenish_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.autonomy_full_replenish_actions_per_minute = 60;
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = false,
        .control_capacity = 5,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
        .last_capacity_replenish_at = brain.now_seconds - 10,
    });

    try brain.runAutonomyReplenish(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expect(state.control_capacity > 5);
}

test "autonomy replenish rate follows active mode" {
    const limited_cfg = config_mod.Config{
        .autonomy_mode = "limited",
        .autonomy_limited_replenish_actions_per_minute = 2.0,
        .autonomy_full_replenish_actions_per_minute = 8.0,
    };
    const full_cfg = config_mod.Config{
        .autonomy_mode = "full",
        .autonomy_limited_replenish_actions_per_minute = 2.0,
        .autonomy_full_replenish_actions_per_minute = 8.0,
    };
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 60.0), brain_autonomy.autonomyReplenishRatePerSecond(limited_cfg), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 60.0), brain_autonomy.autonomyReplenishRatePerSecond(full_cfg), 0.000001);
}

test "waking autonomy can plan immediately when capacity is available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_wake_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = true,
        .control_capacity = 40,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
        .last_capacity_replenish_at = brain.now_seconds - 3600,
    });
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .action_pressures = &[_]chat_mod.ActionProposal{.{ .action = .think_about, .origin = .autonomy, .query = "wake check", .tags = &[_][]const u8{"self"} }},
        .salience = .low,
        .reason = "post-wake self check",
    }} };
    brain.deps.autonomy_planner = scripted.planner();
    brain.cfg.psyche_mode = "off";

    try brain.setAutonomySleeping(false, "user requested wake");
    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expect(state.control_capacity > 0.0);
    try std.testing.expect(std.mem.indexOf(u8, state.last_reason.?, "post-wake self check") != null);
}

test "autonomy tick spends control capacity for quiet action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_energy_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .action_pressures = &[_]chat_mod.ActionProposal{.{ .action = .think_about, .origin = .autonomy, .query = "energy", .tags = &[_][]const u8{"self"} }},
        .salience = .medium,
        .reason = "energy self-check",
    }} };
    var psyche = psyche_client.ScriptedPsycheService{
        .id_turn = .{ .top_need = "preserve energy", .urges = &[_][]const u8{"check limits"}, .random_thoughts = &[_][]const u8{"battery"}, .desired_action_bias = "think_about energy", .salience = .medium, .reason = "energy matters" },
        .superego_turn = .{ .concerns = &[_][]const u8{"avoid waste"}, .vetoes = &[_][]const u8{"speech"}, .preferred_restraints = &[_][]const u8{"quiet self-work"}, .values_to_preserve = &[_][]const u8{"conservation"}, .salience = .medium, .reason = "stay within budget" },
    };
    brain.deps.autonomy_planner = scripted.planner();
    brain.deps.psyche_service = psyche.service();
    brain.cfg.psyche_mode = "on";
    try seedDueAutonomyState(allocator, &brain, state_path, brain.cfg.autonomy_full_max_capacity);

    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(usize, 1), psyche.id_calls);
    try std.testing.expectEqual(@as(usize, 1), psyche.superego_calls);
    try std.testing.expectEqualStrings(psyche.last_id_context, psyche.last_superego_context);
    try std.testing.expect(state.control_capacity < state.max_capacity);
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
}

test "low salience stimulus integrates attention without planner speech pressure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/attention_low_salience_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "off";
    brain.cfg.psyche_mode = "off";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{} };
    brain.deps.autonomy_planner = scripted.planner();
    try brain.stimulus_inbox.enqueue(allocator, .typing, brain.now_seconds, 0.15, null, "draft text");

    try brain.runAutonomyTick(std.testing.io);

    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expectEqual(@as(usize, 0), brain.stimulus_inbox.pendingCount());
}

test "autonomy facial expression runs on consecutive ticks without cooldown delay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_expression_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var clock = TestClock{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.clock = clock.clock();
    brain.deps.io = std.testing.io;
    var expression_output = TestFacialExpressionOutput{};
    defer expression_output.deinit();
    brain.deps.facial_expression_output = expression_output.output();
    try writeAndRefreshFacialExpressionCatalog(&brain, allocator, std.testing.io, "/tmp/test-brain-autonomy-expression", test_avatar_json_autonomy_expressions);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.psyche_mode = "off";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{
        .{ .action_pressures = &[_]chat_mod.ActionProposal{.{ .action = .facial_expression, .origin = .autonomy, .eyes = "neutral", .mouth = "open", .duration_ms = 3000 }}, .salience = .low, .reason = "visible reaction" },
        .{ .action_pressures = &[_]chat_mod.ActionProposal{.{ .action = .facial_expression, .origin = .autonomy, .eyes = "stern", .mouth = "frown", .duration_ms = 1000 }}, .salience = .low, .reason = "second expression" },
        .{ .action_pressures = &[_]chat_mod.ActionProposal{}, .salience = .low, .reason = "capacity hold" },
    } };
    brain.deps.autonomy_planner = scripted.planner();
    try seedDueAutonomyState(allocator, &brain, state_path, brain.cfg.autonomy_full_max_capacity);

    try brain.runAutonomyTick(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), expression_output.calls);
    try std.testing.expectEqualStrings("neutral", expression_output.eyes.?);
    var state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expect(state.control_capacity < state.max_capacity);
    try std.testing.expect(state.last_autonomy_tick_at != null);

    clock.now_seconds += 1;
    try brain.runAutonomyTick(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
    try std.testing.expectEqual(@as(usize, 2), expression_output.calls);

    clock.now_seconds += 1;
    try brain.pollStimulusInbox();
    try brain.runAutonomyTick(std.testing.io);
    state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expectEqual(@as(usize, 3), scripted.calls);
    try std.testing.expectEqual(@as(usize, 2), expression_output.calls);
    try std.testing.expect(state.control_capacity < state.max_capacity);
}

test "autonomy pauses while human input is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_input_active_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    const input: *TestInput = @ptrCast(@alignCast(brain.deps.input.ctx));
    input.active = true;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .action_pressures = &[_]chat_mod.ActionProposal{.{ .action = .say, .origin = .autonomy, .text = "Can I interrupt?" }},
        .salience = .high,
        .reason = "would like to speak",
    }} };
    brain.deps.autonomy_planner = scripted.planner();
    try seedDueAutonomyState(allocator, &brain, state_path, brain.cfg.autonomy_full_max_capacity);

    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(state.control_capacity > 0.0);
    try std.testing.expect(std.mem.indexOf(u8, state.last_reason.?, "human input active") != null);
}

test "autonomy say logs chat question without forcing sleep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_say_question_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.psyche_mode = "off";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var log = TestEventLog{};
    defer log.deinit();
    brain.deps.event_log = log.log();
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .action_pressures = &[_]chat_mod.ActionProposal{.{ .action = .say, .origin = .autonomy, .text = "Should I keep self-directed actions paused?" }},
        .salience = .high,
        .reason = "needs human guidance",
    }} };
    brain.deps.autonomy_planner = scripted.planner();
    try seedDueAutonomyState(allocator, &brain, state_path, brain.cfg.autonomy_full_max_capacity);

    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expect(!state.sleeping);
    if (log.brain_body) |body| try std.testing.expectEqualStrings("Should I keep self-directed actions paused?", body);
    try std.testing.expect(std.mem.indexOf(u8, state.last_reason orelse "", "needs human guidance") != null);
}

test "quiet hours resolve from wall clock without process runner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.process_runner = null;
    brain.deps.io = std.testing.io;
    brain.cfg.autonomy_mode = "limited";
    brain.cfg.autonomy_quiet_hours = "00:00-23:59";

    const io = brain.deps.io.?;
    try std.testing.expect(try brain_autonomy.inQuietHours(&brain, io));
    const day_key = try brain.localDayKey(io);
    defer allocator.free(day_key);
    try std.testing.expect(day_key.len == 10);
}

test "autonomy tick wakes persisted sleep outside quiet hours" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_wake_outside_quiet_hours_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.psyche_mode = "off";
    brain.cfg.maintenance_state_path = state_path;
    brain.cfg.autonomy_sleep = "off";
    // Empty window: quiet hours are never active.
    brain.cfg.autonomy_quiet_hours = "12:00-12:00";
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .action_pressures = &[_]chat_mod.ActionProposal{.{ .action = .say, .origin = .autonomy, .text = "Good morning." }},
        .salience = .high,
        .reason = "woke after rest",
    }} };
    brain.deps.autonomy_planner = scripted.planner();
    try seedDueAutonomyState(allocator, &brain, state_path, brain.cfg.autonomy_full_max_capacity);
    try brain.setAutonomySleeping(true, "test rest");

    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expect(!state.sleeping);
    try std.testing.expect(state.last_woken_at != null);
}

test "autonomy tick keeps persisted sleep during quiet hours" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_sleep_during_quiet_hours_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.psyche_mode = "off";
    brain.cfg.maintenance_state_path = state_path;
    brain.cfg.autonomy_sleep = "off";
    brain.cfg.autonomy_quiet_hours = "00:00-23:59";
    brain.deps.io = std.testing.io;
    try seedDueAutonomyState(allocator, &brain, state_path, brain.cfg.autonomy_full_max_capacity);
    try brain.setAutonomySleeping(true, "test rest");

    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expect(state.sleeping);
}

test "autonomy expands process goals before execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_process_goal_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.psyche_mode = "off";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var composed_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .think_about, .origin = .autonomy, .query = "touch stimulus" },
    };
    var composer = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &composed_pressures,
            .reason = "reflect on touch",
        },
    };
    brain.deps.process_composer = composer.composer();
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{.{
        .action_pressures = &[_]chat_mod.ActionProposal{.{ .action = .unknown, .origin = .autonomy, .process_goal = "investigate_touch" }},
        .salience = .high,
        .reason = "curious touch",
    }} };
    brain.deps.autonomy_planner = scripted.planner();
    try seedDueAutonomyState(allocator, &brain, state_path, brain.cfg.autonomy_full_max_capacity);

    try brain.runAutonomyTick(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), scripted.calls);
    try std.testing.expectEqual(@as(usize, 1), composer.calls);
    try std.testing.expectEqualStrings("investigate_touch", composer.last_goal);
    const recipe = try process_recipe_memory.lookupRecipe(&brain, "investigate_touch", .autonomy);
    defer if (recipe) |loaded| process_recipe_memory.freeRecipe(allocator, loaded);
    try std.testing.expect(recipe != null);
    try std.testing.expect(store.memories.items.len >= 1);
    try std.testing.expectEqual(@as(u64, 1), brain.context_stats.total_process_goal_count);
    try std.testing.expectEqual(@as(u64, 1), brain.context_stats.total_composed_steps);
}

test "autonomy tick skips planner when control capacity is overdrawn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_exhausted_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{} };
    brain.deps.autonomy_planner = scripted.planner();
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = false,
        .control_capacity = -5,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
        .last_capacity_replenish_at = brain.now_seconds - 3600,
    });

    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(!state.sleeping);
    try std.testing.expectEqualStrings("autonomy_overdrawn", state.last_reason.?);
}

test "salient pending speech wakes sleeping autonomy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_wake_on_stimulus_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{} };
    brain.deps.autonomy_planner = scripted.planner();
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = true,
        .control_capacity = 10,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
        .last_reason = "user requested sleep",
    });
    try brain.stimulus_inbox.enqueue(allocator, .heard_speech, brain.now_seconds, 0.85, null, "Hello?");

    brain.runAutonomyTick(std.testing.io) catch |err| switch (err) {
        // Waking is persisted before planning; the sparse test harness may
        // not carry the full planning pipeline.
        error.MissingPsycheService, error.MissingAutonomyPlanner, error.NoScriptedAutonomyTurn, error.LocalDateUnavailable => {},
        else => return err,
    };
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expect(!state.sleeping);
    try std.testing.expect(state.last_woken_at != null);
    try std.testing.expect(std.mem.startsWith(u8, state.last_reason.?, "woke:"));
}

test "idle tick leaves sleeping autonomy asleep" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_sleep_idle_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    // Sleep only persists inside the quiet-hours window now; pin it open so
    // this test stays deterministic regardless of wall clock.
    brain.cfg.autonomy_quiet_hours = "00:00-23:59";
    brain.deps.io = std.testing.io;
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{} };
    brain.deps.autonomy_planner = scripted.planner();
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = true,
        .control_capacity = 10,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
        .last_reason = "user requested sleep",
    });

    try brain.runAutonomyTick(std.testing.io);
    const state = try maintenance.loadAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, false, "full", .{
        .limited_max_capacity = brain.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = brain.cfg.autonomy_full_max_capacity,
    });
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(state.sleeping);
}

test "wake hold declines sleep until it expires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_wake_hold_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = support.makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = false,
        .control_capacity = 10,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
        .last_woken_at = brain.now_seconds,
    });
    try std.testing.expect((try brain.sleepDeclineRemainingSeconds()) != null);

    const hold: i64 = @intCast(brain.cfg.autonomy_wake_hold_seconds);
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = false,
        .control_capacity = 10,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
        .last_woken_at = brain.now_seconds - hold - 1,
    });
    try std.testing.expectEqual(@as(?i64, null), try brain.sleepDeclineRemainingSeconds());
}

test "autonomy overdrawn logs blocked status to developer event log" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/autonomy_exhausted_event_log_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var log = TestEventLog{};
    defer log.deinit();
    brain.deps.event_log = log.log();
    var scripted = autonomy_mod.ScriptedAutonomyPlanner{ .turns = &[_]autonomy_mod.AutonomyTurn{} };
    brain.deps.autonomy_planner = scripted.planner();
    try maintenance.saveAutonomyState(allocator, brain.deps.filesystem.?, std.testing.io, state_path, .{
        .sleeping = false,
        .control_capacity = -5,
        .max_capacity = brain.cfg.autonomy_full_max_capacity,
        .last_capacity_replenish_at = brain.now_seconds - 3600,
    });

    try brain.runAutonomyTick(std.testing.io);
    try std.testing.expectEqualStrings("state", log.kind.?);
    try std.testing.expectEqualStrings("autonomy blocked", log.title.?);
    try std.testing.expectEqualStrings("autonomy_overdrawn", log.body.?);
}

test "dream time request delivers mailbox item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    support.wireTestIo(&brain);
    const item = try brain.requestDreamTime("Connect plant reminders with morning greetings");
    try std.testing.expectEqual(@as(usize, 1), store.dream_time_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.mailbox_items.items.len);
    try std.testing.expectEqualStrings(item.mailbox_id, store.mailbox_items.items[0].mailbox_id);
    try std.testing.expectEqualStrings(item.source_dream_id.?, store.dream_time_records.items[0].dream_id);
}

test "dream time persists causal belief self trust disposition and mailbox chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    support.wireTestIo(&brain);
    const residue_event = try brain.recordSimpleExperienceEvent("User.TextReceived", .user, "The hallway recognition felt uncertain.");

    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_day_residue",
        .source_event_ids = @constCast(&[_][]const u8{residue_event.id}),
        .scope = .long_term,
        .text = "I was unsure whether the dim hallway face was Mara.",
        .interpretation = "Recognition uncertainty should affect future greetings.",
        .tags = @constCast(&[_][]const u8{"recognition"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 4,
        .salience = 0.85,
    });

    const item = try brain.requestDreamTime("dim hallway recognition uncertainty");

    try std.testing.expectEqual(schema.BrainMode.waking, try brain.deps.store.loadBrainMode());
    try std.testing.expectEqual(@as(usize, 1), store.dream_time_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.mailbox_items.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.artifacts.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.beliefs.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.self_trust.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.dispositions.items.len);
    try std.testing.expect(store.experience_events.items.len >= 6);

    const dream = store.dream_time_records.items[0];
    try std.testing.expectEqualStrings(dream.dream_id, item.source_dream_id.?);
    try std.testing.expectEqualStrings(item.mailbox_id, dream.delivered_mailbox_id.?);
    try std.testing.expectEqualStrings(store.artifacts.items[0].artifact_id, dream.generated_artifact_id.?);
    try std.testing.expectEqualStrings(store.artifacts.items[0].artifact_id, item.image_artifact_id.?);
    try std.testing.expectEqualStrings("dream_time_internal_synthesis", store.artifacts.items[0].provenance);
    try std.testing.expect(store.artifacts.items[0].source_event_ids.len > 0);
    try std.testing.expect(dream.source_event_ids.len >= 4);
    try std.testing.expect(stringSliceContains(dream.source_event_ids, residue_event.id));
    var persona_directive_event_id: ?[]const u8 = null;
    for (store.experience_events.items) |event| {
        if (std.mem.eql(u8, event.kind, experience_kinds.dream_time_persona_directive_synthesized)) {
            persona_directive_event_id = event.id;
            break;
        }
    }
    const persona_event_id = persona_directive_event_id orelse return error.MissingPersonaDirectiveEvent;
    try std.testing.expect(stringSliceContains(dream.source_event_ids, persona_event_id));
    try std.testing.expectEqual(@as(usize, 1), dream.source_memory_ids.len);
    try std.testing.expectEqualStrings("memory_day_residue", dream.source_memory_ids[0]);
    try std.testing.expectEqual(@as(usize, 0), dream.updated_belief_ids.len);
    try std.testing.expectEqual(@as(usize, 0), dream.self_trust_change_ids.len);
    try std.testing.expectEqual(@as(usize, 0), dream.disposition_change_ids.len);

    try std.testing.expectEqualStrings(dream.source_event_ids[0], item.source_event_ids[0]);
    try std.testing.expect(std.mem.indexOf(u8, item.text, "Overnight consolidation:") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.text, "Focus: dim hallway recognition uncertainty") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.image_spec_json, "dim hallway recognition uncertainty") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.image_spec_json, "recognition") != null);
    try std.testing.expect(std.mem.indexOf(u8, dream.maintenance_counts_json, "\"consolidation\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dream.maintenance_counts_json, "\"selected_memories\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dream.maintenance_counts_json, "\"pruning_passes\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.debug_details, "\"belief_updates\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.debug_details, "\"mailbox_deliveries\":1") != null);

    const snapshot = try brain.readModelsSnapshot(allocator);
    try std.testing.expectEqual(@as(usize, 0), snapshot.belief_model.active_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.self_trust_model.entry_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.disposition_model.disposition_count);
    try std.testing.expect(dream.persona.len > 0);
    try std.testing.expect(dream.short_term.len > 0);
    try std.testing.expect(dream.long_term.len > 0);
    try std.testing.expect(brain.persona_directive != null);
    try std.testing.expectEqualStrings(dream.persona, brain.persona_directive.?.persona);
    try std.testing.expectEqualStrings(dream.short_term, item.waking_thought);
    try std.testing.expectEqual(@as(usize, 1), store.persona_synthesizer.calls);
}

test "dream persona synthesis consults psyche when enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = "data/test/dream_persona_psyche_state.json";
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.psyche_mode = "on";
    brain.cfg.autonomy_mode = "full";
    brain.cfg.maintenance_state_path = state_path;
    brain.deps.io = std.testing.io;
    var psyche = psyche_client.ScriptedPsycheService{
        .id_turn = .{ .top_need = "stabilize identity", .urges = &[_][]const u8{"ask before guessing"}, .random_thoughts = &[_][]const u8{"hallway"}, .desired_action_bias = "clarify recognition", .salience = .medium, .reason = "uncertainty lingered" },
        .superego_turn = .{ .concerns = &[_][]const u8{"avoid false certainty"}, .vetoes = &[_][]const u8{}, .preferred_restraints = &[_][]const u8{"ask first"}, .values_to_preserve = &[_][]const u8{"honesty"}, .salience = .medium, .reason = "repair over performance" },
    };
    brain.deps.psyche_service = psyche.service();
    try seedDueAutonomyState(allocator, &brain, state_path, brain.cfg.autonomy_full_max_capacity);

    _ = try brain.requestDreamTime("consolidate uncertain recognition");

    try std.testing.expectEqual(@as(usize, 1), psyche.id_calls);
    try std.testing.expectEqual(@as(usize, 1), psyche.superego_calls);
    try std.testing.expect(std.mem.indexOf(u8, store.persona_synthesizer.last_context, "psyche_consult:") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.persona_synthesizer.last_context, "stabilize identity") != null);
    try std.testing.expect(std.mem.indexOf(u8, psyche.last_id_context, "dream_consolidation:") != null);
}

test "action pressures are proposed selected suppressed and visible in read models" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "full";
    brain.current_focus = .{
        .text = "reply to the user",
        .source = .self_set,
        .set_at = brain.now_seconds,
        .base_attention = 0.77,
    };
    brain.rememberVisualUpdate("fixtures/visitors/known_01.jpg");
    brain.setCurrentStimulusContext("user asked for speech");

    const stimulus = try brain.recordSimpleExperienceEvent("User.TextReceived", .user, "please speak");
    const pressure = try brain.proposeActionPressure(
        "LanguageMind",
        "reply_text",
        "text_reply",
        "The user addressed the brain directly.",
        0.82,
        0.70,
        0.10,
        &[_][]const u8{stimulus.id},
    );
    const selected = try brain.selectActionPressure(pressure);
    const quiet_pressure = try brain.proposeActionPressure(
        "Needs",
        "proactive_speech",
        "speech",
        "A low urgency proactive comment was possible.",
        0.22,
        0.15,
        0.30,
        &[_][]const u8{stimulus.id},
    );
    const suppressed = try brain.suppressActionPressure(quiet_pressure, "quiet policy gate");
    const snapshot = try brain.readModelsSnapshot(allocator);

    try std.testing.expectEqual(@as(usize, 2), store.action_pressures.items.len);
    try std.testing.expectEqual(@as(usize, 2), store.action_outcomes.items.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.action_pressure_count);
    try std.testing.expectEqualStrings("user asked for speech", snapshot.current_stimulus_model.text.?);
    try std.testing.expectEqualStrings("reply to the user", snapshot.focus_model.text.?);
    try std.testing.expectEqualStrings("self_set", snapshot.focus_model.source.?);
    try std.testing.expectEqual(@as(f32, 0.77), snapshot.focus_model.attention);
    try std.testing.expectEqualStrings("fixtures/visitors/known_01.jpg", snapshot.visual_state_model.last_observation_path.?);
    try std.testing.expect(snapshot.visual_state_model.awaited_host_request_id == null);
    try std.testing.expect(snapshot.visual_state_model.awaited_host_sense == null);
    try std.testing.expect(snapshot.visual_state_model.awaited_host_purpose == null);
    try std.testing.expectEqualStrings("full", snapshot.autonomy_control_model.mode);
    try std.testing.expect(snapshot.autonomy_control_model.max_capacity > 0.0);
    try std.testing.expectEqualStrings("LanguageMind", store.action_pressures.items[0].subsystem);
    try std.testing.expectEqualStrings(stimulus.id, store.action_pressures.items[0].causal_parent_ids[0]);
    try std.testing.expect(!selected.suppressed);
    try std.testing.expect(suppressed.suppressed);
    try std.testing.expectEqualStrings(pressure.pressure_id, selected.pressure_id);
    try std.testing.expectEqualStrings(quiet_pressure.pressure_id, suppressed.pressure_id);
}

test "maintenance request_dream_time delivers mailbox through Dream Time manager" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    support.wireTestIo(&brain);

    try brain.runMaintenanceCapability("request_dream_time:plant reminders");
    try std.testing.expectEqual(@as(usize, 1), store.dream_time_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.mailbox_items.items.len);
    try std.testing.expectEqualStrings(store.mailbox_items.items[0].source_dream_id.?, store.dream_time_records.items[0].dream_id);
    try std.testing.expect(eventKindSeen(store.experience_events.items, "DreamTime.Entered"));
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Mailbox.Delivered"));
}

test "unknown maintenance capability is a hard error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try std.testing.expectError(error.UnknownMaintenanceCapability, brain.runMaintenanceCapability("unsupported_maintenance_spec"));
}

test "dream time records source ids through canonical dream record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    support.wireTestIo(&brain);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_seed",
        .scope = .long_term,
        .text = "Plants need morning checks",
        .interpretation = "Plants need morning checks",
        .tags = @constCast(&[_][]const u8{"plants"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 1,
        .score = 5,
    });
    const item = try brain.requestDreamTime("A plant reminder becomes a morning ritual");
    try std.testing.expectEqual(@as(usize, 1), store.dream_time_records.items.len);
    try std.testing.expectEqualStrings(item.source_dream_id.?, store.dream_time_records.items[0].dream_id);
    try std.testing.expect(store.dream_time_records.items[0].source_memory_ids.len >= 1);
}

test "registered subsystems arbitrate action pressures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.current_focus = .{
        .text = "stay on topic",
        .source = .self_set,
        .set_at = brain.now_seconds,
        .base_attention = 0.80,
    };

    const stimulus = try brain.recordSimpleExperienceEvent("User.TextReceived", .user, "hello");
    const outcomes = try brain.arbitrateSubsystemPressures(allocator, .{
        .source_event_ids = &[_][]const u8{stimulus.id},
        .focus = "stay on topic",
    });
    defer allocator.free(outcomes);

    try std.testing.expect(outcomes.len >= 1);
    try std.testing.expect(store.action_pressures.items.len >= 1);
    try std.testing.expect(store.action_outcomes.items.len >= 1);
}

test "event backed subsystems emit concrete action pressures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const event: schema.ExperienceEvent = .{
        .id = "evt_subsystem_media_uncertain",
        .brain_id = brain.cfg.brain_id,
        .host_id = brain.currentHostId(),
        .timestamp_ms = brain.now_seconds * 1000,
        .source = .user,
        .kind = "User.MediaUploaded",
        .payload = "camera image with uncertain identity",
        .salience = 0.82,
        .confidence = 0.78,
        .valence = -0.20,
        .arousal = 0.48,
        .uncertainty = 0.72,
        .retention = .durable,
        .visibility = .internal,
    };
    try brain.recordExperienceEvent(event);

    const pressures = try subsystems.collectSubsystemPressures(&brain, allocator, .{
        .source_event_ids = &[_][]const u8{event.id},
    });
    defer allocator.free(pressures);

    var saw_pipeline = false;
    var saw_appraisal = false;
    var saw_belief = false;
    var saw_memory = false;
    var saw_focus = false;
    var saw_recognition = false;
    var saw_host_binding = false;
    for (pressures) |pressure| {
        if (std.mem.eql(u8, pressure.subsystem, "ExperiencePipeline")) saw_pipeline = true;
        if (std.mem.eql(u8, pressure.subsystem, "Appraisal")) saw_appraisal = true;
        if (std.mem.eql(u8, pressure.subsystem, "Belief")) saw_belief = true;
        if (std.mem.eql(u8, pressure.subsystem, "Memory")) saw_memory = true;
        if (std.mem.eql(u8, pressure.subsystem, "Focus")) saw_focus = true;
        if (std.mem.eql(u8, pressure.subsystem, "Recognition")) saw_recognition = true;
        if (std.mem.eql(u8, pressure.subsystem, "HostBinding")) saw_host_binding = true;
        if (pressure.causal_parent_ids.len > 0) {
            try std.testing.expectEqualStrings(event.id, pressure.causal_parent_ids[0]);
        }
    }

    try std.testing.expect(saw_pipeline);
    try std.testing.expect(saw_appraisal);
    try std.testing.expect(saw_belief);
    try std.testing.expect(saw_memory);
    try std.testing.expect(saw_focus);
    try std.testing.expect(saw_recognition);
    try std.testing.expect(saw_host_binding);
}

test "dream residue ignores capability failures outside waking period" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    support.wireTestIo(&brain);

    const yesterday_ms = brain.now_seconds * 1000 - 86_400_000;
    try store.store().addCapabilityResult(.{
        .request_id = "capreq_old_fail",
        .capability_id = "recognize",
        .state = .failed,
        .error_message = "ancient failure",
        .completed_at_ms = yesterday_ms,
    });
    try store.store().addCapabilityResult(.{
        .request_id = "capreq_recent_fail",
        .capability_id = "recall_fact",
        .state = .failed,
        .error_message = "today failure",
        .completed_at_ms = brain.now_seconds * 1000,
    });

    const item = try brain.requestDreamTime(null);
    try std.testing.expect(std.mem.indexOf(u8, item.text, "capability failures reviewed: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, item.text, "capability failures reviewed: 2") == null);
}

test "conversation expands process goals before executing skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{ "hello there" }, &store, &desc);
    var chat_service = ScriptedProcessGoalChatService{};
    brain.deps.chat_service = chat_service.service();
    var composed_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .think_about, .origin = .interaction, .query = "touch stimulus" },
        .{ .action = .say, .origin = .interaction, .text = "That touch felt intentional." },
    };
    var composer = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &composed_pressures,
            .reason = "reflect on touch",
        },
    };
    brain.deps.process_composer = composer.composer();

    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello there"), .{});
    defer allocator.free(result.spoken_text);
    defer allocator.free(result.user_summary);
    defer allocator.free(result.brain_summary);
    try std.testing.expectEqual(@as(usize, 1), composer.calls);
    try std.testing.expectEqualStrings("investigate_touch", composer.last_goal);
    try std.testing.expect(result.spoken_text.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.spoken_text, "That touch felt intentional.") != null);
    try std.testing.expectEqual(@as(u64, 1), brain.context_stats.total_process_goal_count);
    try std.testing.expectEqual(@as(u64, 2), brain.context_stats.total_composed_steps);
    try std.testing.expect(brain.context_stats.operations.get("process_composition.interaction") != null);
    try std.testing.expect(brain.active_process == null);
}

test "conversation process goal composition records stats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat_service = ScriptedProcessGoalChatService{};
    var composed_pressures = [_]chat_mod.ActionProposal{
        .{ .action = .think_about, .origin = .interaction, .query = "touch stimulus" },
    };
    var composer = process_goal_mod.ScriptedProcessComposer{
        .composition = .{
            .action_pressures = &composed_pressures,
            .reason = "reflect on touch",
        },
    };
    brain.deps.process_composer = composer.composer();

    const turn = try chat_service.service().respond(allocator, "memory", "hello there", "observations");
    const composition_context = try process_goal_resolver.buildChatCompositionContext(allocator, "memory", "hello there", "observations");
    defer allocator.free(composition_context);
    var expanded_turn = turn;
    try process_goal_resolver.expandChatTurn(&brain, &expanded_turn, composition_context);
    defer chat_mod.freeActionProposals(allocator, expanded_turn.action_pressures);

    try std.testing.expectEqual(@as(usize, 1), composer.calls);
    try std.testing.expectEqualStrings("investigate_touch", composer.last_goal);
    try std.testing.expectEqual(process_goal_mod.ComposeMode.interaction, composer.last_mode.?);
    try std.testing.expectEqual(@as(usize, 0), expanded_turn.action_pressures.len);
    try std.testing.expect(brain.active_process != null);
    try std.testing.expectEqualStrings("investigate_touch", brain.active_process.?.goal);
    try std.testing.expectEqual(@as(u64, 1), brain.context_stats.total_process_goal_count);
    try std.testing.expectEqual(@as(u64, 1), brain.context_stats.total_composed_steps);
    try std.testing.expect(brain.context_stats.operations.get("process_composition.interaction") != null);
}

test "drowsy mode blocks conversation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain.enterDrowsy();
    const result = try brain.handleConversationText(.{ .text = try allocator.dupe(u8, "hello"), .source = .typed_text }, .{});
    try std.testing.expectEqualStrings("", result.spoken_text);
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Conversation.BlockedByBrainMode"));
}

test "dreaming mode blocks conversation until host reinitialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    try brain.deps.store.setBrainMode(.dreaming);
    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "hello"), .{});
    try std.testing.expect(eventKindSeen(store.experience_events.items, "Conversation.BlockedByBrainMode"));
    try std.testing.expectEqual(schema.BrainMode.dreaming, try brain.deps.store.loadBrainMode());
    try std.testing.expect(std.mem.indexOf(u8, result.brain_summary, "unavailable") != null);
}

test "dream request does not recover active dreaming mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    support.wireTestIo(&brain);

    try brain.deps.store.setBrainMode(.dreaming);
    try std.testing.expectError(error.BrainUnavailable, brain.requestDreamTime(null));
    try std.testing.expectEqual(schema.BrainMode.dreaming, try brain.deps.store.loadBrainMode());
}

test "dreaming mode blocks action proposal execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.setBrainMode(.dreaming);

    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{
        .{ .action = .say, .text = "hello while dreaming" },
    };
    const result = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expectEqual(@as(?[]const u8, null), result.spoken_text);
    try std.testing.expectEqual(@as(usize, 0), store.action_pressures.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.capability_results.items.len);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "action_blocked: brain_mode=dreaming") != null);
    try std.testing.expect(eventKindSeen(store.experience_events.items, experience_kinds.action_selection_blocked));
}

test "autonomy shared context surfaces pending heard speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.io = std.testing.io;
    brain.syncClock(std.testing.io);
    try brain.stimulus_inbox.enqueue(allocator, .heard_speech, brain.now_seconds, 0.85, null, "I heard Other say \"are you there?\"");
    brain.last_conversation_turn_seconds = brain.now_seconds;

    const text = try brain_autonomy.buildPsycheSharedContext(&brain, std.testing.io, .{
        .sleeping = false,
        .control_capacity = 5.0,
        .max_capacity = 8.0,
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "stimulus_inbox:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "are you there?") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fresh speech is pending in stimulus_inbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Nothing particular is pressing on me from outside") == null);
}

test "autonomy shared context keeps answered-contact line without pending speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.io = std.testing.io;
    brain.syncClock(std.testing.io);
    brain.last_conversation_turn_seconds = brain.now_seconds;

    const text = try brain_autonomy.buildPsycheSharedContext(&brain, std.testing.io, .{
        .sleeping = false,
        .control_capacity = 5.0,
        .max_capacity = 8.0,
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "contact already answered") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "stimulus_inbox:") == null);
}
