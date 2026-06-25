const std = @import("std");
const schema = @import("../storage/schema.zig");
const process = @import("../platform/common/process.zig");

pub const PollContext = struct {
    now_seconds: i64,
};

pub const Source = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool = true,
    interval_seconds: u64 = 5,
    ctx: *anyopaque,
    pollFn: *const fn (*anyopaque, std.mem.Allocator, PollContext) anyerror![]schema.RuntimeEvent,

    pub fn poll(self: Source, allocator: std.mem.Allocator, context: PollContext) ![]schema.RuntimeEvent {
        if (!self.enabled) return &.{};
        return self.pollFn(self.ctx, allocator, context);
    }
};

pub const ExternalConfig = struct {
    command: []const u8 = "",
    interval_seconds: u64 = 60,
    restart_cooldown_seconds: i64 = 60,
};

pub const Manager = struct {
    last_poll_at: ?i64 = null,
    last_external_poll_at: ?i64 = null,
    last_external_crash_at: ?i64 = null,
    last_dedupe_key: ?[]const u8 = null,
    last_dedupe_at: ?i64 = null,

    pub fn inProcessDue(self: *Manager, now_seconds: i64, interval_seconds: u64) bool {
        const last = self.last_poll_at orelse return true;
        return now_seconds - last >= @as(i64, @intCast(interval_seconds));
    }

    pub fn markInProcessPoll(self: *Manager, now_seconds: i64) void {
        self.last_poll_at = now_seconds;
    }

    pub fn externalDue(self: *Manager, now_seconds: i64, cfg: ExternalConfig) bool {
        if (cfg.command.len == 0) return false;
        if (self.last_external_crash_at) |crash_at| {
            if (now_seconds - crash_at < cfg.restart_cooldown_seconds) return false;
        }
        const last = self.last_external_poll_at orelse return true;
        return now_seconds - last >= @as(i64, @intCast(cfg.interval_seconds));
    }

    pub fn markExternalPoll(self: *Manager, now_seconds: i64) void {
        self.last_external_poll_at = now_seconds;
    }

    pub fn markExternalCrash(self: *Manager, now_seconds: i64) void {
        self.last_external_crash_at = now_seconds;
    }

    pub fn shouldEmit(self: *Manager, allocator: std.mem.Allocator, now_seconds: i64, event: schema.RuntimeEvent, cooldown_seconds: i64) !bool {
        const key = event.dedupe_key orelse return true;
        if (self.last_dedupe_key) |last_key| {
            if (std.mem.eql(u8, last_key, key) and self.last_dedupe_at != null and now_seconds - self.last_dedupe_at.? < cooldown_seconds) {
                return false;
            }
        }
        self.last_dedupe_key = try allocator.dupe(u8, key);
        self.last_dedupe_at = now_seconds;
        return true;
    }
};

pub fn runExternalMonitor(allocator: std.mem.Allocator, io: std.Io, monitor_id: []const u8, command: []const u8) ![]schema.RuntimeEvent {
    const argv = try parseCommandArgv(allocator, command);
    if (argv.len == 0) return error.EmptyExternalMonitorCommand;
    const stdout = try process.runCapture(allocator, io, argv);
    defer allocator.free(stdout);
    return parseExternalEvents(allocator, monitor_id, stdout);
}

fn parseCommandArgv(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (it.next()) |part| try argv.append(allocator, try allocator.dupe(u8, part));
    return argv.toOwnedSlice(allocator);
}

pub fn parseExternalEvents(allocator: std.mem.Allocator, monitor_id: []const u8, stdout: []const u8) ![]schema.RuntimeEvent {
    var out = std.ArrayList(schema.RuntimeEvent).empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(schema.RuntimeEvent, allocator, line, .{ .ignore_unknown_fields = false }) catch continue;
        defer parsed.deinit();
        const event = parsed.value;
        if (!validExternalEvent(event)) continue;
        try out.append(allocator, .{
            .kind = event.kind,
            .source = if (event.source.len > 0) event.source else "id_monitor",
            .title = try allocator.dupe(u8, event.title),
            .body = try allocator.dupe(u8, event.body),
            .command = if (event.command) |value| try allocator.dupe(u8, value) else null,
            .subject = try allocator.dupe(u8, event.subject),
            .raw = try allocator.dupe(u8, event.raw),
            .interpretation = try allocator.dupe(u8, event.interpretation),
            .developer_log_kind = if (event.developer_log_kind) |value| try allocator.dupe(u8, value) else null,
            .developer_log_title = if (event.developer_log_title) |value| try allocator.dupe(u8, value) else null,
            .developer_log_body = if (event.developer_log_body) |value| try allocator.dupe(u8, value) else null,
            .experience_source = event.experience_source,
            .experience_kind = event.experience_kind,
            .experience_retention = event.experience_retention,
            .derived_memory_ids = try cloneStringSlice(allocator, event.derived_memory_ids),
            .created_memory_id = if (event.created_memory_id) |value| try allocator.dupe(u8, value) else null,
            .forgotten_memory_id = if (event.forgotten_memory_id) |value| try allocator.dupe(u8, value) else null,
            .created_fact_id = if (event.created_fact_id) |value| try allocator.dupe(u8, value) else null,
            .invalidated_fact_id = if (event.invalidated_fact_id) |value| try allocator.dupe(u8, value) else null,
            .severity = event.severity,
            .psyche_role = event.psyche_role,
            .monitor_id = if (event.monitor_id) |value| try allocator.dupe(u8, value) else try allocator.dupe(u8, monitor_id),
            .pattern_id = if (event.pattern_id) |value| try allocator.dupe(u8, value) else null,
            .confidence = event.confidence,
            .dedupe_key = if (event.dedupe_key) |value| try allocator.dupe(u8, value) else null,
            .attention_candidate = event.attention_candidate,
            .tags = try cloneStringSlice(allocator, event.tags),
        });
    }
    return out.toOwnedSlice(allocator);
}

fn validExternalEvent(event: schema.RuntimeEvent) bool {
    if (event.title.len == 0 or event.body.len == 0) return false;
    if (event.monitor_id == null and event.source.len == 0) return false;
    return true;
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, i| out[i] = try allocator.dupe(u8, value);
    return out;
}

pub fn severityRank(severity: schema.RuntimeEventSeverity) u8 {
    return switch (severity) {
        .debug => 0,
        .info => 1,
        .notice => 2,
        .concern => 3,
        .warning => 4,
        .critical => 5,
    };
}

test "external id monitor parser accepts valid jsonl and rejects malformed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stdout =
        \\{"kind":"system","source":"id_monitor","title":"storage pressure","body":"storage is high","severity":"warning","tags":["id","storage"]}
        \\
        \\not json
        \\
        \\{"kind":"system","source":"id_monitor","title":"","body":"missing title","severity":"warning"}
        \\
    ;

    const events = try parseExternalEvents(allocator, "external_test", stdout);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(schema.RuntimeEventKind.system, events[0].kind);
    try std.testing.expectEqual(schema.RuntimeEventSeverity.warning, events[0].severity.?);
    try std.testing.expectEqualStrings("external_test", events[0].monitor_id.?);
}
