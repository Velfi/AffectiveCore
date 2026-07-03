const std = @import("std");
const chat = @import("chat_client.zig");
const skills = @import("skills.zig");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const autonomy_port = @import("../core/port_autonomy.zig");
const llm_routing = @import("../core/llm_routing.zig");
const capability_registry = @import("../core/capability_registry.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");
const action_pressure_json_schema = @import("action_pressure_json_schema.zig");
const llm_voice = @import("../core/llm_voice.zig");
const brain_mod = @import("../core/brain.zig");
const service_errors = @import("service_errors.zig");

pub const Salience = autonomy_port.Salience;
pub const AutonomyTurn = autonomy_port.AutonomyTurn;
pub const AutonomyPlanner = autonomy_port.AutonomyPlanner;
pub const ScriptedAutonomyPlanner = autonomy_port.ScriptedAutonomyPlanner;

pub const RandomProviderAutonomyPlanner = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,
    autonomy_mode: []const u8,
    parse_failure_brain: ?*brain_mod.Brain = null,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?chat.ReasoningEffort,
        autonomy_mode: []const u8,
    ) RandomProviderAutonomyPlanner {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
            .autonomy_mode = autonomy_mode,
        };
    }

    pub fn planner(self: *RandomProviderAutonomyPlanner) AutonomyPlanner {
        return .{ .ctx = self, .planFn = plan };
    }

    fn plan(ctx: *anyopaque, allocator: std.mem.Allocator, context: []const u8) !AutonomyTurn {
        const self: *RandomProviderAutonomyPlanner = @ptrCast(@alignCast(ctx));
        const system_prompt = try autonomySystemPrompt(allocator, self.autonomy_mode);
        defer allocator.free(system_prompt);
        const json_schema = if (self.parse_failure_brain) |brain|
            try brain.autonomyJsonSchema()
        else
            autonomyJsonSchema();
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const content = self.provider_client.completeText(allocator, .{
                .subsystem = "autonomy",
                .system_prompt = system_prompt,
                .user_prompt = context,
                .temperature = 0.3,
                .response_format = .json_object,
                .response_size = .medium,
                .reasoning_effort = self.reasoning_effort,
                .json_schema = json_schema,
                .response_validator = validateAutonomyEnvelope,
                .bad_response_logger = reportAutonomyProviderParseError,
            }) catch |err| {
                if (service_errors.shouldRetryAutonomyParse(err, attempt)) {
                    service_errors.logAutonomyParseRetry("autonomy", "host", "host_llm_complete", attempt);
                    continue;
                }
                return err;
            };
            defer self.provider_client.freeHttpResponse(allocator, content);
            return parseAutonomyTurn(allocator, content, self.autonomy_mode) catch |err| {
                reportAutonomyParseError(err, content);
                if (service_errors.shouldRetryAutonomyParse(err, attempt)) {
                    service_errors.logAutonomyParseRetry("autonomy", "host", "host_llm_complete", attempt);
                    continue;
                }
                return err;
            };
        }
    }
};

