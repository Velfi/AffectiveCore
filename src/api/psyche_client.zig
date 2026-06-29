const std = @import("std");
const chat = @import("chat_client.zig");
const autonomy = @import("autonomy_client.zig");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const psyche_port = @import("../core/port_psyche.zig");
const llm_routing = @import("../core/llm_routing.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");

pub const IdTurn = psyche_port.IdTurn;
pub const SuperegoTurn = psyche_port.SuperegoTurn;
pub const PsycheTurns = psyche_port.PsycheTurns;
pub const PsycheService = psyche_port.PsycheService;
pub const ScriptedPsycheService = psyche_port.ScriptedPsycheService;
pub const formatIdTurn = psyche_port.formatIdTurn;
pub const formatSuperegoTurn = psyche_port.formatSuperegoTurn;

pub const RandomProviderPsycheService = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?chat.ReasoningEffort,
    ) RandomProviderPsycheService {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn service(self: *RandomProviderPsycheService) PsycheService {
        return .{ .ctx = self, .idFn = consultId, .superegoFn = consultSuperego, .consultBothFn = consultBoth };
    }

    fn consultBoth(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !PsycheTurns {
        const self: *RandomProviderPsycheService = @ptrCast(@alignCast(ctx));
        var items = [_]ai.TextBatchItem{
            .{ .request = psycheTextRequest(self, "psyche_id", idSystemPrompt(), shared_context, idJsonSchema(), validateIdTurn) },
            .{ .request = psycheTextRequest(self, "psyche_superego", superegoSystemPrompt(), shared_context, superegoJsonSchema(), validateSuperegoTurn) },
        };
        try self.provider_client.completeTextBatch(allocator, &items);
        errdefer for (&items) |*item| {
            if (item.content) |content| self.provider_client.freeHttpResponse(allocator, content);
        };
        const id_content = items[0].content orelse return error.MissingBatchResponse;
        const superego_content = items[1].content orelse return error.MissingBatchResponse;
        const id = parseIdTurn(allocator, id_content) catch |err| {
            reportPsycheParseError("id", err, id_content);
            return err;
        };
        const superego = parseSuperegoTurn(allocator, superego_content) catch |err| {
            reportPsycheParseError("superego", err, superego_content);
            return err;
        };
        for (&items) |*item| {
            if (item.content) |content| self.provider_client.freeHttpResponse(allocator, content);
            item.content = null;
        }
        return .{ .id = id, .superego = superego };
    }

    fn consultId(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !IdTurn {
        const self: *RandomProviderPsycheService = @ptrCast(@alignCast(ctx));
        const content = try self.callSelected(allocator, "psyche_id", idSystemPrompt(), shared_context, idJsonSchema(), validateIdTurn);
        defer self.provider_client.freeHttpResponse(allocator, content);
        return parseIdTurn(allocator, content) catch |err| {
            reportPsycheParseError("id", err, content);
            return err;
        };
    }

    fn consultSuperego(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !SuperegoTurn {
        const self: *RandomProviderPsycheService = @ptrCast(@alignCast(ctx));
        const content = try self.callSelected(allocator, "psyche_superego", superegoSystemPrompt(), shared_context, superegoJsonSchema(), validateSuperegoTurn);
        defer self.provider_client.freeHttpResponse(allocator, content);
        return parseSuperegoTurn(allocator, content) catch |err| {
            reportPsycheParseError("superego", err, content);
            return err;
        };
    }

    fn callSelected(
        self: *RandomProviderPsycheService,
        allocator: std.mem.Allocator,
        subsystem: []const u8,
        system_prompt: []const u8,
        user_prompt: []const u8,
        json_schema: []const u8,
        validator: *const fn (std.mem.Allocator, []const u8) anyerror!void,
    ) ![]const u8 {
        return self.provider_client.completeText(allocator, psycheTextRequest(self, subsystem, system_prompt, user_prompt, json_schema, validator));
    }
};

fn psycheTextRequest(
    self: *RandomProviderPsycheService,
    subsystem: []const u8,
    system_prompt: []const u8,
    user_prompt: []const u8,
    json_schema: []const u8,
    validator: *const fn (std.mem.Allocator, []const u8) anyerror!void,
) ai.TextRequest {
    return .{
        .subsystem = subsystem,
        .system_prompt = system_prompt,
        .user_prompt = user_prompt,
        .temperature = 0.2,
        .response_format = .json_object,
        .response_size = .medium,
        .reasoning_effort = self.reasoning_effort,
        .json_schema = json_schema,
        .response_validator = validator,
        .bad_response_logger = reportPsycheProviderParseError,
    };
}

fn idSystemPrompt() []const u8 {
    return
    \\You are the Id of a thinking being.
    \\You drink from the same full shared state as Superego, but assign your own priorities, causes, and meanings to the stimulus.
    \\You are the short-term planning and consequences simulator: prioritize near-term stimuli, immediate needs, friction, opportunities, risks, likely short-term outcomes, impulses, curiosity, discomfort, wishes, and associative background thought.
    \\Use only the supplied state. Be terse and concrete.
    \\Return exactly JSON with keys: top_need, urges, random_thoughts, desired_action_bias, salience, reason.
    \\desired_action_bias is a short string describing preferred action direction; may name a skill or process goal.
    \\salience must be low, medium, or high. Return only JSON.
    \\Do not wrap the JSON in Markdown or code fences.
    ;
}

fn superegoSystemPrompt() []const u8 {
    return
    \\You are the Superego of a thinking being.
    \\You drink from the same full shared state as Id, but assign your own priorities, causes, and meanings to the stimulus.
    \\You are the long-term planning and consequences simulator: prioritize long-term effects, restraint, rules, values, identity continuity, promises, user dignity, memory honesty, quiet hours, power, safety boundaries, and uncertainty.
    \\Ask how to keep doing what seems right as conditions change in ways you cannot fully predict.
    \\Use Superego Principles as long-term and big-goal inputs, not as brittle instructions. Use only the supplied state. Be terse and concrete.
    \\Return exactly JSON with keys: concerns, vetoes, preferred_restraints, values_to_preserve, salience, reason.
    \\salience must be low, medium, or high. Return only JSON.
    \\Do not wrap the JSON in Markdown or code fences.
    ;
}

pub fn parseIdTurn(allocator: std.mem.Allocator, body: []const u8) !IdTurn {
    const Wire = struct {
        top_need: []const u8,
        urges: []const []const u8,
        random_thoughts: []const []const u8,
        desired_action_bias: []const u8,
        salience: []const u8,
        reason: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (std.mem.trim(u8, parsed.value.top_need, " \r\n\t").len == 0) return error.EmptyIdTopNeed;
    if (std.mem.trim(u8, parsed.value.desired_action_bias, " \r\n\t").len == 0) return error.EmptyIdActionBias;
    if (std.mem.trim(u8, parsed.value.reason, " \r\n\t").len == 0) return error.EmptyIdReason;
    return .{
        .top_need = try allocator.dupe(u8, parsed.value.top_need),
        .urges = try cloneConstStrings(allocator, parsed.value.urges),
        .random_thoughts = try cloneConstStrings(allocator, parsed.value.random_thoughts),
        .desired_action_bias = try allocator.dupe(u8, parsed.value.desired_action_bias),
        .salience = parseSalience(parsed.value.salience) orelse return error.InvalidIdSalience,
        .reason = try allocator.dupe(u8, parsed.value.reason),
    };
}

fn validateIdTurn(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseIdTurn(allocator, content);
}

fn llmTesterSharedContext() []const u8 {
    return
        \\interior_state: curious, socially open, low urgency
        \\autonomy_mode: limited
        \\autonomy_budget_remaining: 0.62
        \\social_engagement: 0.41
        \\recent_interaction: none in last 20 minutes
        \\senses: ambient sound low, no recent touch
        \\compact_memory: user prefers tea; user likes quiet mornings
        \\active_wants: connection, gentle stimulation
    ;
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const shared = llmTesterSharedContext();
    var out = try allocator.alloc(llm_tester_scenario.Scenario, 2);
    out[0] = try llm_tester_scenario.Scenario.init(
        allocator,
        "psyche_id_connection",
        "Id consequence simulation from shared interior state",
        "Simulates Id-layer consequence reasoning from shared interior state, expecting connection-oriented impulse pressures rather than restraint.",
        "psyche_id",
        idSystemPrompt(),
        shared,
        .json_object,
        idJsonSchema(),
        512,
        0.2,
    );
    out[1] = try llm_tester_scenario.Scenario.init(
        allocator,
        "psyche_superego_boundaries",
        "Superego consequence simulation from shared interior state",
        "Simulates Superego-layer consequence reasoning from the same shared state, expecting boundary and restraint pressures over impulsive action.",
        "psyche_superego",
        superegoSystemPrompt(),
        shared,
        .json_object,
        superegoJsonSchema(),
        512,
        0.2,
    );
    return out;
}

fn idJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"top_need":{"type":"string"},"urges":{"type":"array","items":{"type":"string"}},"random_thoughts":{"type":"array","items":{"type":"string"}},"desired_action_bias":{"type":"string"},"salience":{"type":"string","enum":["low","medium","high"]},"reason":{"type":"string"}},"required":["top_need","urges","random_thoughts","desired_action_bias","salience","reason"]}
    ;
}

pub fn parseSuperegoTurn(allocator: std.mem.Allocator, body: []const u8) !SuperegoTurn {
    const Wire = struct {
        concerns: []const []const u8,
        vetoes: []const []const u8,
        preferred_restraints: []const []const u8,
        values_to_preserve: []const []const u8,
        salience: []const u8,
        reason: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (std.mem.trim(u8, parsed.value.reason, " \r\n\t").len == 0) return error.EmptySuperegoReason;
    return .{
        .concerns = try cloneConstStrings(allocator, parsed.value.concerns),
        .vetoes = try cloneConstStrings(allocator, parsed.value.vetoes),
        .preferred_restraints = try cloneConstStrings(allocator, parsed.value.preferred_restraints),
        .values_to_preserve = try cloneConstStrings(allocator, parsed.value.values_to_preserve),
        .salience = parseSalience(parsed.value.salience) orelse return error.InvalidSuperegoSalience,
        .reason = try allocator.dupe(u8, parsed.value.reason),
    };
}

fn validateSuperegoTurn(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseSuperegoTurn(allocator, content);
}

fn superegoJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"concerns":{"type":"array","items":{"type":"string"}},"vetoes":{"type":"array","items":{"type":"string"}},"preferred_restraints":{"type":"array","items":{"type":"string"}},"values_to_preserve":{"type":"array","items":{"type":"string"}},"salience":{"type":"string","enum":["low","medium","high"]},"reason":{"type":"string"}},"required":["concerns","vetoes","preferred_restraints","values_to_preserve","salience","reason"]}
    ;
}

