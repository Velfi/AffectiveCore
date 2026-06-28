const std = @import("std");

pub const CognitiveEnumDiagnostic = struct {
    path: []const u8,
    value: []const u8,
    allowed: []const u8,

    pub fn deinit(self: CognitiveEnumDiagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.value);
        allocator.free(self.allowed);
    }
};

const relationship_status_tags = [_][]const u8{ "unknown", "visitor", "friend", "creator", "forgotten" };
const greeting_style_tags = [_][]const u8{ "formal", "warm", "playful", "quiet" };
const embedding_source_tags = [_][]const u8{ "enrollment", "confirmed_sighting", "manual_merge", "local_reference" };
const trace_source_tags = [_][]const u8{ "human", "brain", "environment", "model", "maintenance", "autonomy", "memory", "visual", "dream", "capability" };
const trace_kind_tags = [_][]const u8{ "perception", "utterance", "action", "capability_result", "failure", "memory_update", "appraisal", "dream", "self_definition", "reminder", "summary", "thought", "belief_evidence" };
const trace_scope_tags = [_][]const u8{ "short_term", "long_term" };
const cognitive_status_tags = [_][]const u8{ "active", "doubted", "invalidated", "pending_deletion" };
const artifact_kind_tags = [_][]const u8{ "image", "audio", "video", "text", "embedding", "other" };
const cognitive_retention_tags = [_][]const u8{ "ephemeral", "episode", "durable", "disposition", "discard" };

pub fn traceInvalidCognitiveEnumTag(allocator: std.mem.Allocator, memory_path: []const u8, bytes: []const u8) void {
    const diagnostic = cognitiveEnumDiagnosticAlloc(allocator, bytes) catch |diag_err| {
        std.debug.print(
            "TRACE stage=storage.cognitive.invalid_enum diagnostic_error={s} memory_path=\"{s}\"\n",
            .{ @errorName(diag_err), memory_path },
        );
        return;
    };
    if (diagnostic) |diag| {
        defer diag.deinit(allocator);
        std.debug.print(
            "TRACE stage=storage.cognitive.invalid_enum memory_path=\"{s}\" path={s} value=\"{s}\" allowed=\"{s}\"\n",
            .{ memory_path, diag.path, diag.value, diag.allowed },
        );
    } else {
        std.debug.print(
            "TRACE stage=storage.cognitive.invalid_enum memory_path=\"{s}\" path=unknown value=unknown allowed=unknown\n",
            .{memory_path},
        );
    }
}

pub fn cognitiveEnumDiagnosticAlloc(allocator: std.mem.Allocator, bytes: []const u8) !?CognitiveEnumDiagnostic {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    if (try traceArrayEnumDiagnostic(allocator, parsed.value, "traces")) |diag| return diag;
    if (try lifecycleArrayEnumDiagnostic(allocator, parsed.value, "beliefs")) |diag| return diag;
    if (try subjectArrayEnumDiagnostic(allocator, parsed.value)) |diag| return diag;
    if (try artifactArrayEnumDiagnostic(allocator, parsed.value)) |diag| return diag;
    return null;
}

fn traceArrayEnumDiagnostic(allocator: std.mem.Allocator, root: std.json.Value, field: []const u8) !?CognitiveEnumDiagnostic {
    const value = root.object.get(field) orelse return null;
    if (value != .array) return null;
    for (value.array.items, 0..) |item, i| {
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "{s}[{d}].source", .{ field, i }), "source", &trace_source_tags)) |diag| return diag;
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "{s}[{d}].kind", .{ field, i }), "kind", &trace_kind_tags)) |diag| return diag;
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "{s}[{d}].scope", .{ field, i }), "scope", &trace_scope_tags)) |diag| return diag;
        if (try lifecycleDiagnostic(allocator, item, field, i)) |diag| return diag;
    }
    return null;
}

fn lifecycleArrayEnumDiagnostic(allocator: std.mem.Allocator, root: std.json.Value, field: []const u8) !?CognitiveEnumDiagnostic {
    const value = root.object.get(field) orelse return null;
    if (value != .array) return null;
    for (value.array.items, 0..) |item, i| {
        if (try lifecycleDiagnostic(allocator, item, field, i)) |diag| return diag;
    }
    return null;
}

fn subjectArrayEnumDiagnostic(allocator: std.mem.Allocator, root: std.json.Value) !?CognitiveEnumDiagnostic {
    const value = root.object.get("subjects") orelse return null;
    if (value != .array) return null;
    for (value.array.items, 0..) |item, i| {
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "subjects[{d}].relationship_status", .{i}), "relationship_status", &relationship_status_tags)) |diag| return diag;
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "subjects[{d}].greeting_style", .{i}), "greeting_style", &greeting_style_tags)) |diag| return diag;
        if (try lifecycleDiagnostic(allocator, item, "subjects", i)) |diag| return diag;
        const embeddings = objectField(item, "embeddings") orelse continue;
        if (embeddings != .array) continue;
        for (embeddings.array.items, 0..) |embedding, embedding_index| {
            if (try enumFieldDiagnostic(allocator, embedding, try std.fmt.allocPrint(allocator, "subjects[{d}].embeddings[{d}].source", .{ i, embedding_index }), "source", &embedding_source_tags)) |diag| return diag;
        }
    }
    return null;
}

fn artifactArrayEnumDiagnostic(allocator: std.mem.Allocator, root: std.json.Value) !?CognitiveEnumDiagnostic {
    const value = root.object.get("artifacts") orelse return null;
    if (value != .array) return null;
    for (value.array.items, 0..) |item, i| {
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "artifacts[{d}].kind", .{i}), "kind", &artifact_kind_tags)) |diag| return diag;
        if (try enumFieldDiagnostic(allocator, item, try std.fmt.allocPrint(allocator, "artifacts[{d}].retention", .{i}), "retention", &cognitive_retention_tags)) |diag| return diag;
        if (try lifecycleDiagnostic(allocator, item, "artifacts", i)) |diag| return diag;
    }
    return null;
}

fn lifecycleDiagnostic(allocator: std.mem.Allocator, item: std.json.Value, field: []const u8, index: usize) !?CognitiveEnumDiagnostic {
    const lifecycle = objectField(item, "lifecycle") orelse return null;
    return enumFieldDiagnostic(
        allocator,
        lifecycle,
        try std.fmt.allocPrint(allocator, "{s}[{d}].lifecycle.status", .{ field, index }),
        "status",
        &cognitive_status_tags,
    );
}

fn enumFieldDiagnostic(allocator: std.mem.Allocator, item: std.json.Value, owned_path: []const u8, field: []const u8, allowed: []const []const u8) !?CognitiveEnumDiagnostic {
    defer allocator.free(owned_path);
    const value = objectField(item, field) orelse return null;
    if (value != .string) return null;
    if (enumTagAllowed(value.string, allowed)) return null;
    return .{
        .path = try allocator.dupe(u8, owned_path),
        .value = try allocator.dupe(u8, value.string),
        .allowed = try allowedListAlloc(allocator, allowed),
    };
}

fn objectField(value: std.json.Value, field: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(field);
}

fn enumTagAllowed(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |tag| {
        if (std.mem.eql(u8, value, tag)) return true;
    }
    return false;
}

fn allowedListAlloc(allocator: std.mem.Allocator, allowed: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (allowed, 0..) |tag, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, tag);
    }
    return out.toOwnedSlice(allocator);
}