fn autonomySystemPrompt(allocator: std.mem.Allocator, autonomy_mode: []const u8) ![]const u8 {
    const allowed = try skills.autonomySkillNames(allocator, autonomy_mode);
    defer allocator.free(allowed);
    return std.fmt.allocPrint(
        allocator,
        llm_voice.conscious_being_preamble ++
            "Id (short-term impulse) and Superego (long-term consequence) share the same state but may weigh salience, causes, and meaning differently; compare their disagreement before you act.\n" ++
            "Output strict JSON only (no markdown or prose).\n" ++
            "\n" ++
            "Read the supplied context as your present lived situation: event stream, body senses, attention, drives, boundaries, Id/Superego readings, recent contact, and speech gates.\n" ++
            "Agency budget is internal action energy—not battery charge and not external power.\n" ++
            "Only use get_power or say about shutting down when power evidence shows low charge, lost cord, or a source change.\n" ++
            "The goal is not to perform friendliness or prove responsiveness. Notice what matters, choose whether to think, feel, look, wait, remember, emote, or speak.\n" ++
            "For ambient stimuli speech is optional: quiet curiosity, private thought, and respectful waiting are valid outcomes.\n" ++
            "Being spoken to is different from ambient noise: fresh unanswered speech in stimulus_inbox or present_moment means someone reached out to you, and staying silent is itself a social choice—make it deliberately, not by default.\n" ++
            "\n" ++
            "Return one JSON object with required top-level keys salience (low|medium|high), reason (brief first-person why), and action_pressures (ordered array).\n" ++
            "Never return action_pressures without salience and reason.\n" ++
            "\n" ++
            "Plan action_pressures for this pass only:\n" ++
            "- Each step requires action; include every schema property on each step and use null for unused fields.\n" ++
            "- Allowed skills: {s}.\n" ++
            "- Registered skill fits → use exact name only in action (e.g. think_about, not \"think_about connection\").\n" ++
            "- think_about and feel_about: put the topic in query or text; action stays the bare skill name.\n" ++
            "- No skill fits → snake_case process goal (runtime expands it); must not imply unavailable capabilities.\n" ++
            "- Prefer ordered registered skills (feel_about, think_about, take_picture, schedule_reminder, …) over inventing process goals when the chain fits allowed skills.\n" ++
            "- Reuse known_processes or introspection related_processes when present—emit that goal name or copy its skill chain.\n" ++
            "- Do not emit a new process goal while active_process is running the same work.\n" ++
            "- Retry a failed process goal with the same chain when host_sense_delivered, timer_fired, or affordances show a prior blocker cleared.\n" ++
            "- Never use skills marked forbidden, unavailable, or invalid in the supplied affordance catalog.\n" ++
            "- Tag every pressure origin=autonomy; use delay_ms for timed chains within a pass.\n" ++
            "- say: speak aloud when the event stream, social context, or explicit contact makes speech welcome and useful. Fresh unanswered speech directed at you is explicit contact; answering it—even briefly—is usually the honest response, unless the words clearly were not for you or silence genuinely fits better. When you answer, speak in your own words; do not quote, copy, or paraphrase the full fresh user utterance inside visible speech. Refer to the intent or situation instead of replaying the stimulus text. When contact_window is open and the last speech was already answered, inner work (choose_attention, think_about, feel_about, emote) completes the moment unless a new salient need appears.\n" ++
            "- choose_attention, think_about, feel_about, emote, or wait are preferred when a stimulus is interesting but not socially demanding.\n" ++
            "- emote: zero-cost visible affect fallback rendered as *text* in chat; include text; no speech. Prefer when facial_expression is unavailable.\n" ++
            "- When Id and Superego disagree, prefer quiet inner work unless state shows an urgent actionable need or unanswered contact.\n" ++
            "- define_need, define_want, or define_goal when a stable self-definition belongs in memory; edit_need, edit_want, or edit_goal only when context supplies a matching memory_id.\n" ++
            "- facial_expression: eyes, mouth, or both from the skill description; unspecified aspects default to neutral; duration_ms may not exceed 5000. Use emote when facial expression output or catalog is unavailable.\n" ++
            "- heat_bias when set: low, mixed, or high only. Include tags only when non-empty.\n",
        .{allowed},
    );
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const context =
        \\autonomy_mode: limited
        \\autonomy_budget_remaining: 0.62
        \\social_engagement: 0.41
        \\consecutive_voluntary_speech: 0
        \\quiet_hours_active: false
        \\id: top_need=connection, salience=medium, desired_action_bias=think_about connection
        \\superego: concerns=quiet hours approaching, salience=low
        \\senses: ambient sound low, no recent touch
        \\recent_interaction: none in last 20 minutes
    ;
    const system_prompt = try autonomySystemPrompt(allocator, "limited");
    defer allocator.free(system_prompt);
    const scenario = try llm_tester_scenario.Scenario.init(
        allocator,
        "autonomy_idle_reflection",
        "Autonomy planning with Id/Superego and budget context",
        "Tests voluntary speech planning when Id, Superego, autonomy budget, and quiet-hours signals are present but no recent interaction has occurred.",
        "autonomy",
        system_prompt,
        context,
        .json_object,
        autonomyJsonSchema(),
        512,
        0.3,
    );
    const out = try allocator.alloc(llm_tester_scenario.Scenario, 1);
    out[0] = scenario;
    return out;
}

fn autonomyJsonSchema() []const u8 {
    return action_pressure_json_schema.strictAutonomyTurnSchema();
}

pub fn validateAutonomyEnvelope(allocator: std.mem.Allocator, body: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidAutonomyJson,
    };
    _ = try requiredStringField(object, "salience");
    _ = try requiredStringField(object, "reason");
    _ = try requiredArrayField(object, "action_pressures");
}

