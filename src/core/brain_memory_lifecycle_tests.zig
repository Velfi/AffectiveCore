const std = @import("std");
const brain_mod = @import("brain.zig");
const support = @import("brain_test_support.zig");
const store_support = @import("brain_test_store.zig");
const ports = @import("ports.zig");
const schema = ports.schema;
const chat_mod = ports.chat;
const openai = ports.openai;
const process_recipe_memory = @import("process_recipe_memory.zig");
const conversation_context = @import("conversation_context.zig");
const input_mod = ports.input;

const maintenance = @import("maintenance.zig");
const id_monitor = @import("id_monitor.zig");
const interrupt_mod = @import("interrupt.zig");
const seed_mod = @import("seed.zig");
const facts = @import("facts.zig");
const vector_index = @import("vector_index.zig");
const time_mod = @import("time.zig");
const helpers = @import("brain_helpers.zig");

const findExperienceEventByKind = support.findExperienceEventByKind;
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

test "memory sweep decays and removes low scoring short term memories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_low",
        .scope = .short_term,
        .text = "Temporary thought",
        .tags = @constCast(&[_][]const u8{"temp"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 1,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_long",
        .scope = .long_term,
        .text = "Durable thought",
        .tags = @constCast(&[_][]const u8{"durable"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 4,
        .score = 8,
    });

    _ = try brain.sweepShortTermMemories();
    try std.testing.expectEqual(@as(usize, 1), store.memories.items.len);
    try std.testing.expectEqualStrings("memory_long", store.memories.items[0].memory_id);
}

test "introspection summarizes memory and senses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_one",
        .scope = .long_term,
        .text = "A durable note",
        .tags = @constCast(&[_][]const u8{"note"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 2,
        .score = 5,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "want_music",
        .scope = .long_term,
        .text = "I want quiet music during maintenance.",
        .interpretation = "self-defined want: I want quiet music during maintenance.",
        .tags = @constCast(&[_][]const u8{ "self_model", "self_want" }),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 5,
    });
    const text = try brain.introspect(null);
    try std.testing.expect(std.mem.indexOf(u8, text, "2 long-term") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Drill-down topics:") != null);

    const needs = try brain.introspect("needs");
    try std.testing.expect(std.mem.indexOf(u8, needs, "inner_directives:") != null);
    try std.testing.expect(std.mem.indexOf(u8, needs, "self_wants:") != null);
    try std.testing.expect(std.mem.indexOf(u8, needs, "self_defined_want:want_music") != null);

    const senses = try brain.introspect("senses");
    try std.testing.expect(std.mem.indexOf(u8, senses, "senses: camera") != null);
    try std.testing.expect(std.mem.indexOf(u8, senses, "battery level") != null);
    try std.testing.expect(std.mem.indexOf(u8, senses, "plugged-in power state") != null);
    try std.testing.expect(std.mem.indexOf(u8, senses, "database statistics") != null);
}

test "compact memory includes known_processes from stored recipes" {
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
    const blocks = try brain.buildConversationMemoryBlocks(null, null, .heard_speech);
    defer conversation_context.freeMemoryBlocks(allocator, blocks);
    var found = false;
    for (blocks) |block| {
        switch (block.kind) {
            .memory => |kind| {
                if (kind == .known_processes) {
                    found = true;
                    try std.testing.expect(std.mem.indexOf(u8, block.text, "investigate_touch") != null);
                }
            },
            else => {},
        }
    }
    try std.testing.expect(found);
}

test "unavailable introspection records command result without forming brain memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var log = TestEventLog{};
    brain.deps.event_log = log.log();
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .introspect }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "skill_failed: introspect: unavailable") != null);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"kind\":\"capability_requested\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"kind\":\"capability_result\""));
    try std.testing.expectEqualStrings("result", log.kind.?);
    try std.testing.expectEqualStrings("introspect", log.title.?);
    try std.testing.expect(findExperienceEventWithPrefix(store.experience_events.items, "Memory.ExperienceRecorded.") == null);
}

test "sweep memory performs runtime event compaction as dreamtime work" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.io = std.testing.io;
    brain.cfg.audio_input_dir = "data/test/runtime_event_sweep_audio";

    try brain.runMaintenanceCapability("sweep_memory");
}

test "event readers log forget memory without making a tombstone memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_to_forget",
        .scope = .short_term,
        .text = "temporary note",
        .tags = @constCast(&[_][]const u8{"temporary"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
    });
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .forget_memory, .memory_id = "memory_to_forget" }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "memory_forgotten: memory_to_forget true") != null);
    try std.testing.expectEqual(@as(usize, 0), store.memories.items.len);
    try std.testing.expect(findExperienceEventWithPrefix(store.experience_events.items, "Memory.ExperienceRecorded.") == null);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"action\":\"forget_memory\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"forgotten_memory_id\":\"memory_to_forget\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"superego_memory_boundary\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"psyche_role\":\"superego\""));
}

