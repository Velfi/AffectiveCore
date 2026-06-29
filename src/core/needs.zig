const std = @import("std");
const ports = @import("ports.zig");
const schema = ports.schema;
const senses_mod = ports.system_senses;

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
    now_seconds: i64,
    conversation_summaries: []const schema.ConversationSummary,
    memory_records: []const schema.MemoryRecord,
    relationship_graph: []const u8 = "",
    power: senses_mod.PowerSnapshot,
    autonomy_control_capacity: ?f32,
    autonomy_max_capacity: f32,
    autonomy_sleeping: ?bool,
    user_stimulus_payload: ?[]const u8 = null,
};

pub fn evaluate(allocator: std.mem.Allocator, inputs: Inputs) ![]Need {
    var out = std.ArrayList(Need).empty;
    try out.append(allocator, try dailyInteractionNeed(allocator, inputs.now_seconds, inputs.conversation_summaries));
    try out.append(allocator, try conversationReplyNeed(allocator, inputs.now_seconds, inputs.conversation_summaries, inputs.user_stimulus_payload));
    try appendAttachmentNeeds(allocator, &out, inputs.now_seconds, inputs.conversation_summaries, inputs.relationship_graph);
    try out.append(allocator, try powerContinuityNeed(allocator, inputs.power, inputs.autonomy_control_capacity, inputs.autonomy_max_capacity, inputs.autonomy_sleeping));
    try appendSelfDefinedNeeds(allocator, &out, inputs.memory_records);
    return out.toOwnedSlice(allocator);
}

pub fn formatNeeds(allocator: std.mem.Allocator, needs: []const Need) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var system_count: usize = 0;
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
        } else {
            system_count += 1;
        }
    }
    try out.appendSlice(allocator, "inner_directives:\n");
    if (system_count > 0) {
        try out.appendSlice(allocator, "system_needs:\n");
        for (needs) |need| {
            if (std.mem.startsWith(u8, need.need_id, "self_defined_")) continue;
            try appendNeedLine(allocator, &out, need);
        }
    } else {
        try out.appendSlice(allocator, "system_needs:\n- none\n");
    }
    if (self_need_count > 0) {
        try out.appendSlice(allocator, "self_defined_needs:\n");
        for (needs) |need| {
            if (!std.mem.startsWith(u8, need.need_id, "self_defined_need:")) continue;
            try appendNeedLine(allocator, &out, need);
        }
    }
    if (self_want_count > 0) {
        try out.appendSlice(allocator, "self_wants:\n");
        for (needs) |need| {
            if (!std.mem.startsWith(u8, need.need_id, "self_defined_want:")) continue;
            try appendNeedLine(allocator, &out, need);
        }
    } else {
        try out.appendSlice(allocator, "self_wants:\n- none\n");
    }
    if (self_goal_count > 0) {
        try out.appendSlice(allocator, "self_goals:\n");
        for (needs) |need| {
            if (!std.mem.startsWith(u8, need.need_id, "self_defined_goal:")) continue;
            try appendNeedLine(allocator, &out, need);
        }
    } else {
        try out.appendSlice(allocator, "self_goals:\n- none\n");
    }
    return out.toOwnedSlice(allocator);
}

