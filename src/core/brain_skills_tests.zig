const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const email_mod = ports.email;
const helpers = @import("brain_helpers.zig");
const process_recipe_memory = @import("process_recipe_memory.zig");

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

test "send email action uses configured email service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var mailer = email_mod.TestEmailService{};
    brain.deps.email_service = mailer.service();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .send_email, .to = "mara@example.com", .subject = "Garden", .text = "The moonflowers opened." }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expectEqual(@as(usize, 1), mailer.sent.items.len);
    try std.testing.expectEqualStrings("mara@example.com", mailer.sent.items[0].to);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "email_sent: to=mara@example.com subject=Garden") != null);
}

test "skill implementation error is reported before failing loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var mailer = email_mod.TestEmailService{};
    brain.deps.email_service = mailer.service();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .send_email, .to = "mara@example.com", .subject = "Garden" }};

    try std.testing.expectError(error.MissingEmailBody, brain.executeActionProposals(commands[0..], &observations));

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: send_email: MissingEmailBody") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "Configure data/email.json") != null);
}

test "introspection separates available and unavailable skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.capabilities.live_camera = false;

    const text = try brain.introspect("capabilities");

    try std.testing.expect(std.mem.indexOf(u8, text, "- live_camera: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- unknown:") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- describe_image:") == null);
}

test "affordance observation uses grouped skill library summary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;

    try brain.appendAffordanceObservation(&observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_library:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "speech (") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "query=skill/") != null);
    try std.testing.expect(observations.items.len < 4096);
}

test "introspect drills into skill groups and individual skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const tree = try brain.introspect("skills");
    try std.testing.expect(std.mem.indexOf(u8, tree, "skill_library_tree:") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree, "speech") != null);

    const group = try brain.introspect("skills/speech");
    try std.testing.expect(std.mem.indexOf(u8, group, "skill_group: speech") != null);
    try std.testing.expect(std.mem.indexOf(u8, group, "- say:") != null);

    const skill = try brain.introspect("skill/say");
    try std.testing.expect(std.mem.indexOf(u8, skill, "skill_detail: say") != null);
}

test "introspect skill detail includes related working processes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pressures = [_]chat_mod.ActionProposal{
        .{ .action = .recognize, .origin = .interaction },
        .{ .action = .say, .origin = .interaction, .text = "Hello again." },
    };
    try process_recipe_memory.recordOutcome(&brain, "answer_with_host_visual", .interaction, .{
        .action_pressures = &pressures,
        .reason = "recognize then say",
        .step_kinds = &.{},
    }, .success, &.{}, null);

    const skill = try brain.introspect("skill/recognize");
    try std.testing.expect(std.mem.indexOf(u8, skill, "related_processes") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill, "answer_with_host_visual") != null);

    const processes = try brain.introspect("processes");
    try std.testing.expect(std.mem.indexOf(u8, processes, "answer_with_host_visual") != null);

    const detail = try brain.introspect("process/answer_with_host_visual");
    try std.testing.expect(std.mem.indexOf(u8, detail, "interaction:") != null);
    try std.testing.expect(std.mem.indexOf(u8, detail, "answer_with_host_visual") != null);
}

test "affordance observation includes known working processes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pressures = [_]chat_mod.ActionProposal{
        .{ .action = .feel_about, .origin = .autonomy, .query = "touch" },
    };
    try process_recipe_memory.recordOutcome(&brain, "investigate_touch", .autonomy, .{
        .action_pressures = &pressures,
        .reason = "cached",
        .step_kinds = &.{},
    }, .success, &.{}, null);
    var observations = std.ArrayList(u8).empty;
    try brain.appendAffordanceObservation(&observations);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "known_working_processes:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "investigate_touch") != null);
}

test "unavailable action records reason without executing sense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.capabilities.live_camera = false;
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .describe_image, .query = "desk" }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: describe_image: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "no live camera or uploaded image is available for this body") != null);
    try std.testing.expect(brain.last_visual_observation_path == null);
}

