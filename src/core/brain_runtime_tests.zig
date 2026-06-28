const std = @import("std");
const brain_event = @import("brain_event.zig");
const brain_actor = @import("brain_actor.zig");
const brain_runtime_mod = @import("brain_runtime.zig");

const BrainRuntime = brain_runtime_mod.BrainRuntime;
const RuntimeError = brain_runtime_mod.RuntimeError;

const no_events = [_]brain_event.BrainEvent{};

fn makeEvent(event_type: []const u8, source_actor: []const u8, ttl: u8, depth: u16, timestamp: i64) brain_event.BrainEvent {
    return .{
        .id = "",
        .event_type = event_type,
        .timestamp = timestamp,
        .source_actor = source_actor,
        .activity_id = null,
        .correlation_id = "",
        .causation_id = null,
        .priority = .normal,
        .ttl = ttl,
        .depth = depth,
        .payload = "{}",
    };
}

test "brain runtime publish and dispatch to subscribers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var runtime = BrainRuntime.init(allocator, .{});
    defer runtime.deinit();

    const ProposalActor = struct {
        calls: usize = 0,
        emitted: [1]brain_event.BrainEvent = undefined,

        fn id(_: *anyopaque) []const u8 {
            return "proposal_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created);
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, _: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            self.emitted[0] = .{
                .id = "",
                .event_type = brain_event.EventTypes.governance_decision,
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"decision\":\"allow\"}",
            };
            return self.emitted[0..];
        }
    };

    const GovernanceActor = struct {
        calls: usize = 0,

        fn id(_: *anyopaque) []const u8 {
            return "governance_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, brain_event.EventTypes.governance_decision);
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, _: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return no_events[0..];
        }
    };

    var proposal = ProposalActor{};
    var governance = GovernanceActor{};

    try runtime.registerActor(.{
        .ctx = &proposal,
        .idFn = ProposalActor.id,
        .subscribesToFn = ProposalActor.subscribesTo,
        .handleFn = ProposalActor.handle,
    });
    try runtime.registerActor(.{
        .ctx = &governance,
        .idFn = GovernanceActor.id,
        .subscribesToFn = GovernanceActor.subscribesTo,
        .handleFn = GovernanceActor.handle,
    });

    _ = try runtime.publishAutoPhase(makeEvent(
        brain_event.EventTypes.proposal_created,
        "entrypoint",
        4,
        0,
        101,
    ));
    const report = try runtime.dispatchTick();

    try std.testing.expectEqual(@as(usize, 2), report.processed);
    try std.testing.expectEqual(@as(usize, 0), report.remaining);
    try std.testing.expectEqual(@as(usize, 1), proposal.calls);
    try std.testing.expectEqual(@as(usize, 1), governance.calls);
    try std.testing.expectEqual(@as(usize, 2), runtime.publishedEventCount());
}

test "brain runtime preserves causation chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var runtime = BrainRuntime.init(allocator, .{});
    defer runtime.deinit();

    const ProposalActor = struct {
        emitted: [1]brain_event.BrainEvent = undefined,

        fn id(_: *anyopaque) []const u8 {
            return "proposal_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created);
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, _: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.emitted[0] = .{
                .id = "",
                .event_type = brain_event.EventTypes.governance_decision,
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"governance\":\"allow\"}",
            };
            return self.emitted[0..];
        }
    };

    const GovernanceActor = struct {
        emitted: [1]brain_event.BrainEvent = undefined,

        fn id(_: *anyopaque) []const u8 {
            return "governance_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, brain_event.EventTypes.governance_decision);
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, _: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.emitted[0] = .{
                .id = "",
                .event_type = brain_event.EventTypes.action_scheduled,
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"action\":\"speak\"}",
            };
            return self.emitted[0..];
        }
    };

    var proposal = ProposalActor{};
    var governance = GovernanceActor{};

    try runtime.registerActor(.{
        .ctx = &proposal,
        .idFn = ProposalActor.id,
        .subscribesToFn = ProposalActor.subscribesTo,
        .handleFn = ProposalActor.handle,
    });
    try runtime.registerActor(.{
        .ctx = &governance,
        .idFn = GovernanceActor.id,
        .subscribesToFn = GovernanceActor.subscribesTo,
        .handleFn = GovernanceActor.handle,
    });

    const root = try runtime.publishAutoPhase(makeEvent(
        brain_event.EventTypes.proposal_created,
        "entrypoint",
        5,
        0,
        202,
    ));
    _ = try runtime.dispatchTick();

    const events = runtime.events();
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expect(events[0].causation_id == null);
    try std.testing.expectEqualStrings(events[1].causation_id.?, events[0].id);
    try std.testing.expectEqualStrings(events[2].causation_id.?, events[1].id);
    try std.testing.expectEqualStrings(root.correlation_id, events[1].correlation_id);
    try std.testing.expectEqualStrings(root.correlation_id, events[2].correlation_id);

    const trace = try runtime.debugTraceForCorrelation(allocator, root.correlation_id);
    try std.testing.expect(std.mem.indexOf(u8, trace, events[0].id) != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, events[1].id) != null);
    try std.testing.expect(std.mem.indexOf(u8, trace, events[2].id) != null);
}

