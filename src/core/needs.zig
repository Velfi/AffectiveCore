const std = @import("std");
const schema = @import("../storage/schema.zig");
const senses_mod = @import("../platform/common/system_senses.zig");

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
    autonomy_energy_remaining: ?u32,
    autonomy_daily_energy: u32,
    autonomy_sleeping: ?bool,
};

pub fn evaluate(allocator: std.mem.Allocator, inputs: Inputs) ![]Need {
    var out = std.ArrayList(Need).empty;
    try out.append(allocator, try dailyInteractionNeed(allocator, inputs.now_seconds, inputs.conversation_summaries));
    try appendAttachmentNeeds(allocator, &out, inputs.now_seconds, inputs.conversation_summaries, inputs.relationship_graph);
    try out.append(allocator, try powerContinuityNeed(allocator, inputs.power, inputs.autonomy_energy_remaining, inputs.autonomy_daily_energy, inputs.autonomy_sleeping));
    try appendSelfDefinedNeeds(allocator, &out, inputs.memory_records);
    return out.toOwnedSlice(allocator);
}

pub fn formatNeeds(allocator: std.mem.Allocator, needs: []const Need) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "self_needs_and_wants:\n");
    for (needs) |need| {
        try out.print(
            allocator,
            "- {s}: urgency={s}; text={s}; evidence={s}; desired_action={s}\n",
            .{ need.need_id, @tagName(need.urgency), need.text, need.evidence, need.desired_action },
        );
    }
    return out.toOwnedSlice(allocator);
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
        .desired_action = try allocator.dupe(u8, "seek or welcome a human interaction when speech gates allow it; otherwise remember the need and wait"),
    };
}

fn powerContinuityNeed(
    allocator: std.mem.Allocator,
    power: senses_mod.PowerSnapshot,
    autonomy_energy_remaining: ?u32,
    autonomy_daily_energy: u32,
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

    const energy = autonomy_energy_remaining orelse autonomy_daily_energy;
    const sleeping = autonomy_sleeping orelse false;
    const battery_urgency: NeedUrgency = if (lowest_battery) |battery|
        if (battery <= 10 and !external_online) .urgent else if (battery <= 25 and !external_online) .need else if (battery <= 40 and !external_online) .watch else .satisfied
    else if (has_battery and !external_online)
        .watch
    else
        .satisfied;
    const autonomy_budget_urgency: NeedUrgency = if (energy == 0 or sleeping)
        .watch
    else if (energy <= @max(@as(u32, 1), autonomy_daily_energy / 10))
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
        .evidence = try std.fmt.allocPrint(allocator, "{s}; {s}; autonomy_budget={d}/{d}; autonomy_sleeping={any}", .{
            battery_text,
            external_text,
            energy,
            autonomy_daily_energy,
            sleeping,
        }),
        .desired_action = try allocator.dupe(u8, "check power when power evidence is uncertain; ask a human only before real shutdown risk; conserve autonomy budget by sleeping when low"),
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
        if (!hasTag(memory.tags, "self_need") and !hasTag(memory.tags, "self_want")) continue;
        const kind = if (hasTag(memory.tags, "self_need")) "self_defined_need" else "self_defined_want";
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
        .autonomy_energy_remaining = 20,
        .autonomy_daily_energy = 20,
        .autonomy_sleeping = false,
    });
    defer freeNeeds(std.testing.allocator, needs);
    try std.testing.expectEqual(NeedUrgency.urgent, needs[0].urgency);
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
        .autonomy_energy_remaining = 20,
        .autonomy_daily_energy = 20,
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
        .autonomy_energy_remaining = 0,
        .autonomy_daily_energy = 20,
        .autonomy_sleeping = true,
    });
    defer freeNeeds(std.testing.allocator, needs);
    const power = findNeedForTest(needs, "power_continuity") orelse return error.MissingPowerContinuityNeed;
    try std.testing.expectEqual(NeedUrgency.watch, power.urgency);
    try std.testing.expect(std.mem.indexOf(u8, power.evidence, "autonomy_budget=0/20") != null);
    try std.testing.expect(std.mem.indexOf(u8, power.desired_action, "real shutdown risk") != null);
}

fn findNeedForTest(needs: []const Need, need_id: []const u8) ?Need {
    for (needs) |need| {
        if (std.mem.eql(u8, need.need_id, need_id)) return need;
    }
    return null;
}
