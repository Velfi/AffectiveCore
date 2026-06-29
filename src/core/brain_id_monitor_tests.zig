const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const id_monitor = @import("id_monitor.zig");
const helpers = @import("brain_helpers.zig");

const findExperienceEventWithPrefix = support.findExperienceEventWithPrefix;

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

test "id monitor dedupe cooldown suppresses repeated identical concerns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.id_monitor_interval_seconds = 1;
    brain.cfg.id_monitor_external_restart_cooldown_seconds = 60;
    var monitor = TestIdMonitor{ .event = .{
        .kind = .system,
        .source = "id",
        .title = "rapid interrupts",
        .body = "Rapid interrupts repeated.",
        .severity = .warning,
        .monitor_id = "interrupt_pattern",
        .dedupe_key = "rapid_interrupts",
        .tags = @constCast(&[_][]const u8{ "id", "interrupt" }),
    } };
    const sources = [_]id_monitor.Source{monitor.source()};
    brain.deps.id_monitor_sources = sources[0..];

    brain.now_seconds = 100;
    try brain.runIdMonitors(std.testing.io);
    brain.now_seconds = 102;
    try brain.runIdMonitors(std.testing.io);

    try std.testing.expectEqual(@as(usize, 2), monitor.calls);
    try std.testing.expectEqual(@as(usize, 7), store.experience_events.items.len);
}

test "id monitor crash emits audit event and does not crash brain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var monitor = TestIdMonitor{ .fail = true };
    const sources = [_]id_monitor.Source{monitor.source()};
    brain.deps.id_monitor_sources = sources[0..];

    try brain.runIdMonitors(std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), monitor.calls);
    try std.testing.expectEqual(@as(usize, 7), store.experience_events.items.len);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"id_monitor_crash\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"severity\":\"warning\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"superego_concern\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"ego_attention_candidate\""));
    try std.testing.expect(findExperienceEventWithPrefix(store.experience_events.items, "Memory.ExperienceRecorded.") == null);
}

test "external id monitor crash emits audit event and cooldown prevents immediate retry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.cfg.id_monitor_external_command = "definitely_missing_id_monitor_binary";
    brain.cfg.id_monitor_interval_seconds = 1;
    brain.cfg.id_monitor_external_restart_cooldown_seconds = 60;

    brain.now_seconds = 100;
    try brain.runIdMonitors(std.testing.io);
    brain.now_seconds = 101;
    try brain.runIdMonitors(std.testing.io);

    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"id_monitor_external_start\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"id_monitor_crash\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"superego_concern\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"ego_attention_candidate\""));
    try std.testing.expectEqual(@as(usize, 8), store.experience_events.items.len);
}

test "ego and superego project warning events without forming memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var log = TestEventLog{};
    brain.deps.event_log = log.log();

    _ = try brain.recordExperienceLogEvent(.{
        .kind = .system,
        .source = "test",
        .title = "hard_error_pattern",
        .body = "Repeated hard errors crossed the warning threshold.",
        .severity = .warning,
        .attention_candidate = true,
        .tags = @constCast(&[_][]const u8{ "test", "warning" }),
    });

    try std.testing.expectEqual(@as(usize, 7), store.experience_events.items.len);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"hard_error_pattern\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"superego_concern\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"ego_attention_candidate\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"psyche_role\":\"ego\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"psyche_role\":\"superego\""));
    try std.testing.expect(findExperienceEventWithPrefix(store.experience_events.items, "Memory.ExperienceRecorded.") == null);
    try std.testing.expectEqual(@as(usize, 0), store.impressions.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.appraisals.items.len);
    try std.testing.expectEqualStrings("ego", log.kind.?);
}

