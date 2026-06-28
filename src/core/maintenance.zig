const std = @import("std");
const ports = @import("ports.zig");
const files = ports.files;
const FileSystem = files.FileSystem;

pub const ScheduleKind = enum { every_hours, daily_at, once_at };

pub const Task = struct {
    task_id: []const u8,
    capability_spec: []const u8,
    kind: ScheduleKind,
    interval_hours: u32 = 0,
    minute_of_day: u32 = 0,
    run_at_seconds: i64 = 0,
};

const TaskRun = struct {
    task_id: []const u8,
    last_run: i64,
};

const StateFile = struct {
    runs: []TaskRun = &.{},
    autonomy: ?AutonomyState = null,
};

pub const AutonomyState = struct {
    sleeping: bool = false,
    control_capacity: f32 = 0.0,
    max_capacity: f32 = 0.0,
    social_engagement: f32 = 0.0,
    consecutive_voluntary_speech: u32 = 0,
    last_user_turn_at: ?i64 = null,
    last_autonomy_tick_at: ?i64 = null,
    last_capacity_replenish_at: ?i64 = null,
    replenish_pending_capacity: f32 = 0.0,
    last_error: ?[]const u8 = null,
    last_reason: ?[]const u8 = null,
};

pub const AutonomyCapacityConfig = struct {
    limited_max_capacity: f32,
    full_max_capacity: f32,
};

