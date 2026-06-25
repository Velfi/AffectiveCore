const std = @import("std");

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: std.json.Value,
};

pub fn tools(allocator: std.mem.Allocator) ![]const Tool {
    const specs = [_]struct { name: []const u8, description: []const u8, schema_json: []const u8 }{
        .{ .name = "brain_inspect", .description = "Return safe metadata for the active brain container without exposing memory contents.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "conversation_turn", .description = "Run a real text conversation turn through the brain, mutating memory, appraisals, and summaries.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "chat_dry_run_prompt", .description = "Build the full conversation prompt for a user request without sending it to any LLM or mutating memory.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "memory_index", .description = "Return bounded memory counts and available tags.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "recall_memory", .description = "Recall matching memories by query and/or tags. Matching memories gain access count and score.", .schema_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}" },
        .{ .name = "remember_memory", .description = "Create a short-term tagged memory.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}" },
        .{ .name = "forget_memory", .description = "Delete a memory by memory_id.", .schema_json = "{\"type\":\"object\",\"required\":[\"memory_id\"],\"properties\":{\"memory_id\":{\"type\":\"string\"}}}" },
        .{ .name = "sweep_memory", .description = "Decay short-term memory scores and remove low-scoring short-term memories.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "introspect", .description = "Return a compact reflection about the brain's memory, senses, reminders, and tools.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "inner_state", .description = "Return bounded inner-state counts, recent appraisal, and dream/consolidation activity.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "appraise_event", .description = "Create an impression and structured appraisal for an event.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}" },
        .{ .name = "feel_about", .description = "Ask the brain for a structured feeling/appraisal about a topic.", .schema_json = "{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{\"query\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}" },
        .{ .name = "choose_attention", .description = "Choose what deserves attention next from appraisals and memory salience.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "ask_for_help", .description = "Record and surface a need for human help.", .schema_json = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "consolidate_memory", .description = "Run offline memory consolidation.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "dream", .description = "Randomly connect memories and recent conversation summaries.", .schema_json = "{\"type\":\"object\",\"properties\":{\"heat_bias\":{\"type\":\"string\",\"enum\":[\"low\",\"mixed\",\"high\",\"grounded\",\"surreal\"]},\"text\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}" },
        .{ .name = "set_reminder", .description = "Append a reminder or wait timer to the brain's Markdown maintenance schedule. Relative schedules such as `in 5 minutes` are stored as one-shot timers.", .schema_json = "{\"type\":\"object\",\"required\":[\"schedule\",\"text\"],\"properties\":{\"schedule\":{\"type\":\"string\"},\"text\":{\"type\":\"string\"}}}" },
        .{ .name = "list_reminders", .description = "Return the raw Markdown maintenance schedule.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "update_face_picture", .description = "Update an existing person's face recognition reference picture and embedding cache. Provide person_id or unique name plus image_path.", .schema_json = "{\"type\":\"object\",\"required\":[\"image_path\"],\"properties\":{\"person_id\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"},\"image_path\":{\"type\":\"string\"},\"keep_existing\":{\"type\":\"boolean\"}}}" },
        .{ .name = "graph_type_create", .description = "Create or fetch a validated dynamic graph node or edge type.", .schema_json = "{\"type\":\"object\",\"required\":[\"kind\",\"name\",\"description\"],\"properties\":{\"kind\":{\"type\":\"string\",\"enum\":[\"node\",\"edge\"]},\"name\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"created_by\":{\"type\":\"string\"},\"confidence\":{\"type\":\"number\"}}}" },
        .{ .name = "graph_node_create", .description = "Create or update a graph node using an existing node type.", .schema_json = "{\"type\":\"object\",\"required\":[\"type_name\",\"node_id\",\"label\"],\"properties\":{\"type_name\":{\"type\":\"string\"},\"node_id\":{\"type\":\"string\"},\"label\":{\"type\":\"string\"}}}" },
        .{ .name = "graph_edge_upsert", .description = "Create or strengthen a graph relationship edge using an existing edge type.", .schema_json = "{\"type\":\"object\",\"required\":[\"source_node_id\",\"target_node_id\",\"type_name\",\"evidence\"],\"properties\":{\"source_node_id\":{\"type\":\"string\"},\"target_node_id\":{\"type\":\"string\"},\"type_name\":{\"type\":\"string\"},\"strength\":{\"type\":\"number\"},\"confidence\":{\"type\":\"number\"},\"salience\":{\"type\":\"number\"},\"evidence\":{\"type\":\"string\"},\"created_by\":{\"type\":\"string\"}}}" },
        .{ .name = "graph_entity_context", .description = "Return active graph edges touching a node.", .schema_json = "{\"type\":\"object\",\"required\":[\"node_id\"],\"properties\":{\"node_id\":{\"type\":\"string\"}}}" },
        .{ .name = "graph_summary", .description = "Return a compact relationship graph summary.", .schema_json = "{\"type\":\"object\",\"properties\":{}}" },
        .{ .name = "graph_edge_forget", .description = "Deactivate a graph edge by edge_id.", .schema_json = "{\"type\":\"object\",\"required\":[\"edge_id\"],\"properties\":{\"edge_id\":{\"type\":\"string\"},\"created_by\":{\"type\":\"string\"}}}" },
    };
    const out = try allocator.alloc(Tool, specs.len);
    for (specs, 0..) |spec, i| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, spec.schema_json, .{});
        out[i] = .{ .name = spec.name, .description = spec.description, .inputSchema = parsed };
    }
    return out;
}

pub fn toolNames() []const []const u8 {
    return &.{ "brain_inspect", "conversation_turn", "chat_dry_run_prompt", "memory_index", "recall_memory", "remember_memory", "forget_memory", "sweep_memory", "introspect", "inner_state", "appraise_event", "feel_about", "choose_attention", "ask_for_help", "consolidate_memory", "dream", "set_reminder", "list_reminders", "update_face_picture", "graph_type_create", "graph_node_create", "graph_edge_upsert", "graph_entity_context", "graph_summary", "graph_edge_forget" };
}