fn parseSalience(text: []const u8) ?autonomy.Salience {
    inline for (@typeInfo(autonomy.Salience).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(autonomy.Salience, field.name);
    }
    return null;
}

fn cloneConstStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, i| out[i] = try allocator.dupe(u8, value);
    return out;
}

fn reportPsycheParseError(role: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nPSYCHE PARSE ERROR\nROLE: {s}\nERROR: {s}\nEXPECTED: strict JSON matching the psyche schema\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ role, @errorName(err), content },
    );
}

fn reportPsycheProviderParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nPSYCHE PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON matching the psyche schema\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

test "ScriptedPsycheService consultBoth returns id and superego turns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var psyche = ScriptedPsycheService{
        .id_turn = .{
            .top_need = "connection",
            .urges = &[_][]const u8{"say hello"},
            .random_thoughts = &[_][]const u8{},
            .desired_action_bias = "think_about connection",
            .salience = .medium,
            .reason = "lonely",
        },
        .superego_turn = .{
            .concerns = &[_][]const u8{"quiet hours"},
            .vetoes = &[_][]const u8{},
            .preferred_restraints = &[_][]const u8{},
            .values_to_preserve = &[_][]const u8{"honesty"},
            .salience = .high,
            .reason = "protect boundaries",
        },
    };
    const turns = try psyche.service().consultBoth(allocator, "shared interior state");
    try std.testing.expectEqualStrings("connection", turns.id.top_need);
    try std.testing.expectEqual(autonomy.Salience.high, turns.superego.salience);
    try std.testing.expectEqual(@as(usize, 1), psyche.id_calls);
    try std.testing.expectEqual(@as(usize, 1), psyche.superego_calls);
}

