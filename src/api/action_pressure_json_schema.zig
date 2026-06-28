/// JSON Schema fragments for action_pressure objects, compatible with OpenAI strict mode.
/// Every listed property must appear in `required`; unused fields use null.

const std = @import("std");

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

pub fn strictAutonomyTurnSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"action_pressures":{"type":"array","items":
    ++ strict_autonomy_item_schema ++
    \\},"salience":{"type":"string","enum":["low","medium","high"]},"reason":{"type":"string"}},"required":["action_pressures","salience","reason"]}
    ;
}

pub fn strictCompositionTurnSchema(allocator: std.mem.Allocator, max_items: usize, action_enum: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        \\{{"type":"object","additionalProperties":false,"properties":{{"action_pressures":{{"type":"array","maxItems":{d},"items":{{"type":"object","additionalProperties":false,"properties":{{"action":{{"type":"string","enum":{s}}},"origin":{{"type":["string","null"],"enum":["interaction","autonomy",null]}},"delay_ms":{{"type":["integer","null"]}},"scale":{{"type":["string","null"],"enum":["full","medium","tiny",null]}},"text":{{"type":["string","null"]}},"query":{{"type":["string","null"]}},"memory_id":{{"type":["string","null"]}},"schedule":{{"type":["string","null"]}},"heat_bias":{{"type":["string","null"],"enum":["low","mixed","high",null]}},"eyes":{{"type":["string","null"]}},"mouth":{{"type":["string","null"]}},"duration_ms":{{"type":["integer","null"]}},"tags":{{"type":"array","items":{{"type":"string"}}}}}},"required":["action","origin","delay_ms","scale","text","query","memory_id","schedule","heat_bias","eyes","mouth","duration_ms","tags"]}}}},"reason":{{"type":"string"}}}},"required":["action_pressures","reason"]}}
        ,
        .{ max_items, action_enum },
    );
}
