const std = @import("std");
const context_composition = @import("context_composition.zig");
const ports = @import("ports.zig");
const FileSystem = ports.files.FileSystem;

/// LLM completion counters track each provider HTTP attempt, not each logical
/// completion. Route fallbacks, validation failures that retry, and provider
/// errors all emit separate records before a success is returned.
pub const flush_every_n: u32 = 16;
pub const max_top_sections: usize = 20;

pub const OperationTotals = struct {
    call_count: u64 = 0,
    total_bytes: u64 = 0,
    max_bytes: u64 = 0,
    total_tokens: u64 = 0,
    max_tokens: u64 = 0,
};

pub const SectionTotals = struct {
    total_bytes: u64 = 0,
    appearance_count: u64 = 0,
};

pub const LlmCompletionOutcome = enum {
    success,
    provider_error,
    validation_error,
};

pub const LlmCompletionTotals = struct {
    call_count: u64 = 0,
    success_count: u64 = 0,
    error_count: u64 = 0,
    request_bytes: u64 = 0,
    response_bytes: u64 = 0,
    max_response_bytes: u64 = 0,
    total_latency_ms: u64 = 0,
};

pub const LlmCompletionRecord = struct {
    subsystem: []const u8,
    provider: []const u8,
    model: []const u8,
    effort_tier: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    request_bytes: usize,
    response_bytes: usize,
    outcome: LlmCompletionOutcome,
    latency_ms: u64 = 0,
    llm_call_id: ?[]const u8 = null,
};

const LastLlmCall = struct {
    subsystem: []const u8,
    provider: []const u8,
    model: []const u8,
    effort_tier: ?[]const u8,
    response_bytes: usize,
    at_seconds: i64,
};

pub const State = struct {
    operations: std.StringHashMap(OperationTotals),
    sections: std.StringHashMap(SectionTotals),
    llm_subsystems: std.StringHashMap(LlmCompletionTotals),
    total_composition_count: u64 = 0,
    total_process_goal_count: u64 = 0,
    total_composed_steps: u64 = 0,
    budget_exceeded_count: u64 = 0,
    total_llm_calls: u64 = 0,
    total_llm_errors: u64 = 0,
    updated_at_seconds: i64 = 0,
    dirty_since_flush: u32 = 0,
    last_conversation_bytes: ?usize = null,
    last_conversation_tokens: ?usize = null,
    last_conversation_at_seconds: ?i64 = null,
    last_llm_call: ?LastLlmCall = null,
    last_dispatch: ?LastDispatchSnapshot = null,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{
            .operations = std.StringHashMap(OperationTotals).init(allocator),
            .sections = std.StringHashMap(SectionTotals).init(allocator),
            .llm_subsystems = std.StringHashMap(LlmCompletionTotals).init(allocator),
        };
    }

    pub fn deinit(self: *State) void {
        const allocator = self.operations.allocator;
        self.operations.deinit();
        self.sections.deinit();
        var llm_iter = self.llm_subsystems.iterator();
        while (llm_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.llm_subsystems.deinit();
        if (self.last_llm_call) |last| {
            allocator.free(last.subsystem);
            allocator.free(last.provider);
            allocator.free(last.model);
            if (last.effort_tier) |tier| allocator.free(tier);
        }
        if (self.last_dispatch) |last| {
            allocator.free(last.dispatch_id);
            allocator.free(last.operation);
            for (last.sections) |section| allocator.free(section.section);
            allocator.free(last.sections);
        }
    }
};

const OperationEntryFile = struct {
    operation: []const u8,
    totals: OperationTotals,
};

const SectionEntryFile = struct {
    section: []const u8,
    totals: SectionTotals,
};

const LastConversationFile = struct {
    bytes: usize,
    tokens: usize,
    at_seconds: i64,
};

const LlmSubsystemEntryFile = struct {
    subsystem: []const u8,
    totals: LlmCompletionTotals,
};

const LastLlmCallFile = struct {
    subsystem: []const u8,
    provider: []const u8 = "",
    model: []const u8,
    effort_tier: ?[]const u8 = null,
    response_bytes: usize,
    at_seconds: i64,
};

const LastDispatchSectionFile = struct {
    section: []const u8,
    bytes: usize,
    count: ?usize = null,
};

const LastDispatchFile = struct {
    dispatch_id: []const u8,
    at_seconds: i64,
    operation: []const u8,
    user_prompt_tokens: usize,
    budget_exceeded: bool,
    sections: []LastDispatchSectionFile = &.{},
};

