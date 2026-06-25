const std = @import("std");
const schema = @import("../storage/schema.zig");
const needs_mod = @import("needs.zig");
const psyche_client = @import("../api/psyche_client.zig");

pub const SharedInputs = struct {
    now: []const u8,
    energy_remaining: u32,
    daily_energy: u32,
    day_key: []const u8,
    sleeping: bool,
    quiet_hours_active: bool,
    speech_cooldown_active: bool,
    blocked: []const u8,
    affordances: []const u8,
    needs: []const needs_mod.Need,
    relationship_graph: []const u8,
    memories: []const schema.MemoryRecord,
    appraisals: []const schema.Appraisal,
    impressions: []const schema.Impression,
    superego_self_model: []const u8 = "",
    current_stimulus: []const u8 = "",
};

pub fn formatSharedContext(allocator: std.mem.Allocator, inputs: SharedInputs) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.print(
        allocator,
        "Shared psyche state:\n- time: {s}\n- autonomy_budget_remaining: {d}/{d}\n- autonomy_budget_note: internal daily action budget, not battery charge or external power\n- day_key: {s}\n- sleeping: {any}\n- quiet_hours_active: {any}\n- speech_cooldown_active: {any}\n- autonomy_blocked: {s}\n- proactive_camera: forbidden\n- current_stimulus: {s}\n\nNeeds:\n",
        .{ inputs.now, inputs.energy_remaining, inputs.daily_energy, inputs.day_key, inputs.sleeping, inputs.quiet_hours_active, inputs.speech_cooldown_active, inputs.blocked, if (inputs.current_stimulus.len > 0) inputs.current_stimulus else "none" },
    );
    try appendTopNeeds(allocator, &out, inputs.needs, 5);
    try out.print(allocator, "\nRelationship graph:\n{s}", .{inputs.relationship_graph});
    try out.appendSlice(allocator, "\nRecent appraisals:\n");
    try appendRecentAppraisals(allocator, &out, inputs.appraisals, 4);
    try out.appendSlice(allocator, "\nRecent impressions:\n");
    try appendRecentImpressions(allocator, &out, inputs.impressions, 4);
    try out.print(allocator, "\nSuperego self-model:\n{s}", .{if (inputs.superego_self_model.len > 0) inputs.superego_self_model else "- none\n"});
    try out.appendSlice(allocator, "\nSalient memories:\n");
    try appendSalientMemories(allocator, &out, inputs.memories, 6);
    try out.print(allocator, "\nAutonomy skills:\n{s}", .{inputs.affordances});
    return out.toOwnedSlice(allocator);
}

pub fn formatEgoContext(allocator: std.mem.Allocator, shared_context: []const u8, id: psyche_client.IdTurn, superego: psyche_client.SuperegoTurn) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Ego deliberation context:\nYou are the Ego of a stationary household robot. Reconcile the Id short-term consequence simulation, the Superego long-term consequence simulation, external reality, autonomy budget, and command availability. Both voices used the same shared state, but may assign different salience, causes, and meanings to the same stimulus. Choose exactly one allowed command. Superego advice is influential, but runtime gates still hard-block forbidden actions.\n\n{s}\n\n{s}\n{s}\nEgo task:\n- Compare the two simulations and notice priority conflicts, causal disagreements, and meaning disagreements.\n- Satisfy urgent needs only through available commands and current autonomy budget.\n- Treat autonomy budget as separate from battery charge and external power.\n- Prefer quiet self-work unless speech is genuinely high salience and allowed.\n- Return exactly one autonomy JSON command envelope.\n",
        .{ shared_context, try psyche_client.formatIdTurn(allocator, id), try psyche_client.formatSuperegoTurn(allocator, superego) },
    );
}

pub fn formatEgoContextWithoutPsyche(allocator: std.mem.Allocator, shared_context: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Ego deliberation context:\nPsyche voices are disabled. Choose exactly one allowed command using the shared state, command availability, autonomy budget, and runtime gates.\n\n{s}\n",
        .{shared_context},
    );
}

fn appendTopNeeds(allocator: std.mem.Allocator, out: *std.ArrayList(u8), needs: []const needs_mod.Need, limit: usize) !void {
    var emitted: usize = 0;
    const urgencies = [_]needs_mod.NeedUrgency{ .urgent, .need, .watch, .satisfied };
    for (urgencies) |urgency| {
        for (needs) |need| {
            if (emitted >= limit) return;
            if (need.urgency != urgency) continue;
            try out.print(allocator, "- {s}: urgency={s}; text={s}; evidence={s}; desired_action={s}\n", .{
                need.need_id,
                @tagName(need.urgency),
                need.text,
                need.evidence,
                need.desired_action,
            });
            emitted += 1;
        }
    }
    if (emitted == 0) try out.appendSlice(allocator, "- none\n");
}

