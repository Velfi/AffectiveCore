const std = @import("std");
const brain_mod = @import("brain.zig");
const config_mod = @import("config.zig");
const maintenance = @import("maintenance.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const ports = @import("ports.zig");
const chat_mod = ports.chat;
const skills_mod = ports.skills;
const autonomy_mod = ports.autonomy;
const psyche_client = ports.psyche;
const brain_introspection = @import("brain_introspection_autonomy.zig");
const context_composition = @import("context_composition.zig");
const present_moment = @import("present_moment.zig");
const process_runtime_mod = @import("process_runtime.zig");
const process_recipe_memory = @import("process_recipe_memory.zig");
const brain_observation_append = @import("brain_observation_append.zig");
const clock_mod = @import("../platform/common/clock.zig");

const Brain = brain_mod.Brain;
const QuietHours = brain_mod.Brain.QuietHours;

pub fn autonomyStateForNeeds(self: *Brain) !?maintenance.AutonomyState {
    const io = self.deps.io orelse return null;
    const fs = self.deps.filesystem orelse return null;
    return try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, defaultAutonomySleeping(self), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
}

pub fn autonomyEnabled(self: *Brain) bool {
    return std.mem.eql(u8, self.cfg.autonomy_mode, "limited") or std.mem.eql(u8, self.cfg.autonomy_mode, "full");
}

pub fn psycheEnabled(self: *Brain) !bool {
    if (std.mem.eql(u8, self.cfg.psyche_mode, "on")) return true;
    if (std.mem.eql(u8, self.cfg.psyche_mode, "off")) return false;
    return error.InvalidPsycheMode;
}

pub fn defaultAutonomySleeping(self: *Brain) bool {
    return std.mem.eql(u8, self.cfg.autonomy_sleep, "on");
}

pub fn autonomyReplenishPointsPerMinute(cfg: config_mod.Config) f32 {
    if (std.mem.eql(u8, cfg.autonomy_mode, "limited")) return cfg.autonomy_limited_replenish_actions_per_minute;
    return cfg.autonomy_full_replenish_actions_per_minute;
}

pub fn autonomyReplenishRatePerSecond(cfg: config_mod.Config) f32 {
    return maintenance.replenishPointsPerSecond(autonomyReplenishPointsPerMinute(cfg));
}

pub fn autonomyReplenishSecondsPerPoint(cfg: config_mod.Config) f32 {
    const points_per_minute = autonomyReplenishPointsPerMinute(cfg);
    if (points_per_minute <= 0.0) return 0.0;
    return 60.0 / points_per_minute;
}

pub fn autonomyPlannerCost() u32 {
    return 0;
}

pub fn autonomyActionCost(command: chat_mod.ActionProposalType) !u32 {
    _ = command;
    return 0;
}

pub fn autonomyIntrospection(self: *Brain) ![]const u8 {
    const costs = try skills_mod.autonomyCostCatalog(self.allocator, self.cfg.autonomy_mode);
    if (!autonomyEnabled(self)) {
        return std.fmt.allocPrint(
            self.allocator,
            "- autonomy: mode={s} sleeping=false control_capacity=0.00/0.00 social_engagement=0.00 blocked=mode_off\n- autonomy_effort_catalog: {s}",
            .{ self.cfg.autonomy_mode, costs },
        );
    }
    const io = self.deps.io orelse return error.LocalDateUnavailable;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, defaultAutonomySleeping(self), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    const blocked = try autonomyBlockedReason(self, io, state);
    return std.fmt.allocPrint(
        self.allocator,
        "- autonomy: mode={s} sleeping={any} control_capacity={d:.2}/{d:.2} social_engagement={d:.2} voluntary_speech_streak={d} blocked={s}\n- autonomy_effort_catalog: {s}",
        .{ self.cfg.autonomy_mode, state.sleeping, state.control_capacity, state.max_capacity, state.social_engagement, state.consecutive_voluntary_speech, blocked, costs },
    );
}

pub fn autonomyBlockedReason(self: *Brain, io: std.Io, state: maintenance.AutonomyState) ![]const u8 {
    if (state.sleeping) return "sleep";
    if (std.mem.eql(u8, self.cfg.autonomy_mode, "off")) return "mode_off";
    if (!maintenance.autonomyBudgetAvailable(state)) return "autonomy_overdrawn";
    if (maintenance.autonomyActionCooldownActive(state, self.now_seconds)) return "action_cooldown";
    if (std.mem.eql(u8, self.cfg.autonomy_mode, "limited") and (try inQuietHours(self, io))) return "quiet_hours_bias";
    return "none";
}

pub fn buildAutonomyContext(self: *Brain, io: std.Io, state: maintenance.AutonomyState) ![]const u8 {
    const shared_context = try buildPsycheSharedContext(self, io, state);
    defer self.allocator.free(shared_context);
    if (!(try psycheEnabled(self))) {
        const ego_context = try psyche_mod.formatEgoContextWithoutPsyche(self.allocator, shared_context);
        try self.traceContextComposition(context_composition.auditAutonomyPlan(ego_context.len));
        return ego_context;
    }
    const psyche = self.deps.psyche_service orelse return error.MissingPsycheService;
    try self.traceContextComposition(context_composition.auditPsycheConsult("id", shared_context.len));
    try self.traceContextComposition(context_composition.auditPsycheConsult("superego", shared_context.len));
    const turns = try psyche.consultBoth(self.allocator, shared_context);
    const id = turns.id;
    const superego = turns.superego;
    const id_text = try psyche_client.formatIdTurn(self.allocator, id);
    defer self.allocator.free(id_text);
    const superego_text = try psyche_client.formatSuperegoTurn(self.allocator, superego);
    defer self.allocator.free(superego_text);
    try self.traceContextComposition(context_composition.auditPsycheEgoContext(shared_context.len, id_text.len, superego_text.len));
    const ego_context = try psyche_mod.formatEgoContext(self.allocator, shared_context, id, superego);
    try self.traceContextComposition(context_composition.auditAutonomyPlan(ego_context.len));
    return ego_context;
}

pub fn buildPsycheSharedContext(self: *Brain, io: std.Io, state: maintenance.AutonomyState) ![]const u8 {
    const inputs = try psycheSharedInputs(self, io, state);
    try self.traceContextComposition(context_composition.auditPsycheSharedInputs(inputs));
    const shared = try psyche_mod.formatSharedContext(self.allocator, inputs);
    defer self.allocator.free(shared);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.allocator, shared);
    try out.appendSlice(self.allocator, "\n");
    var pm = std.ArrayList(u8).empty;
    defer pm.deinit(self.allocator);
    try present_moment.appendObservation(self, &pm, null, null);
    try out.appendSlice(self.allocator, pm.items);
    if (present_moment.contactWindowOpen(self)) {
        try out.appendSlice(self.allocator, "recent_contact: open — contact already answered; inner work over voluntary say unless a new salient need appears.\n");
    }
    return out.toOwnedSlice(self.allocator);
}

