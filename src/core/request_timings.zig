const std = @import("std");

pub const Outcome = enum {
    success,
    provider_error,
    validation_error,

    pub fn tag(self: Outcome) []const u8 {
        return @tagName(self);
    }
};

pub const Span = struct {
    span_id: []const u8,
    kind: []const u8,
    label: []const u8,
    duration_ms: i64,
    dispatch_id: ?[]const u8 = null,
    activity_id: ?[]const u8 = null,
    process_id: ?[]const u8 = null,
    step_id: ?[]const u8 = null,
    step_index: ?usize = null,
    action_id: ?[]const u8 = null,
    action: ?[]const u8 = null,
    llm_call_id: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    capability_id: ?[]const u8 = null,
    subsystem: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    outcome: ?Outcome = null,
    request_bytes: ?usize = null,
    response_bytes: ?usize = null,
    estimated_prompt_tokens: ?usize = null,
    effort_tier: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    llm_call_count: ?usize = null,
    total_request_bytes: ?usize = null,
    total_prompt_tokens: ?usize = null,
    context_user_prompt_tokens: ?usize = null,

    pub fn jsonStringify(self: Span, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("span_id");
        try jw.write(self.span_id);
        try jw.objectField("kind");
        try jw.write(self.kind);
        try jw.objectField("label");
        try jw.write(self.label);
        try jw.objectField("duration_ms");
        try jw.write(self.duration_ms);
        try writeOptionalString(jw, "dispatch_id", self.dispatch_id);
        try writeOptionalString(jw, "activity_id", self.activity_id);
        try writeOptionalString(jw, "process_id", self.process_id);
        try writeOptionalString(jw, "step_id", self.step_id);
        if (self.step_index) |index| {
            try jw.objectField("step_index");
            try jw.write(index);
        }
        try writeOptionalString(jw, "action_id", self.action_id);
        try writeOptionalString(jw, "action", self.action);
        try writeOptionalString(jw, "llm_call_id", self.llm_call_id);
        try writeOptionalString(jw, "operation_id", self.operation_id);
        try writeOptionalString(jw, "capability_id", self.capability_id);
        try writeOptionalString(jw, "subsystem", self.subsystem);
        try writeOptionalString(jw, "provider", self.provider);
        try writeOptionalString(jw, "model", self.model);
        if (self.outcome) |outcome| {
            try jw.objectField("outcome");
            try jw.write(outcome.tag());
        }
        if (self.request_bytes) |value| {
            try jw.objectField("request_bytes");
            try jw.write(value);
        }
        if (self.response_bytes) |value| {
            try jw.objectField("response_bytes");
            try jw.write(value);
        }
        if (self.estimated_prompt_tokens) |value| {
            try jw.objectField("estimated_prompt_tokens");
            try jw.write(value);
        }
        try writeOptionalString(jw, "effort_tier", self.effort_tier);
        try writeOptionalString(jw, "reasoning_effort", self.reasoning_effort);
        if (self.llm_call_count) |value| {
            try jw.objectField("llm_call_count");
            try jw.write(value);
        }
        if (self.total_request_bytes) |value| {
            try jw.objectField("total_request_bytes");
            try jw.write(value);
        }
        if (self.total_prompt_tokens) |value| {
            try jw.objectField("total_prompt_tokens");
            try jw.write(value);
        }
        if (self.context_user_prompt_tokens) |value| {
            try jw.objectField("context_user_prompt_tokens");
            try jw.write(value);
        }
        try jw.endObject();
    }

    fn writeOptionalString(jw: anytype, field: []const u8, value: ?[]const u8) !void {
        if (value) |actual| {
            if (actual.len == 0) return;
            try jw.objectField(field);
            try jw.write(actual);
        }
    }
};

pub const Report = struct {
    dispatch_id: []const u8,
    total_ms: i64,
    spans: []const Span,

    pub fn jsonStringify(self: Report, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("dispatch_id");
        try jw.write(self.dispatch_id);
        try jw.objectField("total_ms");
        try jw.write(self.total_ms);
        try jw.objectField("spans");
        try jw.write(self.spans);
        try jw.endObject();
    }
};

pub const empty_report: Report = .{
    .dispatch_id = "",
    .total_ms = 0,
    .spans = &.{},
};

pub fn emptyReport(allocator: std.mem.Allocator, dispatch_id: []const u8) !Report {
    return .{
        .dispatch_id = try allocator.dupe(u8, dispatch_id),
        .total_ms = 0,
        .spans = &.{},
    };
}

