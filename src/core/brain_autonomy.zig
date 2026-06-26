const std = @import("std");
const brain_mod = @import("brain.zig");
const maintenance = @import("maintenance.zig");
const needs_mod = @import("needs.zig");
const psyche_mod = @import("psyche.zig");
const ports = @import("ports.zig");
const chat_mod = ports.chat;
const skills_mod = ports.skills;
const autonomy_mod = ports.autonomy;
const facial_expression = ports.facial_expression;
const brain_introspection = @import("brain_introspection_autonomy.zig");

const Brain = brain_mod.Brain;
const QuietHours = brain_mod.Brain.QuietHours;

pub fn autonomyStateForNeeds(self: *Brain) !?maintenance.AutonomyState {
    if (!autonomyEnabled(self)) return null;
    const io = self.deps.io orelse return error.LocalDateUnavailable;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const day_key = try localDayKey(self, io);
    return try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, defaultAutonomySleeping(self), self.cfg.autonomy_daily_energy, day_key);
}

pub fn autonomyEnabled(self: *Brain) bool {
    return std.mem.eql(u8, self.cfg.autonomy_mode, "on");
}

pub fn psycheEnabled(self: *Brain) !bool {
    if (std.mem.eql(u8, self.cfg.psyche_mode, "on")) return true;
    if (std.mem.eql(u8, self.cfg.psyche_mode, "off")) return false;
    return error.InvalidPsycheMode;
}

pub fn defaultAutonomySleeping(self: *Brain) bool {
    return std.mem.eql(u8, self.cfg.autonomy_sleep, "on");
}

pub fn autonomyPlannerCost() u32 {
    return 1;
}

pub fn autonomyCommandCost(command: chat_mod.ChatCommandType) !u32 {
    return try skills_mod.autonomyEnergyCost(command);
}

pub fn autonomyIntrospection(self: *Brain) ![]const u8 {
    const costs = try skills_mod.autonomyCostCatalog(self.allocator);
    if (!autonomyEnabled(self)) {
        return std.fmt.allocPrint(
            self.allocator,
            "- autonomy: enabled=false sleeping=false energy_remaining=0 daily_energy_allowance={d} day_key=disabled blocked=disabled\n- autonomy_energy_costs: {s}",
            .{ self.cfg.autonomy_daily_energy, costs },
        );
    }
    const io = self.deps.io orelse return error.LocalDateUnavailable;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const day_key = try localDayKey(self, io);
    const state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, defaultAutonomySleeping(self), self.cfg.autonomy_daily_energy, day_key);
    const blocked = try autonomyBlockedReason(self, io, state);
    return std.fmt.allocPrint(
        self.allocator,
        "- autonomy: enabled=true sleeping={any} energy_remaining={d} daily_energy_allowance={d} day_key={s} blocked={s}\n- autonomy_energy_costs: {s}",
        .{ state.sleeping, state.energy_remaining, self.cfg.autonomy_daily_energy, state.energy_day_key, blocked, costs },
    );
}

pub fn autonomyBlockedReason(self: *Brain, io: std.Io, state: maintenance.AutonomyState) ![]const u8 {
    if (state.sleeping) return if (state.energy_exhausted) "energy_exhausted" else "sleep";
    if (state.energy_remaining == 0) return "energy_exhausted";
    if (try inQuietHours(self, io)) return "quiet_hours";
    if (speechCooldownActive(self, state)) return "speech_cooldown";
    return "none";
}

pub fn buildAutonomyContext(self: *Brain, io: std.Io, state: maintenance.AutonomyState) ![]const u8 {
    const shared_context = try buildPsycheSharedContext(self, io, state);
    if (!(try psycheEnabled(self))) return psyche_mod.formatEgoContextWithoutPsyche(self.allocator, shared_context);
    const psyche = self.deps.psyche_service orelse return error.MissingPsycheService;
    const id = try psyche.consultId(self.allocator, shared_context);
    const superego = try psyche.consultSuperego(self.allocator, shared_context);
    return psyche_mod.formatEgoContext(self.allocator, shared_context, id, superego);
}

pub fn buildPsycheSharedContext(self: *Brain, io: std.Io, state: maintenance.AutonomyState) ![]const u8 {
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
        .autonomy_energy_remaining = state.energy_remaining,
        .autonomy_daily_energy = self.cfg.autonomy_daily_energy,
        .autonomy_sleeping = state.sleeping,
    });
    return psyche_mod.formatSharedContext(self.allocator, .{
        .now = try self.timestampNow(),
        .energy_remaining = state.energy_remaining,
        .daily_energy = self.cfg.autonomy_daily_energy,
        .day_key = state.energy_day_key,
        .sleeping = state.sleeping,
        .quiet_hours_active = try inQuietHours(self, io),
        .speech_cooldown_active = speechCooldownActive(self, state),
        .blocked = try autonomyBlockedReason(self, io, state),
        .affordances = try autonomyAffordanceCatalog(self),
        .needs = active_needs,
        .relationship_graph = try self.deps.graph.summary(self.allocator, 8),
        .memories = memories,
        .appraisals = appraisals,
        .impressions = impressions,
        .superego_self_model = try brain_introspection.superegoSelfModelSummary(self, memories),
        .current_stimulus = self.current_stimulus_context orelse "",
    });
}