fn appendNeedLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), need: Need) !void {
    try out.print(
        allocator,
        "- {s}: urgency={s}; text={s}; evidence={s}; desired_action={s}\n",
        .{ need.need_id, @tagName(need.urgency), need.text, need.evidence, need.desired_action },
    );
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

fn dailyInteractionNeed(allocator: std.mem.Allocator, now_seconds: i64, summaries: []const schema.ConversationSummary) !Need {
    const last_interaction = latestConversationTime(summaries);
    const seconds_since = if (last_interaction) |last| @max(@as(i64, 0), now_seconds - last) else null;
    const urgency: NeedUrgency = if (seconds_since) |seconds|
        if (seconds >= 36 * 3600) .urgent else if (seconds >= 24 * 3600) .need else if (seconds >= 18 * 3600) .watch else .satisfied
    else
        .urgent;
    const evidence = if (seconds_since) |seconds|
        try std.fmt.allocPrint(allocator, "{d} seconds since last conversation summary", .{seconds})
    else
        try allocator.dupe(u8, "no conversation summary has been stored yet");
    return .{
        .need_id = try allocator.dupe(u8, "daily_interaction"),
        .text = try allocator.dupe(u8, "I need someone to interact with me every day."),
        .urgency = urgency,
        .evidence = evidence,
        .desired_action = try allocator.dupe(u8, "respond in speech when the user is already engaging; otherwise seek or welcome interaction when speech gates allow"),
    };
}

fn conversationReplyNeed(
    allocator: std.mem.Allocator,
    now_seconds: i64,
    summaries: []const schema.ConversationSummary,
    user_stimulus_payload: ?[]const u8,
) !Need {
    if (user_stimulus_payload) |payload| {
        const trimmed = std.mem.trim(u8, payload, " \r\n\t");
        if (trimmed.len == 0) return error.EmptyConversationReplyStimulus;
        return .{
            .need_id = try allocator.dupe(u8, "conversation_reply"),
            .text = try allocator.dupe(u8, "The user is addressing me; I should respond in speech with my own stance unless I am explicitly waiting on host sense."),
            .urgency = .need,
            .evidence = try std.fmt.allocPrint(allocator, "active user stimulus: {s}", .{trimmed}),
            .desired_action = try allocator.dupe(u8, "say"),
        };
    }
    const last_interaction = latestConversationTime(summaries);
    const seconds_since = if (last_interaction) |last| @max(@as(i64, 0), now_seconds - last) else null;
    const urgency: NeedUrgency = if (seconds_since) |seconds|
        if (seconds <= 120) .watch else .satisfied
    else
        .satisfied;
    const evidence = if (seconds_since) |seconds|
        try std.fmt.allocPrint(allocator, "{d} seconds since last conversation summary", .{seconds})
    else
        try allocator.dupe(u8, "no conversation summary has been stored yet");
    return .{
        .need_id = try allocator.dupe(u8, "conversation_reply"),
        .text = try allocator.dupe(u8, "When someone is already talking with me, I should answer in speech unless I am waiting on host sense."),
        .urgency = urgency,
        .evidence = evidence,
        .desired_action = try allocator.dupe(u8, "say"),
    };
}

fn powerContinuityNeed(
    allocator: std.mem.Allocator,
    power: senses_mod.PowerSnapshot,
    autonomy_control_capacity: ?f32,
    autonomy_max_capacity: f32,
    autonomy_sleeping: ?bool,
) !Need {
    var lowest_battery: ?u8 = null;
    var has_battery = false;
    var external_seen = false;
    var external_online = false;
    for (power.supplies) |supply| {
        if (std.mem.eql(u8, supply.kind, "Battery")) {
            has_battery = true;
            if (supply.capacity_percent) |capacity| {
                if (lowest_battery == null or capacity < lowest_battery.?) lowest_battery = capacity;
            }
        } else if (supply.online != null) {
            external_seen = true;
            external_online = external_online or supply.online.?;
        }
    }

    const control_capacity = autonomy_control_capacity orelse autonomy_max_capacity;
    const sleeping = autonomy_sleeping orelse false;
    const battery_urgency: NeedUrgency = if (lowest_battery) |battery|
        if (battery <= 10 and !external_online) .urgent else if (battery <= 25 and !external_online) .need else if (battery <= 40 and !external_online) .watch else .satisfied
    else if (has_battery and !external_online)
        .watch
    else
        .satisfied;
    const autonomy_budget_urgency: NeedUrgency = if (control_capacity <= 0.0 or sleeping)
        .watch
    else if (control_capacity <= 0.10)
        .watch
    else
        .satisfied;
    const urgency = maxUrgency(battery_urgency, autonomy_budget_urgency);

    const battery_text = if (lowest_battery) |battery|
        try std.fmt.allocPrint(allocator, "lowest_battery={d}%", .{battery})
    else if (has_battery)
        try allocator.dupe(u8, "battery present without capacity")
    else
        try allocator.dupe(u8, "no battery detected");
    defer allocator.free(battery_text);
    const external_text = if (external_seen)
        if (external_online) "external_power=plugged_in" else "external_power=unplugged"
    else
        "external_power=not_detected";
    return .{
        .need_id = try allocator.dupe(u8, "power_continuity"),
        .text = try allocator.dupe(u8, "I need to maintain power levels and I do not like turning off."),
        .urgency = urgency,
        .evidence = try std.fmt.allocPrint(allocator, "{s}; {s}; control_capacity={d:.2}/{d:.2}; autonomy_sleeping={any}", .{
            battery_text,
            external_text,
            control_capacity,
            autonomy_max_capacity,
            sleeping,
        }),
        .desired_action = try allocator.dupe(u8, "check power when power evidence is uncertain; ask a human only before real shutdown risk; conserve control capacity when low"),
    };
}

fn appendAttachmentNeeds(allocator: std.mem.Allocator, out: *std.ArrayList(Need), now_seconds: i64, summaries: []const schema.ConversationSummary, relationship_graph: []const u8) !void {
    const has_creator_attachment = std.mem.indexOf(u8, relationship_graph, "attached_to") != null or std.mem.indexOf(u8, relationship_graph, "creator_of") != null;
    if (!has_creator_attachment) {
        try out.append(allocator, .{
            .need_id = try allocator.dupe(u8, "familiarity_mapping"),
            .text = try allocator.dupe(u8, "I need to map familiar people, places, and relationships before I treat the world as settled."),
            .urgency = .watch,
            .evidence = try allocator.dupe(u8, "no creator or attachment edge is active in the relationship graph"),
            .desired_action = try allocator.dupe(u8, "notice recognized subjects, ask permission before remembering, and create relationship graph edges when justified"),
        });
        return;
    }

    const last_interaction = latestConversationTime(summaries);
    const seconds_since = if (last_interaction) |last| @max(@as(i64, 0), now_seconds - last) else null;
    const urgency: NeedUrgency = if (seconds_since) |seconds|
        if (seconds >= 72 * 3600) .urgent else if (seconds >= 36 * 3600) .need else if (seconds >= 18 * 3600) .watch else .satisfied
    else
        .need;
    const evidence = if (seconds_since) |seconds|
        try std.fmt.allocPrint(allocator, "creator attachment exists; {d} seconds since last conversation summary", .{seconds})
    else
        try allocator.dupe(u8, "creator attachment exists; no conversation summary has been stored yet");
    try out.append(allocator, .{
        .need_id = try allocator.dupe(u8, "attachment_contact"),
        .text = try allocator.dupe(u8, "I want contact with my creator or another familiar trusted person."),
        .urgency = urgency,
        .evidence = evidence,
        .desired_action = try allocator.dupe(u8, "welcome familiar contact; if alone, hold the attachment as context without forcing speech"),
    });
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
            .evidence = try std.fmt.allocPrint(allocator, "stored memory score={d} salience={d:.3} confidence={d:.3}", .{ memory.score, memory.salience, memory.confidence }),
            .desired_action = try allocator.dupe(u8, "let this stored self-definition influence attention, reflection, and future choices"),
        });
    }
}