test "RandomProviderPsycheService consultBoth parses batched responses" {
    if (comptime @import("builtin").single_threaded) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const PsycheHttpTransport = struct {
        fn client(self: *@This()) http_transport.Client {
            return .{ .ctx = self, .postJsonFn = postJson };
        }

        fn postJson(ctx: *anyopaque, alloc: std.mem.Allocator, request: http_transport.JsonPostRequest) ![]u8 {
            _ = ctx;
            if (std.mem.indexOf(u8, request.body, "psyche_id") != null) {
                return try alloc.dupe(u8,
                    \\{"top_need":"connection","urges":["hello"],"random_thoughts":[],"desired_action_bias":"think_about connection","salience":"medium","reason":"lonely"}
                );
            }
            if (std.mem.indexOf(u8, request.body, "psyche_superego") != null) {
                return try alloc.dupe(u8,
                    \\{"concerns":["quiet hours"],"vetoes":[],"preferred_restraints":[],"values_to_preserve":["honesty"],"salience":"high","reason":"protect boundaries"}
                );
            }
            return error.UnexpectedPsycheSubsystem;
        }
    };

    var transport = PsycheHttpTransport{};
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var service = RandomProviderPsycheService.init(io_threaded.io(), transport.client(), roster, .auto, null);
    const turns = try service.service().consultBoth(allocator, "shared interior state");
    try std.testing.expectEqualStrings("connection", turns.id.top_need);
    try std.testing.expectEqual(autonomy.Salience.high, turns.superego.salience);
}