test "brain runtime ttl and depth guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const EmitterActor = struct {
        emitted: [1]brain_event.BrainEvent = undefined,

        fn id(_: *anyopaque) []const u8 {
            return "emitter_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created);
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, _: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.emitted[0] = .{
                .id = "",
                .event_type = brain_event.EventTypes.governance_decision,
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"decision\":\"continue\"}",
            };
            return self.emitted[0..];
        }
    };

    var ttl_runtime = BrainRuntime.init(allocator, .{});
    defer ttl_runtime.deinit();
    var ttl_emitter = EmitterActor{};
    try ttl_runtime.registerActor(.{
        .ctx = &ttl_emitter,
        .idFn = EmitterActor.id,
        .subscribesToFn = EmitterActor.subscribesTo,
        .handleFn = EmitterActor.handle,
    });
    _ = try ttl_runtime.publishAutoPhase(makeEvent(
        brain_event.EventTypes.proposal_created,
        "entrypoint",
        1,
        0,
        303,
    ));
    try std.testing.expectError(RuntimeError.TtlExpired, ttl_runtime.dispatchTick());

    var depth_runtime = BrainRuntime.init(allocator, .{ .max_depth = 1, .per_tick_event_budget = 128 });
    defer depth_runtime.deinit();
    var depth_emitter = EmitterActor{};
    try depth_runtime.registerActor(.{
        .ctx = &depth_emitter,
        .idFn = EmitterActor.id,
        .subscribesToFn = EmitterActor.subscribesTo,
        .handleFn = EmitterActor.handle,
    });
    _ = try depth_runtime.publishAutoPhase(makeEvent(
        brain_event.EventTypes.proposal_created,
        "entrypoint",
        4,
        1,
        404,
    ));
    try std.testing.expectError(RuntimeError.DepthExceeded, depth_runtime.dispatchTick());
}

test "brain runtime dispatches in phase order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var runtime = BrainRuntime.init(allocator, .{});
    defer runtime.deinit();

    const PhaseRecorder = struct {
        phases: std.ArrayList([]const u8),

        fn id(_: *anyopaque) []const u8 {
            return "phase_recorder";
        }

        fn subscribesTo(_: *anyopaque, _: []const u8) bool {
            return true;
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, context: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.phases.append(context.allocator, context.phase_name);
            return no_events[0..];
        }
    };

    var recorder = PhaseRecorder{ .phases = .empty };
    defer recorder.phases.deinit(allocator);

    try runtime.registerActor(.{
        .ctx = &recorder,
        .idFn = PhaseRecorder.id,
        .subscribesToFn = PhaseRecorder.subscribesTo,
        .handleFn = PhaseRecorder.handle,
    });

    _ = try runtime.publishAutoPhase(makeEvent("ingest.external", "entrypoint", 3, 0, 1001));
    _ = try runtime.publishAutoPhase(makeEvent(brain_event.EventTypes.memory_candidate, "entrypoint", 3, 0, 1002));
    _ = try runtime.publishAutoPhase(makeEvent(brain_event.EventTypes.proposal_created, "entrypoint", 3, 0, 1003));
    _ = try runtime.publishAutoPhase(makeEvent(brain_event.EventTypes.governance_decision, "entrypoint", 3, 0, 1004));
    _ = try runtime.publishAutoPhase(makeEvent(brain_event.EventTypes.action_scheduled, "entrypoint", 3, 0, 1005));
    _ = try runtime.publishAutoPhase(makeEvent(brain_event.EventTypes.outcome_created, "entrypoint", 3, 0, 1006));

    const report = try runtime.dispatchTick();
    try std.testing.expectEqual(@as(usize, 6), report.processed);
    try std.testing.expectEqual(@as(usize, 0), report.remaining);
    try std.testing.expectEqual(@as(usize, 6), recorder.phases.items.len);
    try std.testing.expectEqualStrings("ingest", recorder.phases.items[0]);
    try std.testing.expectEqualStrings("context", recorder.phases.items[1]);
    try std.testing.expectEqualStrings("proposal", recorder.phases.items[2]);
    try std.testing.expectEqualStrings("governance", recorder.phases.items[3]);
    try std.testing.expectEqualStrings("execution", recorder.phases.items[4]);
    try std.testing.expectEqualStrings("feedback", recorder.phases.items[5]);
}