fn psycheSharedInputs(self: *Brain, io: std.Io, state: maintenance.AutonomyState) !psyche_mod.SharedInputs {
    const summaries = try self.deps.store.loadConversationSummaries(self.allocator);
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const impressions = try self.deps.store.loadImpressions(self.allocator);
    const appraisals = try self.deps.store.loadAppraisals(self.allocator);
    const power = try self.deps.system_senses.power(self.allocator);
    const active_needs = try needs_mod.evaluate(self.allocator, .{
        .now_seconds = self.now_seconds,
        .conversation_summaries = summaries,
        .memory_records = memories,
        .relationship_graph = try self.deps.graph.summary(self.allocator, 8),
        .power = power,
        .autonomy_control_capacity = state.control_capacity,
        .autonomy_max_capacity = state.max_capacity,
        .autonomy_sleeping = state.sleeping,
    });
    const affordances = try autonomyAffordanceCatalog(self);
    defer self.allocator.free(affordances);
    var affordances_out = std.ArrayList(u8).empty;
    try affordances_out.appendSlice(self.allocator, affordances);
    try self.appendFacialExpressionCatalogObservation(&affordances_out);
    try process_recipe_memory.appendKnownWorkingProcessesBlock(self, &affordances_out);
    const affordances_with_catalog = try affordances_out.toOwnedSlice(self.allocator);
    return .{
        .now = try self.timestampNow(),
        .control_capacity = state.control_capacity,
        .max_capacity = state.max_capacity,
        .social_engagement = state.social_engagement,
        .consecutive_voluntary_speech = state.consecutive_voluntary_speech,
        .mode = self.cfg.autonomy_mode,
        .sleeping = state.sleeping,
        .quiet_hours_active = try inQuietHours(self, io),
        .blocked = try autonomyBlockedReason(self, io, state),
        .affordances = affordances_with_catalog,
        .needs = active_needs,
        .relationship_graph = try self.deps.graph.summary(self.allocator, 8),
        .memories = memories,
        .appraisals = appraisals,
        .impressions = impressions,
        .superego_self_model = try brain_introspection.superegoSelfModelSummary(self, memories),
        .current_stimulus = self.current_stimulus_context orelse "",
    };
}

