const std = @import("std");
const brain_mod = @import("brain.zig");
const chat_mod = @import("port_chat.zig");
const stimulus_mod = @import("stimulus.zig");
const interrupt_mod = @import("interrupt.zig");
const brain_runtime_bridge = @import("brain_runtime_bridge.zig");
const brain_logging_events = @import("brain_logging_events.zig");
const context_composition = @import("context_composition.zig");
const process_goal_mod = @import("port_process_goal.zig");
const operation_ids = @import("operation_ids.zig");

const Brain = brain_mod.Brain;

pub const StepKind = enum {
    sync_capability,
    async_host_pull,
    wait_timer,
    wait_stimulus,
    respond,
};

pub const ProcessState = enum {
    composing,
    running,
    waiting_host,
    waiting_timer,
    waiting_stimulus,
    completed,
    failed,
};

pub const ProcessStep = struct {
    kind: StepKind,
    action: chat_mod.ActionProposalType = .unknown,
    sense: ?[]const u8 = null,
    purpose: ?[]const u8 = null,
    stimulus_kind: ?stimulus_mod.Kind = null,
    stimulus_signature: ?[]const u8 = null,
    evidence_marker: ?[]const u8 = null,
    respond_text: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
    timer_intent: ?[]const u8 = null,
};

pub const ActiveProcess = struct {
    id: []const u8,
    goal: []const u8,
    user_anchor: []const u8,
    origin: chat_mod.ActionOrigin,
    steps: []ProcessStep,
    step_ids: []const []const u8,
    step_index: usize,
    state: ProcessState,
    started_at: i64,
    timeout_deadline_seconds: ?i64,
    composition_reason: ?[]const u8,
    wait_stimulus_kind: ?stimulus_mod.Kind = null,
    wait_stimulus_signature: ?[]const u8 = null,
    step_started_ms: ?i64 = null,
};

pub const ActiveProcessModel = struct {
    process_id: ?[]const u8 = null,
    goal: ?[]const u8 = null,
    state: ?[]const u8 = null,
    step_index: usize = 0,
    step_count: usize = 0,
    current_step_kind: ?[]const u8 = null,
    waiting_for: ?[]const u8 = null,
    timeout_remaining_seconds: ?i64 = null,
    origin: ?[]const u8 = null,
};

pub const ResumeTrigger = enum {
    host_delivery,
    timer_fired,
    stimulus,
    timeout,
};

pub const AdvanceResult = struct {
    spoken_text: []const u8 = "",
    final_turn: ?chat_mod.ChatTurn = null,
    pending_interrupt: ?interrupt_mod.Stimulus = null,
    awaiting_host_sense: bool = false,
    process_waiting: bool = false,
};

pub fn templateSteps(allocator: std.mem.Allocator, goal: []const u8) !?[]ProcessStep {
    if (std.mem.eql(u8, goal, "answer_with_host_visual")) {
        const steps = try allocator.alloc(ProcessStep, 2);
        steps[0] = .{
            .kind = .async_host_pull,
            .action = .recognize,
            .sense = try allocator.dupe(u8, "camera"),
            .purpose = try allocator.dupe(u8, "recognize"),
        };
        steps[1] = .{
            .kind = .respond,
            .action = .say,
            .evidence_marker = "Current speaker recognition:",
        };
        return steps;
    }
    return null;
}

pub fn stepsFromComposition(
    allocator: std.mem.Allocator,
    composition: process_goal_mod.ProcessComposition,
) ![]ProcessStep {
    const steps = try allocator.alloc(ProcessStep, composition.action_pressures.len);
    errdefer allocator.free(steps);
    for (composition.action_pressures, 0..) |pressure, index| {
        const step_kind = if (index < composition.step_kinds.len) composition.step_kinds[index] else null;
        steps[index] = if (step_kind) |kind_text|
            try stepFromKindText(allocator, kind_text, pressure)
        else
            try stepFromProposal(allocator, pressure);
    }
    return steps;
}

fn stepFromKindText(allocator: std.mem.Allocator, kind_text: []const u8, proposal: chat_mod.ActionProposal) !ProcessStep {
    const kind = parseStepKind(kind_text) orelse return try stepFromProposal(allocator, proposal);
    var step = try stepFromProposal(allocator, proposal);
    step.kind = kind;
    return step;
}

