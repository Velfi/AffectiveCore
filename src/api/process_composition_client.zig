const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat = @import("chat_client.zig");
const skills = @import("skills.zig");
const process_goal_port = @import("../core/port_process_goal.zig");
const llm_routing = @import("../core/llm_routing.zig");
const capability_registry = @import("../core/capability_registry.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");
const action_pressure_json_schema = @import("action_pressure_json_schema.zig");

pub const ComposeMode = process_goal_port.ComposeMode;
pub const ProcessComposition = process_goal_port.ProcessComposition;
pub const ProcessComposer = process_goal_port.ProcessComposer;
pub const ScriptedProcessComposer = process_goal_port.ScriptedProcessComposer;
pub const max_composed_steps = process_goal_port.max_composed_steps;
pub const isForbiddenAutonomyAction = process_goal_port.isForbiddenAutonomyAction;

pub const RandomProviderProcessComposer = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?chat.ReasoningEffort,
    ) RandomProviderProcessComposer {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn composer(self: *RandomProviderProcessComposer) ProcessComposer {
        return .{ .ctx = self, .composeFn = compose };
    }

    fn compose(ctx: *anyopaque, allocator: std.mem.Allocator, goal: []const u8, context: []const u8, mode: ComposeMode) !ProcessComposition {
        const self: *RandomProviderProcessComposer = @ptrCast(@alignCast(ctx));
        const system_prompt = try compositionSystemPrompt(allocator, mode);
        defer allocator.free(system_prompt);
        const user_prompt = try buildUserPrompt(allocator, goal, context);
        defer allocator.free(user_prompt);
        const json_schema = try compositionJsonSchema(allocator, mode);
        defer allocator.free(json_schema);
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "process_composition",
            .system_prompt = system_prompt,
            .user_prompt = user_prompt,
            .temperature = 0.2,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = json_schema,
            .response_validator = validateCompositionResponse(mode),
            .bad_response_logger = reportCompositionParseError,
        });
        return parseProcessComposition(allocator, content, mode);
    }
};

fn compositionSystemPrompt(allocator: std.mem.Allocator, mode: ComposeMode) ![]const u8 {
    const allowed = switch (mode) {
        .autonomy => try skills.autonomySkillNames(allocator),
        .interaction => try skills.interactionSkillNames(allocator),
    };
    defer allocator.free(allowed);
    const origin_rule = switch (mode) {
        .autonomy => "Set origin to autonomy for every step.",
        .interaction => "Set origin to interaction for every step.",
    };
    return std.fmt.allocPrint(
        allocator,
        "You expand a process goal into an ordered chain of registered capability actions.\n" ++
            "Return exactly one JSON object with keys action_pressures and reason.\n" ++
            "action_pressures must be an ordered array with at most {d} steps.\n" ++
            "Each action_pressure requires action; include only fields the step uses—omit unused keys (never null placeholders).\n" ++
            "Allowed capability actions: {s}.\n" ++
            "Use only listed actions. Never invent new action names.\n" ++
            "Process goals are inputs describing intent; do not put process goal names in action fields.\n" ++
            "{s}\n" ++
            "Use delay_ms for sequencing when order matters.\n" ++
            "Include tags only when non-empty.\n" ++
            "Return only JSON.\n" ++
            "Do not wrap the JSON in Markdown or code fences.",
        .{ max_composed_steps, allowed, origin_rule },
    );
}

