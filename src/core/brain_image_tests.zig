const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const image_mod = ports.image;
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

test "describe image reuses host-delivered frame on pull camera without recapturing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.last_visual_observation_path = "fixtures/visitors/known_01.jpg";
    brain.last_visual_update_seconds = brain.now_seconds;
    brain.last_visual_observation_uploaded = false;
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();

    const text = try brain.describeImageForObservation("expression");

    try std.testing.expect(std.mem.indexOf(u8, text, "image_description:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fixtures/visitors/known_01.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Focus: expression") != null);
}

test "describe image requests host pull when pull camera has no remembered frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var pull_camera = support.FrontendPullCamera{};
    brain.deps.camera = pull_camera.camera();

    const text = try brain.describeImageForObservation("desk");

    try std.testing.expect(std.mem.indexOf(u8, text, "host_sense_pull_requested:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "purpose: describe_image") != null);
    try std.testing.expect(brain.awaitedHostRequestMatches("camera", "describe_image"));
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
    var commands = [_]chat_mod.ActionProposal{.{ .action = .describe_image, .query = "colors" }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "image_description:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "remembered: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "reason: missing_file") != null);
    try std.testing.expect(brain.last_visual_observation_path == null);
    try std.testing.expect(!brain.last_visual_observation_uploaded);
}

test "compare image action requires stored visual observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .compare_images, .query = "desk" }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: compare_images: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "no previous retained visual observation") != null);
}

test "imagine_image action calls image generation service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/empty/empty_room_01.jpg", &.{}, &store, &desc);
    var image_gen = image_mod.TestImageGenerationService{ .path = "data/test/moonflowers.png" };
    brain.deps.image_generation_service = image_gen.service();

    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .imagine_image, .text = "a brass automaton tending moonflowers" }};
    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expectEqualStrings("a brass automaton tending moonflowers", image_gen.last_prompt.?);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "imagined_image:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "data/test/moonflowers.png") != null);
}

test "image comparison uses previous visual observation as baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.last_visual_observation_path = "fixtures/visitors/known_changed_01.jpg";
    const text = try brain.compareImagesForObservation("clothing");
    try std.testing.expect(std.mem.indexOf(u8, text, "before: fixtures/visitors/known_changed_01.jpg") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "after: fixtures/visitors/known_01.jpg") != null);
    try std.testing.expectEqualStrings("fixtures/visitors/known_01.jpg", brain.last_visual_observation_path.?);
}