fn parseStepKind(kind_text: []const u8) ?StepKind {
    if (std.mem.eql(u8, kind_text, "sync_capability")) return .sync_capability;
    if (std.mem.eql(u8, kind_text, "async_host_pull")) return .async_host_pull;
    if (std.mem.eql(u8, kind_text, "wait_timer")) return .wait_timer;
    if (std.mem.eql(u8, kind_text, "wait_stimulus")) return .wait_stimulus;
    if (std.mem.eql(u8, kind_text, "respond")) return .respond;
    return null;
}

fn stepFromProposal(allocator: std.mem.Allocator, proposal: chat_mod.ActionProposal) !ProcessStep {
    return switch (proposal.action) {
        .get_time, .get_power, .get_storage, .get_database_stats, .request_orientation => .{
            .kind = .sync_capability,
            .action = proposal.action,
        },
        .recognize, .take_picture, .describe_image => .{
            .kind = .async_host_pull,
            .action = proposal.action,
            .sense = try allocator.dupe(u8, hostSenseForAction(proposal.action)),
            .purpose = try allocator.dupe(u8, hostPurposeForAction(proposal.action)),
            .timeout_ms = null,
        },
        .schedule_reminder => .{
            .kind = .wait_timer,
            .action = .schedule_reminder,
            .timer_intent = if (proposal.text) |text| try allocator.dupe(u8, text) else try allocator.dupe(u8, "scheduled wait"),
        },
        .say => .{
            .kind = .respond,
            .action = .say,
            .evidence_marker = null,
            .respond_text = if (proposal.text) |text| try allocator.dupe(u8, text) else null,
        },
        else => .{
            .kind = .sync_capability,
            .action = proposal.action,
        },
    };
}

fn hostSenseForAction(action: chat_mod.ActionProposalType) []const u8 {
    return switch (action) {
        .recognize, .take_picture, .describe_image => "camera",
        .request_orientation => "orientation",
        else => "unknown",
    };
}

fn hostPurposeForAction(action: chat_mod.ActionProposalType) []const u8 {
    return switch (action) {
        .recognize => "recognize",
        .take_picture => "take_picture",
        .describe_image => "describe_image",
        .request_orientation => "sample",
        else => "interaction",
    };
}

const process_recipe_memory = @import("process_recipe_memory.zig");

fn persistActiveProcessOutcome(self: *Brain, outcome: process_recipe_memory.ProcessOutcome, failure_detail: ?[]const u8) !void {
    const process = self.active_process orelse return;
    const composition = try process_recipe_memory.compositionFromActiveProcess(self.allocator, process);
    defer process_recipe_memory.freeCompositionMemory(self.allocator, composition);
    try process_recipe_memory.recordOutcome(self, process.goal, process.origin, composition, outcome, &.{}, failure_detail);
}

pub fn clearActiveProcess(self: *Brain) void {
    const process = self.active_process orelse return;
    self.allocator.free(process.id);
    self.allocator.free(process.goal);
    self.allocator.free(process.user_anchor);
    if (process.composition_reason) |reason| self.allocator.free(reason);
    if (process.wait_stimulus_signature) |signature| self.allocator.free(signature);
    for (process.steps) |step| freeProcessStep(self.allocator, step);
    self.allocator.free(process.steps);
    for (process.step_ids) |step_id| self.allocator.free(step_id);
    self.allocator.free(process.step_ids);
    self.active_process = null;
}

pub fn abortActiveProcessForInterrupt(self: *Brain, reason: []const u8) !void {
    const process = self.active_process orelse return;
    const current = if (process.step_index < process.steps.len) process.steps[process.step_index] else null;
    const waiting_for: []const u8 = switch (process.state) {
        .waiting_host => "host_sense",
        .waiting_timer => process.steps[process.step_index].timer_intent orelse "timer",
        .waiting_stimulus => "stimulus",
        else => "none",
    };
    const step_kind = if (current) |step| @tagName(step.kind) else "none";
    const body = try std.fmt.allocPrint(self.allocator, "goal={s} state={s} step={d}/{d} kind={s} waiting={s} reason={s}", .{
        process.goal,
        @tagName(process.state),
        process.step_index + 1,
        process.steps.len,
        step_kind,
        waiting_for,
        reason,
    });
    defer self.allocator.free(body);
    try logProcessEvent(self, "process.aborted", body);
    try persistActiveProcessOutcome(self, .aborted, body);
    clearActiveProcess(self);
}