test "memory formation reader stores eligible perception command results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ActionProposal{.{ .action = .describe_image, .query = "colors" }};

    _ = try brain.executeActionProposals(commands[0..], &observations);

    try std.testing.expect(std.mem.indexOf(u8, observations.items, "image_description:") != null);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"kind\":\"developer_log\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"sense_stimulus\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"kind\":\"observation\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"kind\":\"capability_result\""));
    const event = findExperienceEventByKind(store.experience_events.items, "Memory.ExperienceRecorded.perception") orelse return error.MissingPerceptionExperienceEvent;
    try std.testing.expectEqual(schema.ExperienceEventSource.sense, event.source);
    try std.testing.expect(std.mem.indexOf(u8, event.payload, "Test image description") != null);
}

test "id monitor emits concern event to jsonl and developer log without memory by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var log = TestEventLog{};
    brain.deps.event_log = log.log();
    var monitor = TestIdMonitor{ .event = .{
        .kind = .system,
        .source = "id",
        .title = "storage pressure",
        .body = "storage pressure crossed a concern threshold",
        .severity = .concern,
        .monitor_id = "storage_pressure",
        .pattern_id = "storage_high",
        .confidence = 0.90,
        .dedupe_key = "storage_high",
        .tags = @constCast(&[_][]const u8{ "id", "storage" }),
    } };
    const sources = [_]id_monitor.Source{monitor.source()};
    brain.deps.id_monitor_sources = sources[0..];

    try brain.runIdMonitors(std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), monitor.calls);
    try std.testing.expectEqual(@as(usize, 1), store.experience_events.items.len);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"monitor_id\":\"storage_pressure\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"severity\":\"concern\""));
    try std.testing.expectEqual(@as(usize, 1), store.experience_events.items.len);
    try std.testing.expectEqualStrings("ExperienceLog.system", store.experience_events.items[0].kind);
    try std.testing.expectEqualStrings("id", log.kind.?);
    try std.testing.expectEqualStrings("storage pressure", log.title.?);
}

test "id monitor eligible event forms memory only through memory formation reader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var monitor = TestIdMonitor{ .event = .{
        .kind = .perception,
        .source = "id",
        .title = "repeated unknown sighting",
        .body = "The Id noticed repeated unknown-person sightings.",
        .subject = "unknown_person_pattern",
        .raw = "unknown sightings repeated",
        .interpretation = "Repeated unknown-person sightings may need attention.",
        .experience_source = .environment,
        .experience_kind = .perception,
        .experience_retention = .summarize,
        .severity = .warning,
        .monitor_id = "unknown_sighting_pattern",
        .pattern_id = "unknown_repeated",
        .dedupe_key = "unknown_repeated",
        .tags = @constCast(&[_][]const u8{ "id", "recognition" }),
    } };
    const sources = [_]id_monitor.Source{monitor.source()};
    brain.deps.id_monitor_sources = sources[0..];

    try brain.runIdMonitors(std.testing.io);

    const event = findExperienceEventByKind(store.experience_events.items, "Memory.ExperienceRecorded.perception") orelse return error.MissingPerceptionExperienceEvent;
    try std.testing.expectEqual(schema.ExperienceEventSource.sense, event.source);
    try std.testing.expect(std.mem.indexOf(u8, event.payload, "unknown_person_pattern") != null);
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"superego_concern\""));
    try std.testing.expect(experienceEventsContain(store.experience_events.items, "\"title\":\"ego_attention_candidate\""));
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
    try std.testing.expectEqual(brain.deps.embedding_service.dimensions(), core.vector.len);

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

