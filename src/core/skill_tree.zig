const std = @import("std");
const skills = @import("port_skills.zig");

pub const SkillId = skills.SkillId;
pub const SkillGroup = enum {
    speech,
    vision,
    people,
    senses,
    memory,
    facts,
    self_directives,
    inner_life,
    focus,
    autonomy_control,
    communication,
    introspection,
};

pub const GroupSpec = struct {
    id: SkillGroup,
    name: []const u8,
    summary: []const u8,
};

pub const Availability = struct {
    ctx: *anyopaque,
    isAvailable: *const fn (*anyopaque, SkillId) bool,
};

pub const IntrospectTarget = union(enum) {
    overview,
    skills_tree,
    skills_group: SkillGroup,
    skill: SkillId,
    memory,
    facts,
    needs,
    capabilities,
    senses,
    autonomy,
    focus,
    identity,
    processes,
    process: []const u8,
    unknown: []const u8,
};

pub const group_specs = [_]GroupSpec{
    .{ .id = .speech, .name = "speech", .summary = "Outward speech, IRC-style emotes, and silent facial expression." },
    .{ .id = .vision, .name = "vision", .summary = "Camera capture, image description, comparison, and generation." },
    .{ .id = .people, .name = "people", .summary = "Face recognition enrollment, updates, and forgetting people." },
    .{ .id = .senses, .name = "senses", .summary = "Host time, orientation, power, storage, and database observations." },
    .{ .id = .memory, .name = "memory", .summary = "Forget, sweep, and dream-time consolidation of stored memories." },
    .{ .id = .facts, .name = "facts", .summary = "Create, recall, and invalidate durable self facts." },
    .{ .id = .self_directives, .name = "self_directives", .summary = "Define and edit self needs, wants, and goals." },
    .{ .id = .inner_life, .name = "inner_life", .summary = "Appraise events, feel about topics, think privately, and choose attention." },
    .{ .id = .focus, .name = "focus", .summary = "Set or clear working-memory focus." },
    .{ .id = .autonomy_control, .name = "autonomy_control", .summary = "Sleep or wake autonomy, and schedule reminders." },
    .{ .id = .communication, .name = "communication", .summary = "Send email when the user clearly asks for it." },
    .{ .id = .introspection, .name = "introspection", .summary = "Observe internal state and drill into topics with query." },
};

pub fn groupFor(id: SkillId) SkillGroup {
    return switch (id) {
        .say, .emote, .facial_expression => .speech,
        .take_picture, .describe_image, .compare_images, .recognize, .imagine_image => .vision,
        .remember_person, .update_face_picture, .forget_person => .people,
        .get_time, .request_orientation, .get_power, .get_storage, .get_database_stats => .senses,
        .forget_memory, .sweep_memory, .consolidate_memory => .memory,
        .set_fact, .recall_fact, .invalidate_fact => .facts,
        .define_need, .define_want, .define_goal, .edit_need, .edit_want, .edit_goal => .self_directives,
        .appraise_event, .feel_about, .think_about, .choose_attention => .inner_life,
        .set_focus, .clear_focus, .begin_subtask, .resume_parent => .focus,
        .sleep_autonomy, .wake_autonomy, .schedule_reminder => .autonomy_control,
        .send_email => .communication,
        .introspect => .introspection,
        .unknown => unreachable,
    };
}

pub fn groupSpec(group: SkillGroup) GroupSpec {
    for (group_specs) |spec| {
        if (spec.id == group) return spec;
    }
    unreachable;
}

pub fn parseGroupName(name: []const u8) ?SkillGroup {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    inline for (group_specs) |spec| {
        if (std.ascii.eqlIgnoreCase(trimmed, spec.name)) return spec.id;
    }
    return null;
}

pub fn parseSkillName(name: []const u8) ?SkillId {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    inline for (@typeInfo(SkillId).@"enum".fields) |field| {
        if (std.ascii.eqlIgnoreCase(trimmed, field.name)) {
            return @field(SkillId, field.name);
        }
    }
    return null;
}

fn stripIntrospectQueryPrefix(trimmed: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(trimmed, "query")) return "";
    const prefix = "query=";
    if (trimmed.len > prefix.len and std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) {
        return std.mem.trim(u8, trimmed[prefix.len..], " \t\r\n");
    }
    return trimmed;
}