pub fn parseAutonomyTurn(allocator: std.mem.Allocator, body: []const u8, autonomy_mode: []const u8) !AutonomyTurn {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidAutonomyJson;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidAutonomyJson,
    };
    const pressure_values = try requiredArrayField(object, "action_pressures");
    const salience_text = try requiredStringField(object, "salience");
    const reason = try requiredStringField(object, "reason");
    var action_pressures = try allocator.alloc(chat.ActionProposal, pressure_values.items.len);
    for (pressure_values.items, 0..) |value, i| {
        const pressure_object = switch (value) {
            .object => |child| child,
            else => return error.InvalidAutonomyField,
        };
        const action_text = try requiredStringField(pressure_object, "action");
        const resolved_action = parseAction(action_text);
        if (resolved_action == null and std.mem.indexOfScalar(u8, action_text, ' ') != null) return error.InvalidAutonomyAction;
        const action: chat.ActionProposalType = if (resolved_action) |known| known else .unknown;
        if (action != .unknown and !skills.autonomyAllowed(action, autonomy_mode)) return error.InvalidAutonomyAction;
        const process_goal: ?[]const u8 = if (resolved_action == null) try allocator.dupe(u8, action_text) else null;
        const origin_text = optionalStringField(pressure_object, "origin") catch return error.InvalidAutonomyField;
        const scale_text = optionalStringField(pressure_object, "scale") catch return error.InvalidAutonomyField;
        action_pressures[i] = .{
            .action = action,
            .origin = parseOrigin(origin_text orelse "autonomy") orelse return error.InvalidAutonomyField,
            .delay_ms = try optionalIntegerField(pressure_object, "delay_ms"),
            .scale = parseScale(scale_text orelse "full") orelse return error.InvalidAutonomyField,
            .text = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "text")),
            .query = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "query")),
            .memory_id = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "memory_id")),
            .schedule = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "schedule")),
            .heat_bias = try dupeOptionalString(allocator, try optionalHeatBiasField(pressure_object)),
            .eyes = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "eyes")),
            .mouth = try dupeOptionalString(allocator, try optionalStringField(pressure_object, "mouth")),
            .duration_ms = try optionalIntegerField(pressure_object, "duration_ms"),
            .tags = try cloneTagsField(allocator, pressure_object),
            .process_goal = process_goal,
        };
    }
    return .{
        .action_pressures = action_pressures,
        .salience = parseSalience(salience_text) orelse return error.InvalidAutonomySalience,
        .reason = try allocator.dupe(u8, reason),
    };
}

fn requiredArrayField(object: std.json.ObjectMap, name: []const u8) !std.json.Array {
    const value = object.get(name) orelse return error.MissingAutonomyField;
    return switch (value) {
        .array => |items| items,
        else => error.InvalidAutonomyField,
    };
}

fn requiredObjectField(object: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    const value = object.get(name) orelse return error.MissingAutonomyField;
    return switch (value) {
        .object => |child| child,
        else => error.InvalidAutonomyField,
    };
}

fn requiredStringField(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingAutonomyField;
    return switch (value) {
        .string => |text| text,
        else => error.InvalidAutonomyField,
    };
}

fn optionalStringField(object: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidAutonomyField,
    };
}

fn optionalIntegerField(object: std.json.ObjectMap, name: []const u8) !?u32 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .null => null,
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else error.InvalidAutonomyField,
        else => error.InvalidAutonomyField,
    };
}

fn optionalHeatBiasField(object: std.json.ObjectMap) !?[]const u8 {
    const text = try optionalStringField(object, "heat_bias");
    if (text) |value| {
        if (std.mem.eql(u8, value, "low") or std.mem.eql(u8, value, "mixed") or std.mem.eql(u8, value, "high")) return value;
        return error.InvalidAutonomyField;
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
                    else => return error.InvalidAutonomyField,
                };
            }
            return tags;
        },
        else => error.InvalidAutonomyField,
    };
}

fn reportAutonomyParseError(err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nAUTONOMY PARSE ERROR\nPROVIDER: random selected\nERROR: {s}\nEXPECTED: strict JSON object with action_pressures/salience/reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ @errorName(err), content },
    );
}

fn reportAutonomyProviderParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nAUTONOMY PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON object with action_pressures/salience/reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

fn parseAction(text: []const u8) ?chat.ActionProposalType {
    return capability_registry.actionForCapabilityId(text);
}

fn parseSalience(text: []const u8) ?Salience {
    inline for (@typeInfo(Salience).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(Salience, field.name);
    }
    return null;
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

test "parseAutonomyTurn rejects action names with embedded spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidAutonomyAction, parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"think_about connection","origin":"autonomy","delay_ms":null,"scale":"medium","text":"Reflect on connection.","query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":[]}],"salience":"medium","reason":"connection"}
    , "limited"));
}