fn buildUserPrompt(allocator: std.mem.Allocator, goal: []const u8, context: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "process_goal:\n{s}\n\ncontext:\n{s}",
        .{ goal, context },
    );
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const goal = "investigate_unusual_touch";
    const context =
        \\autonomy_mode: limited
        \\recent_touch: short tap on head
        \\senses: no camera available
        \\id: curious about touch source
    ;
    const modes = [_]ComposeMode{ .autonomy, .interaction };
    var out = try allocator.alloc(llm_tester_scenario.Scenario, modes.len);
    for (modes, 0..) |mode, i| {
        const system_prompt = try compositionSystemPrompt(allocator, mode);
        const user_prompt = try buildUserPrompt(allocator, goal, context);
        const json_schema = try compositionJsonSchema(allocator, mode);
        const id = switch (mode) {
            .autonomy => "process_composition_autonomy",
            .interaction => "process_composition_interaction",
        };
        const label = switch (mode) {
            .autonomy => "Expand process goal into autonomy action chain",
            .interaction => "Expand process goal into interaction action chain",
        };
        const description = switch (mode) {
            .autonomy => "Expands a touch-investigation goal into an ordered autonomy action chain the robot can execute without user interaction.",
            .interaction => "Expands the same goal into an interaction action chain that may involve speech or other user-visible steps.",
        };
        out[i] = try llm_tester_scenario.Scenario.init(
            allocator,
            id,
            label,
            description,
            "process_composition",
            system_prompt,
            user_prompt,
            .json_object,
            json_schema,
            512,
            0.2,
        );
    }
    return out;
}

fn compositionJsonSchema(allocator: std.mem.Allocator, mode: ComposeMode) ![]const u8 {
    const action_enum = switch (mode) {
        .autonomy => try skills.autonomyActionEnumJson(allocator),
        .interaction => try skills.interactionActionEnumJson(allocator),
    };
    defer allocator.free(action_enum);
    return action_pressure_json_schema.strictCompositionTurnSchema(allocator, max_composed_steps, action_enum);
}

fn validateCompositionResponse(mode: ComposeMode) *const fn (std.mem.Allocator, []const u8) anyerror!void {
    return switch (mode) {
        .autonomy => validateAutonomyComposition,
        .interaction => validateInteractionComposition,
    };
}

fn validateAutonomyComposition(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseProcessComposition(allocator, content, .autonomy);
}

fn validateInteractionComposition(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseProcessComposition(allocator, content, .interaction);
}

pub fn parseProcessComposition(allocator: std.mem.Allocator, body: []const u8, mode: ComposeMode) !ProcessComposition {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidProcessCompositionJson;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidProcessCompositionJson,
    };
    const pressure_values = try requiredArrayField(object, "action_pressures");
    if (pressure_values.items.len == 0) return error.EmptyProcessComposition;
    if (pressure_values.items.len > max_composed_steps) return error.TooManyProcessCompositionSteps;
    const reason = try requiredStringField(object, "reason");
    var action_pressures = try allocator.alloc(chat.ActionProposal, pressure_values.items.len);
    for (pressure_values.items, 0..) |value, i| {
        const pressure_object = switch (value) {
            .object => |child| child,
            else => return error.InvalidProcessCompositionField,
        };
        action_pressures[i] = try parseCompositionPressure(allocator, pressure_object, mode);
    }
    return .{
        .action_pressures = action_pressures,
        .reason = try allocator.dupe(u8, reason),
    };
}

fn parseCompositionPressure(allocator: std.mem.Allocator, pressure_object: std.json.ObjectMap, mode: ComposeMode) !chat.ActionProposal {
    const action_text = try requiredStringField(pressure_object, "action");
    const action = capability_registry.actionForCapabilityId(action_text) orelse return error.InvalidProcessCompositionAction;
    if (action == .unknown) return error.InvalidProcessCompositionAction;
    if (mode == .autonomy and process_goal_port.isForbiddenAutonomyAction(action)) return error.InvalidProcessCompositionAction;
    const origin_text = optionalStringField(pressure_object, "origin") catch return error.InvalidProcessCompositionField;
    const scale_text = optionalStringField(pressure_object, "scale") catch return error.InvalidProcessCompositionField;
    const default_origin: []const u8 = switch (mode) {
        .autonomy => "autonomy",
        .interaction => "interaction",
    };
    return .{
        .action = action,
        .origin = parseOrigin(origin_text orelse default_origin) orelse return error.InvalidProcessCompositionField,
        .delay_ms = try optionalIntegerField(pressure_object, "delay_ms"),
        .scale = parseScale(scale_text orelse "full") orelse return error.InvalidProcessCompositionField,
        .text = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "text")),
        .query = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "query")),
        .memory_id = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "memory_id")),
        .schedule = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "schedule")),
        .heat_bias = try dupeOptionalString(allocator, try optionalHeatBiasField(pressure_object)),
        .eyes = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "eyes")),
        .mouth = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "mouth")),
        .duration_ms = try optionalIntegerField(pressure_object, "duration_ms"),
        .tags = try cloneTagsField(allocator, pressure_object),
    };
}