pub const LastDispatchSection = struct {
    section: []const u8,
    bytes: usize,
    count: ?usize = null,
};

pub const LastDispatchSnapshot = struct {
    dispatch_id: []const u8,
    at_seconds: i64,
    operation: []const u8,
    user_prompt_tokens: usize,
    budget_exceeded: bool,
    sections: []LastDispatchSection,
};

const StateFile = struct {
    updated_at_seconds: i64 = 0,
    total_composition_count: u64 = 0,
    total_process_goal_count: u64 = 0,
    total_composed_steps: u64 = 0,
    budget_exceeded_count: u64 = 0,
    total_llm_calls: u64 = 0,
    total_llm_errors: u64 = 0,
    last_conversation: ?LastConversationFile = null,
    last_llm_call: ?LastLlmCallFile = null,
    last_dispatch: ?LastDispatchFile = null,
    operations: []OperationEntryFile = &.{},
    sections: []SectionEntryFile = &.{},
    llm_subsystems: []LlmSubsystemEntryFile = &.{},
};

pub fn load(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, path: []const u8) !State {
    var state = State.init(allocator);
    errdefer state.deinit();

    const bytes = fs.readFileAllocPath(io, path, allocator, .limited(512 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return state,
        else => return err,
    };
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(StateFile, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    state.updated_at_seconds = parsed.value.updated_at_seconds;
    state.total_composition_count = parsed.value.total_composition_count;
    state.total_process_goal_count = parsed.value.total_process_goal_count;
    state.total_composed_steps = parsed.value.total_composed_steps;
    state.budget_exceeded_count = parsed.value.budget_exceeded_count;
    if (parsed.value.last_conversation) |last| {
        state.last_conversation_bytes = last.bytes;
        state.last_conversation_tokens = last.tokens;
        state.last_conversation_at_seconds = last.at_seconds;
    }

    for (parsed.value.operations) |entry| {
        try state.operations.put(try allocator.dupe(u8, entry.operation), .{
            .call_count = entry.totals.call_count,
            .total_bytes = entry.totals.total_bytes,
            .max_bytes = entry.totals.max_bytes,
            .total_tokens = entry.totals.total_tokens,
            .max_tokens = entry.totals.max_tokens,
        });
    }
    for (parsed.value.sections) |entry| {
        try state.sections.put(try allocator.dupe(u8, entry.section), .{
            .total_bytes = entry.totals.total_bytes,
            .appearance_count = entry.totals.appearance_count,
        });
    }

    state.total_llm_calls = parsed.value.total_llm_calls;
    state.total_llm_errors = parsed.value.total_llm_errors;
    if (parsed.value.last_llm_call) |last| {
        state.last_llm_call = .{
            .subsystem = try allocator.dupe(u8, last.subsystem),
            .provider = try allocator.dupe(u8, last.provider),
            .model = try allocator.dupe(u8, last.model),
            .effort_tier = if (last.effort_tier) |tier| try allocator.dupe(u8, tier) else null,
            .response_bytes = last.response_bytes,
            .at_seconds = last.at_seconds,
        };
    }
    for (parsed.value.llm_subsystems) |entry| {
        try state.llm_subsystems.put(try allocator.dupe(u8, entry.subsystem), entry.totals);
    }

    if (parsed.value.last_dispatch) |last| {
        var sections = try allocator.alloc(LastDispatchSection, last.sections.len);
        for (last.sections, 0..) |section, index| {
            sections[index] = .{
                .section = try allocator.dupe(u8, section.section),
                .bytes = section.bytes,
                .count = section.count,
            };
        }
        state.last_dispatch = .{
            .dispatch_id = try allocator.dupe(u8, last.dispatch_id),
            .at_seconds = last.at_seconds,
            .operation = try allocator.dupe(u8, last.operation),
            .user_prompt_tokens = last.user_prompt_tokens,
            .budget_exceeded = last.budget_exceeded,
            .sections = sections,
        };
    }

    return state;
}

pub fn save(allocator: std.mem.Allocator, fs: FileSystem, io: std.Io, path: []const u8, state: *const State) !void {
    var operation_names = std.ArrayList([]const u8).empty;
    defer operation_names.deinit(allocator);

    var op_iter = state.operations.iterator();
    while (op_iter.next()) |entry| {
        try operation_names.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, operation_names.items, {}, stringLessThan);

    var sorted_operations = std.ArrayList(OperationEntryFile).empty;
    defer sorted_operations.deinit(allocator);
    for (operation_names.items) |name| {
        const totals = state.operations.get(name) orelse continue;
        try sorted_operations.append(allocator, .{ .operation = name, .totals = totals });
    }

    var section_names = std.ArrayList([]const u8).empty;
    defer section_names.deinit(allocator);

    var section_iter = state.sections.iterator();
    while (section_iter.next()) |entry| {
        try section_names.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, section_names.items, {}, stringLessThan);

    var sorted_sections = std.ArrayList(SectionEntryFile).empty;
    defer sorted_sections.deinit(allocator);
    for (section_names.items) |name| {
        const totals = state.sections.get(name) orelse continue;
        try sorted_sections.append(allocator, .{ .section = name, .totals = totals });
    }

    var llm_subsystem_names = std.ArrayList([]const u8).empty;
    defer llm_subsystem_names.deinit(allocator);

    var llm_iter = state.llm_subsystems.iterator();
    while (llm_iter.next()) |entry| {
        try llm_subsystem_names.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, llm_subsystem_names.items, {}, stringLessThan);

    var sorted_llm_subsystems = std.ArrayList(LlmSubsystemEntryFile).empty;
    defer sorted_llm_subsystems.deinit(allocator);
    for (llm_subsystem_names.items) |name| {
        const totals = state.llm_subsystems.get(name) orelse continue;
        try sorted_llm_subsystems.append(allocator, .{ .subsystem = name, .totals = totals });
    }

    var last_dispatch_section_files: ?[]LastDispatchSectionFile = null;
    defer if (last_dispatch_section_files) |sections| allocator.free(sections);
    const last_dispatch_file: ?LastDispatchFile = if (state.last_dispatch) |last| blk: {
        var section_files = try allocator.alloc(LastDispatchSectionFile, last.sections.len);
        last_dispatch_section_files = section_files;
        for (last.sections, 0..) |section, index| {
            section_files[index] = .{
                .section = section.section,
                .bytes = section.bytes,
                .count = section.count,
            };
        }
        break :blk .{
            .dispatch_id = last.dispatch_id,
            .at_seconds = last.at_seconds,
            .operation = last.operation,
            .user_prompt_tokens = last.user_prompt_tokens,
            .budget_exceeded = last.budget_exceeded,
            .sections = section_files,
        };
    } else null;

    const file: StateFile = .{
        .updated_at_seconds = state.updated_at_seconds,
        .total_composition_count = state.total_composition_count,
        .total_process_goal_count = state.total_process_goal_count,
        .total_composed_steps = state.total_composed_steps,
        .budget_exceeded_count = state.budget_exceeded_count,
        .total_llm_calls = state.total_llm_calls,
        .total_llm_errors = state.total_llm_errors,
        .last_conversation = if (state.last_conversation_at_seconds) |at_seconds| .{
            .bytes = state.last_conversation_bytes orelse 0,
            .tokens = state.last_conversation_tokens orelse 0,
            .at_seconds = at_seconds,
        } else null,
        .last_llm_call = if (state.last_llm_call) |last| .{
            .subsystem = last.subsystem,
            .provider = last.provider,
            .model = last.model,
            .effort_tier = last.effort_tier,
            .response_bytes = last.response_bytes,
            .at_seconds = last.at_seconds,
        } else null,
        .last_dispatch = last_dispatch_file,
        .operations = try sorted_operations.toOwnedSlice(allocator),
        .sections = try sorted_sections.toOwnedSlice(allocator),
        .llm_subsystems = try sorted_llm_subsystems.toOwnedSlice(allocator),
    };
    defer allocator.free(file.operations);
    defer allocator.free(file.sections);
    defer allocator.free(file.llm_subsystems);

    try fs.ensureParentDir(io, path);
    const json = try std.json.Stringify.valueAlloc(allocator, file, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    try fs.writeFilePath(io, path, json);
}

pub fn recordComposition(state: *State, report: context_composition.ContextCompositionReport, now_seconds: i64) !void {
    state.total_composition_count += 1;
    state.updated_at_seconds = now_seconds;
    state.dirty_since_flush += 1;

    const op_gop = try state.operations.getOrPut(report.operation);
    if (!op_gop.found_existing) {
        op_gop.key_ptr.* = try state.operations.allocator.dupe(u8, report.operation);
        op_gop.value_ptr.* = .{};
    }
    const op = op_gop.value_ptr;
    op.call_count += 1;
    op.total_bytes += @intCast(report.total_bytes);
    if (report.total_bytes > op.max_bytes) op.max_bytes = @intCast(report.total_bytes);
    if (report.user_prompt_tokens > 0) {
        const tokens: u64 = @intCast(report.user_prompt_tokens);
        op.total_tokens += tokens;
        if (tokens > op.max_tokens) op.max_tokens = tokens;
    }

    for (report.sections) |section| {
        const section_gop = try state.sections.getOrPut(section.name);
        if (!section_gop.found_existing) {
            section_gop.key_ptr.* = try state.sections.allocator.dupe(u8, section.name);
            section_gop.value_ptr.* = .{};
        }
        const totals = section_gop.value_ptr;
        totals.total_bytes += @intCast(section.bytes);
        totals.appearance_count += 1;
    }

    if (std.mem.eql(u8, report.operation, "conversation_chat")) {
        state.last_conversation_bytes = report.total_bytes;
        state.last_conversation_tokens = if (report.user_prompt_tokens > 0) report.user_prompt_tokens else null;
        state.last_conversation_at_seconds = now_seconds;
    }
}

pub fn recordLastDispatch(
    state: *State,
    dispatch_id: []const u8,
    report: context_composition.ContextCompositionReport,
    budget_exceeded: bool,
    now_seconds: i64,
) !void {
    if (!std.mem.eql(u8, report.operation, "conversation_chat")) return;

    const allocator = state.operations.allocator;
    if (state.last_dispatch) |previous| {
        allocator.free(previous.dispatch_id);
        allocator.free(previous.operation);
        for (previous.sections) |section| allocator.free(section.section);
        allocator.free(previous.sections);
        state.last_dispatch = null;
    }

    const top_sections = try context_composition.ownedTopSections(allocator, report.sections, context_composition.top_section_limit);
    errdefer {
        for (top_sections) |section| allocator.free(section.name);
        allocator.free(top_sections);
    }
    const stored = try allocator.alloc(LastDispatchSection, top_sections.len);
    errdefer allocator.free(stored);
    for (top_sections, 0..) |section, index| {
        stored[index] = .{
            .section = section.name,
            .bytes = section.bytes,
            .count = section.count,
        };
    }
    allocator.free(top_sections);

    const user_prompt_tokens = if (report.user_prompt_tokens > 0)
        report.user_prompt_tokens
    else
        @import("context_tokens.zig").estimateTokensFromByteLength(report.user_prompt_bytes);

    state.last_dispatch = .{
        .dispatch_id = try allocator.dupe(u8, dispatch_id),
        .at_seconds = now_seconds,
        .operation = try allocator.dupe(u8, report.operation),
        .user_prompt_tokens = user_prompt_tokens,
        .budget_exceeded = budget_exceeded,
        .sections = stored,
    };
    state.updated_at_seconds = now_seconds;
    state.dirty_since_flush += 1;
}

pub fn recordBudgetExceeded(state: *State, now_seconds: i64) void {
    state.budget_exceeded_count += 1;
    state.updated_at_seconds = now_seconds;
    state.dirty_since_flush += 1;
}

pub const ProcessGoalCompositionRecord = struct {
    goal: []const u8,
    mode: []const u8,
    context_bytes: usize,
    step_count: usize,
};

pub fn recordLlmCompletion(state: *State, record: LlmCompletionRecord, now_seconds: i64) !void {
    state.total_llm_calls += 1;
    if (record.outcome != .success) state.total_llm_errors += 1;
    state.updated_at_seconds = now_seconds;
    state.dirty_since_flush += 1;

    const sub_gop = try state.llm_subsystems.getOrPut(record.subsystem);
    if (!sub_gop.found_existing) {
        sub_gop.key_ptr.* = try state.llm_subsystems.allocator.dupe(u8, record.subsystem);
        sub_gop.value_ptr.* = .{};
    }
    const totals = sub_gop.value_ptr;
    totals.call_count += 1;
    totals.request_bytes += @intCast(record.request_bytes);
    totals.response_bytes += @intCast(record.response_bytes);
    switch (record.outcome) {
        .success => totals.success_count += 1,
        .provider_error, .validation_error => totals.error_count += 1,
    }
    const response_bytes: u64 = @intCast(record.response_bytes);
    if (response_bytes > totals.max_response_bytes) totals.max_response_bytes = response_bytes;
    totals.total_latency_ms += record.latency_ms;

    const allocator = state.llm_subsystems.allocator;
    if (state.last_llm_call) |last| {
        allocator.free(last.subsystem);
        allocator.free(last.provider);
        allocator.free(last.model);
        if (last.effort_tier) |tier| allocator.free(tier);
    }
    state.last_llm_call = .{
        .subsystem = try allocator.dupe(u8, record.subsystem),
        .provider = try allocator.dupe(u8, record.provider),
        .model = try allocator.dupe(u8, record.model),
        .effort_tier = if (record.effort_tier) |tier| try allocator.dupe(u8, tier) else null,
        .response_bytes = record.response_bytes,
        .at_seconds = now_seconds,
    };
}

pub fn recordProcessGoalComposition(state: *State, record: ProcessGoalCompositionRecord, now_seconds: i64) !void {
    state.total_process_goal_count += 1;
    state.total_composed_steps += @intCast(record.step_count);
    state.updated_at_seconds = now_seconds;
    state.dirty_since_flush += 1;

    const operation = if (std.mem.eql(u8, record.mode, "autonomy"))
        "process_composition.autonomy"
    else if (std.mem.eql(u8, record.mode, "interaction"))
        "process_composition.interaction"
    else
        return error.InvalidProcessGoalCompositionMode;

    const op_gop = try state.operations.getOrPut(operation);
    if (!op_gop.found_existing) {
        op_gop.key_ptr.* = try state.operations.allocator.dupe(u8, operation);
        op_gop.value_ptr.* = .{};
    }
    const op = op_gop.value_ptr;
    op.call_count += 1;
    op.total_bytes += @intCast(record.context_bytes);
    if (record.context_bytes > op.max_bytes) op.max_bytes = @intCast(record.context_bytes);

    const goal_section_owned = try std.fmt.allocPrint(state.sections.allocator, "process_goal.{s}", .{record.goal});
    defer state.sections.allocator.free(goal_section_owned);
    const goal_gop = try state.sections.getOrPut(goal_section_owned);
    if (!goal_gop.found_existing) {
        goal_gop.key_ptr.* = try state.sections.allocator.dupe(u8, goal_section_owned);
        goal_gop.value_ptr.* = .{};
    }
    const goal_totals = goal_gop.value_ptr;
    goal_totals.total_bytes += @intCast(record.context_bytes);
    goal_totals.appearance_count += 1;

    const steps_gop = try state.sections.getOrPut("composed_steps");
    if (!steps_gop.found_existing) {
        steps_gop.key_ptr.* = try state.sections.allocator.dupe(u8, "composed_steps");
        steps_gop.value_ptr.* = .{};
    }
    const steps_totals = steps_gop.value_ptr;
    steps_totals.total_bytes += @intCast(record.step_count);
    steps_totals.appearance_count += 1;
}

pub fn maybeFlush(
    state: *State,
    allocator: std.mem.Allocator,
    fs: FileSystem,
    io: std.Io,
    path: []const u8,
) !void {
    if (state.dirty_since_flush < flush_every_n) return;
    try save(allocator, fs, io, path, state);
    state.dirty_since_flush = 0;
}

pub fn flushIfDirty(
    state: *State,
    allocator: std.mem.Allocator,
    fs: FileSystem,
    io: std.Io,
    path: []const u8,
) !void {
    if (state.dirty_since_flush == 0) return;
    try save(allocator, fs, io, path, state);
    state.dirty_since_flush = 0;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

const SectionRank = struct {
    name: []const u8,
    totals: SectionTotals,
};

fn sectionRankLessThan(_: void, lhs: SectionRank, rhs: SectionRank) bool {
    if (lhs.totals.total_bytes != rhs.totals.total_bytes) {
        return lhs.totals.total_bytes > rhs.totals.total_bytes;
    }
    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
}

pub fn sortedLlmSubsystemNames(state: *const State, allocator: std.mem.Allocator) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    var iter = state.llm_subsystems.iterator();
    while (iter.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);
    return try names.toOwnedSlice(allocator);
}

pub fn sortedOperationNames(state: *const State, allocator: std.mem.Allocator) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    var iter = state.operations.iterator();
    while (iter.next()) |entry| {
        try names.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);
    return try names.toOwnedSlice(allocator);
}

pub fn topSectionRanks(state: *const State, allocator: std.mem.Allocator) ![]SectionRank {
    var ranks = std.ArrayList(SectionRank).empty;
    defer ranks.deinit(allocator);
    var iter = state.sections.iterator();
    while (iter.next()) |entry| {
        try ranks.append(allocator, .{ .name = entry.key_ptr.*, .totals = entry.value_ptr.* });
    }
    std.mem.sort(SectionRank, ranks.items, {}, sectionRankLessThan);
    const limit = @min(max_top_sections, ranks.items.len);
    const out = try allocator.alloc(SectionRank, limit);
    @memcpy(out, ranks.items[0..limit]);
    return out;
}
