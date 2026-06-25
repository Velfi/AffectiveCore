const std = @import("std");
const files = @import("../platform/common/files.zig");

pub const ScheduleKind = enum { every_hours, daily_at, once_at };

pub const Task = struct {
    task_id: []const u8,
    command: []const u8,
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
    energy_remaining: u32 = 0,
    energy_day_key: []const u8 = "",
    energy_exhausted: bool = false,
    last_autonomy_tick_at: ?i64 = null,
    last_autonomous_speech_at: ?i64 = null,
    last_error: ?[]const u8 = null,
    last_reason: ?[]const u8 = null,
};

pub fn loadTasks(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]Task {
    const bytes = files.readFileAllocPath(io, path, allocator, .limited(128 * 1024)) catch |err| switch (err) {
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

pub fn dueTasks(allocator: std.mem.Allocator, io: std.Io, schedule_path: []const u8, state_path: []const u8, now_seconds: i64) ![]Task {
    const tasks = try loadTasks(allocator, io, schedule_path);
    const state = try loadState(allocator, io, state_path);
    var due = std.ArrayList(Task).empty;
    for (tasks) |task| {
        const last_run = findLastRun(state, task.task_id);
        if (isDue(task, last_run, now_seconds)) try due.append(allocator, task);
    }
    return due.toOwnedSlice(allocator);
}

pub fn markRun(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, task_id: []const u8, now_seconds: i64) !void {
    var state = try loadState(allocator, io, state_path);
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
    try saveState(allocator, io, state_path, state);
}

pub fn loadAutonomyState(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, default_sleeping: bool, daily_energy: u32, day_key: []const u8) !AutonomyState {
    const state = try loadState(allocator, io, state_path);
    const existing = state.autonomy orelse return .{
        .sleeping = default_sleeping,
        .energy_remaining = daily_energy,
        .energy_day_key = try allocator.dupe(u8, day_key),
    };
    if (!std.mem.eql(u8, existing.energy_day_key, day_key)) {
        return .{
            .sleeping = default_sleeping,
            .energy_remaining = daily_energy,
            .energy_day_key = try allocator.dupe(u8, day_key),
        };
    }
    return existing;
}

pub fn saveAutonomyState(allocator: std.mem.Allocator, io: std.Io, state_path: []const u8, autonomy: AutonomyState) !void {
    var state = try loadState(allocator, io, state_path);
    state.autonomy = try cloneAutonomyState(allocator, autonomy);
    try saveState(allocator, io, state_path, state);
}

pub fn addReminder(allocator: std.mem.Allocator, io: std.Io, schedule_path: []const u8, schedule: []const u8, text: []const u8, now_seconds: i64) ![]const u8 {
    try files.ensureParentDir(io, schedule_path);
    const normalized_schedule = try normalizeReminderSchedule(allocator, schedule, now_seconds);
    errdefer allocator.free(normalized_schedule);
    const validation_text = try std.fmt.allocPrint(allocator, "{s} run say:{s}", .{ normalized_schedule, text });
    defer allocator.free(validation_text);
    const validation_task = (try parseTask(allocator, validation_text, 0)) orelse return error.InvalidReminderSchedule;
    defer allocator.free(validation_task.task_id);
    defer allocator.free(validation_task.command);

    const previous_result = files.readFileAllocPath(io, schedule_path, allocator, .limited(128 * 1024));
    const previous = previous_result catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (previous) |bytes| allocator.free(bytes);
    const previous_text = previous orelse "";
    const line = try std.fmt.allocPrint(allocator, "{s}- {s} run say:{s}\n", .{ previous_text, normalized_schedule, text });
    defer allocator.free(line);
    try files.writeFilePath(io, schedule_path, line);
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

fn makeTask(allocator: std.mem.Allocator, index: usize, command: []const u8, kind: ScheduleKind, interval_hours: u32, minute_of_day: u32, run_at_seconds: i64) !Task {
    return .{
        .task_id = try std.fmt.allocPrint(allocator, "task_{d}_{s}", .{ index, command }),
        .command = try allocator.dupe(u8, command),
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

fn loadState(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !StateFile {
    const bytes = files.readFileAllocPath(io, path, allocator, .limited(128 * 1024)) catch |err| switch (err) {
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
        .energy_remaining = autonomy.energy_remaining,
        .energy_day_key = try allocator.dupe(u8, autonomy.energy_day_key),
        .energy_exhausted = autonomy.energy_exhausted,
        .last_autonomy_tick_at = autonomy.last_autonomy_tick_at,
        .last_autonomous_speech_at = autonomy.last_autonomous_speech_at,
        .last_error = if (autonomy.last_error) |text| try allocator.dupe(u8, text) else null,
        .last_reason = if (autonomy.last_reason) |text| try allocator.dupe(u8, text) else null,
    };
}

fn saveState(allocator: std.mem.Allocator, io: std.Io, path: []const u8, state: StateFile) !void {
    try files.ensureParentDir(io, path);
    const json = try std.json.Stringify.valueAlloc(allocator, state, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try files.writeFilePath(io, path, json);
}

fn findLastRun(state: StateFile, task_id: []const u8) ?i64 {
    for (state.runs) |run| {
        if (std.mem.eql(u8, run.task_id, task_id)) return run.last_run;
    }
    return null;
}

test "parses plain markdown maintenance tasks" {
    const allocator = std.testing.allocator;
    const task = (try parseTask(allocator, "every 6 hours run sweep_memory", 0)).?;
    defer allocator.free(task.task_id);
    defer allocator.free(task.command);
    try std.testing.expectEqual(ScheduleKind.every_hours, task.kind);
    try std.testing.expectEqual(@as(u32, 6), task.interval_hours);
    try std.testing.expectEqualStrings("sweep_memory", task.command);
}

test "daily task is due once after scheduled time" {
    const allocator = std.testing.allocator;
    const task = (try parseTask(allocator, "every day at 03:00 run sweep_memory", 1)).?;
    defer allocator.free(task.task_id);
    defer allocator.free(task.command);
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
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, state_path) catch {};

    const schedule = try addReminder(allocator, std.testing.io, path, "in 5 minutes", "Check the kettle.", 1_000);
    try std.testing.expectEqualStrings("at unix 1300", schedule);

    const early = try dueTasks(allocator, std.testing.io, path, state_path, 1_299);
    try std.testing.expectEqual(@as(usize, 0), early.len);

    const due = try dueTasks(allocator, std.testing.io, path, state_path, 1_300);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqual(ScheduleKind.once_at, due[0].kind);
    try std.testing.expectEqual(@as(i64, 1_300), due[0].run_at_seconds);
    try std.testing.expectEqualStrings("say:Check the kettle", due[0].command);

    try markRun(allocator, std.testing.io, state_path, due[0].task_id, 1_300);
    const later = try dueTasks(allocator, std.testing.io, path, state_path, 1_900);
    try std.testing.expectEqual(@as(usize, 0), later.len);
}

test "invalid reminder schedule fails before writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = "data/test/invalid_timer_maintenance.md";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.testing.expectError(error.InvalidReminderSchedule, addReminder(allocator, std.testing.io, path, "whenever later", "Do something.", 1_000));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
}

test "autonomy state resets energy on a new local day key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = "data/test/autonomy_state_test.json";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, "data/test");
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    try saveAutonomyState(allocator, std.testing.io, path, .{
        .sleeping = true,
        .energy_remaining = 0,
        .energy_day_key = "2026-06-22",
        .energy_exhausted = true,
        .last_reason = "energy exhausted",
    });

    const reset = try loadAutonomyState(allocator, std.testing.io, path, false, 20, "2026-06-23");
    try std.testing.expect(!reset.sleeping);
    try std.testing.expect(!reset.energy_exhausted);
    try std.testing.expectEqual(@as(u32, 20), reset.energy_remaining);
    try std.testing.expectEqualStrings("2026-06-23", reset.energy_day_key);
}