fn freeProcessStep(allocator: std.mem.Allocator, step: ProcessStep) void {
    if (step.sense) |sense| allocator.free(sense);
    if (step.purpose) |purpose| allocator.free(purpose);
    if (step.stimulus_signature) |signature| allocator.free(signature);
    if (step.respond_text) |value| allocator.free(value);
    if (step.timer_intent) |intent| allocator.free(intent);
}

pub fn freeProcessStepFields(allocator: std.mem.Allocator, step: ProcessStep) void {
    freeProcessStep(allocator, step);
}

pub fn startProcessUnchecked(
    self: *Brain,
    goal: []const u8,
    user_anchor: []const u8,
    origin: chat_mod.ActionOrigin,
    composition_reason: ?[]const u8,
    steps: []ProcessStep,
) !void {
    try startProcessIntoSlot(self, goal, user_anchor, origin, composition_reason, steps, .primary);
}

pub fn startSecondaryProcess(
    self: *Brain,
    goal: []const u8,
    user_anchor: []const u8,
    origin: chat_mod.ActionOrigin,
    composition_reason: ?[]const u8,
    steps: []ProcessStep,
) !void {
    const id = try operation_ids.allocProcessId(self, goal);
    const owned_steps = try self.allocator.alloc(ProcessStep, steps.len);
    for (steps, 0..) |step, index| {
        owned_steps[index] = try cloneProcessStep(self.allocator, step);
    }
    const step_ids = try operation_ids.allocStepIds(self.allocator, id, steps.len);
    errdefer {
        for (step_ids) |step_id| self.allocator.free(step_id);
        self.allocator.free(step_ids);
    }
    const process: ActiveProcess = .{
        .id = id,
        .goal = try self.allocator.dupe(u8, goal),
        .user_anchor = try self.allocator.dupe(u8, user_anchor),
        .origin = origin,
        .steps = owned_steps,
        .step_ids = step_ids,
        .step_index = 0,
        .state = .running,
        .started_at = self.now_seconds,
        .timeout_deadline_seconds = null,
        .composition_reason = if (composition_reason) |reason| try self.allocator.dupe(u8, reason) else null,
    };
    try self.work_registry.registerSecondary(self.allocator, process);
    try logProcessEvent(self, "process.start.side_lane", try formatProcessStartBody(self, goal, steps, composition_reason));
    self.traceText("process.start.side_lane", goal);
}

fn startProcessIntoSlot(
    self: *Brain,
    goal: []const u8,
    user_anchor: []const u8,
    origin: chat_mod.ActionOrigin,
    composition_reason: ?[]const u8,
    steps: []ProcessStep,
    slot: enum { primary, secondary },
) !void {
    _ = slot;
    const id = try operation_ids.allocProcessId(self, goal);
    const owned_steps = try self.allocator.alloc(ProcessStep, steps.len);
    for (steps, 0..) |step, index| {
        owned_steps[index] = try cloneProcessStep(self.allocator, step);
    }
    const step_ids = try operation_ids.allocStepIds(self.allocator, id, steps.len);
    errdefer {
        for (step_ids) |step_id| self.allocator.free(step_id);
        self.allocator.free(step_ids);
    }
    self.active_process = .{
        .id = id,
        .goal = try self.allocator.dupe(u8, goal),
        .user_anchor = try self.allocator.dupe(u8, user_anchor),
        .origin = origin,
        .steps = owned_steps,
        .step_ids = step_ids,
        .step_index = 0,
        .state = .running,
        .started_at = self.now_seconds,
        .timeout_deadline_seconds = null,
        .composition_reason = if (composition_reason) |reason| try self.allocator.dupe(u8, reason) else null,
    };
    try logProcessEvent(self, "process.start", try formatProcessStartBody(self, goal, steps, composition_reason));
    self.traceText("process.start", goal);
}