test "brain can revise recall and invalidate managed facts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.now_seconds = facts.test_first_turned_on_at_unix_seconds + 5000;

    var observations = std.ArrayList(u8).empty;
    var set_commands = [_]chat_mod.ActionProposal{
        .{ .action = .set_fact, .name = "name", .text = "Otto Prime", .tags = &[_][]const u8{ "identity", "self" } },
    };
    _ = try brain.executeActionProposals(set_commands[0..], &observations);
    try std.testing.expectEqual(@as(usize, 1), store.facts.items.len);
    try std.testing.expectEqual(@as(usize, 1), store.beliefs.items.len);
    try std.testing.expectEqualStrings("Otto Prime", store.facts.items[0].value);
    try std.testing.expectEqualStrings("Otto Prime", store.beliefs.items[0].proposition);
    try std.testing.expectEqual(schema.CognitiveStatus.active, store.beliefs.items[0].lifecycle.status);

    const recalled = try brain.recallFacts("name", &[_][]const u8{"identity"});
    try std.testing.expect(std.mem.indexOf(u8, recalled, "Otto Prime") != null);
    var saw_fact_recall_event = false;
    for (store.experience_events.items) |event| {
        if (std.mem.eql(u8, event.kind, "Memory.MemoryRecalled") and
            std.mem.indexOf(u8, event.payload, "fact_id=fact_name") != null)
        {
            saw_fact_recall_event = true;
        }
    }
    try std.testing.expect(saw_fact_recall_event);

    var revise_commands = [_]chat_mod.ActionProposal{
        .{ .action = .set_fact, .name = "name", .text = "Otto Maybe", .tags = &[_][]const u8{ "identity", "self" } },
    };
    _ = try brain.executeActionProposals(revise_commands[0..], &observations);
    try std.testing.expectEqual(@as(usize, 1), store.facts.items.len);
    try std.testing.expect(store.facts.items[0].revisions.len > 0);
    try std.testing.expectEqualStrings("Otto Maybe", store.beliefs.items[0].proposition);
    try std.testing.expectEqual(schema.CognitiveStatus.doubted, store.beliefs.items[0].lifecycle.status);

    var invalidate_commands = [_]chat_mod.ActionProposal{
        .{ .action = .invalidate_fact, .name = "name" },
    };
    _ = try brain.executeActionProposals(invalidate_commands[0..], &observations);
    try std.testing.expect(!store.facts.items[0].active);
    try std.testing.expectEqual(schema.CognitiveStatus.invalidated, store.beliefs.items[0].lifecycle.status);
    const context = try brain.selfFactsSummary();
    try std.testing.expect(std.mem.indexOf(u8, context, "Otto Maybe") == null);
    try std.testing.expect(std.mem.indexOf(u8, context, "inactive_fact_count: 1") != null);
}

test "consolidation promotes salient memories and decays weak short term memories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_salient",
        .scope = .short_term,
        .text = "Important preference",
        .interpretation = "Important preference",
        .tags = @constCast(&[_][]const u8{"preference"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 2,
        .salience = 0.90,
    });
    try brain.deps.store.saveMemoryRecord(.{
        .memory_id = "memory_weak",
        .scope = .short_term,
        .text = "Weak fragment",
        .interpretation = "Weak fragment",
        .tags = @constCast(&[_][]const u8{"temp"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 0,
        .score = 2,
        .salience = 0.35,
    });
    const text = try brain.consolidateMemory();
    try std.testing.expect(std.mem.indexOf(u8, text, "promoted=1") != null);
    try std.testing.expectEqual(schema.MemoryScope.long_term, store.memories.items[0].scope);
    try std.testing.expect(store.memories.items[1].score < 2);
}

test "runtime memory consolidation emits consolidation chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);

    const activity: schema.ActivityRecord = .{
        .id = "activity_runtime_chain",
        .kind = .conversation,
        .kind_label = "conversation",
        .status = .complete,
        .goal = "check runtime memory chain",
        .summary = "conversation completed and should consolidate",
        .started_at_ms = brain.now_seconds * 1000,
        .updated_at_ms = brain.now_seconds * 1000,
        .originating_request_id = "req_runtime_chain",
        .interpretation = "completed activity",
    };
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .activity = activity,
        .reason = "integration_test",
    }, .{ .whitespace = .minified });
    try brain.publishRuntimeMemoryConsolidation(payload, "brain_memory_tests");

    var saw_consolidated = false;
    var saw_candidate = false;
    for (brain.runtime.events()) |event| {
        if (std.mem.eql(u8, event.event_type, brain_mod.BrainEventTypes.memory_consolidated)) saw_consolidated = true;
        if (std.mem.eql(u8, event.event_type, brain_mod.BrainEventTypes.memory_candidate)) saw_candidate = true;
    }
    try std.testing.expect(saw_consolidated);
    try std.testing.expect(saw_candidate);
    try std.testing.expect(store.memories.items.len >= 1);
}

test "runtime memory extraction fails loudly without extraction service" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = TestStore.init(allocator);
    var desc = openai.TestDescriptionService{};
    var brain = makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.memory_extraction_service = null;

    const activity: schema.ActivityRecord = .{
        .id = "activity_runtime_missing_extraction",
        .kind = .conversation,
        .kind_label = "conversation",
        .status = .complete,
        .goal = "assert missing extraction service fails loudly",
        .summary = "memory extraction requested without llm service",
        .started_at_ms = brain.now_seconds * 1000,
        .updated_at_ms = brain.now_seconds * 1000,
        .originating_request_id = "req_runtime_missing_extraction",
        .interpretation = "completed activity",
    };
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .activity = activity,
        .reason = "integration_test_missing_extraction",
    }, .{ .whitespace = .minified });

    try std.testing.expectError(
        error.MissingMemoryExtractionService,
        brain.publishRuntimeMemoryConsolidation(payload, "brain_memory_tests"),
    );
}