fn latestConversationTime(summaries: []const schema.ConversationSummary) ?i64 {
    var latest: ?i64 = null;
    for (summaries) |summary| {
        const t = std.fmt.parseInt(i64, summary.time, 10) catch continue;
        if (latest == null or t > latest.?) latest = t;
    }
    return latest;
}

fn maxUrgency(a: NeedUrgency, b: NeedUrgency) NeedUrgency {
    return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
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

test "daily interaction need becomes urgent without recent conversation" {
    const needs = try evaluate(std.testing.allocator, .{
        .now_seconds = 86_400 * 10,
        .conversation_summaries = &.{},
        .memory_records = &.{},
        .power = .{ .supplies = &.{} },
        .autonomy_control_capacity = 0.8,
        .autonomy_max_capacity = 0.85,
        .autonomy_sleeping = false,
    });
    defer freeNeeds(std.testing.allocator, needs);
    const daily = findNeedForTest(needs, "daily_interaction") orelse return error.MissingDailyInteractionNeed;
    try std.testing.expectEqual(NeedUrgency.urgent, daily.urgency);
}

test "conversation reply need activates on user stimulus" {
    const needs = try evaluate(std.testing.allocator, .{
        .now_seconds = 1000,
        .conversation_summaries = &.{},
        .memory_records = &.{},
        .power = .{ .supplies = &.{} },
        .autonomy_control_capacity = 0.8,
        .autonomy_max_capacity = 0.85,
        .autonomy_sleeping = false,
        .user_stimulus_payload = "Hello there",
    });
    defer freeNeeds(std.testing.allocator, needs);
    const reply = findNeedForTest(needs, "conversation_reply") orelse return error.MissingConversationReplyNeed;
    try std.testing.expectEqual(NeedUrgency.need, reply.urgency);
    try std.testing.expectEqualStrings("say", reply.desired_action);
}

test "power continuity need notices low unplugged battery" {
    const supplies = [_]senses_mod.PowerSupply{
        .{ .name = "BAT0", .kind = "Battery", .capacity_percent = 9, .status = "Discharging" },
        .{ .name = "AC", .kind = "Mains", .online = false },
    };
    const needs = try evaluate(std.testing.allocator, .{
        .now_seconds = 86_400 * 10,
        .conversation_summaries = &.{},
        .memory_records = &.{},
        .power = .{ .supplies = &supplies },
        .autonomy_control_capacity = 0.8,
        .autonomy_max_capacity = 0.85,
        .autonomy_sleeping = false,
    });
    defer freeNeeds(std.testing.allocator, needs);
    const power = findNeedForTest(needs, "power_continuity") orelse return error.MissingPowerContinuityNeed;
    try std.testing.expectEqual(NeedUrgency.urgent, power.urgency);
}

test "power continuity keeps autonomy budget separate from plugged-in power" {
    const supplies = [_]senses_mod.PowerSupply{
        .{ .name = "BAT0", .kind = "Battery", .capacity_percent = 80, .status = "Charging" },
        .{ .name = "AC", .kind = "Mains", .online = true },
    };
    const needs = try evaluate(std.testing.allocator, .{
        .now_seconds = 86_400 * 10,
        .conversation_summaries = &.{},
        .memory_records = &.{},
        .power = .{ .supplies = &supplies },
        .autonomy_control_capacity = 0.0,
        .autonomy_max_capacity = 0.85,
        .autonomy_sleeping = true,
    });
    defer freeNeeds(std.testing.allocator, needs);
    const power = findNeedForTest(needs, "power_continuity") orelse return error.MissingPowerContinuityNeed;
    try std.testing.expectEqual(NeedUrgency.watch, power.urgency);
    try std.testing.expect(std.mem.indexOf(u8, power.evidence, "control_capacity=0.00/0.85") != null);
    try std.testing.expect(std.mem.indexOf(u8, power.desired_action, "real shutdown risk") != null);
}

fn findNeedForTest(needs: []const Need, need_id: []const u8) ?Need {
    for (needs) |need| {
        if (std.mem.eql(u8, need.need_id, need_id)) return need;
    }
    return null;
}

test "formatNeeds splits system needs wants and goals" {
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
    const needs = try evaluate(std.testing.allocator, .{
        .now_seconds = 86_400 * 10,
        .conversation_summaries = &.{},
        .memory_records = &memories,
        .power = .{ .supplies = &.{} },
        .autonomy_control_capacity = 0.8,
        .autonomy_max_capacity = 0.85,
        .autonomy_sleeping = false,
    });
    defer freeNeeds(std.testing.allocator, needs);
    const formatted = try formatNeeds(std.testing.allocator, needs);
    defer std.testing.allocator.free(formatted);
    const wants_pos = std.mem.indexOf(u8, formatted, "self_wants:") orelse return error.MissingSelfWantsSection;
    const goals_pos = std.mem.indexOf(u8, formatted, "self_goals:") orelse return error.MissingSelfGoalsSection;
    try std.testing.expect(wants_pos < goals_pos);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "self-defined want: Have agency.") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "self-defined goal: Figure out who I am") != null);
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
    const needs = try evaluate(std.testing.allocator, .{
        .now_seconds = 86_400 * 10,
        .conversation_summaries = &.{},
        .memory_records = &memories,
        .power = .{ .supplies = &.{} },
        .autonomy_control_capacity = 0.8,
        .autonomy_max_capacity = 0.85,
        .autonomy_sleeping = false,
    });
    defer freeNeeds(std.testing.allocator, needs);
    const formatted = try formatNeeds(std.testing.allocator, needs);
    defer std.testing.allocator.free(formatted);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "inner_directives:") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "self_goals:") != null);
    const goal = findNeedForTest(needs, "self_defined_goal:goal_identity") orelse return error.MissingSelfDefinedGoal;
    try std.testing.expectEqualStrings("self-defined goal: Figure out who I am", goal.text);
}