pub fn startProcess(
    self: *Brain,
    goal: []const u8,
    user_anchor: []const u8,
    origin: chat_mod.ActionOrigin,
    composition_reason: ?[]const u8,
    steps: []ProcessStep,
) !void {
    if (self.active_process != null) {
        if (!self.work_registry.slotAvailable()) return error.NestedProcessGoal;
        try startSecondaryProcess(self, goal, user_anchor, origin, composition_reason, steps);
        return;
    }
    try startProcessUnchecked(self, goal, user_anchor, origin, composition_reason, steps);
}

fn cloneProcessStep(allocator: std.mem.Allocator, step: ProcessStep) !ProcessStep {
    return .{
        .kind = step.kind,
        .action = step.action,
        .sense = if (step.sense) |value| try allocator.dupe(u8, value) else null,
        .purpose = if (step.purpose) |value| try allocator.dupe(u8, value) else null,
        .stimulus_kind = step.stimulus_kind,
        .stimulus_signature = if (step.stimulus_signature) |value| try allocator.dupe(u8, value) else null,
        .evidence_marker = step.evidence_marker,
        .respond_text = if (step.respond_text) |value| try allocator.dupe(u8, value) else null,
        .timeout_ms = step.timeout_ms,
        .timer_intent = if (step.timer_intent) |value| try allocator.dupe(u8, value) else null,
    };
}

fn formatProcessStartBody(self: *Brain, goal: []const u8, steps: []ProcessStep, reason: ?[]const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(self.allocator);
    try out.appendSlice(self.allocator, "goal=");
    try out.appendSlice(self.allocator, goal);
    try out.appendSlice(self.allocator, "\nsteps=");
    for (steps, 0..) |step, index| {
        if (index > 0) try out.appendSlice(self.allocator, ",");
        try out.print(self.allocator, "{s}:{s}", .{ @tagName(step.kind), @tagName(step.action) });
    }
    if (reason) |value| try out.print(self.allocator, "\nreason={s}", .{value});
    return out.toOwnedSlice(self.allocator);
}

pub fn startFromProcessGoal(
    self: *Brain,
    goal: []const u8,
    user_anchor: []const u8,
    origin: chat_mod.ActionOrigin,
    composition: process_goal_mod.ProcessComposition,
) !void {
    const steps = try stepsFromComposition(self.allocator, composition);
    defer {
        for (steps) |step| freeProcessStep(self.allocator, step);
        self.allocator.free(steps);
    }
    const persistent = try self.allocator.alloc(ProcessStep, steps.len);
    for (steps, 0..) |step, index| persistent[index] = try cloneProcessStep(self.allocator, step);
    try startProcess(self, goal, user_anchor, origin, composition.reason, persistent);
}

pub fn activeProcessModel(self: *Brain) ActiveProcessModel {
    const process = self.active_process orelse return .{};
    const current = if (process.step_index < process.steps.len) process.steps[process.step_index] else null;
    const timeout_remaining: ?i64 = if (process.timeout_deadline_seconds) |deadline|
        @max(@as(i64, 0), deadline - self.now_seconds)
    else
        null;
    const waiting_for: ?[]const u8 = switch (process.state) {
        .waiting_host => "host_sense",
        .waiting_timer => process.steps[process.step_index].timer_intent,
        .waiting_stimulus => "stimulus",
        else => null,
    };
    return .{
        .process_id = process.id,
        .goal = process.goal,
        .state = @tagName(process.state),
        .step_index = process.step_index,
        .step_count = process.steps.len,
        .current_step_kind = if (current) |step| @tagName(step.kind) else null,
        .waiting_for = waiting_for,
        .timeout_remaining_seconds = timeout_remaining,
        .origin = @tagName(process.origin),
    };
}