pub fn parseIntrospectQuery(query: ?[]const u8) IntrospectTarget {
    const raw = query orelse return .overview;
    const trimmed = stripIntrospectQueryPrefix(std.mem.trim(u8, raw, " \t\r\n"));
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "overview")) return .overview;

    var parts = std.mem.splitScalar(u8, trimmed, '/');
    const head = std.mem.trim(u8, parts.next() orelse trimmed, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(head, "skills")) {
        const group_name = parts.next();
        if (group_name == null) return .skills_tree;
        const group_trimmed = std.mem.trim(u8, group_name.?, " \t\r\n");
        const group = parseGroupName(group_trimmed) orelse return .{ .unknown = trimmed };
        const skill_name = parts.next();
        if (skill_name == null) return .{ .skills_group = group };
        const skill = parseSkillName(std.mem.trim(u8, skill_name.?, " \t\r\n")) orelse return .{ .unknown = trimmed };
        if (groupFor(skill) != group) return .{ .unknown = trimmed };
        return .{ .skill = skill };
    }
    if (std.ascii.eqlIgnoreCase(head, "skill")) {
        const skill_name = parts.next() orelse return .{ .unknown = trimmed };
        const skill = parseSkillName(std.mem.trim(u8, skill_name, " \t\r\n")) orelse return .{ .unknown = trimmed };
        return .{ .skill = skill };
    }
    if (std.ascii.eqlIgnoreCase(head, "memory")) return .memory;
    if (std.ascii.eqlIgnoreCase(head, "facts")) return .facts;
    if (std.ascii.eqlIgnoreCase(head, "needs")) return .needs;
    if (std.ascii.eqlIgnoreCase(head, "capabilities")) return .capabilities;
    if (std.ascii.eqlIgnoreCase(head, "senses")) return .senses;
    if (std.ascii.eqlIgnoreCase(head, "autonomy")) return .autonomy;
    if (std.ascii.eqlIgnoreCase(head, "focus")) return .focus;
    if (std.ascii.eqlIgnoreCase(head, "identity")) return .identity;
    if (std.ascii.eqlIgnoreCase(head, "processes")) return .processes;
    if (std.ascii.eqlIgnoreCase(head, "process")) {
        const goal_name = parts.next() orelse return .{ .unknown = trimmed };
        const goal_trimmed = std.mem.trim(u8, goal_name, " \t\r\n");
        if (goal_trimmed.len == 0) return .{ .unknown = trimmed };
        return .{ .process = goal_trimmed };
    }
    if (parseGroupName(head)) |group| return .{ .skills_group = group };
    if (parseSkillName(head)) |skill| return .{ .skill = skill };
    return .{ .unknown = trimmed };
}

pub fn appendConversationSummary(allocator: std.mem.Allocator, out: *std.ArrayList(u8), availability: Availability) !void {
    try out.appendSlice(allocator, "Current skill availability:\n");
    try out.appendSlice(allocator, "skill_library:\n");
    var callable_total: usize = 0;
    for (group_specs) |group| {
        var available: usize = 0;
        var total: usize = 0;
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(allocator);
        for (skills.registry) |entry| {
            if (entry.id == .unknown) continue;
            if (groupFor(entry.id) != group.id) continue;
            total += 1;
            if (!availability.isAvailable(availability.ctx, entry.id)) continue;
            available += 1;
            try names.append(allocator, entry.name);
        }
        if (total == 0) continue;
        callable_total += available;
        try out.print(allocator, "- {s} ({d}/{d}): ", .{ group.name, available, total });
        for (names.items, 0..) |name, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, name);
        }
        try out.print(allocator, " — {s}\n", .{group.summary});
    }
    try out.print(allocator, "callable_now: {d}\n", .{callable_total});
    try out.appendSlice(allocator, "Use introspect with query=skills, query=skills/<group>, or query=skill/<name> for full descriptions.\n");
}

