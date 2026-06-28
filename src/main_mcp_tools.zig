const std = @import("std");

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: std.json.Value,
};

pub fn tools(allocator: std.mem.Allocator) ![]const Tool {
    const specs = [_]struct { name: []const u8, description: []const u8, schema_json: []const u8 }{
        .{ .name = "connect", .description = "Return safe metadata for the active Brain connection.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "host_attach", .description = "Attach or update the current host binding for this Brain.", .schema_json = "{\"type\":\"object\",\"required\":[\"host_id\"],\"properties\":{\"host_id\":{\"type\":\"string\"},\"platform\":{\"type\":\"string\"},\"app_version\":{\"type\":\"string\"},\"permissions\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"capability_ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"provider_availability\":{\"type\":\"string\"},\"sensor_quality\":{\"type\":\"string\"},\"local_policy\":{\"type\":\"string\"}}}" },
        .{ .name = "host_capability_manifest", .description = "Record host capability IDs into the Brain capability registry.", .schema_json = "{\"type\":\"object\",\"properties\":{\"host_id\":{\"type\":\"string\"},\"capability_ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}" },
        .{ .name = "send_experience_event", .description = "Append a canonical ExperienceEvent to the Brain event log.", .schema_json = "{\"type\":\"object\",\"required\":[\"kind\",\"payload\"],\"properties\":{\"host_id\":{\"type\":\"string\"},\"source\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\"},\"payload\":{\"type\":\"string\"},\"salience\":{\"type\":\"number\"},\"confidence\":{\"type\":\"number\"},\"valence\":{\"type\":\"number\"},\"arousal\":{\"type\":\"number\"},\"uncertainty\":{\"type\":\"number\"},\"retention\":{\"type\":\"string\"},\"visibility\":{\"type\":\"string\"}}}" },
        .{ .name = "user_text", .description = "Deliver typed user text through the Brain ingest.user_text pipeline.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\"},\"request_id\":{\"type\":\"string\",\"description\":\"Optional correlation id; echoed as dispatch_id in the outcome and TRACE logs.\"}}}" },
        .{ .name = "request_dream_time", .description = "Enter Dream Time and deliver any resulting Brain-owned mailbox item.", .schema_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "brain_mode", .description = "Return the current Brain mode.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "read_models_snapshot", .description = "Return compact read models derived from Brain event and memory state.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "set_runtime_option", .description = "Update persisted runtime or LLM quality preferences for the active brain.", .schema_json = "{\"type\":\"object\",\"properties\":{\"llm_quality\":{\"type\":\"string\",\"enum\":[\"frugal\",\"auto\",\"best\"]},\"reasoning_effort\":{\"type\":\"string\"},\"psyche_reasoning_effort\":{\"type\":\"string\"},\"ai_mode\":{\"type\":\"string\"},\"capacity\":{\"type\":\"object\",\"properties\":{\"activity_stack_max\":{\"type\":\"integer\"},\"focus_slots_max\":{\"type\":\"integer\"},\"memory_selected_max\":{\"type\":\"integer\"},\"memory_prefilter_max\":{\"type\":\"integer\"},\"candidate_actions_max\":{\"type\":\"integer\"},\"open_loops_soft_max\":{\"type\":\"integer\"},\"conversation_summaries_in_context_max\":{\"type\":\"integer\"},\"chat_context_tokens_max\":{\"type\":\"integer\"},\"dispatch_envelope_bytes_max\":{\"type\":\"integer\"},\"dispatch_event_count_max\":{\"type\":\"integer\"}}}}}" },
        .{ .name = "mailbox_list", .description = "List Brain-owned mailbox items.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "mailbox_mark_read", .description = "Record that a mailbox item was read by the host.", .schema_json = "{\"type\":\"object\",\"required\":[\"mailbox_id\"],\"properties\":{\"mailbox_id\":{\"type\":\"string\"}}}" },
        .{ .name = "capability_status", .description = "Record or update status for a host capability.", .schema_json = "{\"type\":\"object\",\"required\":[\"capability_id\"],\"properties\":{\"capability_id\":{\"type\":\"string\"},\"host_id\":{\"type\":\"string\"},\"request_id\":{\"type\":\"string\"},\"permission\":{\"type\":\"string\"},\"availability\":{\"type\":\"string\"},\"quality\":{\"type\":\"number\"},\"reliability\":{\"type\":\"number\"},\"cost\":{\"type\":\"number\"},\"latency_ms\":{\"type\":\"number\"},\"risk\":{\"type\":\"number\"},\"unavailable_reason\":{\"type\":\"string\"}}}" },
        .{ .name = "export_brain", .description = "Export Brain-owned state to a portable archive without host secrets.", .schema_json = "{\"type\":\"object\",\"required\":[\"brain_file_path\"],\"properties\":{\"brain_file_path\":{\"type\":\"string\"}}}" },
        .{ .name = "import_brain", .description = "Import a portable Brain archive and record host binding changes.", .schema_json = "{\"type\":\"object\",\"required\":[\"brain_file_path\",\"brain_root\"],\"properties\":{\"brain_file_path\":{\"type\":\"string\"},\"brain_id\":{\"type\":\"string\"},\"brain_root\":{\"type\":\"string\"},\"host_id\":{\"type\":\"string\"}}}" },
    };
    const out = try allocator.alloc(Tool, specs.len);
    for (specs, 0..) |spec, i| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, spec.schema_json, .{});
        out[i] = .{ .name = spec.name, .description = spec.description, .inputSchema = parsed };
    }
    return out;
}

pub fn toolNames() []const []const u8 {
    return &.{ "connect", "host_attach", "host_capability_manifest", "send_experience_event", "user_text", "request_dream_time", "brain_mode", "read_models_snapshot", "set_runtime_option", "mailbox_list", "mailbox_mark_read", "capability_status", "export_brain", "import_brain" };
}

test "mcp tools expose typed brain operations" {
    const names = toolNames();
    const required = [_][]const u8{
        "connect",
        "host_attach",
        "host_capability_manifest",
        "send_experience_event",
        "user_text",
        "request_dream_time",
        "brain_mode",
        "read_models_snapshot",
        "set_runtime_option",
        "mailbox_list",
        "mailbox_mark_read",
        "capability_status",
        "export_brain",
        "import_brain",
    };
    for (required) |name| {
        try std.testing.expect(containsName(names, name));
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const listed = try tools(arena.allocator());
    try std.testing.expectEqual(required.len, listed.len);
    for (listed) |tool| {
        try std.testing.expect(containsName(&required, tool.name));
    }
}

fn containsName(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}