test "brain runtime maps memory and learning contracts" {
    try std.testing.expectEqual(brain_runtime_mod.Phase.context, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_consolidate));
    try std.testing.expectEqual(brain_runtime_mod.Phase.context, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_consolidated));
    try std.testing.expectEqual(brain_runtime_mod.Phase.context, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_extract));
    try std.testing.expectEqual(brain_runtime_mod.Phase.context, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_retrieve));
    try std.testing.expectEqual(brain_runtime_mod.Phase.context, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_retrieved));
    try std.testing.expectEqual(brain_runtime_mod.Phase.context, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_audit_query));
    try std.testing.expectEqual(brain_runtime_mod.Phase.context, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_audit));
    try std.testing.expectEqual(brain_runtime_mod.Phase.feedback, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_decay));
    try std.testing.expectEqual(brain_runtime_mod.Phase.feedback, BrainRuntime.phaseForEventType(brain_event.EventTypes.memory_decayed));
    try std.testing.expectEqual(brain_runtime_mod.Phase.feedback, BrainRuntime.phaseForEventType(brain_event.EventTypes.learning_capability_recorded));
    try std.testing.expectEqual(brain_runtime_mod.Phase.feedback, BrainRuntime.phaseForEventType(brain_event.EventTypes.learning_correction_recorded));
}