pub const Collector = struct {
    active: bool = false,
    started_ms: i64 = 0,
    dispatch_id: []const u8 = "",
    span_serial: u64 = 0,
    llm_call_serial: u64 = 0,
    spans: std.ArrayList(Span) = .empty,

    pub fn begin(self: *Collector, allocator: std.mem.Allocator, io: std.Io, dispatch_id: []const u8) !void {
        self.reset(allocator);
        self.active = true;
        self.started_ms = nowMs(io);
        self.dispatch_id = try allocator.dupe(u8, dispatch_id);
    }

    pub fn reset(self: *Collector, allocator: std.mem.Allocator) void {
        for (self.spans.items) |span| freeSpanStrings(allocator, span);
        self.spans.deinit(allocator);
        if (self.dispatch_id.len > 0) allocator.free(self.dispatch_id);
        self.* = .{};
    }

    pub fn allocSpanId(self: *Collector, allocator: std.mem.Allocator) ![]const u8 {
        const id = self.span_serial;
        self.span_serial += 1;
        return std.fmt.allocPrint(allocator, "span_{d}", .{id});
    }

    pub fn allocLlmCallId(self: *Collector, allocator: std.mem.Allocator) ![]const u8 {
        const id = self.llm_call_serial;
        self.llm_call_serial += 1;
        return std.fmt.allocPrint(allocator, "llmcall_{d}", .{id});
    }

    pub fn record(self: *Collector, allocator: std.mem.Allocator, span: Span) !void {
        if (!self.active) return;
        try self.spans.append(allocator, span);
    }

    pub fn finish(self: *Collector, allocator: std.mem.Allocator, io: std.Io) !Report {
        const total_ms = if (self.active) nowMs(io) - self.started_ms else 0;
        const dispatch_id = try allocator.dupe(u8, self.dispatch_id);
        const spans = try self.spans.toOwnedSlice(allocator);
        self.spans = .empty;
        self.dispatch_id = "";
        self.active = false;
        return .{
            .dispatch_id = dispatch_id,
            .total_ms = total_ms,
            .spans = spans,
        };
    }
};

pub fn deinitReport(allocator: std.mem.Allocator, report: *Report) void {
    if (report.dispatch_id.len > 0) allocator.free(report.dispatch_id);
    for (report.spans) |span| freeSpanStrings(allocator, span);
    allocator.free(report.spans);
    report.* = .{
        .dispatch_id = "",
        .total_ms = 0,
        .spans = &.{},
    };
}

fn freeSpanStrings(allocator: std.mem.Allocator, span: Span) void {
    allocator.free(span.span_id);
    allocator.free(span.kind);
    allocator.free(span.label);
    if (span.dispatch_id) |v| allocator.free(v);
    if (span.activity_id) |v| allocator.free(v);
    if (span.process_id) |v| allocator.free(v);
    if (span.step_id) |v| allocator.free(v);
    if (span.action_id) |v| allocator.free(v);
    if (span.action) |v| allocator.free(v);
    if (span.llm_call_id) |v| allocator.free(v);
    if (span.operation_id) |v| allocator.free(v);
    if (span.capability_id) |v| allocator.free(v);
    if (span.subsystem) |v| allocator.free(v);
    if (span.provider) |v| allocator.free(v);
    if (span.model) |v| allocator.free(v);
    if (span.effort_tier) |v| allocator.free(v);
    if (span.reasoning_effort) |v| allocator.free(v);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

test "collector assigns unique span ids and preserves order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var collector: Collector = .{};
    try collector.begin(allocator, std.testing.io, "req-1");

    const span_a_id = try collector.allocSpanId(allocator);
    try collector.record(allocator, .{
        .span_id = span_a_id,
        .kind = try allocator.dupe(u8, "llm"),
        .label = try allocator.dupe(u8, "conversation"),
        .duration_ms = 10,
    });
    const span_b_id = try collector.allocSpanId(allocator);
    try collector.record(allocator, .{
        .span_id = span_b_id,
        .kind = try allocator.dupe(u8, "action"),
        .label = try allocator.dupe(u8, "say"),
        .duration_ms = 5,
    });

    var report = try collector.finish(allocator, std.testing.io);
    defer deinitReport(allocator, &report);

    try std.testing.expectEqualStrings("req-1", report.dispatch_id);
    try std.testing.expect(report.total_ms >= 0);
    try std.testing.expectEqual(@as(usize, 2), report.spans.len);
    try std.testing.expectEqualStrings("span_0", report.spans[0].span_id);
    try std.testing.expectEqualStrings("span_1", report.spans[1].span_id);
}

test "allocLlmCallId increments separately from span ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var collector: Collector = .{};
    try collector.begin(allocator, std.testing.io, "req-2");

    const llm_a = try collector.allocLlmCallId(allocator);
    defer allocator.free(llm_a);
    const llm_b = try collector.allocLlmCallId(allocator);
    defer allocator.free(llm_b);
    try std.testing.expectEqualStrings("llmcall_0", llm_a);
    try std.testing.expectEqualStrings("llmcall_1", llm_b);

    var report = try collector.finish(allocator, std.testing.io);
    defer deinitReport(allocator, &report);
}
