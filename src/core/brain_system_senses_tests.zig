const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const facial_expression = ports.facial_expression;
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;
const TestStore = store_support.TestStore;
const TestInput = support.TestInput;
const TestIdMonitor = support.TestIdMonitor;
const TestInterruptSource = support.TestInterruptSource;
const TestEventLog = support.TestEventLog;
const TestFacialExpressionOutput = support.TestFacialExpressionOutput;
const ScriptedRememberPersonChatService = support.ScriptedRememberPersonChatService;
const ScriptedIdentityClaimChatService = support.ScriptedIdentityClaimChatService;
const ScriptedForgetPersonChatService = support.ScriptedForgetPersonChatService;
const ScriptedRecallChatService = support.ScriptedRecallChatService;
const ScriptedClarificationChatService = support.ScriptedClarificationChatService;
const ScriptedHardErrorRecoveryChatService = support.ScriptedHardErrorRecoveryChatService;
const HeardSpeechObservationChatService = support.HeardSpeechObservationChatService;
const FailingIdentityClaimIntentService = support.FailingIdentityClaimIntentService;
const ScriptedContinuingChatService = support.ScriptedContinuingChatService;
const makeBrain = support.makeBrain;
const addMara = support.addMara;
const addZelda = support.addZelda;
const countOccurrences = support.countOccurrences;
const findMemoryById = helpers.findMemoryById;
const findMemoryWithTagForTest = helpers.findMemoryWithTagForTest;
const experienceEventsContain = helpers.experienceEventsContain;
const tagInSlice = helpers.tagInSlice;
const speech_artifact_ttl_seconds = brain_mod.speech_artifact_ttl_seconds;
const remote_thinking_failure_message = brain_mod.remote_thinking_failure_message;

test "get_time reports date time only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .get_time }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

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
    var commands = [_]chat_mod.ActionProposal{.{ .action = .get_power }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

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
    var commands = [_]chat_mod.ActionProposal{.{ .action = .get_storage }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

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
    var commands = [_]chat_mod.ActionProposal{.{ .action = .get_database_stats }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

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
    var commands = [_]chat_mod.ActionProposal{.{ .action = .facial_expression, .eyes = "unfocused", .mouth = "smirk" }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

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
    defer expression_output.deinit();
    brain.deps.facial_expression_output = expression_output.output();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .facial_expression, .eyes = "unfocused", .mouth = "smirk" }};

    const result = try brain.executeActionProposals(commands[0..], &observations);

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
    defer expression_output.deinit();
    brain.deps.facial_expression_output = expression_output.output();
    var observations = std.ArrayList(u8).empty;
    var bad_sprite = [_]chat_mod.ActionProposal{.{ .action = .facial_expression, .eyes = "nope", .mouth = "smirk" }};
    try std.testing.expectError(error.UnknownFacialExpressionEyes, brain.executeActionProposals(bad_sprite[0..], &observations));

    var long_duration = [_]chat_mod.ActionProposal{.{ .action = .facial_expression, .eyes = "unfocused", .mouth = "smirk", .duration_ms = facial_expression.max_duration_ms + 1 }};
    try std.testing.expectError(error.FacialExpressionDurationTooLong, brain.executeActionProposals(long_duration[0..], &observations));
}

const runtime_bridge = @import("brain_runtime_bridge.zig");

const ScriptedSenseBatchChatService = struct {
    pub fn service(_: *ScriptedSenseBatchChatService) chat_mod.ChatService {
        return .{ .ctx = @as(*anyopaque, @ptrFromInt(1)), .respondFn = respond };
    }

    fn respond(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !chat_mod.ChatTurn {
        var pressures = try allocator.alloc(chat_mod.ActionProposal, 5);
        pressures[0] = .{ .action = .get_time };
        pressures[1] = .{ .action = .get_power };
        pressures[2] = .{ .action = .get_storage };
        pressures[3] = .{ .action = .get_database_stats };
        pressures[4] = .{ .action = .request_orientation };
        return .{
            .action_pressures = pressures,
            .user_summary = try allocator.dupe(u8, "test senses"),
            .brain_summary = try allocator.dupe(u8, "polling senses"),
        };
    }
};

test "runtime conversation pass executes five sense proposals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedSenseBatchChatService{};
    brain.deps.chat_service = chat.service();
    var observations = std.ArrayList(u8).empty;
    const result = try runtime_bridge.runConversationPass(&brain, "memory", &.{}, "test your senses", &observations, 0);
    try std.testing.expectEqual(@as(usize, 5), result.turn.action_pressures.len);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "time:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "power:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "storage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "database:") != null);
}

test "conversation runtime forces interaction origin when autonomy mode is off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.autonomy_mode = "off";
    var chat = ScriptedAutonomyOriginSenseChatService{};
    brain.deps.chat_service = chat.service();
    var observations = std.ArrayList(u8).empty;
    const result = try runtime_bridge.runConversationPass(&brain, "memory", &.{}, "poll senses", &observations, 0);
    _ = result;
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "time:") != null);
}

const ScriptedAutonomyOriginSenseChatService = struct {
    pub fn service(_: *ScriptedAutonomyOriginSenseChatService) chat_mod.ChatService {
        return .{ .ctx = @as(*anyopaque, @ptrFromInt(2)), .respondFn = respond };
    }

    fn respond(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !chat_mod.ChatTurn {
        var pressures = try allocator.alloc(chat_mod.ActionProposal, 1);
        pressures[0] = .{ .action = .get_time, .origin = .autonomy };
        return .{
            .action_pressures = pressures,
            .user_summary = try allocator.dupe(u8, "poll senses"),
            .brain_summary = try allocator.dupe(u8, "autonomy-origin sense poll"),
        };
    }
};

const ScriptedSenseThenReportChatService = struct {
    calls: usize = 0,

    pub fn service(self: *ScriptedSenseThenReportChatService) chat_mod.ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8, observations: []const u8) !chat_mod.ChatTurn {
        const self: *ScriptedSenseThenReportChatService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.calls == 1) {
            var pressures = try allocator.alloc(chat_mod.ActionProposal, 1);
            pressures[0] = .{ .action = .get_time };
            return .{
                .action_pressures = pressures,
                .user_summary = try allocator.dupe(u8, "test senses"),
                .brain_summary = try allocator.dupe(u8, "polling time"),
            };
        }
        try std.testing.expect(std.mem.indexOf(u8, observations, "time:") != null);
        var pressures = try allocator.alloc(chat_mod.ActionProposal, 1);
        pressures[0] = .{ .action = .say, .text = try allocator.dupe(u8, "The clock reads 2026-06-23.") };
        return .{
            .action_pressures = pressures,
            .user_summary = try allocator.dupe(u8, "test senses"),
            .brain_summary = try allocator.dupe(u8, "reporting sense results"),
        };
    }
};

test "conversation capability loop speaks after sense-only first pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var chat = ScriptedSenseThenReportChatService{};
    brain.deps.chat_service = chat.service();
    const result = try brain.handleConversationText(try input_mod.HeardSpeech.typed(allocator, "test your senses and report back"), .{});
    try std.testing.expectEqual(@as(usize, 2), chat.calls);
    try std.testing.expectEqualStrings("The clock reads 2026-06-23.", result.spoken_text);
}

