const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const input_mod = ports.input;

const audio_mod = ports.audio;
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

test "uploaded image marker is described and stored as visual observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const text = "Please look at this uploaded image.\n[uploaded_image path=\"data/test/image.png\" source=\"drop\"]";
    const observation = (try brain.uploadedMediaObservation(text)).?;

    try std.testing.expect(std.mem.indexOf(u8, observation, "uploaded_image:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "data/test/image.png") != null);
    try std.testing.expectEqualStrings("data/test/image.png", brain.last_visual_observation_path.?);
}

test "uploaded media marker image is described and stored as visual observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const text = "Please look at this upload.\n[uploaded_media path=\"data/test/image.png\" mime_type=\"image/png\" source=\"drop\"]";
    const observation = (try brain.uploadedMediaObservation(text)).?;

    try std.testing.expect(std.mem.indexOf(u8, observation, "uploaded_image:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "data/test/image.png") != null);
    try std.testing.expectEqualStrings("data/test/image.png", brain.last_visual_observation_path.?);
}

test "frontend camera image is recorded as sensed image observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const text = "Affective sensed a webcam image.\n[uploaded_media path=\"data/test/image.png\" mime_type=\"image/png\" source=\"affective_requested_capture\"]";
    const observation = (try brain.uploadedMediaObservation(text)).?;

    try std.testing.expect(std.mem.indexOf(u8, observation, "sensed_image:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "uploaded_image:") == null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "source: affective_requested_capture") != null);
    try std.testing.expectEqualStrings("data/test/image.png", brain.last_visual_observation_path.?);
}

test "missing uploaded image reports missing file observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{ .missing_image_path = "data/test/missing_upload.png" };
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const text = "Please look at this upload.\n[uploaded_media path=\"data/test/missing_upload.png\" mime_type=\"image/png\" source=\"drop\"]";
    const observation = (try brain.uploadedMediaObservation(text)).?;

    try std.testing.expect(std.mem.indexOf(u8, observation, "uploaded_image:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "remembered: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "reason: missing_file") != null);
    try std.testing.expect(brain.last_visual_observation_path == null);
    try std.testing.expect(!brain.last_visual_observation_uploaded);
}

test "uploaded speech audio classification routes to transcription observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const inspector: *audio_mod.TestAudioInspectionService = @ptrCast(@alignCast(brain.deps.audio_inspection_service.?.ctx));
    inspector.kind = .speech;
    inspector.transcript = "hello from the uploaded audio";

    const text = "Please inspect this audio.\n[uploaded_media path=\"data/test/speech.wav\" mime_type=\"audio/wav\" source=\"drop\"]";
    const observation = (try brain.uploadedMediaObservation(text)).?;

    try std.testing.expect(std.mem.indexOf(u8, observation, "uploaded_audio:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "audio_kind: speech") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "transcript: hello from the uploaded audio") != null);
}

test "uploaded mixed audio preserves mixed classification while transcribing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const inspector: *audio_mod.TestAudioInspectionService = @ptrCast(@alignCast(brain.deps.audio_inspection_service.?.ctx));
    inspector.kind = .mixed;
    inspector.transcript = "voice over music";

    const text = "Please inspect this audio.\n[uploaded_media path=\"data/test/mixed.wav\" mime_type=\"audio/wav\" source=\"drop\"]";
    const observation = (try brain.uploadedMediaObservation(text)).?;

    try std.testing.expect(std.mem.indexOf(u8, observation, "audio_kind: mixed") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "transcript: voice over music") != null);
}

test "uploaded non speech audio suggests say instead of pretending to inspect music" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const inspector: *audio_mod.TestAudioInspectionService = @ptrCast(@alignCast(brain.deps.audio_inspection_service.?.ctx));
    inspector.kind = .music;

    const text = "Please inspect this audio.\n[uploaded_media path=\"data/test/song.mp3\" mime_type=\"audio/mpeg\" source=\"drop\"]";
    const observation = (try brain.uploadedMediaObservation(text)).?;

    try std.testing.expect(std.mem.indexOf(u8, observation, "audio_kind: music") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "action: say") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "no_configured_non_speech_audio_analysis") != null);
}

test "uploaded video reports unsupported media observation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const text = "Please inspect this video.\n[uploaded_media path=\"data/test/clip.mp4\" mime_type=\"video/mp4\" source=\"drop\"]";
    const observation = (try brain.uploadedMediaObservation(text)).?;

    try std.testing.expect(std.mem.indexOf(u8, observation, "uploaded_media_unsupported:") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "kind: video") != null);
    try std.testing.expect(std.mem.indexOf(u8, observation, "reason: no_configured_capability") != null);
}

