/// JSON Schema fragments for action_pressure objects, compatible with OpenAI strict mode.
/// Every listed property must appear in `required`; unused fields use null.

const std = @import("std");
const facial_expression = @import("../core/port_facial_expression.zig");

pub const strict_autonomy_item_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"action":{"type":"string"},"origin":{"type":["string","null"],"enum":["interaction","autonomy",null]},"delay_ms":{"type":["integer","null"]},"scale":{"type":["string","null"],"enum":["full","medium","tiny",null]},"text":{"type":["string","null"]},"query":{"type":["string","null"]},"memory_id":{"type":["string","null"]},"schedule":{"type":["string","null"]},"heat_bias":{"type":["string","null"],"enum":["low","mixed","high",null]},"eyes":{"type":["string","null"]},"mouth":{"type":["string","null"]},"duration_ms":{"type":["integer","null"]},"tags":{"type":"array","items":{"type":"string"}}},"required":["action","origin","delay_ms","scale","text","query","memory_id","schedule","heat_bias","eyes","mouth","duration_ms","tags"]}
;

pub const strict_chat_item_schema =
    \\{"type":"object","additionalProperties":false,"properties":{"action":{"type":"string"},"origin":{"type":["string","null"],"enum":["interaction","autonomy",null]},"delay_ms":{"type":["integer","null"]},"scale":{"type":["string","null"],"enum":["full","medium","tiny",null]},"text":{"type":["string","null"]},"query":{"type":["string","null"]},"memory_id":{"type":["string","null"]},"person_id":{"type":["string","null"]},"name":{"type":["string","null"]},"image_path":{"type":["string","null"]},"schedule":{"type":["string","null"]},"to":{"type":["string","null"]},"subject":{"type":["string","null"]},"heat_bias":{"type":["string","null"]},"eyes":{"type":["string","null"]},"mouth":{"type":["string","null"]},"duration_ms":{"type":["integer","null"]},"keep_existing":{"type":["boolean","null"]},"tags":{"type":"array","items":{"type":"string"}}},"required":["action","origin","delay_ms","scale","text","query","memory_id","person_id","name","image_path","schedule","to","subject","heat_bias","eyes","mouth","duration_ms","keep_existing","tags"]}
;

pub fn strictChatTurnSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"action_pressures":{"type":"array","items":
    ++ strict_chat_item_schema ++
    \\},"user_summary":{"type":"string"},"brain_summary":{"type":"string"},"reasoning_effort":{"type":["string","null"],"enum":["low","medium","high",null]},"effort_tier":{"type":["string","null"],"enum":["basic","standard","complex",null]},"turn_complete":{"type":["boolean","null"]}},"required":["action_pressures","user_summary","brain_summary","reasoning_effort","effort_tier","turn_complete"]}
    ;
}

pub fn strictChatTurnSchemaAlloc(allocator: std.mem.Allocator, catalog: facial_expression.Catalog) ![]const u8 {
    const item_schema = try strictChatItemSchemaAlloc(allocator, catalog);
    defer allocator.free(item_schema);
    return std.fmt.allocPrint(
        allocator,
        \\{{"type":"object","additionalProperties":false,"properties":{{"action_pressures":{{"type":"array","items":{s}}},"user_summary":{{"type":"string"}},"brain_summary":{{"type":"string"}},"reasoning_effort":{{"type":["string","null"],"enum":["low","medium","high",null]}},"effort_tier":{{"type":["string","null"],"enum":["basic","standard","complex",null]}},"turn_complete":{{"type":["boolean","null"]}}}},"required":["action_pressures","user_summary","brain_summary","reasoning_effort","effort_tier","turn_complete"]}}
        ,
        .{item_schema},
    );
}

fn strictChatItemSchemaAlloc(allocator: std.mem.Allocator, catalog: facial_expression.Catalog) ![]const u8 {
    const eyes_enum = try nullableEnumProperty(allocator, "eyes", catalog.eye_names);
    defer allocator.free(eyes_enum);
    const mouth_enum = try nullableEnumProperty(allocator, "mouth", catalog.mouth_names);
    defer allocator.free(mouth_enum);
    return std.fmt.allocPrint(
        allocator,
        \\{{"type":"object","additionalProperties":false,"properties":{{"action":{{"type":"string"}},"origin":{{"type":["string","null"],"enum":["interaction","autonomy",null]}},"delay_ms":{{"type":["integer","null"]}},"scale":{{"type":["string","null"],"enum":["full","medium","tiny",null]}},"text":{{"type":["string","null"]}},"query":{{"type":["string","null"]}},"memory_id":{{"type":["string","null"]}},"person_id":{{"type":["string","null"]}},"name":{{"type":["string","null"]}},"image_path":{{"type":["string","null"]}},"schedule":{{"type":["string","null"]}},"to":{{"type":["string","null"]}},"subject":{{"type":["string","null"]}},"heat_bias":{{"type":["string","null"]}},{s},{s},"duration_ms":{{"type":["integer","null"]}},"keep_existing":{{"type":["boolean","null"]}},"tags":{{"type":"array","items":{{"type":"string"}}}}}},"required":["action","origin","delay_ms","scale","text","query","memory_id","person_id","name","image_path","schedule","to","subject","heat_bias","eyes","mouth","duration_ms","keep_existing","tags"]}}
        ,
        .{ eyes_enum, mouth_enum },
    );
}

