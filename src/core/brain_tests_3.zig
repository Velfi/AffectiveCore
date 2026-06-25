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
    try std.testing.expectEqual(@as(usize, 7), store.runtime_events.items.len);
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
    try std.testing.expectEqual(@as(usize, 7), store.runtime_events.items.len);
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"id_monitor_crash\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"severity\":\"warning\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"superego_concern\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"ego_attention_candidate\""));
    try std.testing.expectEqual(@as(usize, 0), store.experiences.items.len);
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

    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"id_monitor_external_start\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"id_monitor_crash\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"superego_concern\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"ego_attention_candidate\""));
    try std.testing.expectEqual(@as(usize, 8), store.runtime_events.items.len);
}

test "ego and superego project warning events without forming memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var log = TestCommandLog{};
    brain.deps.command_log = log.log();

    try brain.recordRuntimeEvent(.{
        .kind = .system,
        .source = "test",
        .title = "hard_error_pattern",
        .body = "Repeated hard errors crossed the warning threshold.",
        .severity = .warning,
        .attention_candidate = true,
        .tags = @constCast(&[_][]const u8{ "test", "warning" }),
    });

    try std.testing.expectEqual(@as(usize, 7), store.runtime_events.items.len);
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"hard_error_pattern\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"superego_concern\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"title\":\"ego_attention_candidate\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"psyche_role\":\"ego\""));
    try std.testing.expect(runtimeEventsContain(store.runtime_events.items, "\"psyche_role\":\"superego\""));
    try std.testing.expectEqual(@as(usize, 0), store.experiences.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.impressions.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.appraisals.items.len);
    try std.testing.expectEqualStrings("ego", log.kind.?);
}

test "startup seeds markdown document once as long term memories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const doc = try seed_mod.parseSeedMarkdown(allocator,
        \\# Garden Seed
        \\
        \\## Core Values
        \\
        \\- Grow patient knowledge.
        \\
        \\## Operating Tendencies
        \\
        \\- Ask before interrupting.
        \\
        \\## Wants
        \\
        \\- Maintain a living map of the garden.
        \\
        \\## Superego Principles
        \\
        \\- Do not pretend a failed action worked.
    );

    try brain.seedDocument(doc);
    try brain.seedDocument(doc);

    try std.testing.expectEqual(@as(usize, 4), store.memories.items.len);
    const core = findMemoryById(store.memories.items, "seed_garden_seed_core_value_1") orelse return error.MissingCoreValueSeed;
    try std.testing.expectEqual(schema.MemoryScope.long_term, core.scope);
    try std.testing.expectEqualStrings("Grow patient knowledge.", core.text);
    try std.testing.expect(tagInSlice(core.tags, "core_value"));
    try std.testing.expect(std.mem.indexOf(u8, core.interpretation, "seed Garden Seed core value:") != null);
    try std.testing.expectEqual(vector_index.dimensions, core.vector.len);

    const tendency = findMemoryById(store.memories.items, "seed_garden_seed_seed_operating_tendency_1") orelse return error.MissingOperatingTendencySeed;
    try std.testing.expectEqualStrings("Ask before interrupting.", tendency.text);
    try std.testing.expect(tagInSlice(tendency.tags, "seed_operating_tendency"));

    const want = findMemoryById(store.memories.items, "seed_garden_seed_self_want_1") orelse return error.MissingWantSeed;
    try std.testing.expectEqual(schema.MemoryScope.long_term, want.scope);
    try std.testing.expectEqualStrings("Maintain a living map of the garden.", want.text);
    try std.testing.expect(tagInSlice(want.tags, "self_want"));
    try std.testing.expect(std.mem.indexOf(u8, want.interpretation, "seed Garden Seed want:") != null);

    const principle = findMemoryById(store.memories.items, "seed_garden_seed_superego_principle_1") orelse return error.MissingSuperegoPrincipleSeed;
    try std.testing.expectEqual(schema.MemoryScope.long_term, principle.scope);
    try std.testing.expectEqualStrings("Do not pretend a failed action worked.", principle.text);
    try std.testing.expect(tagInSlice(principle.tags, "superego_principle"));
    try std.testing.expect(std.mem.indexOf(u8, principle.interpretation, "seed Garden Seed superego principle:") != null);
}

test "edit_need updates stored self need" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "need_rest",
        .scope = .long_term,
        .text = "I need occasional rest.",
        .interpretation = "self-defined need: I need occasional rest.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_need" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
    });
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .edit_need, .memory_id = "need_rest", .text = "I need quiet recovery time after long conversations." }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "self_definition_edited:") != null);
    try std.testing.expectEqualStrings("I need quiet recovery time after long conversations.", store.memories.items[0].text);
    try std.testing.expect(std.mem.indexOf(u8, store.memories.items[0].interpretation, "quiet recovery time") != null);
    try std.testing.expectEqual(@as(usize, 1), store.memories.items[0].revisions.len);
}

test "chat command batch continues after speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{
        .{ .command = .say, .text = "I can hold both names." },
        .{ .command = .remember_memory, .text = "My name is Otto, and Junior is also an appropriate name when Papa is present.", .tags = &[_][]const u8{ "identity", "name" } },
    };

    const spoken = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expectEqualStrings("I can hold both names.", spoken.spoken_text.?);
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.traces.items.len);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "memory_saved:") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.memories.items[0].text, "Junior") != null);
    try std.testing.expect(std.mem.indexOf(u8, store.traces.items[0].text, "Junior") != null);
}

