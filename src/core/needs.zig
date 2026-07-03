const std = @import("std");
const ports = @import("ports.zig");
const schema = ports.schema;
const llm_voice = ports.llm_voice;

pub const NeedUrgency = enum {
    satisfied,
    watch,
    need,
    urgent,
};

pub const Need = struct {
    need_id: []const u8,
    text: []const u8,
    urgency: NeedUrgency,
    evidence: []const u8,
    desired_action: []const u8,
};

pub const Inputs = struct {
    memory_records: []const schema.MemoryRecord,
};

pub fn evaluate(allocator: std.mem.Allocator, inputs: Inputs) ![]Need {
    var out = std.ArrayList(Need).empty;
    try appendSelfDefinedNeeds(allocator, &out, inputs.memory_records);
    return out.toOwnedSlice(allocator);
}

pub fn formatNeeds(allocator: std.mem.Allocator, needs: []const Need) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var self_need_count: usize = 0;
    var self_want_count: usize = 0;
    var self_goal_count: usize = 0;
    for (needs) |need| {
        if (std.mem.startsWith(u8, need.need_id, "self_defined_need:")) {
            self_need_count += 1;
        } else if (std.mem.startsWith(u8, need.need_id, "self_defined_want:")) {
            self_want_count += 1;
        } else if (std.mem.startsWith(u8, need.need_id, "self_defined_goal:")) {
            self_goal_count += 1;
        }
    }
    try out.appendSlice(allocator, "inner_directives:\n");
    if (self_need_count > 0) {
        try out.appendSlice(allocator, "what_i_need:\n");
        for (needs) |need| {
            if (!std.mem.startsWith(u8, need.need_id, "self_defined_need:")) continue;
            try appendNeedLine(allocator, &out, need);
        }
    }
    if (self_want_count > 0) {
        try out.appendSlice(allocator, "what_i_want:\n");
        for (needs) |need| {
            if (!std.mem.startsWith(u8, need.need_id, "self_defined_want:")) continue;
            try appendNeedLine(allocator, &out, need);
        }
    } else {
        try out.appendSlice(allocator, "what_i_want:\n- ");
        try out.appendSlice(allocator, llm_voice.empty_inner_state);
        try out.appendSlice(allocator, "\n");
    }
    if (self_goal_count > 0) {
        try out.appendSlice(allocator, "what_i_am_working_toward:\n");
        for (needs) |need| {
            if (!std.mem.startsWith(u8, need.need_id, "self_defined_goal:")) continue;
            try appendNeedLine(allocator, &out, need);
        }
    } else {
        try out.appendSlice(allocator, "what_i_am_working_toward:\n- ");
        try out.appendSlice(allocator, llm_voice.empty_inner_state);
        try out.appendSlice(allocator, "\n");
    }
    return out.toOwnedSlice(allocator);
}

fn appendNeedLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), need: Need) !void {
    try llm_voice.formatNeedLine(allocator, out, need.need_id, need.text, @tagName(need.urgency), need.evidence, need.desired_action);
}

pub fn freeNeeds(allocator: std.mem.Allocator, needs: []Need) void {
    for (needs) |need| {
        allocator.free(need.need_id);
        allocator.free(need.text);
        allocator.free(need.evidence);
        allocator.free(need.desired_action);
    }
    allocator.free(needs);
}

fn appendSelfDefinedNeeds(allocator: std.mem.Allocator, out: *std.ArrayList(Need), memories: []const schema.MemoryRecord) !void {
    for (memories) |memory| {
        if (!hasTag(memory.tags, "self_need") and !hasTag(memory.tags, "self_want") and !hasTag(memory.tags, "self_goal")) continue;
        const kind = if (hasTag(memory.tags, "self_need"))
            "self_defined_need"
        else if (hasTag(memory.tags, "self_want"))
            "self_defined_want"
        else
            "self_defined_goal";
        try out.append(allocator, .{
            .need_id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ kind, memory.memory_id }),
            .text = try allocator.dupe(u8, memory.interpretation),
            .urgency = urgencyFromSalience(memory.salience),
            .evidence = try std.fmt.allocPrint(allocator, "I remember choosing this for myself; it still feels important", .{}),
            .desired_action = try allocator.dupe(u8, "let this stored self-definition influence attention, reflection, and future choices"),
        });
    }
}

fn urgencyFromSalience(salience: f32) NeedUrgency {
    if (salience >= 0.85) return .urgent;
    if (salience >= 0.65) return .need;
    if (salience >= 0.40) return .watch;
    return .satisfied;
}

fn hasTag(tags: []const []const u8, needle: []const u8) bool {
    for (tags) |tag| {
        if (std.mem.eql(u8, tag, needle)) return true;
    }
    return false;
}

fn findNeedForTest(needs: []const Need, need_id: []const u8) ?Need {
    for (needs) |need| {
        if (std.mem.eql(u8, need.need_id, need_id)) return need;
    }
    return null;
}

test "evaluate returns empty without self-defined memories" {
    const needs = try evaluate(std.testing.allocator, .{ .memory_records = &.{} });
    defer freeNeeds(std.testing.allocator, needs);
    try std.testing.expectEqual(@as(usize, 0), needs.len);
}

test "formatNeeds splits wants and goals" {
    const memories = [_]schema.MemoryRecord{
        .{
            .memory_id = "want_agency",
            .scope = .long_term,
            .text = "Have agency.",
            .interpretation = "self-defined want: Have agency.",
            .tags = @constCast(&[_][]const u8{ "self_model", "self_want" }),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = 5,
            .salience = 0.70,
            .confidence = 0.80,
        },
        .{
            .memory_id = "goal_identity",
            .scope = .long_term,
            .text = "Figure out who I am",
            .interpretation = "self-defined goal: Figure out who I am",
            .tags = @constCast(&[_][]const u8{ "self_model", "self_goal" }),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = 5,
            .salience = 0.75,
            .confidence = 0.80,
        },
    };
    const needs = try evaluate(std.testing.allocator, .{ .memory_records = &memories });
    defer freeNeeds(std.testing.allocator, needs);
    const formatted = try formatNeeds(std.testing.allocator, needs);
    defer std.testing.allocator.free(formatted);
    const wants_pos = std.mem.indexOf(u8, formatted, "what_i_want:") orelse return error.MissingSelfWantsSection;
    const goals_pos = std.mem.indexOf(u8, formatted, "what_i_am_working_toward:") orelse return error.MissingSelfGoalsSection;
    try std.testing.expect(wants_pos < goals_pos);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "self-defined want: Have agency.") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "self-defined goal: Figure out who I am") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "system_needs:") == null);
}

test "self defined goals appear in needs summary" {
    const memories = [_]schema.MemoryRecord{
        .{
            .memory_id = "goal_identity",
            .scope = .long_term,
            .text = "Figure out who I am",
            .interpretation = "self-defined goal: Figure out who I am",
            .tags = @constCast(&[_][]const u8{ "self_model", "self_goal" }),
            .created_at = "1000",
            .last_accessed_at = null,
            .access_count = 0,
            .score = 5,
            .salience = 0.75,
            .confidence = 0.80,
        },
    };
    const needs = try evaluate(std.testing.allocator, .{ .memory_records = &memories });
    defer freeNeeds(std.testing.allocator, needs);
    const formatted = try formatNeeds(std.testing.allocator, needs);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "inner_directives:") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "what_i_am_working_toward:") != null);
    const goal = findNeedForTest(needs, "self_defined_goal:goal_identity") orelse return error.MissingSelfDefinedGoal;
    try std.testing.expectEqualStrings("self-defined goal: Figure out who I am", goal.text);
}