test "brain runtime user utterance reaches executed action with causation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var runtime = BrainRuntime.init(allocator, .{});
    defer runtime.deinit();

    const PhaseRecorder = struct {
        phases: std.ArrayList([]const u8),
    };

    const IngestActor = struct {
        emitted: [1]brain_event.BrainEvent = undefined,
        recorder: *PhaseRecorder,

        fn id(_: *anyopaque) []const u8 {
            return "test_ingest_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, "ingest.user_text");
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, context: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.recorder.phases.append(context.allocator, context.phase_name);
            self.emitted[0] = .{
                .id = "",
                .event_type = "interpretation.created",
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"intent\":\"reply\"}",
            };
            return self.emitted[0..];
        }
    };

    const ContextActor = struct {
        emitted: [1]brain_event.BrainEvent = undefined,
        recorder: *PhaseRecorder,

        fn id(_: *anyopaque) []const u8 {
            return "test_context_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, "interpretation.created");
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, context: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.recorder.phases.append(context.allocator, context.phase_name);
            self.emitted[0] = .{
                .id = "",
                .event_type = brain_event.EventTypes.proposal_created,
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"action\":\"say\"}",
            };
            return self.emitted[0..];
        }
    };

    const ProposalActor = struct {
        emitted: [1]brain_event.BrainEvent = undefined,
        recorder: *PhaseRecorder,

        fn id(_: *anyopaque) []const u8 {
            return "test_proposal_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, brain_event.EventTypes.proposal_created);
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, context: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.recorder.phases.append(context.allocator, context.phase_name);
            self.emitted[0] = .{
                .id = "",
                .event_type = brain_event.EventTypes.governance_decision,
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"decision\":\"allow\"}",
            };
            return self.emitted[0..];
        }
    };

    const GovernanceActor = struct {
        emitted: [2]brain_event.BrainEvent = undefined,
        recorder: *PhaseRecorder,

        fn id(_: *anyopaque) []const u8 {
            return "test_governance_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, brain_event.EventTypes.governance_decision);
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, context: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.recorder.phases.append(context.allocator, context.phase_name);
            self.emitted[0] = .{
                .id = "",
                .event_type = brain_event.EventTypes.action_executed,
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"action\":\"say\",\"status\":\"ok\"}",
            };
            self.emitted[1] = .{
                .id = "",
                .event_type = brain_event.EventTypes.outcome_created,
                .timestamp = 0,
                .source_actor = "",
                .activity_id = null,
                .correlation_id = "",
                .causation_id = null,
                .priority = .normal,
                .ttl = 0,
                .depth = 0,
                .payload = "{\"result\":\"spoken\"}",
            };
            return self.emitted[0..];
        }
    };

    const FeedbackActor = struct {
        recorder: *PhaseRecorder,

        fn id(_: *anyopaque) []const u8 {
            return "test_feedback_actor";
        }

        fn subscribesTo(_: *anyopaque, event_type: []const u8) bool {
            return std.mem.eql(u8, event_type, brain_event.EventTypes.outcome_created);
        }

        fn handle(ctx: *anyopaque, _: brain_event.BrainEvent, context: brain_actor.HandleContext) ![]const brain_event.BrainEvent {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.recorder.phases.append(context.allocator, context.phase_name);
            return no_events[0..];
        }
    };

    var recorder = PhaseRecorder{ .phases = .empty };
    defer recorder.phases.deinit(allocator);
    var ingest = IngestActor{ .recorder = &recorder };
    var context = ContextActor{ .recorder = &recorder };
    var proposal = ProposalActor{ .recorder = &recorder };
    var governance = GovernanceActor{ .recorder = &recorder };
    var feedback = FeedbackActor{ .recorder = &recorder };

    try runtime.registerActor(.{
        .ctx = &ingest,
        .idFn = IngestActor.id,
        .subscribesToFn = IngestActor.subscribesTo,
        .handleFn = IngestActor.handle,
    });
    try runtime.registerActor(.{
        .ctx = &context,
        .idFn = ContextActor.id,
        .subscribesToFn = ContextActor.subscribesTo,
        .handleFn = ContextActor.handle,
    });
    try runtime.registerActor(.{
        .ctx = &proposal,
        .idFn = ProposalActor.id,
        .subscribesToFn = ProposalActor.subscribesTo,
        .handleFn = ProposalActor.handle,
    });
    try runtime.registerActor(.{
        .ctx = &governance,
        .idFn = GovernanceActor.id,
        .subscribesToFn = GovernanceActor.subscribesTo,
        .handleFn = GovernanceActor.handle,
    });
    try runtime.registerActor(.{
        .ctx = &feedback,
        .idFn = FeedbackActor.id,
        .subscribesToFn = FeedbackActor.subscribesTo,
        .handleFn = FeedbackActor.handle,
    });

    const root = try runtime.publishAutoPhase(makeEvent("ingest.user_text", "entrypoint", 8, 0, 7001));
    const report = try runtime.dispatchTick();
    try std.testing.expectEqual(@as(usize, 6), report.processed);
    try std.testing.expectEqual(@as(usize, 0), report.remaining);

    try std.testing.expectEqual(@as(usize, 5), recorder.phases.items.len);
    try std.testing.expectEqualStrings("ingest", recorder.phases.items[0]);
    try std.testing.expectEqualStrings("context", recorder.phases.items[1]);
    try std.testing.expectEqualStrings("proposal", recorder.phases.items[2]);
    try std.testing.expectEqualStrings("governance", recorder.phases.items[3]);
    try std.testing.expectEqualStrings("feedback", recorder.phases.items[4]);

    const events = runtime.events();
    try std.testing.expectEqual(@as(usize, 6), events.len);
    try std.testing.expectEqualStrings("ingest.user_text", events[0].event_type);
    try std.testing.expectEqualStrings("interpretation.created", events[1].event_type);
    try std.testing.expectEqualStrings(brain_event.EventTypes.proposal_created, events[2].event_type);
    try std.testing.expectEqualStrings(brain_event.EventTypes.governance_decision, events[3].event_type);
    try std.testing.expectEqualStrings(brain_event.EventTypes.action_executed, events[4].event_type);
    try std.testing.expectEqualStrings(brain_event.EventTypes.outcome_created, events[5].event_type);

    try std.testing.expect(events[0].causation_id == null);
    try std.testing.expectEqualStrings(events[0].id, events[1].causation_id.?);
    try std.testing.expectEqualStrings(events[1].id, events[2].causation_id.?);
    try std.testing.expectEqualStrings(events[2].id, events[3].causation_id.?);
    try std.testing.expectEqualStrings(events[3].id, events[4].causation_id.?);
    try std.testing.expectEqualStrings(events[3].id, events[5].causation_id.?);

    try std.testing.expectEqualStrings(root.correlation_id, events[0].correlation_id);
    for (events[1..]) |event| {
        try std.testing.expectEqualStrings(root.correlation_id, event.correlation_id);
    }
}