test "brain can revise recall and invalidate managed facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.now_seconds = facts.test_first_turned_on_at_unix_seconds + 5000;

    var observations = std.ArrayList(u8).empty;
    var set_commands = [_]chat_mod.ChatCommand{
        .{ .command = .set_fact, .name = "name", .text = "Otto Prime", .tags = &[_][]const u8{ "identity", "self" } },
    };
    _ = try brain.executeChatCommands(set_commands[0..], &observations);
    try std.testing.expectEqual(@as(usize, 1), store.facts.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.beliefs.items.len);
    try std.testing.expectEqualStrings("Otto Prime", store.facts.items[0].value);
    try std.testing.expectEqualStrings("Otto Prime", store.beliefs.items[0].proposition);
    try std.testing.expectEqual(schema.CognitiveStatus.active, store.beliefs.items[0].lifecycle.status);

    const recalled = try brain.recallFacts("name", &[_][]const u8{"identity"});
    try std.testing.expect(std.mem.indexOf(u8, recalled, "Otto Prime") != null);

    var revise_commands = [_]chat_mod.ChatCommand{
        .{ .command = .set_fact, .name = "name", .text = "Otto Maybe", .tags = &[_][]const u8{ "identity", "self" } },
    };
    _ = try brain.executeChatCommands(revise_commands[0..], &observations);
    try std.testing.expectEqual(@as(usize, 1), store.facts.items.len);
    try std.testing.expect(store.facts.items[0].revisions.len > 0);
    try std.testing.expectEqualStrings("Otto Maybe", store.beliefs.items[0].proposition);
    try std.testing.expectEqual(schema.CognitiveStatus.doubted, store.beliefs.items[0].lifecycle.status);

    var invalidate_commands = [_]chat_mod.ChatCommand{
        .{ .command = .invalidate_fact, .name = "name" },
    };
    _ = try brain.executeChatCommands(invalidate_commands[0..], &observations);
    try std.testing.expect(!store.facts.items[0].active);
    try std.testing.expectEqual(schema.CognitiveStatus.invalidated, store.beliefs.items[0].lifecycle.status);
    const context = try brain.selfFactsSummary();
    try std.testing.expect(std.mem.indexOf(u8, context, "Otto Maybe") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "inactive_fact_count: 1") != null);
}

test "send email command uses configured email service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var mailer = email_mod.TestEmailService{};
    brain.deps.email_service = mailer.service();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .send_email, .to = "mara@example.com", .subject = "Garden", .text = "The moonflowers opened." }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

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
    var commands = [_]chat_mod.ChatCommand{.{ .command = .send_email, .to = "mara@example.com", .subject = "Garden" }};

    try std.testing.expectError(error.MissingEmailBody, brain.executeChatCommands(commands[0..], &observations));

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: send_email: MissingEmailBody") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "Configure data/email.json") != null);
}

test "conversation hard error asks for user aided recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{ "send Mara the garden email", "nevermind" }, &store, &desc);
    var mailer = email_mod.TestEmailService{};
    brain.deps.email_service = mailer.service();
    var scripted_chat = ScriptedHardErrorRecoveryChatService{};
    brain.deps.chat_service = scripted_chat.service();

    try brain.handleConversationTurn();

    try std.testing.expectEqual(@as(usize, 1), scripted_chat.calls);
    try std.testing.expect(brain.pending_hard_error != null);
    try std.testing.expectEqualStrings("MissingEmailBody", brain.pending_hard_error.?.error_name);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_hard_error.?.command, "command=send_email") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_hard_error.?.command, "to=mara@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, brain.pending_hard_error.?.command, "subject=Garden") != null);

    try brain.handleConversationTurn();

    try std.testing.expectEqual(@as(usize, 2), scripted_chat.calls);
    try std.testing.expect(brain.pending_hard_error == null);
    try std.testing.expect(std.mem.indexOf(u8, scripted_chat.followup_observations, "pending_hard_error:") != null);
    try std.testing.expect(std.mem.indexOf(u8, scripted_chat.followup_observations, "- error: MissingEmailBody") != null);
    try std.testing.expect(std.mem.indexOf(u8, scripted_chat.followup_observations, "command=send_email") != null);
    try std.testing.expect(std.mem.indexOf(u8, scripted_chat.followup_observations, "nevermind") != null);
}

test "edit_want rejects need memory id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "need_rest",
        .scope = .long_term,
        .text = "I need occasional rest.",
        .interpretation = "self-defined need: I need occasional rest.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_need" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
    });
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .edit_want, .memory_id = "need_rest", .text = "I want more color." }};

    try std.testing.expectError(error.SelfDefinitionKindMismatch, brain.executeChatCommands(commands[0..], &observations));
}

test "introspection separates available and unavailable skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.capabilities.live_camera = false;

    const text = try brain.introspect();

    try std.testing.expect(std.mem.indexOf(u8, text, "- live_camera: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- recall_memory: search remembered experience") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "- describe_image:") == null);
}

test "unavailable command records reason without executing sense" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.capabilities.live_camera = false;
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{.{ .command = .describe_image, .query = "desk" }};

    _ = try brain.executeChatCommands(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: describe_image: unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "no live camera or uploaded image is available for this body") != null);
    try std.testing.expect(brain.last_visual_observation_path == null);
}

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

test "uploaded non speech audio asks human instead of pretending to inspect music" {
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
    try std.testing.expect(std.mem.indexOf(u8, observation, "action: ask_human") != null);
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