fn nullableEnumProperty(allocator: std.mem.Allocator, key: []const u8, names: []const []const u8) ![]const u8 {
    var enum_values = std.ArrayList(u8).empty;
    defer enum_values.deinit(allocator);
    for (names) |name| {
        if (enum_values.items.len > 0) try enum_values.append(allocator, ',');
        const quoted = try std.json.Stringify.valueAlloc(allocator, name, .{});
        defer allocator.free(quoted);
        try enum_values.appendSlice(allocator, quoted);
    }
    if (enum_values.items.len > 0) try enum_values.append(allocator, ',');
    try enum_values.appendSlice(allocator, "null");
    return std.fmt.allocPrint(
        allocator,
        "\"{s}\":{{\"type\":[\"string\",\"null\"],\"enum\":[{s}]}}",
        .{ key, enum_values.items },
    );
}

pub fn strictAutonomyTurnSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"salience":{"type":"string","enum":["low","medium","high"]},"reason":{"type":"string"},"action_pressures":{"type":"array","items":
    ++ strict_autonomy_item_schema ++
    \\}},"required":["salience","reason","action_pressures"]}
    ;
}

pub fn strictAutonomyTurnSchemaAlloc(allocator: std.mem.Allocator, catalog: facial_expression.Catalog) ![]const u8 {
    const item_schema = try strictAutonomyItemSchemaAlloc(allocator, catalog);
    defer allocator.free(item_schema);
    return std.fmt.allocPrint(
        allocator,
        \\{{"type":"object","additionalProperties":false,"properties":{{"salience":{{"type":"string","enum":["low","medium","high"]}},"reason":{{"type":"string"}},"action_pressures":{{"type":"array","items":{s}}}}},"required":["salience","reason","action_pressures"]}}
        ,
        .{item_schema},
    );
}

fn strictAutonomyItemSchemaAlloc(allocator: std.mem.Allocator, catalog: facial_expression.Catalog) ![]const u8 {
    const eyes_enum = try nullableEnumProperty(allocator, "eyes", catalog.eye_names);
    defer allocator.free(eyes_enum);
    const mouth_enum = try nullableEnumProperty(allocator, "mouth", catalog.mouth_names);
    defer allocator.free(mouth_enum);
    return std.fmt.allocPrint(
        allocator,
        \\{{"type":"object","additionalProperties":false,"properties":{{"action":{{"type":"string"}},"origin":{{"type":["string","null"],"enum":["interaction","autonomy",null]}},"delay_ms":{{"type":["integer","null"]}},"scale":{{"type":["string","null"],"enum":["full","medium","tiny",null]}},"text":{{"type":["string","null"]}},"query":{{"type":["string","null"]}},"memory_id":{{"type":["string","null"]}},"schedule":{{"type":["string","null"]}},"heat_bias":{{"type":["string","null"],"enum":["low","mixed","high",null]}},{s},{s},"duration_ms":{{"type":["integer","null"]}},"tags":{{"type":"array","items":{{"type":"string"}}}}}},"required":["action","origin","delay_ms","scale","text","query","memory_id","schedule","heat_bias","eyes","mouth","duration_ms","tags"]}}
        ,
        .{ eyes_enum, mouth_enum },
    );
}

pub fn strictCompositionTurnSchema(allocator: std.mem.Allocator, action_enum: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        \\{{"type":"object","additionalProperties":false,"properties":{{"action_pressures":{{"type":"array","items":{{"type":"object","additionalProperties":false,"properties":{{"action":{{"type":"string","enum":{s}}},"step_kind":{{"type":["string","null"],"enum":["sync_capability","async_host_pull","wait_timer","wait_stimulus","respond",null]}},"origin":{{"type":["string","null"],"enum":["interaction","autonomy",null]}},"delay_ms":{{"type":["integer","null"]}},"scale":{{"type":["string","null"],"enum":["full","medium","tiny",null]}},"text":{{"type":["string","null"]}},"query":{{"type":["string","null"]}},"memory_id":{{"type":["string","null"]}},"schedule":{{"type":["string","null"]}},"heat_bias":{{"type":["string","null"],"enum":["low","mixed","high",null]}},"eyes":{{"type":["string","null"]}},"mouth":{{"type":["string","null"]}},"duration_ms":{{"type":["integer","null"]}},"tags":{{"type":"array","items":{{"type":"string"}}}}}},"required":["action","step_kind","origin","delay_ms","scale","text","query","memory_id","schedule","heat_bias","eyes","mouth","duration_ms","tags"]}}}},"reason":{{"type":"string"}}}},"required":["action_pressures","reason"]}}
        ,
        .{action_enum},
    );
}

test "strict autonomy schema constrains eyes and mouth to avatar catalog" {
    const catalog = facial_expression.Catalog{
        .eye_names = &[_][]const u8{ "bright_eyes" },
        .mouth_names = &[_][]const u8{ "small_smile", "smirk" },
    };
    const schema = try strictAutonomyTurnSchemaAlloc(std.testing.allocator, catalog);
    defer std.testing.allocator.free(schema);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"bright_eyes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"small_smile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"unfocused\"") == null);
}

test "strict chat schema constrains eyes and mouth to avatar catalog" {
    const catalog = facial_expression.Catalog{
        .eye_names = &[_][]const u8{ "bright_eyes" },
        .mouth_names = &[_][]const u8{ "small_smile", "smirk" },
    };
    const schema = try strictChatTurnSchemaAlloc(std.testing.allocator, catalog);
    defer std.testing.allocator.free(schema);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"bright_eyes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"small_smile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"smirk\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"unfocused\"") == null);
}