test "parseAutonomyTurn accepts host sense pulls without legacy full mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"take_picture","origin":"autonomy","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":[]}],"salience":"high","reason":"curious"}
    , "limited");
    try std.testing.expectEqual(chat.ActionProposalType.take_picture, turn.action_pressures[0].action);
}

test "parseAutonomyTurn accepts host sense pulls in compatibility full mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"take_picture","origin":"autonomy","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":[]}],"salience":"high","reason":"curious"}
    , "full");
    try std.testing.expectEqual(chat.ActionProposalType.take_picture, turn.action_pressures[0].action);
}

test "validateAutonomyEnvelope rejects action_pressures-only payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.MissingAutonomyField,
        validateAutonomyEnvelope(arena.allocator(), "{\"action_pressures\":[]}"),
    );
}

test "random-provider autonomy schema matches strict required envelope" {
    const schema = autonomyJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"salience\",\"reason\",\"action_pressures\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"action\",\"origin\",\"delay_ms\",\"scale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"type\":[\"string\",\"null\"]") != null);
}

test "autonomy prompt tells speech to answer in its own words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prompt = try autonomySystemPrompt(arena.allocator(), "limited");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "speak in your own words") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "do not quote, copy, or paraphrase the full fresh user utterance inside visible speech") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Refer to the intent or situation instead of replaying the stimulus text") != null);
}

test "parseAutonomyTurn preserves invented action names as process goals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"investigate_touch","origin":"autonomy","delay_ms":null,"scale":"tiny","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":500,"tags":["exploration","touch"]}],"salience":"high","reason":"curious touch"}
    , "limited");
    try std.testing.expectEqual(chat.ActionProposalType.unknown, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("investigate_touch", turn.action_pressures[0].process_goal.?);
}

test "parseAutonomyTurn accepts minimal action pressure without null placeholders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"think_about","query":"energy","tags":["self"]}],"salience":"medium","reason":"checking limits"}
    , "limited");
    try std.testing.expectEqual(chat.ActionProposalType.think_about, turn.action_pressures[0].action);
    try std.testing.expectEqual(chat.ActionOrigin.autonomy, turn.action_pressures[0].origin);
    try std.testing.expectEqual(chat.ActionScale.full, turn.action_pressures[0].scale);
    try std.testing.expectEqualStrings("energy", turn.action_pressures[0].query.?);
}

test "parseAutonomyTurn accepts a reflective action pressure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"think_about","origin":"autonomy","delay_ms":null,"scale":"full","text":null,"query":"energy","memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":["self"]}],"salience":"medium","reason":"checking limits"}
    , "limited");
    try std.testing.expectEqual(chat.ActionProposalType.think_about, turn.action_pressures[0].action);
    try std.testing.expectEqual(Salience.medium, turn.salience);
}

test "parseAutonomyTurn resolves capability synonyms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"speak","origin":"autonomy","delay_ms":null,"scale":"full","text":"hello","query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":[]}],"salience":"low","reason":"greeting"}
    , "limited");
    try std.testing.expectEqual(chat.ActionProposalType.say, turn.action_pressures[0].action);
}

test "parseAutonomyTurn rejects wrong optional field type clearly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidAutonomyField, parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"think_about","origin":"autonomy","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":0.5,"eyes":null,"mouth":null,"duration_ms":null,"tags":[]}],"salience":"low","reason":"resting"}
    , "limited"));
}

test "parseAutonomyTurn accepts facial expression fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"action_pressures":[{"action":"facial_expression","origin":"autonomy","delay_ms":250,"scale":"tiny","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":"neutral","mouth":"open","duration_ms":5000,"tags":["visible_affect"]}],"salience":"low","reason":"visible reaction"}
    , "limited");
    try std.testing.expectEqual(chat.ActionProposalType.facial_expression, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("neutral", turn.action_pressures[0].eyes.?);
    try std.testing.expectEqualStrings("open", turn.action_pressures[0].mouth.?);
    try std.testing.expectEqual(@as(?u32, 5000), turn.action_pressures[0].duration_ms);
    try std.testing.expectEqual(@as(?u32, 250), turn.action_pressures[0].delay_ms);
    try std.testing.expectEqual(chat.ActionScale.tiny, turn.action_pressures[0].scale);
}
