const std = @import("std");
const chat = @import("chat_client.zig");
const autonomy = @import("autonomy_client.zig");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const psyche_port = @import("../core/port_psyche.zig");

pub const IdTurn = psyche_port.IdTurn;
pub const SuperegoTurn = psyche_port.SuperegoTurn;
pub const PsycheService = psyche_port.PsycheService;
pub const ScriptedPsycheService = psyche_port.ScriptedPsycheService;
pub const formatIdTurn = psyche_port.formatIdTurn;
pub const formatSuperegoTurn = psyche_port.formatSuperegoTurn;

pub const RandomProviderPsycheService = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(io: std.Io, http: http_transport.Client, models_spec: []const u8, reasoning_effort: ?chat.ReasoningEffort) RandomProviderPsycheService {
        return .{
            .provider_client = ai.RandomProviderClient.init(io, http, models_spec),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn service(self: *RandomProviderPsycheService) PsycheService {
        return .{ .ctx = self, .idFn = consultId, .superegoFn = consultSuperego };
    }

    fn consultId(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !IdTurn {
        const self: *RandomProviderPsycheService = @ptrCast(@alignCast(ctx));
        const content = try self.callSelected(allocator, "psyche_id", idSystemPrompt(), shared_context, idJsonSchema(), validateIdTurn);
        return parseIdTurn(allocator, content) catch |err| {
            reportPsycheParseError("id", err, content);
            return err;
        };
    }

    fn consultSuperego(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !SuperegoTurn {
        const self: *RandomProviderPsycheService = @ptrCast(@alignCast(ctx));
        const content = try self.callSelected(allocator, "psyche_superego", superegoSystemPrompt(), shared_context, superegoJsonSchema(), validateSuperegoTurn);
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
        return self.provider_client.completeText(allocator, .{
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
        });
    }
};

fn idSystemPrompt() []const u8 {
    return
    \\You are the Id of thinking being.
    \\You drink from the same full shared state as Superego, but assign your own priorities, causes, and meanings to the stimulus.
    \\You are the short-term planning and consequences simulator: prioritize near-term stimuli, immediate needs, friction, opportunities, risks, likely short-term outcomes, impulses, curiosity, discomfort, wishes, and associative background thought.
    \\Use only the supplied state. Be terse and concrete.
    \\Return exactly JSON with keys: top_need, urges, random_thoughts, desired_action_bias, salience, reason.
    \\salience must be low, medium, or high. Return only JSON.
    \\Do not wrap the JSON in Markdown or code fences.
    ;
}

fn superegoSystemPrompt() []const u8 {
    return
    \\You are the Superego of thinking being.
    \\You drink from the same full shared state as Id, but assign your own priorities, causes, and meanings to the stimulus.
    \\You are the long-term planning and consequences simulator: prioritize long-term effects, restraint, rules, values, identity continuity, promises, user dignity, memory honesty, quiet hours, power, safety boundaries, and uncertainty.
    \\Ask how to keep doing what seems right as conditions change in ways you cannot fully predict.
    \\Use Superego Principles as long-term and big-goal inputs, not as brittle commands. Use only the supplied state. Be terse and concrete.
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