pub fn autonomyAffordanceCatalog(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (skills_mod.registry) |skill| {
        switch (skill.autonomy_policy) {
            .allowed => {
                if (!self.actionIsAvailable(skill.id)) {
                    try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: unavailable for autonomy\n", .{skill.name}));
                } else {
                    const point_cost = try skills_mod.actionAutonomyPointCost(skill.id);
                    try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: {s}; cost={d}\n", .{ skill.name, skill.description, @as(u32, @intFromFloat(point_cost)) }));
                }
            },
            .full_allowed => {
                if (!std.mem.eql(u8, self.cfg.autonomy_mode, "full")) {
                    try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: forbidden for autonomy (full mode only)\n", .{skill.name}));
                } else if (!self.actionIsAvailable(skill.id)) {
                    try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: unavailable for autonomy\n", .{skill.name}));
                } else {
                    const point_cost = try skills_mod.actionAutonomyPointCost(skill.id);
                    try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: {s}; cost={d}\n", .{ skill.name, skill.description, @as(u32, @intFromFloat(point_cost)) }));
                }
            },
            .forbidden => try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: forbidden for autonomy\n", .{skill.name})),
            .invalid => {},
        }
    }
    return out.toOwnedSlice(self.allocator);
}

pub fn executeAutonomyTurn(self: *Brain, io: std.Io, state: *maintenance.AutonomyState, turn: autonomy_mod.AutonomyTurn) !void {
    _ = io;
    if (turn.action_pressures.len == 0) {
        const reason = "planner returned no action pressures";
        state.last_reason = try self.allocator.dupe(u8, reason);
        try self.logAutonomyStatus("autonomy plan", reason);
        return;
    }
    const pressures: []chat_mod.ActionProposal = @constCast(turn.action_pressures);
    for (pressures) |*proposal| proposal.origin = .autonomy;
    state.last_reason = try self.allocator.dupe(u8, turn.reason);
    try self.logAutonomyStatus("autonomy plan", turn.reason);
    var observations = std.ArrayList(u8).empty;
    _ = try self.executeRuntimeAutonomyBatch(pressures, &observations);
}

pub const AutonomyProcessTick = enum {
    idle,
    waiting,
    advanced,
};