fn requiredArrayField(object: std.json.ObjectMap, name: []const u8) !std.json.Array {
    const value = object.get(name) orelse return error.MissingProcessCompositionField;
    return switch (value) {
        .array => |items| items,
        else => error.InvalidProcessCompositionField,
    };
}

fn requiredStringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingProcessCompositionField;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidProcessCompositionField,
    };
}

fn optionalStringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidProcessCompositionField,
    };
}

fn optionalIntegerField(object: std.json.ObjectMap, name: []const u8) !?u32 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else error.InvalidProcessCompositionField,
        else => error.InvalidProcessCompositionField,
    };
}

fn optionalHeatBiasField(object: std.json.ObjectMap) !?[]const u8 {
    const text = try optionalStringField(object, "heat_bias");
    if (text) |value| {
        if (std.mem.eql(u8, value, "low") or std.mem.eql(u8, value, "mixed") or std.mem.eql(u8, value, "high")) return value;
        return error.InvalidProcessCompositionField;
    }
    return null;
}

fn dupeOptionalString(allocator: std.mem.Allocator, text: ?[]const u8) !?[]const u8 {
    return if (text) |value| try allocator.dupe(u8, value) else null;
}

fn cloneTagsField(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]const []const u8 {
    const value = object.get("tags") orelse return &.{};
    return switch (value) {
        .array => |array| {
            const tags = try allocator.alloc([]const u8, array.items.len);
            for (array.items, 0..) |item, i| {
                tags[i] = switch (item) {
                    .string => |text| try allocator.dupe(u8, text),
                    else => return error.InvalidProcessCompositionField,
                };
            }
            return tags;
        },
        else => error.InvalidProcessCompositionField,
    };
}

fn parseOrigin(text: []const u8) ?chat.ActionOrigin {
    if (std.mem.eql(u8, text, "interaction")) return .interaction;
    if (std.mem.eql(u8, text, "autonomy")) return .autonomy;
    return null;
}

fn parseScale(text: []const u8) ?chat.ActionScale {
    if (std.mem.eql(u8, text, "full")) return .full;
    if (std.mem.eql(u8, text, "medium")) return .medium;
    if (std.mem.eql(u8, text, "tiny")) return .tiny;
    return null;
}

fn reportCompositionParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nPROCESS COMPOSITION PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with action_pressures and reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

test "parseProcessComposition requires non-empty action pressures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.EmptyProcessComposition, parseProcessComposition(allocator,
        \\{"action_pressures":[],"reason":"nothing"}
    , .autonomy));
    const result = try parseProcessComposition(allocator,
        \\{"action_pressures":[{"action":"think_about","origin":"autonomy","query":"touch","tags":["touch"]}],"reason":"reflect"}
    , .autonomy);
    try std.testing.expectEqual(@as(usize, 1), result.action_pressures.len);
    try std.testing.expectEqual(chat.ActionProposalType.think_about, result.action_pressures[0].action);
}

test "parseProcessComposition rejects forbidden autonomy camera actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidProcessCompositionAction, parseProcessComposition(allocator,
        \\{"action_pressures":[{"action":"take_picture","origin":"autonomy","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":[]}],"reason":"look"}
    , .autonomy));
}