pub fn advanceProcess(
    self: *Brain,
    memory: []const u8,
    memory_sections: []const context_composition.SectionStat,
    user_text: []const u8,
    observations: *std.ArrayList(u8),
) !AdvanceResult {
    const process_ptr = &self.active_process.?;
    _ = memory;
    _ = memory_sections;
    if (process_ptr.state == .completed or process_ptr.state == .failed) return error.NoActiveProcess;
    if (try checkProcessTimeout(self)) |failure| return failure;

    while (process_ptr.step_index < process_ptr.steps.len) {
        const step = process_ptr.steps[process_ptr.step_index];
        try logProcessStepStart(self, step);
        const step_result = try executeProcessStep(self, step, user_text, observations);
        try logProcessStepDone(self, step, step_result.detail);
        switch (step_result.outcome) {
            .continued => {
                process_ptr.step_index += 1;
                process_ptr.state = .running;
                continue;
            },
            .waiting_host => {
                process_ptr.state = .waiting_host;
                if (step.timeout_ms) |timeout_ms| {
                    process_ptr.timeout_deadline_seconds = self.now_seconds + @divFloor(timeout_ms, 1000) + 1;
                }
                try logProcessEvent(self, "process.wait", "waiting_for=host_sense");
                return .{
                    .spoken_text = step_result.spoken_text orelse "",
                    .final_turn = step_result.final_turn,
                    .awaiting_host_sense = true,
                    .process_waiting = true,
                };
            },
            .waiting_timer => {
                process_ptr.state = .waiting_timer;
                try logProcessEvent(self, "process.wait", try std.fmt.allocPrint(
                    self.allocator,
                    "waiting_for=timer intent={s}",
                    .{step.timer_intent orelse "scheduled wait"},
                ));
                return .{
                    .spoken_text = step_result.spoken_text orelse "",
                    .final_turn = step_result.final_turn,
                    .process_waiting = true,
                };
            },
            .waiting_stimulus => {
                process_ptr.state = .waiting_stimulus;
                process_ptr.wait_stimulus_kind = step.stimulus_kind;
                if (process_ptr.wait_stimulus_signature) |signature| self.allocator.free(signature);
                process_ptr.wait_stimulus_signature = if (step.stimulus_signature) |signature|
                    try self.allocator.dupe(u8, signature)
                else
                    null;
                try logProcessEvent(self, "process.wait", "waiting_for=stimulus");
                return .{
                    .spoken_text = step_result.spoken_text orelse "",
                    .final_turn = step_result.final_turn,
                    .process_waiting = true,
                };
            },
            .completed => {
                process_ptr.state = .completed;
                try logProcessEvent(self, "process.complete", step_result.detail orelse "completed");
                const spoken = step_result.spoken_text orelse "";
                const turn = step_result.final_turn orelse try syntheticProcessTurn(self, user_text, "process completed");
                try persistActiveProcessOutcome(self, .success, null);
                clearActiveProcess(self);
                return .{
                    .spoken_text = spoken,
                    .final_turn = turn,
                    .awaiting_host_sense = false,
                };
            },
            .failed => |message| {
                process_ptr.state = .failed;
                try logProcessEvent(self, "process.failed", message);
                try persistActiveProcessOutcome(self, .failed, message);
                clearActiveProcess(self);
                return error.ProcessStepFailed;
            },
        }
    }
    process_ptr.state = .completed;
    try logProcessEvent(self, "process.complete", "steps exhausted without respond");
    try persistActiveProcessOutcome(self, .success, null);
    clearActiveProcess(self);
    return .{
        .spoken_text = "",
        .final_turn = try syntheticProcessTurn(self, user_text, "process steps exhausted"),
    };
}

const StepOutcomeTag = enum {
    continued,
    waiting_host,
    waiting_timer,
    waiting_stimulus,
    completed,
    failed,
};

const StepExecutionResult = struct {
    outcome: union(enum) {
        continued: void,
        waiting_host: void,
        waiting_timer: void,
        waiting_stimulus: void,
        completed: void,
        failed: []const u8,
    },
    spoken_text: ?[]const u8 = null,
    final_turn: ?chat_mod.ChatTurn = null,
    detail: ?[]const u8 = null,
};

fn executeProcessStep(
    self: *Brain,
    step: ProcessStep,
    user_text: []const u8,
    observations: *std.ArrayList(u8),
) !StepExecutionResult {
    return switch (step.kind) {
        .sync_capability => try executeSyncCapabilityStep(self, step, observations),
        .async_host_pull => try executeAsyncHostPullStep(self, step, observations),
        .wait_timer => try executeWaitTimerStep(self, step),
        .wait_stimulus => .{ .outcome = .{ .waiting_stimulus = {} } },
        .respond => try executeRespondStep(self, step, user_text, observations.items),
    };
}