pub fn loadTasks(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, path: []const u8) ![]Task {
    const bytes = fs.readFileAllocPath(io, path, allocator, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(bytes);

    var tasks = std.ArrayList(Task).empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var index: usize = 0;
    while (lines.next()) |line| : (index += 1) {
        const trimmed = trimMarkdownBullet(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (try parseTask(allocator, trimmed, index)) |task| try tasks.append(allocator, task);
    }
    return tasks.toOwnedSlice(allocator);
}

pub fn dueTasks(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, schedule_path: []const u8, state_path: []const u8, now_seconds: i64) ![]Task {
    const tasks = try loadTasks(allocator, fs, io, schedule_path);
    const state = try loadState(allocator, fs, io, state_path);
    var due = std.ArrayList(Task).empty;
    for (tasks) |task| {
        const last_run = findLastRun(state, task.task_id);
        if (isDue(task, last_run, now_seconds)) try due.append(allocator, task);
    }
    return due.toOwnedSlice(allocator);
}

pub fn markRun(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, state_path: []const u8, task_id: []const u8, now_seconds: i64) !void {
    var state = try loadState(allocator, fs, io, state_path);
    var replaced = false;
    for (state.runs, 0..) |run, i| {
        if (std.mem.eql(u8, run.task_id, task_id)) {
            state.runs[i] = .{ .task_id = try allocator.dupe(u8, task_id), .last_run = now_seconds };
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        var next = try allocator.alloc(TaskRun, state.runs.len + 1);
        @memcpy(next[0..state.runs.len], state.runs);
        next[state.runs.len] = .{ .task_id = try allocator.dupe(u8, task_id), .last_run = now_seconds };
        state.runs = next;
    }
    try saveState(allocator, fs, io, state_path, state);
}

pub fn loadAutonomyState(
    allocator: std.mem.Allocator,
    fs: FileSystem,
    io: std.Io,
    state_path: []const u8,
    default_sleeping: bool,
    autonomy_mode: []const u8,
    capacity_cfg: AutonomyCapacityConfig,
) !AutonomyState {
    const mode_max_capacity = maxCapacityForMode(autonomy_mode, capacity_cfg);
    const state = try loadState(allocator, fs, io, state_path);
    const existing = state.autonomy orelse return .{
        .sleeping = default_sleeping,
        .control_capacity = mode_max_capacity,
        .max_capacity = mode_max_capacity,
    };
    var next = existing;
    next.max_capacity = mode_max_capacity;
    next.control_capacity = clampCapacityUpper(next.control_capacity, next.max_capacity);
    next.social_engagement = clamp01(next.social_engagement);
    if (!default_sleeping and next.sleeping and next.last_reason == null) {
        // Old state files used sleeping as a zero-budget proxy. Keep explicit
        // user intent only.
        next.sleeping = false;
    }
    return next;
}

pub fn saveAutonomyState(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, state_path: []const u8, autonomy: AutonomyState) !void {
    var state = try loadState(allocator, fs, io, state_path);
    state.autonomy = try cloneAutonomyState(allocator, autonomy);
    try saveState(allocator, fs, io, state_path, state);
}

pub fn addReminder(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, schedule_path: []const u8, schedule: []const u8, text: []const u8, now_seconds: i64) ![]const u8 {
    try fs.ensureParentDir(io, schedule_path);
    const normalized_schedule = try normalizeReminderSchedule(allocator, schedule, now_seconds);
    errdefer allocator.free(normalized_schedule);
    const validation_text = try std.fmt.allocPrint(allocator, "{s} run say:{s}", .{ normalized_schedule, text });
    defer allocator.free(validation_text);
    const validation_task = (try parseTask(allocator, validation_text, 0)) orelse return error.InvalidReminderSchedule;
    defer allocator.free(validation_task.task_id);
    defer allocator.free(validation_task.capability_spec);

    const previous_result = fs.readFileAllocPath(io, schedule_path, allocator, .limited(128 * 1024));
    const previous = previous_result catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (previous) |bytes| allocator.free(bytes);
    const previous_text = previous orelse "";
    const line = try std.fmt.allocPrint(allocator, "{s}- {s} run say:{s}\n", .{ previous_text, normalized_schedule, text });
    defer allocator.free(line);
    try fs.writeFilePath(io, schedule_path, line);
    return normalized_schedule;
}

fn parseTask(allocator: std.mem.Allocator, text: []const u8, index: usize) !?Task {
    if (std.ascii.startsWithIgnoreCase(text, "at unix ")) {
        if (std.ascii.indexOfIgnoreCase(text, " run ")) |run_idx| {
            const timestamp_text = std.mem.trim(u8, text["at unix ".len..run_idx], " \t");
            const command = std.mem.trim(u8, text[run_idx + " run ".len ..], " \t`.");
            const run_at = try std.fmt.parseInt(i64, timestamp_text, 10);
            return try makeTask(allocator, index, command, .once_at, 0, 0, run_at);
        }
    }

    if (std.ascii.startsWithIgnoreCase(text, "every ")) {
        if (std.ascii.indexOfIgnoreCase(text, " run ")) |run_idx| {
            const schedule = std.mem.trim(u8, text["every ".len..run_idx], " \t");
            const command = std.mem.trim(u8, text[run_idx + " run ".len ..], " \t`.");
            if (std.ascii.endsWithIgnoreCase(schedule, " hours")) {
                const number_text = std.mem.trim(u8, schedule[0 .. schedule.len - " hours".len], " \t");
                const hours = try std.fmt.parseInt(u32, number_text, 10);
                return try makeTask(allocator, index, command, .every_hours, hours, 0, 0);
            }
            if (std.ascii.endsWithIgnoreCase(schedule, " hour")) {
                const number_text = std.mem.trim(u8, schedule[0 .. schedule.len - " hour".len], " \t");
                const hours = try std.fmt.parseInt(u32, number_text, 10);
                return try makeTask(allocator, index, command, .every_hours, hours, 0, 0);
            }
            if (std.ascii.startsWithIgnoreCase(schedule, "day at ")) {
                const minute = try parseMinuteOfDay(schedule["day at ".len..]);
                return try makeTask(allocator, index, command, .daily_at, 0, minute, 0);
            }
        }
    }

    if (std.ascii.startsWithIgnoreCase(text, "run ")) {
        if (std.ascii.indexOfIgnoreCase(text, " every ")) |every_idx| {
            const command = std.mem.trim(u8, text["run ".len..every_idx], " \t`.");
            const schedule = std.mem.trim(u8, text[every_idx + " every ".len ..], " \t.");
            if (std.ascii.endsWithIgnoreCase(schedule, " hours")) {
                const number_text = std.mem.trim(u8, schedule[0 .. schedule.len - " hours".len], " \t");
                const hours = try std.fmt.parseInt(u32, number_text, 10);
                return try makeTask(allocator, index, command, .every_hours, hours, 0, 0);
            }
        }
    }

    return null;
}

fn makeTask(allocator: std.mem.Allocator, index: usize, capability_spec: []const u8, kind: ScheduleKind, interval_hours: u32, minute_of_day: u32, run_at_seconds: i64) !Task {
    return .{
        .task_id = try std.fmt.allocPrint(allocator, "task_{d}_{s}", .{ index, capability_spec }),
        .capability_spec = try allocator.dupe(u8, capability_spec),
        .kind = kind,
        .interval_hours = interval_hours,
        .minute_of_day = minute_of_day,
        .run_at_seconds = run_at_seconds,
    };
}

fn isDue(task: Task, last_run: ?i64, now_seconds: i64) bool {
    switch (task.kind) {
        .every_hours => {
            const interval = @as(i64, task.interval_hours) * 3600;
            return last_run == null or now_seconds - last_run.? >= interval;
        },
        .daily_at => {
            const today_start = @divFloor(now_seconds, 86_400) * 86_400;
            const scheduled = today_start + @as(i64, task.minute_of_day) * 60;
            if (now_seconds < scheduled) return false;
            return last_run == null or last_run.? < scheduled;
        },
        .once_at => return last_run == null and now_seconds >= task.run_at_seconds,
    }
}

fn normalizeReminderSchedule(allocator: std.mem.Allocator, schedule: []const u8, now_seconds: i64) ![]const u8 {
    const trimmed = std.mem.trim(u8, schedule, " \r\n\t.");
    if (trimmed.len == 0) return error.EmptyReminderSchedule;
    if (try parseRelativeDelaySeconds(trimmed)) |delay_seconds| {
        if (delay_seconds <= 0) return error.InvalidReminderDelay;
        return std.fmt.allocPrint(allocator, "at unix {d}", .{now_seconds + delay_seconds});
    }
    return try allocator.dupe(u8, trimmed);
}

fn parseRelativeDelaySeconds(schedule: []const u8) !?i64 {
    const prefix_len: usize = if (std.ascii.startsWithIgnoreCase(schedule, "in "))
        "in ".len
    else if (std.ascii.startsWithIgnoreCase(schedule, "after "))
        "after ".len
    else
        return null;

    var parts = std.mem.tokenizeAny(u8, schedule[prefix_len..], " \t");
    const number_text = parts.next() orelse return error.InvalidReminderDelay;
    const amount = try std.fmt.parseInt(i64, number_text, 10);
    const unit = parts.next() orelse return error.InvalidReminderDelay;
    if (parts.next() != null) return error.InvalidReminderDelay;

    if (std.ascii.eqlIgnoreCase(unit, "second") or std.ascii.eqlIgnoreCase(unit, "seconds")) return amount;
    if (std.ascii.eqlIgnoreCase(unit, "minute") or std.ascii.eqlIgnoreCase(unit, "minutes")) return amount * 60;
    if (std.ascii.eqlIgnoreCase(unit, "hour") or std.ascii.eqlIgnoreCase(unit, "hours")) return amount * 3600;
    if (std.ascii.eqlIgnoreCase(unit, "day") or std.ascii.eqlIgnoreCase(unit, "days")) return amount * 86_400;
    return error.InvalidReminderDelayUnit;
}

fn parseMinuteOfDay(text: []const u8) !u32 {
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t."), ':');
    const hour_text = parts.next() orelse return error.InvalidTime;
    const minute_text = parts.next() orelse "0";
    const hour = try std.fmt.parseInt(u32, hour_text, 10);
    const minute = try std.fmt.parseInt(u32, minute_text, 10);
    if (hour > 23 or minute > 59) return error.InvalidTime;
    return hour * 60 + minute;
}

fn trimMarkdownBullet(line: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, line, " \r\n\t");
    if (trimmed.len >= 2 and (trimmed[0] == '-' or trimmed[0] == '*') and trimmed[1] == ' ') {
        trimmed = std.mem.trim(u8, trimmed[2..], " \t");
    }
    return trimmed;
}

fn loadState(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, path: []const u8) !StateFile {
    const bytes = fs.readFileAllocPath(io, path, allocator, .limited(128 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(StateFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var runs = try allocator.alloc(TaskRun, parsed.value.runs.len);
    for (parsed.value.runs, 0..) |run, i| runs[i] = .{ .task_id = try allocator.dupe(u8, run.task_id), .last_run = run.last_run };
    return .{
        .runs = runs,
        .autonomy = if (parsed.value.autonomy) |autonomy| try cloneAutonomyState(allocator, autonomy) else null,
    };
}

fn cloneAutonomyState(allocator: std.mem.Allocator, autonomy: AutonomyState) !AutonomyState {
    return .{
        .sleeping = autonomy.sleeping,
        .control_capacity = autonomy.control_capacity,
        .max_capacity = autonomy.max_capacity,
        .social_engagement = autonomy.social_engagement,
        .consecutive_voluntary_speech = autonomy.consecutive_voluntary_speech,
        .last_user_turn_at = autonomy.last_user_turn_at,
        .last_autonomy_tick_at = autonomy.last_autonomy_tick_at,
        .last_capacity_replenish_at = autonomy.last_capacity_replenish_at,
        .replenish_pending_capacity = autonomy.replenish_pending_capacity,
        .last_error = if (autonomy.last_error) |text| try allocator.dupe(u8, text) else null,
        .last_reason = if (autonomy.last_reason) |text| try allocator.dupe(u8, text) else null,
    };
}

pub fn recoverOnUserTurn(state: *AutonomyState, boost: f32, now_seconds: i64) void {
    const safe_boost = @max(0.0, boost);
    state.social_engagement = clamp01(state.social_engagement + safe_boost);
    state.control_capacity = clampCapacityUpper(state.control_capacity + safe_boost * 0.45, state.max_capacity);
    state.consecutive_voluntary_speech = 0;
    state.last_user_turn_at = now_seconds;
}

pub fn replenishRatePerSecond(actions_per_minute: f32, reference_action_capacity: f32) f32 {
    return @max(0.0, actions_per_minute) * @max(0.0, reference_action_capacity) / 60.0;
}

pub fn replenishCapacity(state: *AutonomyState, rate_per_second: f32, action_capacity: f32, now_seconds: i64) u32 {
    const safe_rate = @max(0.0, rate_per_second);
    const safe_action_capacity = @max(0.0, action_capacity);
    const last = state.last_capacity_replenish_at orelse {
        state.last_capacity_replenish_at = now_seconds;
        return 0;
    };
    const elapsed_seconds = now_seconds - last;
    if (elapsed_seconds <= 0) return 0;
    return applyReplenishElapsed(state, safe_rate, @as(f32, @floatFromInt(elapsed_seconds)), safe_action_capacity, now_seconds);
}

pub fn replenishWholeActionsFromPush(state: *AutonomyState, actions: u32, action_capacity: f32, now_seconds: i64) u32 {
    const safe_action_capacity = @max(0.0, action_capacity);
    const applied_actions = applyWholeActionsToCapacity(state, actions, safe_action_capacity);
    if (applied_actions > 0) state.last_capacity_replenish_at = now_seconds;
    return applied_actions;
}

fn applyReplenishElapsed(state: *AutonomyState, rate_per_second: f32, elapsed_seconds: f32, action_capacity: f32, now_seconds: i64) u32 {
    state.last_capacity_replenish_at = now_seconds;
    applySocialDecay(state, elapsed_seconds);
    const recovered = rate_per_second * elapsed_seconds + state.replenish_pending_capacity;
    const whole_actions = wholeActionsFromCapacity(recovered, action_capacity);
    if (whole_actions == 0) {
        state.replenish_pending_capacity = recovered;
        return 0;
    }
    const applied_actions = applyWholeActionsToCapacity(state, whole_actions, action_capacity);
    state.replenish_pending_capacity = @max(0.0, recovered - @as(f32, @floatFromInt(applied_actions)) * action_capacity);
    return applied_actions;
}

fn applyWholeActionsToCapacity(state: *AutonomyState, actions: u32, action_capacity: f32) u32 {
    if (actions == 0 or action_capacity <= 0.0) return 0;
    const headroom_actions = wholeActionsFromCapacity(state.max_capacity - state.control_capacity, action_capacity);
    const applied_actions = @min(actions, headroom_actions);
    if (applied_actions == 0) return 0;
    const applied_capacity = @as(f32, @floatFromInt(applied_actions)) * action_capacity;
    state.control_capacity = clampCapacityUpper(state.control_capacity + applied_capacity, state.max_capacity);
    return applied_actions;
}

fn clampCapacityUpper(value: f32, max_capacity: f32) f32 {
    if (value > max_capacity) return max_capacity;
    return value;
}

fn wholeActionsFromCapacity(capacity: f32, action_capacity: f32) u32 {
    if (capacity <= 0.0 or action_capacity <= 0.0) return 0;
    return @intFromFloat(@floor(capacity / action_capacity));
}

fn applySocialDecay(state: *AutonomyState, elapsed_seconds: f32) void {
    if (elapsed_seconds <= 0.0) return;
    const decay = std.math.pow(f32, 0.92, elapsed_seconds / 300.0);
    state.social_engagement = clamp01(state.social_engagement * decay);
}

pub fn autonomyBudgetAvailable(state: AutonomyState) bool {
    return state.control_capacity > 0.0;
}

pub fn autonomyPlannerReady(state: AutonomyState) bool {
    return !state.sleeping and autonomyBudgetAvailable(state);
}

pub fn spendCapacity(state: *AutonomyState, amount: f32) void {
    state.control_capacity -= @max(0.0, amount);
}

fn maxCapacityForMode(mode: []const u8, capacity_cfg: AutonomyCapacityConfig) f32 {
    if (std.mem.eql(u8, mode, "limited")) return clamp01(capacity_cfg.limited_max_capacity);
    if (std.mem.eql(u8, mode, "off")) return clamp01(capacity_cfg.full_max_capacity);
    return clamp01(capacity_cfg.full_max_capacity);
}

fn clamp01(value: f32) f32 {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

fn saveState(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, path: []const u8, state: StateFile) !void {
    try fs.ensureParentDir(io, path);
    const json = try std.json.Stringify.valueAlloc(allocator, state, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try fs.writeFilePath(io, path, json);
}

fn findLastRun(state: StateFile, task_id: []const u8) ?i64 {
    for (state.runs) |run| {
        if (std.mem.eql(u8, run.task_id, task_id)) return run.last_run;
    }
    return null;
}

const TestFileSystem = struct {
    const max_files = 8;

    allocator: std.mem.Allocator,
    files: [max_files]File = [_]File{.{}} ** max_files,

    const File = struct {
        path: []const u8 = "",
        data: []const u8 = "",
    };

    fn deinit(self: *TestFileSystem) void {
        for (&self.files) |*file| {
            if (file.path.len == 0) continue;
            self.allocator.free(file.path);
            self.allocator.free(file.data);
            file.* = .{};
        }
    }

    fn hasFile(self: *TestFileSystem, path: []const u8) bool {
        return self.find(path) != null;
    }

    fn find(self: *TestFileSystem, path: []const u8) ?*File {
        for (&self.files) |*file| {
            if (std.mem.eql(u8, file.path, path)) return file;
        }
        return null;
    }

    fn emptySlot(self: *TestFileSystem) !*File {
        for (&self.files) |*file| {
            if (file.path.len == 0) return file;
        }
        return error.TestFileSystemFull;
    }

    fn filesystem(self: *TestFileSystem) FileSystem {
        return .{
            .ctx = self,
            .ensureParentDirFn = ensureParentDir,
            .readFileAllocPathFn = readFileAllocPath,
            .writeFilePathFn = writeFilePath,
            .ensureDirFn = ensureDir,
            .sweepSpeechArtifactsFn = sweepSpeechArtifacts,
        };
    }

    fn ensureParentDir(_: *anyopaque, _: std.Io, _: []const u8) !void {}

    fn readFileAllocPath(ctx: *anyopaque, _: std.Io, path: []const u8, allocator: std.mem.Allocator, _: std.Io.Limit) ![]u8 {
        const self: *TestFileSystem = @ptrCast(@alignCast(ctx));
        const file = self.find(path) orelse return error.FileNotFound;
        return allocator.dupe(u8, file.data);
    }

    fn writeFilePath(ctx: *anyopaque, _: std.Io, path: []const u8, data: []const u8) !void {
        const self: *TestFileSystem = @ptrCast(@alignCast(ctx));
        const file = self.find(path) orelse try self.emptySlot();
        if (file.path.len == 0) file.path = try self.allocator.dupe(u8, path);
        self.allocator.free(file.data);
        file.data = try self.allocator.dupe(u8, data);
    }

    fn ensureDir(_: *anyopaque, _: std.Io, _: []const u8) !void {}

    fn sweepSpeechArtifacts(_: *anyopaque, _: std.Io, _: files.SpeechArtifactSweepRequest) !files.SpeechArtifactSweepResult {
        return .{};
    }
};

test "parses plain markdown maintenance tasks" {
    const allocator = std.testing.allocator;
    const task = (try parseTask(allocator, "every 6 hours run sweep_memory", 0)).?;
    defer allocator.free(task.task_id);
    defer allocator.free(task.capability_spec);
    try std.testing.expectEqual(ScheduleKind.every_hours, task.kind);
    try std.testing.expectEqual(@as(u32, 6), task.interval_hours);
    try std.testing.expectEqualStrings("sweep_memory", task.capability_spec);
}

test "daily task is due once after scheduled time" {
    const allocator = std.testing.allocator;
    const task = (try parseTask(allocator, "every day at 03:00 run sweep_memory", 1)).?;
    defer allocator.free(task.task_id);
    defer allocator.free(task.capability_spec);
    const now = 86_400 + 4 * 3600;
    try std.testing.expect(isDue(task, null, now));
    try std.testing.expect(isDue(task, 86_400 + 2 * 3600, now));
    try std.testing.expect(!isDue(task, 86_400 + 3 * 3600, now));
}

test "relative reminder writes one shot timer and runs once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = "data/test/relative_timer_maintenance.md";
    const state_path = "data/test/relative_timer_maintenance_state.json";
    var test_fs = TestFileSystem{ .allocator = allocator };
    defer test_fs.deinit();
    const fs = test_fs.filesystem();

    const schedule = try addReminder(allocator, fs, std.testing.io, path, "in 5 minutes", "Check the kettle.", 1_000);
    try std.testing.expectEqualStrings("at unix 1300", schedule);

    const early = try dueTasks(allocator, fs, std.testing.io, path, state_path, 1_299);
    try std.testing.expectEqual(@as(usize, 0), early.len);

    const due = try dueTasks(allocator, fs, std.testing.io, path, state_path, 1_300);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(ScheduleKind.once_at, due[0].kind);
    try std.testing.expectEqual(@as(i64, 1_300), due[0].run_at_seconds);
    try std.testing.expectEqualStrings("say:Check the kettle", due[0].capability_spec);

    try markRun(allocator, fs, std.testing.io, state_path, due[0].task_id, 1_300);
    const later = try dueTasks(allocator, fs, std.testing.io, path, state_path, 1_900);
    try std.testing.expectEqual(@as(usize, 0), later.len);
}

test "invalid reminder schedule fails before writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = "data/test/invalid_timer_maintenance.md";
    var test_fs = TestFileSystem{ .allocator = allocator };
    defer test_fs.deinit();
    try std.testing.expectError(error.InvalidReminderSchedule, addReminder(allocator, test_fs.filesystem(), std.testing.io, path, "whenever later", "Do something.", 1_000));
    try std.testing.expect(!test_fs.hasFile(path));
}

test "replenish rate converts actions per minute using reference action capacity" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.002), replenishRatePerSecond(1.0, 0.12), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.008), replenishRatePerSecond(4.0, 0.12), 0.000001);
}

test "internal replenish banks fractional capacity until a whole action is ready" {
    var state = AutonomyState{
        .control_capacity = 0.05,
        .max_capacity = 0.85,
        .last_capacity_replenish_at = 100,
    };
    const applied = applyReplenishElapsed(&state, 0.002, 10.0, 0.12, 110);
    try std.testing.expectEqual(@as(u32, 0), applied);
    try std.testing.expect(state.control_capacity < 0.12);
    try std.testing.expect(state.replenish_pending_capacity > 0.0);
}

test "push replenish applies only whole actions" {
    var state = AutonomyState{
        .control_capacity = 0.05,
        .max_capacity = 0.85,
    };
    const applied = replenishWholeActionsFromPush(&state, 1, 0.12, 200);
    try std.testing.expectEqual(@as(u32, 1), applied);
    try std.testing.expectApproxEqAbs(@as(f32, 0.17), state.control_capacity, 0.000001);
}

test "push replenish skips update when no whole action fits" {
    var state = AutonomyState{
        .control_capacity = 0.83,
        .max_capacity = 0.85,
    };
    const applied = replenishWholeActionsFromPush(&state, 1, 0.12, 200);
    try std.testing.expectEqual(@as(u32, 0), applied);
    try std.testing.expectApproxEqAbs(@as(f32, 0.83), state.control_capacity, 0.000001);
}

test "spend capacity can overdraw autonomy budget" {
    var state = AutonomyState{
        .control_capacity = 0.05,
        .max_capacity = 0.85,
    };
    spendCapacity(&state, 0.12);
    try std.testing.expectApproxEqAbs(@as(f32, -0.07), state.control_capacity, 0.000001);
    try std.testing.expect(!autonomyBudgetAvailable(state));
    try std.testing.expect(!autonomyPlannerReady(state));
}

test "replenish recovers from overdrawn autonomy budget" {
    var state = AutonomyState{
        .control_capacity = -0.05,
        .max_capacity = 0.85,
        .last_capacity_replenish_at = 100,
    };
    const applied = applyReplenishElapsed(&state, 0.002, 600.0, 0.12, 700);
    try std.testing.expect(applied > 0);
    try std.testing.expect(state.control_capacity > 0.0);
    try std.testing.expect(autonomyBudgetAvailable(state));
}

test "autonomy state clamps capacity to mode max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = "data/test/autonomy_state_test.json";
    var test_fs = TestFileSystem{ .allocator = allocator };
    defer test_fs.deinit();
    const fs = test_fs.filesystem();

    try saveAutonomyState(allocator, fs, std.testing.io, path, .{
        .sleeping = false,
        .control_capacity = 0.95,
        .max_capacity = 0.95,
        .social_engagement = 0.7,
        .last_reason = "seed",
    });

    const reset = try loadAutonomyState(allocator, fs, std.testing.io, path, false, "limited", .{
        .limited_max_capacity = 0.45,
        .full_max_capacity = 0.85,
    });
    try std.testing.expect(!reset.sleeping);
    try std.testing.expectEqual(@as(f32, 0.45), reset.max_capacity);
    try std.testing.expectEqual(@as(f32, 0.45), reset.control_capacity);
    try std.testing.expectEqual(@as(f32, 0.7), reset.social_engagement);
}