pub fn autonomyAffordanceCatalog(self: *Brain) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (skills_mod.registry) |skill| {
        switch (skill.autonomy_policy) {
            .allowed => try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: {s}; cost={d}\n", .{ skill.name, skill.description, skill.energy_cost orelse return error.MissingAutonomyEnergyCost })),
            .forbidden => try out.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "- {s}: forbidden for autonomy\n", .{skill.name})),
            .invalid => {},
        }
    }
    return out.toOwnedSlice(self.allocator);
}

pub fn executeAutonomyTurn(self: *Brain, io: std.Io, state: *maintenance.AutonomyState, turn: autonomy_mod.AutonomyTurn) !void {
    const cost = try Brain.autonomyCommandCost(turn.command.command);
    if (cost > state.energy_remaining) {
        state.last_reason = try std.fmt.allocPrint(self.allocator, "insufficient energy for {s}", .{@tagName(turn.command.command)});
        if (state.energy_remaining == 0) {
            state.sleeping = true;
            state.energy_exhausted = true;
        }
        return;
    }
    if (turn.command.command == .say) {
        if (turn.salience != .high) {
            state.last_reason = try self.allocator.dupe(u8, "autonomous speech suppressed: salience below high");
            return;
        }
        if (try inQuietHours(self, io)) {
            state.last_reason = try self.allocator.dupe(u8, "autonomous speech suppressed: quiet hours");
            return;
        }
        if (speechCooldownActive(self, state.*)) {
            state.last_reason = try self.allocator.dupe(u8, "autonomous speech suppressed: cooldown");
            return;
        }
        state.energy_remaining -= cost;
        state.last_autonomous_speech_at = self.now_seconds;
        state.last_reason = try self.allocator.dupe(u8, turn.reason);
        var observations = std.ArrayList(u8).empty;
        var commands = [_]chat_mod.ChatCommand{turn.command};
        _ = try self.executeChatCommands(commands[0..], &observations);
        return;
    }
    if (turn.command.command == .facial_expression and facialExpressionCooldownActive(self)) {
        state.last_reason = try self.allocator.dupe(u8, "autonomous facial expression suppressed: cooldown");
        return;
    }

    state.energy_remaining -= cost;
    state.last_reason = try self.allocator.dupe(u8, turn.reason);
    if (state.energy_remaining == 0) {
        state.sleeping = true;
        state.energy_exhausted = true;
    }
    var observations = std.ArrayList(u8).empty;
    var commands = [_]chat_mod.ChatCommand{turn.command};
    _ = try self.executeChatCommands(commands[0..], &observations);
    if (turn.command.command == .facial_expression) self.last_autonomous_facial_expression_at = self.now_seconds;
    if (turn.command.command == .ask_human) {
        state.sleeping = true;
        state.last_reason = try self.allocator.dupe(u8, "autonomy asked a human and is waiting for a response");
    }
}

pub fn setAutonomySleeping(self: *Brain, sleeping: bool, reason: []const u8) !void {
    const io = self.deps.io orelse return error.LocalDateUnavailable;
    const fs = self.deps.filesystem orelse return error.MissingFileSystem;
    const day_key = try localDayKey(self, io);
    var state = try maintenance.loadAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, defaultAutonomySleeping(self), self.cfg.autonomy_daily_energy, day_key);
    state.sleeping = sleeping;
    if (!sleeping) state.energy_exhausted = false;
    if (!sleeping) state.last_autonomy_tick_at = self.now_seconds;
    state.last_reason = try self.allocator.dupe(u8, reason);
    try maintenance.saveAutonomyState(self.allocator, fs, io, self.cfg.maintenance_state_path, state);
}

pub fn speechCooldownActive(self: *Brain, state: maintenance.AutonomyState) bool {
    const last = state.last_autonomous_speech_at orelse return false;
    const cooldown_seconds: i64 = @intCast(self.cfg.autonomy_speech_cooldown_minutes * 60);
    return self.now_seconds - last < cooldown_seconds;
}

pub fn facialExpressionCooldownActive(self: *Brain) bool {
    const last = self.last_autonomous_facial_expression_at orelse return false;
    return self.now_seconds - last < facial_expression.autonomy_cooldown_seconds;
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
    const runner = self.deps.process_runner orelse return error.MissingProcessRunner;
    const out = try runner.runCapture(self.allocator, io, &.{ "date", "+%F" });
    defer self.allocator.free(out);
    return try self.allocator.dupe(u8, std.mem.trim(u8, out, " \r\n\t"));
}

pub fn localMinuteOfDay(self: *Brain, io: std.Io) !u32 {
    const runner = self.deps.process_runner orelse return error.MissingProcessRunner;
    const out = try runner.runCapture(self.allocator, io, &.{ "date", "+%H:%M" });
    defer self.allocator.free(out);
    return Brain.parseClockMinute(std.mem.trim(u8, out, " \r\n\t"));
}