fn executeSyncCapabilityStep(
    self: *Brain,
    step: ProcessStep,
    observations: *std.ArrayList(u8),
) !StepExecutionResult {
    const proposal = chat_mod.ActionProposal{
        .action = step.action,
        .origin = self.active_process.?.origin,
    };
    var proposals = [_]chat_mod.ActionProposal{proposal};
    const batch = try brain_runtime_bridge.executeProposalBatch(self, proposals[0..], observations);
    if (batch.interrupted_by != null) {
        return .{
            .outcome = .{ .failed = "interrupted during sync capability step" },
            .spoken_text = batch.spoken_text,
        };
    }
    if (observations.items.len == 0) {
        return .{ .outcome = .{ .failed = "sync capability produced no observation" } };
    }
    return .{ .outcome = .{ .continued = {} }, .spoken_text = batch.spoken_text };
}

fn executeAsyncHostPullStep(
    self: *Brain,
    step: ProcessStep,
    observations: *std.ArrayList(u8),
) !StepExecutionResult {
    const proposal = chat_mod.ActionProposal{
        .action = step.action,
        .origin = self.active_process.?.origin,
    };
    var proposals = [_]chat_mod.ActionProposal{proposal};
    const batch = try brain_runtime_bridge.executeProposalBatch(self, proposals[0..], observations);
    if (self.awaitedHostRequestActive()) {
        return .{
            .outcome = .{ .waiting_host = {} },
            .spoken_text = batch.spoken_text,
            .detail = "awaiting host sense delivery",
        };
    }
    return .{ .outcome = .{ .continued = {} }, .spoken_text = batch.spoken_text };
}

fn executeWaitTimerStep(self: *Brain, step: ProcessStep) !StepExecutionResult {
    const intent = step.timer_intent orelse return .{ .outcome = .{ .failed = "wait_timer step missing intent" } };
    try brain_mod.Brain.setWaitingFor(self, .timer, intent);
    return .{ .outcome = .{ .waiting_timer = {} }, .detail = intent };
}

fn executeRespondStep(
    self: *Brain,
    step: ProcessStep,
    user_text: []const u8,
    observations: []const u8,
) !StepExecutionResult {
    _ = step;
    const response_text = deriveRespondText(self, observations) catch |err| switch (err) {
        error.MissingProcessEvidence => return .{ .outcome = .{ .failed = "respond step missing required evidence" } },
        else => return err,
    };
    defer self.allocator.free(response_text);
    const proposal = chat_mod.ActionProposal{
        .action = .say,
        .origin = self.active_process.?.origin,
        .text = try self.allocator.dupe(u8, response_text),
    };
    defer self.allocator.free(proposal.text.?);
    var obs = std.ArrayList(u8).empty;
    defer obs.deinit(self.allocator);
    try obs.appendSlice(self.allocator, observations);
    var proposals = [_]chat_mod.ActionProposal{proposal};
    const batch = try brain_runtime_bridge.executeProposalBatch(self, proposals[0..], &obs);
    const spoken = if (batch.spoken_text) |value|
        try self.allocator.dupe(u8, value)
    else
        try self.allocator.dupe(u8, response_text);
    const turn = try syntheticProcessTurn(self, user_text, "respond step completed");
    return .{
        .outcome = .{ .completed = {} },
        .spoken_text = spoken,
        .final_turn = turn,
        .detail = response_text,
    };
}

fn deriveRespondText(self: *Brain, observations: []const u8) ![]const u8 {
    const process = self.active_process orelse return error.NoActiveProcess;
    const step = process.steps[process.step_index];
    if (step.respond_text) |text| return self.allocator.dupe(u8, text);
    if (step.evidence_marker) |marker| {
        if (std.mem.indexOf(u8, observations, marker) == null) return error.MissingProcessEvidence;
    }
    return error.MissingProcessEvidence;
}

fn syntheticProcessTurn(self: *Brain, user_text: []const u8, brain_summary: []const u8) !chat_mod.ChatTurn {
    return .{
        .action_pressures = &.{},
        .user_summary = try self.allocator.dupe(u8, user_text),
        .brain_summary = try self.allocator.dupe(u8, brain_summary),
        .turn_complete = true,
    };
}