pub fn tickActiveAutonomyProcess(self: *Brain) !AutonomyProcessTick {
    const process = self.active_process orelse return .idle;
    if (process.origin != .autonomy) return .idle;
    switch (process.state) {
        .waiting_host, .waiting_timer, .waiting_stimulus => return .waiting,
        .running => {},
        else => return .idle,
    }
    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(self.allocator);
    _ = try process_runtime_mod.advanceProcess(self, "", &.{}, process.user_anchor, &observations);
    return .advanced;
}

pub fn resumeAutonomyProcessFromHostDelivery(self: *Brain, delivered_line: []const u8) !bool {
    const process = self.active_process orelse return false;
    if (process.origin != .autonomy) return false;
    if (process.state != .waiting_host) return false;
    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(self.allocator);
    try brain_observation_append.appendHostSenseDeliveredObservation(self, &observations, delivered_line);
    if (try process_runtime_mod.resumeProcess(self, .host_delivery, delivered_line, "", &.{}, &observations)) |_| return true;
    return false;
}

pub fn resumeAutonomyProcessFromTimer(self: *Brain, intent_text: []const u8) !bool {
    const process = self.active_process orelse return false;
    if (process.origin != .autonomy) return false;
    if (process.state != .waiting_timer) return false;
    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(self.allocator);
    if (try process_runtime_mod.resumeProcess(self, .timer_fired, intent_text, "", &.{}, &observations)) |_| return true;
    return false;
}

pub fn setAutonomySleeping(self: *Brain, sleeping: bool, reason: []const u8) !void {
    const io = self.deps.io orelse return error.MissingBrainIo;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, defaultAutonomySleeping(self), self.cfg.autonomy_mode, .{
        .limited_max_capacity = self.cfg.autonomy_limited_max_capacity,
        .full_max_capacity = self.cfg.autonomy_full_max_capacity,
    });
    state.sleeping = sleeping;
    if (!sleeping) state.last_capacity_replenish_at = self.now_seconds;
    state.last_reason = try self.allocator.dupe(u8, reason);
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
}

pub fn speechCooldownActive(self: *Brain, state: maintenance.AutonomyState) bool {
    return maintenance.autonomyActionCooldownActive(state, self.now_seconds);
}

pub fn facialExpressionCooldownActive(self: *Brain, state: maintenance.AutonomyState) bool {
    return maintenance.autonomyActionCooldownActive(state, self.now_seconds);
}

pub fn inQuietHours(self: *Brain, io: std.Io) !bool {
    const range = try Brain.parseQuietHours(self.cfg.autonomy_quiet_hours);
    const minute = try localMinuteOfDay(self, io);
    if (range.start_minute == range.end_minute) return false;
    if (range.start_minute < range.end_minute) return minute >= range.start_minute and minute < range.end_minute;
    return minute >= range.start_minute or minute < range.end_minute;
}

pub fn parseQuietHours(text: []const u8) !QuietHours {
    const sep = std.mem.indexOfScalar(u8, text, '-') orelse return error.InvalidQuietHours;
    return .{
        .start_minute = try Brain.parseClockMinute(text[0..sep]),
        .end_minute = try Brain.parseClockMinute(text[sep + 1 ..]),
    };
}

pub fn parseClockMinute(text: []const u8) !u32 {
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), ':');
    const hour_text = parts.next() orelse return error.InvalidQuietHours;
    const minute_text = parts.next() orelse return error.InvalidQuietHours;
    const hour = try std.fmt.parseInt(u32, hour_text, 10);
    const minute = try std.fmt.parseInt(u32, minute_text, 10);
    if (hour > 23 or minute > 59) return error.InvalidQuietHours;
    return hour * 60 + minute;
}

pub fn localDayKey(self: *Brain, io: std.Io) ![]const u8 {
    self.syncClock(io);
    return clock_mod.localDayKeyFromUnix(self.allocator, self.now_seconds);
}

pub fn localMinuteOfDay(self: *Brain, io: std.Io) !u32 {
    self.syncClock(io);
    return clock_mod.localMinuteOfDayFromUnix(self.now_seconds);
}