pub fn appendSkillsTree(allocator: std.mem.Allocator, out: *std.ArrayList(u8), availability: Availability) !void {
    try out.appendSlice(allocator, "skill_library_tree:\n");
    for (group_specs) |group| {
        var available: usize = 0;
        var total: usize = 0;
        for (skills.registry) |entry| {
            if (entry.id == .unknown) continue;
            if (groupFor(entry.id) != group.id) continue;
            total += 1;
            if (availability.isAvailable(availability.ctx, entry.id)) available += 1;
        }
        if (total == 0) continue;
        try out.print(allocator, "- {s} ({d}/{d}): {s}\n", .{ group.name, available, total, group.summary });
    }
    try out.appendSlice(allocator, "Use query=skills/<group> or query=skill/<name> to drill down.\n");
}

pub fn appendGroupCatalog(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    group: SkillGroup,
    availability: Availability,
) !void {
    const spec = groupSpec(group);
    try out.print(allocator, "skill_group: {s}\n{s}\n", .{ spec.name, spec.summary });
    for (skills.registry) |entry| {
        if (entry.id == .unknown) continue;
        if (groupFor(entry.id) != group) continue;
        const available = availability.isAvailable(availability.ctx, entry.id);
        if (available) {
            try out.print(allocator, "- {s}: {s}\n", .{ entry.name, entry.description });
        } else {
            try out.print(allocator, "- {s}: unavailable\n", .{entry.name});
        }
    }
}

pub fn appendSkillDetail(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    id: SkillId,
    availability: Availability,
) !void {
    const entry = skills.spec(id) orelse {
        try out.print(allocator, "skill_detail: unknown skill {s}\n", .{@tagName(id)});
        return;
    };
    const group = groupSpec(groupFor(id));
    const available = availability.isAvailable(availability.ctx, id);
    try out.print(allocator, "skill_detail: {s}\ngroup: {s}\navailable: {any}\n{s}\n", .{
        entry.name,
        group.name,
        available,
        entry.description,
    });
    if (entry.failure_hint.len > 0) {
        try out.print(allocator, "failure_hint: {s}\n", .{entry.failure_hint});
    }
    if (entry.requires_senses.len > 0) {
        try out.appendSlice(allocator, "requires_senses:");
        for (entry.requires_senses) |sense| {
            try out.print(allocator, " {s}", .{@tagName(sense)});
        }
        try out.append(allocator, '\n');
    }
}

test "skill groups cover every registered skill" {
    for (skills.registry) |entry| {
        if (entry.id == .unknown) continue;
        _ = groupFor(entry.id);
    }
}

test "parseIntrospectQuery accepts tree drill-down paths" {
    try std.testing.expect(parseIntrospectQuery(null) == .overview);
    try std.testing.expect(parseIntrospectQuery("") == .overview);
    try std.testing.expect(parseIntrospectQuery("skills") == .skills_tree);
    switch (parseIntrospectQuery("skills/speech")) {
        .skills_group => |group| try std.testing.expectEqual(group, .speech),
        else => try std.testing.expect(false),
    }
    switch (parseIntrospectQuery("skill/say")) {
        .skill => |id| try std.testing.expectEqual(id, .say),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(parseIntrospectQuery("needs") == .needs);
    try std.testing.expect(parseIntrospectQuery("processes") == .processes);
    switch (parseIntrospectQuery("process/investigate_touch")) {
        .process => |goal| try std.testing.expectEqualStrings("investigate_touch", goal),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(parseIntrospectQuery("query=skills") == .skills_tree);
    try std.testing.expect(parseIntrospectQuery("query=needs") == .needs);
    switch (parseIntrospectQuery("not-a-topic")) {
        .unknown => |topic| try std.testing.expectEqualStrings("not-a-topic", topic),
        else => try std.testing.expect(false),
    }
}

test "conversation summary lists grouped callable skills" {
    const TestCtx = struct {
        fn available(_: *anyopaque, id: SkillId) bool {
            return switch (id) {
                .say, .get_time, .introspect => true,
                else => false,
            };
        }
    };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    var ctx: u8 = 0;
    try appendConversationSummary(std.testing.allocator, &out, .{
        .ctx = &ctx,
        .isAvailable = TestCtx.available,
    });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "skill_library:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "speech (") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "say") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "query=skill/") != null);
}