fn appendRecentAppraisals(allocator: std.mem.Allocator, out: *std.ArrayList(u8), appraisals: []const schema.Appraisal, limit: usize) !void {
    if (appraisals.len == 0) {
        try out.appendSlice(allocator, "- none\n");
        return;
    }
    const start = if (appraisals.len > limit) appraisals.len - limit else 0;
    var i = appraisals.len;
    while (i > start) {
        i -= 1;
        const appraisal = appraisals[i];
        try out.print(allocator, "- query={s}; label={s}; valence={d:.2}; arousal={d:.2}; uncertainty={d:.2}; stress={d:.2}; curiosity={d:.2}; action={s}; dynamics={s}; note={s}\n", .{
            appraisal.query,
            appraisal.feeling_label,
            appraisal.valence,
            appraisal.arousal,
            appraisal.uncertainty,
            appraisal.stress,
            appraisal.curiosity,
            appraisal.action_tendency,
            appraisal.dynamics,
            appraisal.freeform,
        });
    }
}

fn appendRecentImpressions(allocator: std.mem.Allocator, out: *std.ArrayList(u8), impressions: []const schema.Impression, limit: usize) !void {
    if (impressions.len == 0) {
        try out.appendSlice(allocator, "- none\n");
        return;
    }
    const start = if (impressions.len > limit) impressions.len - limit else 0;
    var i = impressions.len;
    while (i > start) {
        i -= 1;
        const impression = impressions[i];
        try out.print(allocator, "- source={s}; salience={d:.2}; text={s}\n", .{ @tagName(impression.source), impression.salience, impression.text });
    }
}

fn appendSalientMemories(allocator: std.mem.Allocator, out: *std.ArrayList(u8), memories: []const schema.MemoryRecord, limit: usize) !void {
    if (memories.len == 0) {
        try out.appendSlice(allocator, "- none\n");
        return;
    }
    var emitted: usize = 0;
    while (emitted < limit) : (emitted += 1) {
        var best_index: ?usize = null;
        for (memories, 0..) |memory, i| {
            if (alreadySelected(memories, i, out.items)) continue;
            if (best_index == null or memoryScore(memory) > memoryScore(memories[best_index.?])) best_index = i;
        }
        const index = best_index orelse break;
        const memory = memories[index];
        try out.print(allocator, "- {s}: {s}; scope={s}; score={d}; salience={d:.2}; tags={s}\n", .{
            memory.memory_id,
            memoryInterpretation(memory),
            @tagName(memory.scope),
            memory.score,
            memory.salience,
            try joinTags(allocator, memory.tags),
        });
    }
}

fn alreadySelected(memories: []const schema.MemoryRecord, index: usize, emitted_text: []const u8) bool {
    return std.mem.indexOf(u8, emitted_text, memories[index].memory_id) != null;
}

fn memoryScore(memory: schema.MemoryRecord) f32 {
    return @as(f32, @floatFromInt(memory.score)) + memory.salience * 10.0 + @as(f32, @floatFromInt(memory.access_count)) * 0.5;
}

fn memoryInterpretation(memory: schema.MemoryRecord) []const u8 {
    if (memory.interpretation.len > 0) return memory.interpretation;
    return memory.text;
}

fn joinTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    if (tags.len == 0) return allocator.dupe(u8, "none");
    var out = std.ArrayList(u8).empty;
    for (tags, 0..) |tag, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, tag);
    }
    return out.toOwnedSlice(allocator);
}

test "shared context includes pertinent ranked data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const needs = [_]needs_mod.Need{
        .{ .need_id = "watch", .text = "Watch", .urgency = .watch, .evidence = "soft", .desired_action = "wait" },
        .{ .need_id = "urgent", .text = "Urgent", .urgency = .urgent, .evidence = "hard", .desired_action = "act" },
    };
    const memories = [_]schema.MemoryRecord{.{
        .memory_id = "memory_self",
        .scope = .long_term,
        .text = "I need quiet time",
        .interpretation = "self-defined need: I need quiet time",
        .tags = @constCast(&[_][]const u8{"self_need"}),
        .created_at = "1000",
        .last_accessed_at = null,
        .access_count = 1,
        .score = 5,
    }};
    const text = try formatSharedContext(allocator, .{
        .now = "now",
        .energy_remaining = 8,
        .daily_energy = 10,
        .day_key = "2026-06-23",
        .sleeping = false,
        .quiet_hours_active = false,
        .speech_cooldown_active = false,
        .blocked = "none",
        .affordances = "- think_about\n",
        .needs = &needs,
        .relationship_graph = "relationship_graph:\n- none\n",
        .memories = &memories,
        .appraisals = &.{},
        .impressions = &.{},
    });
    try std.testing.expect(std.mem.indexOf(u8, text, "urgent: urgency=urgent") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "memory_self") != null);
}

test "ego context reconciles different salience causes and meanings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = psyche_client.IdTurn{
        .top_need = "connection",
        .urges = &.{"say hello now"},
        .random_thoughts = &.{"new sound might be interesting"},
        .desired_action_bias = "say",
        .salience = .medium,
        .reason = "near-term contact may help",
    };
    const superego = psyche_client.SuperegoTurn{
        .concerns = &.{"quiet hours"},
        .vetoes = &.{},
        .preferred_restraints = &.{"quiet self-work"},
        .values_to_preserve = &.{"user dignity"},
        .salience = .high,
        .reason = "long-term trust matters",
    };
    const text = try formatEgoContext(allocator, "Shared psyche state:\n- current_stimulus: new sound\n", id, superego);
    try std.testing.expect(std.mem.indexOf(u8, text, "Id short-term consequence simulation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Superego long-term consequence simulation") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "different salience, causes, and meanings") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "priority conflicts, causal disagreements, and meaning disagreements") != null);
}
