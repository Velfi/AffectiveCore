const std = @import("std");
const chat = @import("../port_chat.zig");
const schema = @import("../ports.zig").schema;
const maintenance = @import("../maintenance.zig");
const autonomy_governor = @import("../autonomy_governor.zig");
const brain_actor = @import("brain_actor.zig");
const payloads = @import("payloads.zig");
const AppraisalActor = @import("appraisal_actor.zig").AppraisalActor;
const LanguageMindActor = @import("language_mind_actor.zig").LanguageMindActor;
const ThriftActor = @import("thrift_actor.zig").ThriftActor;
const AutonomyActor = @import("autonomy_actor.zig").AutonomyActor;
const PolicyActor = @import("policy_actor.zig").PolicyActor;
const SchedulerActor = @import("scheduler_actor.zig").SchedulerActor;

const RecordedEvent = struct {
    kind: []const u8,
    payload_json: []const u8,
};

const Recorder = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(RecordedEvent) = .empty,

    fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Recorder) void {
        for (self.events.items) |event| {
            self.allocator.free(event.kind);
            self.allocator.free(event.payload_json);
        }
        self.events.deinit(self.allocator);
    }

    fn sink(self: *Recorder) brain_actor.EventSink {
        return .{ .ctx = self, .emitFn = emit };
    }

    fn emit(ctx: *anyopaque, kind: []const u8, payload_json: []const u8) !void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        try self.events.append(self.allocator, .{
            .kind = try self.allocator.dupe(u8, kind),
            .payload_json = try self.allocator.dupe(u8, payload_json),
        });
    }
};

test "appraisal actor emits appraisal and annotation events" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const actor = AppraisalActor.init(std.testing.allocator, recorder.sink());
    const appraisal = try actor.create(.{
        .salience = 0.8,
        .affect = 0.4,
        .risk = 0.2,
        .social_value = 0.5,
    });
    const proposal = payloads.ProposalEventPayload{
        .proposal_id = "p1",
        .kind = "say",
        .strength = 0.5,
        .urgency = 0.4,
        .expected_value = 0.3,
        .risk = 0.2,
        .alternatives = .{
            .full = "full",
            .short = "short",
            .tiny = "tiny",
            .noop = "noop",
        },
    };
    _ = try actor.annotateProposal(proposal, appraisal);
    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("appraisal.created", recorder.events.items[0].kind);
    try std.testing.expectEqualStrings("proposal.annotated", recorder.events.items[1].kind);
}

test "language mind actor emits interpretation and proposal events" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const actor = LanguageMindActor.init(std.testing.allocator, recorder.sink());
    var chat_service = chat.TestChatService{};
    const turn = try actor.interpretAndPropose(chat_service.service(), .{
        .memory = "memory",
        .user_text = "hello",
        .observations = "obs",
        .now_ms = 42,
    });
    defer freeChatTurn(std.testing.allocator, turn);
    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("interpretation.created", recorder.events.items[0].kind);
    try std.testing.expectEqualStrings("proposal.created", recorder.events.items[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, recorder.events.items[1].payload_json, "\"alternatives\"") != null);
}

test "language mind interpretTurn defers proposal events until emitProposals" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const actor = LanguageMindActor.init(std.testing.allocator, recorder.sink());
    var chat_service = chat.TestChatService{};
    const turn = try actor.interpretTurn(chat_service.service(), .{
        .memory = "memory",
        .user_text = "hello",
        .observations = "obs",
        .now_ms = 42,
    });
    defer freeChatTurn(std.testing.allocator, turn);
    try std.testing.expectEqual(@as(usize, 1), recorder.events.items.len);
    try std.testing.expectEqualStrings("interpretation.created", recorder.events.items[0].kind);
    try actor.emitProposals(42, turn.action_pressures);
    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("proposal.created", recorder.events.items[1].kind);
}