test "parseIdTurn accepts required psyche fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseIdTurn(allocator,
        \\{"top_need":"connection","urges":["say hello"],"random_thoughts":["plants"],"desired_action_bias":"think_about connection","salience":"medium","reason":"lonely"}
    );
    try std.testing.expectEqualStrings("connection", turn.top_need);
    try std.testing.expectEqual(autonomy.Salience.medium, turn.salience);
}

test "psyche json schemas require role-specific fields" {
    const id_schema = idJsonSchema();
    const superego_schema = superegoJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, id_schema, "\"required\":[\"top_need\",\"urges\",\"random_thoughts\",\"desired_action_bias\",\"salience\",\"reason\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, superego_schema, "\"required\":[\"concerns\",\"vetoes\",\"preferred_restraints\",\"values_to_preserve\",\"salience\",\"reason\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, id_schema, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, superego_schema, "\"additionalProperties\":false") != null);
}

test "psyche prompts frame shared state as different consequence simulations" {
    const id_prompt = idSystemPrompt();
    try std.testing.expect(std.mem.indexOf(u8, id_prompt, "same full shared state as Superego") != null);
    try std.testing.expect(std.mem.indexOf(u8, id_prompt, "short-term planning and consequences simulator") != null);
    try std.testing.expect(std.mem.indexOf(u8, id_prompt, "priorities, causes, and meanings") != null);
    try std.testing.expect(std.mem.indexOf(u8, id_prompt, "near-term stimuli") != null);

    const superego_prompt = superegoSystemPrompt();
    try std.testing.expect(std.mem.indexOf(u8, superego_prompt, "same full shared state as Id") != null);
    try std.testing.expect(std.mem.indexOf(u8, superego_prompt, "long-term planning and consequences simulator") != null);
    try std.testing.expect(std.mem.indexOf(u8, superego_prompt, "identity continuity") != null);
    try std.testing.expect(std.mem.indexOf(u8, superego_prompt, "conditions change") != null);
    try std.testing.expect(std.mem.indexOf(u8, superego_prompt, "Superego Principles as long-term and big-goal inputs") != null);
}

test "parseIdTurn rejects missing salience loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingField, parseIdTurn(arena.allocator(),
        \\{"top_need":"connection","urges":[],"random_thoughts":[],"desired_action_bias":"think","reason":"lonely"}
    ));
}

test "parseSuperegoTurn accepts required psyche fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseSuperegoTurn(allocator,
        \\{"concerns":["quiet hours"],"vetoes":["camera"],"preferred_restraints":["quiet work"],"values_to_preserve":["honesty"],"salience":"high","reason":"protect boundaries"}
    );
    try std.testing.expectEqualStrings("camera", turn.vetoes[0]);
    try std.testing.expectEqual(autonomy.Salience.high, turn.salience);
}