fn checkProcessTimeout(self: *Brain) !?AdvanceResult {
    const process = self.active_process orelse return null;
    const deadline = process.timeout_deadline_seconds orelse return null;
    if (self.now_seconds < deadline) return null;
    const process_ptr = &self.active_process.?;
    try logProcessEvent(self, "process.failed", "process timeout elapsed");
    process_ptr.state = .failed;
    const user_anchor = try self.allocator.dupe(u8, process_ptr.user_anchor);
    defer self.allocator.free(user_anchor);
    try persistActiveProcessOutcome(self, .failed, "process timeout elapsed");
    clearActiveProcess(self);
    return .{
        .spoken_text = try self.allocator.dupe(u8, "I ran out of time waiting for what I needed."),
        .final_turn = try syntheticProcessTurn(self, user_anchor, "process timed out"),
    };
}

pub fn resumeProcess(
    self: *Brain,
    trigger: ResumeTrigger,
    detail: []const u8,
    memory: []const u8,
    memory_sections: []const context_composition.SectionStat,
    observations: *std.ArrayList(u8),
) !?AdvanceResult {
    const process = self.active_process orelse return null;
    const expected_state: ProcessState = switch (trigger) {
        .host_delivery => .waiting_host,
        .timer_fired => .waiting_timer,
        .stimulus => .waiting_stimulus,
        .timeout => return try checkProcessTimeout(self),
    };
    if (process.state != expected_state) return null;
    const process_ptr = &self.active_process.?;
    try logProcessEvent(self, "process.resume", detail);
    process_ptr.state = .running;
    process_ptr.timeout_deadline_seconds = null;
    if (trigger == .timer_fired) self.clearWaitingFor();
    process_ptr.step_index += 1;
    return try advanceProcess(self, memory, memory_sections, process_ptr.user_anchor, observations);
}

pub fn tryResumeFromStimulus(self: *Brain, kind: stimulus_mod.Kind, signature: []const u8) bool {
    const process = self.active_process orelse return false;
    if (process.state != .waiting_stimulus) return false;
    if (process.wait_stimulus_kind) |expected| {
        if (expected != kind) return false;
    }
    if (process.wait_stimulus_signature) |expected| {
        if (!std.mem.eql(u8, expected, signature)) return false;
    }
    return true;
}

pub fn logTurnDebug(
    self: *Brain,
    turn_index: usize,
    turn: chat_mod.ChatTurn,
    proposals_before_expansion: []const chat_mod.ActionProposal,
) !void {
    var pressure_summary = std.ArrayList(u8).empty;
    defer pressure_summary.deinit(self.allocator);
    try pressure_summary.appendSlice(self.allocator, "turn=");
    try pressure_summary.print(self.allocator, "{d}", .{turn_index});
    try pressure_summary.appendSlice(self.allocator, "\nbrain_summary=");
    try pressure_summary.appendSlice(self.allocator, turn.brain_summary);
    try pressure_summary.appendSlice(self.allocator, "\naction_pressures=");
    for (proposals_before_expansion, 0..) |proposal, index| {
        if (index > 0) try pressure_summary.appendSlice(self.allocator, ",");
        if (proposal.process_goal) |goal| {
            try pressure_summary.appendSlice(self.allocator, "process:");
            try pressure_summary.appendSlice(self.allocator, goal);
        } else {
            try pressure_summary.appendSlice(self.allocator, @tagName(proposal.action));
        }
    }
    try logProcessEvent(self, "turn.brain_summary", try pressure_summary.toOwnedSlice(self.allocator));
}

fn logProcessStepStart(self: *Brain, step: ProcessStep) !void {
    const body = try std.fmt.allocPrint(
        self.allocator,
        "kind={s} action={s}",
        .{ @tagName(step.kind), @tagName(step.action) },
    );
    defer self.allocator.free(body);
    if (self.active_process) |*process| {
        if (self.deps.io) |io| {
            process.step_started_ms = std.Io.Clock.real.now(io).toMilliseconds();
        }
    }
    try logProcessEvent(self, "process.step.start", body);
    self.traceText("process.step.start", body);
}