test "thrift actor emits ranked proposal events" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const actor = ThriftActor.init(std.testing.allocator, recorder.sink());
    const proposals = [_]chat.ActionProposal{
        .{ .action = .say, .origin = .autonomy, .text = "hello from autonomy" },
    };
    const pressures = [_]schema.ActionPressure{
        .{
            .pressure_id = "pressure_1",
            .subsystem = "LanguageMind",
            .proposed_action = "say",
            .capability_id = "say",
            .rationale = "respond",
            .strength = 0.7,
            .urgency = 0.6,
            .risk = 0.2,
            .created_at_ms = 1,
        },
    };
    const state = maintenance.AutonomyState{
        .sleeping = false,
        .control_capacity = 0.65,
        .max_capacity = 0.85,
    };
    const settings = autonomy_governor.Settings{
        .social_reserve = 0.1,
        .safety_reserve = 0.2,
        .opportunity_reserve = 0.15,
    };
    const evaluated = try actor.rankAndCompress(&proposals, &pressures, state, settings);
    defer std.testing.allocator.free(evaluated);
    try std.testing.expect(recorder.events.items.len >= 1);
    try std.testing.expectEqualStrings("proposal.ranked", recorder.events.items[0].kind);
}

test "autonomy actor emits governance decision" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const actor = AutonomyActor.init(std.testing.allocator, recorder.sink());
    const decision = try actor.decide(.{
        .proposal = .{
            .proposal_id = "p2",
            .kind = "say",
            .strength = 0.8,
            .urgency = 0.7,
            .expected_value = 0.6,
            .risk = 0.1,
            .alternatives = .{
                .full = "say full",
                .short = "say short",
                .tiny = "say tiny",
                .noop = "noop",
            },
        },
        .control_capacity = 0.8,
    });
    try std.testing.expectEqual(payloads.GovernanceDecision.allow, decision.decision);
    try std.testing.expectEqualStrings("governance.decision", recorder.events.items[0].kind);
}

test "policy actor can require approval for identity risk" {
    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    const actor = PolicyActor.init(std.testing.allocator, recorder.sink());
    const decision = try actor.decide(.{
        .proposal = .{
            .proposal_id = "p3",
            .kind = "recognize",
            .strength = 0.7,
            .urgency = 0.6,
            .expected_value = 0.4,
            .risk = 0.4,
            .alternatives = .{
                .full = "recognize full",
                .short = "recognize short",
                .tiny = "recognize tiny",
                .noop = "noop",
            },
        },
        .identity_trust = 0.2,
        .min_identity_trust = 0.45,
    });
    try std.testing.expectEqual(payloads.GovernanceDecision.require_approval, decision.decision);
    try std.testing.expectEqualStrings("governance.decision", recorder.events.items[0].kind);
}

test "scheduler actor emits action.scheduled before sleeping" {
    const SleepState = struct {
        called: bool = false,
        value: u32 = 0,
    };
    const SleepHarness = struct {
        fn sleep(ctx: *anyopaque, delay_ms: u32) !void {
            const state: *SleepState = @ptrCast(@alignCast(ctx));
            state.called = true;
            state.value = delay_ms;
        }
    };

    var recorder = Recorder.init(std.testing.allocator);
    defer recorder.deinit();
    var sleep_state = SleepState{};
    const actor = SchedulerActor.init(
        std.testing.allocator,
        recorder.sink(),
        .{ .ctx = &sleep_state, .sleepMsFn = SleepHarness.sleep },
    );
    try actor.schedule(.{
        .proposal_id = "p4",
        .kind = "say",
        .strength = 0.5,
        .urgency = 0.5,
        .expected_value = 0.4,
        .risk = 0.1,
        .alternatives = .{
            .full = "full",
            .short = "short",
            .tiny = "tiny",
            .noop = "noop",
        },
    }, 250);
    try std.testing.expectEqualStrings("action.scheduled", recorder.events.items[0].kind);
    try std.testing.expect(sleep_state.called);
    try std.testing.expectEqual(@as(u32, 250), sleep_state.value);
}

fn freeChatTurn(allocator: std.mem.Allocator, turn: chat.ChatTurn) void {
    chat.freeActionProposals(allocator, turn.action_pressures);
    allocator.free(turn.user_summary);
    allocator.free(turn.brain_summary);
}