fn logProcessStepDone(self: *Brain, step: ProcessStep, detail: ?[]const u8) !void {
    if (self.active_process) |*process| {
        if (process.step_started_ms) |started_ms| {
            const ended_ms: i64 = if (self.deps.io) |io|
                std.Io.Clock.real.now(io).toMilliseconds()
            else
                started_ms;
            const duration_ms = ended_ms - started_ms;
            process.step_started_ms = null;
            const step_id = if (process.step_index < process.step_ids.len)
                process.step_ids[process.step_index]
            else
                "";
            try self.recordRequestSpan(.{
                .span_id = try self.requestTimingsAllocSpanId(),
                .kind = try self.allocator.dupe(u8, "process_step"),
                .label = try self.allocator.dupe(u8, @tagName(step.kind)),
                .duration_ms = duration_ms,
                .dispatch_id = try self.ownedTimingDispatchId(),
                .activity_id = try self.ownedTimingActivityId(),
                .process_id = try self.allocator.dupe(u8, process.id),
                .step_id = if (step_id.len > 0) try self.allocator.dupe(u8, step_id) else null,
                .step_index = process.step_index,
                .action = try self.allocator.dupe(u8, @tagName(step.action)),
            });
        }
    }
    try logProcessEvent(self, "process.step.done", detail orelse "ok");
}

pub fn logProcessEvent(self: *Brain, title: []const u8, body: []const u8) !void {
    var owned_body: ?[]const u8 = null;
    defer if (owned_body) |text| self.allocator.free(text);
    const final_body = if (self.current_dispatch_request_id) |request_id| blk: {
        owned_body = try std.fmt.allocPrint(self.allocator, "{s}\ndispatch_id={s}", .{ body, request_id });
        break :blk owned_body.?;
    } else body;
    try brain_logging_events.appendEventLog(self, "process", title, final_body);
}

pub const NestedProcessGoal = error{NestedProcessGoal};
pub const NoActiveProcess = error{NoActiveProcess};
pub const MissingProcessEvidence = error{MissingProcessEvidence};
pub const ProcessStepFailed = error{ProcessStepFailed};

test "abortActiveProcessForInterrupt logs and clears active process" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var steps = [_]ProcessStep{
        .{
            .kind = .async_host_pull,
            .action = .recognize,
            .sense = try allocator.dupe(u8, "camera"),
            .purpose = try allocator.dupe(u8, "recognize"),
        },
        .{ .kind = .respond, .action = .say },
    };
    try startProcess(&brain, "search_memory", "Who was that?", .interaction, "test", steps[0..]);
    try std.testing.expect(brain.active_process != null);

    try abortActiveProcessForInterrupt(&brain, "user_requested_interrupt");
    try std.testing.expect(brain.active_process == null);
}

test "template answer_with_host_visual has recognize then respond" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const steps = try templateSteps(arena.allocator(), "answer_with_host_visual");
    const owned = steps.?;
    defer arena.allocator().free(owned);
    try std.testing.expectEqual(@as(usize, 2), owned.len);
    try std.testing.expectEqual(StepKind.async_host_pull, owned[0].kind);
    try std.testing.expectEqual(chat_mod.ActionProposalType.recognize, owned[0].action);
    try std.testing.expectEqual(StepKind.respond, owned[1].kind);
}

test "respond step requires composed say text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    var steps = [_]ProcessStep{
        .{ .kind = .respond, .action = .say, .evidence_marker = "time:\n" },
    };
    try startProcess(&brain, "answer_time_question", "What time is it?", .interaction, "test", steps[0..]);
    try std.testing.expectError(error.MissingProcessEvidence, deriveRespondText(&brain, "time:\n- friendly: noon\n"));
}

test "process step timing span includes process_id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();

    var store = @import("brain_test_support.zig").TestStore.init(allocator);
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    brain.deps.io = io_threaded.io();

    try brain.beginRequestTimings("req-process-step");
    var steps = [_]ProcessStep{
        .{ .kind = .respond, .action = .say },
    };
    try startProcess(&brain, "answer_time_question", "What time is it?", .interaction, "test", steps[0..]);
    try logProcessStepStart(&brain, steps[0]);
    try logProcessStepDone(&brain, steps[0], "ok");

    var report = try brain.finishRequestTimings();
    defer @import("request_timings.zig").deinitReport(allocator, &report);

    var process_step_spans: usize = 0;
    for (report.spans) |span| {
        if (!std.mem.eql(u8, span.kind, "process_step")) continue;
        process_step_spans += 1;
        const process_id = span.process_id orelse return error.MissingProcessId;
        try std.testing.expect(std.mem.startsWith(u8, process_id, "process_"));
    }
    try std.testing.expectEqual(@as(usize, 1), process_step_spans);
}
