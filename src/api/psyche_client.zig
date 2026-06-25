const std = @import("std");
const chat = @import("chat_client.zig");
const autonomy = @import("autonomy_client.zig");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const process = @import("../platform/common/process.zig");
const service_errors = @import("service_errors.zig");

pub const IdTurn = struct {
    top_need: []const u8,
    urges: []const []const u8,
    random_thoughts: []const []const u8,
    desired_action_bias: []const u8,
    salience: autonomy.Salience,
    reason: []const u8,
};

pub const SuperegoTurn = struct {
    concerns: []const []const u8,
    vetoes: []const []const u8,
    preferred_restraints: []const []const u8,
    values_to_preserve: []const []const u8,
    salience: autonomy.Salience,
    reason: []const u8,
};

pub const PsycheService = struct {
    ctx: *anyopaque,
    idFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!IdTurn,
    superegoFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!SuperegoTurn,

    pub fn consultId(self: PsycheService, allocator: std.mem.Allocator, shared_context: []const u8) !IdTurn {
        return self.idFn(self.ctx, allocator, shared_context);
    }

    pub fn consultSuperego(self: PsycheService, allocator: std.mem.Allocator, shared_context: []const u8) !SuperegoTurn {
        return self.superegoFn(self.ctx, allocator, shared_context);
    }
};

const LlmProvider = enum {
    openai,
    anthropic,
    google,
};

const ProviderModel = struct {
    provider: LlmProvider,
    model: []const u8,
};

pub const RandomProviderPsycheService = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, models_spec: []const u8, reasoning_effort: ?chat.ReasoningEffort) RandomProviderPsycheService {
        return .{
            .provider_client = ai.RandomProviderClient.init(io, http, env, models_spec),
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

pub const ScriptedPsycheService = struct {
    id_turn: IdTurn,
    superego_turn: SuperegoTurn,
    id_calls: usize = 0,
    superego_calls: usize = 0,
    last_id_context: []const u8 = "",
    last_superego_context: []const u8 = "",

    pub fn service(self: *ScriptedPsycheService) PsycheService {
        return .{ .ctx = self, .idFn = consultId, .superegoFn = consultSuperego };
    }

    fn consultId(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !IdTurn {
        _ = allocator;
        const self: *ScriptedPsycheService = @ptrCast(@alignCast(ctx));
        self.id_calls += 1;
        self.last_id_context = shared_context;
        return self.id_turn;
    }

    fn consultSuperego(ctx: *anyopaque, allocator: std.mem.Allocator, shared_context: []const u8) !SuperegoTurn {
        _ = allocator;
        const self: *ScriptedPsycheService = @ptrCast(@alignCast(ctx));
        self.superego_calls += 1;
        self.last_superego_context = shared_context;
        return self.superego_turn;
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

fn parseProviderModels(allocator: std.mem.Allocator, spec: []const u8) ![]ProviderModel {
    const text = std.mem.trim(u8, spec, " \r\n\t");
    if (text.len == 0) return error.NoPsycheModels;

    var out = std.ArrayList(ProviderModel).empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \r\n\t");
        if (part.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidPsycheProviderModel;
        const provider_text = std.mem.trim(u8, part[0..sep], " \r\n\t");
        const model_text = std.mem.trim(u8, part[sep + 1 ..], " \r\n\t");
        if (provider_text.len == 0 or model_text.len == 0) return error.InvalidPsycheProviderModel;
        try out.append(allocator, .{
            .provider = parseProvider(provider_text) orelse return error.InvalidPsycheProvider,
            .model = model_text,
        });
    }
    if (out.items.len == 0) return error.NoPsycheModels;
    return out.toOwnedSlice(allocator);
}

fn parseProvider(text: []const u8) ?LlmProvider {
    if (std.ascii.eqlIgnoreCase(text, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(text, "anthropic")) return .anthropic;
    if (std.ascii.eqlIgnoreCase(text, "google") or std.ascii.eqlIgnoreCase(text, "gemini")) return .google;
    return null;
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

fn joinList(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    if (values.len == 0) return allocator.dupe(u8, "none");
    var out = std.ArrayList(u8).empty;
    for (values, 0..) |value, i| {
        if (i > 0) try out.appendSlice(allocator, "; ");
        try out.appendSlice(allocator, value);
    }
    return out.toOwnedSlice(allocator);
}

pub fn formatIdTurn(allocator: std.mem.Allocator, turn: IdTurn) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Id:\n- top_need: {s}\n- urges: {s}\n- random_thoughts: {s}\n- desired_action_bias: {s}\n- salience: {s}\n- reason: {s}\n",
        .{ turn.top_need, try joinList(allocator, turn.urges), try joinList(allocator, turn.random_thoughts), turn.desired_action_bias, @tagName(turn.salience), turn.reason },
    );
}

pub fn formatSuperegoTurn(allocator: std.mem.Allocator, turn: SuperegoTurn) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Superego:\n- concerns: {s}\n- vetoes: {s}\n- preferred_restraints: {s}\n- values_to_preserve: {s}\n- salience: {s}\n- reason: {s}\n",
        .{ try joinList(allocator, turn.concerns), try joinList(allocator, turn.vetoes), try joinList(allocator, turn.preferred_restraints), try joinList(allocator, turn.values_to_preserve), @tagName(turn.salience), turn.reason },
    );
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

fn randomSeed(io: std.Io) u64 {
    const now = std.Io.Clock.now(.boot, io).nanoseconds;
    return @as(u64, @truncate(@as(u128, @intCast(@abs(now)))));
}

fn callOpenAI(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, effort: ?chat.ReasoningEffort, subsystem: []const u8, system_prompt: []const u8, user_prompt: []const u8, json_schema: []const u8) ![]const u8 {
    const maybe_effort = if (effort != null and supportsReasoningEffort(model))
        try std.fmt.allocPrint(allocator, ",\"reasoning_effort\":{s}", .{try jsonString(allocator, @tagName(effort.?))})
    else
        "";
    const response_format = try openAIJsonResponseFormat(allocator, subsystem, json_schema);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s}{s},\"temperature\":0.2{s},\"messages\":[{{\"role\":\"system\",\"content\":{s}}},{{\"role\":\"user\",\"content\":{s}}}]}}",
        .{ try jsonString(allocator, model), maybe_effort, response_format, try jsonString(allocator, system_prompt), try jsonString(allocator, user_prompt) },
    );
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCapture(allocator, io, &.{ "curl", "-sS", "https://api.openai.com/v1/chat/completions", "-H", auth, "-H", "Content-Type: application/json", "-d", body });
        defer allocator.free(out);
        return extractChatContent(allocator, out) catch |err| {
            reportProviderResponseError("psyche", "openai", model, err, out);
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("psyche", "openai", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn callAnthropic(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, system_prompt: []const u8, user_prompt: []const u8, json_schema: []const u8) ![]const u8 {
    const tools = try anthropicJsonToolConfig(allocator, json_schema);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s},\"max_tokens\":500,\"temperature\":0.2,\"system\":{s},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]{s}}}",
        .{ try jsonString(allocator, model), try jsonString(allocator, system_prompt), try jsonString(allocator, user_prompt), tools },
    );
    const auth = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCapture(allocator, io, &.{ "curl", "-sS", "https://api.anthropic.com/v1/messages", "-H", auth, "-H", "anthropic-version: 2023-06-01", "-H", "Content-Type: application/json", "-d", body });
        defer allocator.free(out);
        return extractAnthropicContent(allocator, out) catch |err| {
            reportProviderResponseError("psyche", "anthropic", model, err, out);
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("psyche", "anthropic", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn callGoogle(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"systemInstruction\":{{\"parts\":[{{\"text\":{s}}}]}},\"contents\":[{{\"role\":\"user\",\"parts\":[{{\"text\":{s}}}]}}],\"generationConfig\":{{\"temperature\":0.2,\"maxOutputTokens\":500,\"responseMimeType\":\"application/json\"}}}}",
        .{ try jsonString(allocator, system_prompt), try jsonString(allocator, user_prompt) },
    );
    const url = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{ model, api_key });
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCapture(allocator, io, &.{ "curl", "-sS", url, "-H", "Content-Type: application/json", "-d", body });
        defer allocator.free(out);
        return extractGoogleContent(allocator, out) catch |err| {
            reportProviderResponseError("psyche", "google", model, err, out);
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("psyche", "google", model, attempt);
                continue;
            }
            return err;
        };
    }
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

fn reportProviderResponseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, response: []const u8) void {
    std.debug.print(
        "\nLLM RESPONSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nRAW PROVIDER RESPONSE:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), response },
    );
}

fn supportsReasoningEffort(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "o") or std.mem.startsWith(u8, model, "gpt-5");
}

fn extractChatContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Response = struct {
        choices: []struct { message: struct { content: []const u8 } },
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return error.RemoteServiceFailed;
    return allocator.dupe(u8, parsed.value.choices[0].message.content);
}

fn extractAnthropicContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Response = struct {
        content: []struct {
            type: []const u8 = "",
            text: ?[]const u8 = null,
            name: ?[]const u8 = null,
            input: ?std.json.Value = null,
        },
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    for (parsed.value.content) |part| {
        if (!std.mem.eql(u8, part.type, "tool_use")) continue;
        const name = part.name orelse return error.RemoteServiceFailed;
        if (!std.mem.eql(u8, name, "json_response")) return error.RemoteServiceFailed;
        const input = part.input orelse return error.RemoteServiceFailed;
        return std.json.Stringify.valueAlloc(allocator, input, .{});
    }
    return error.RemoteServiceFailed;
}

fn anthropicJsonToolConfig(allocator: std.mem.Allocator, json_schema: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        ",\"tools\":[{{\"name\":\"json_response\",\"description\":\"Return exactly the requested psyche object.\",\"input_schema\":{s}}}],\"tool_choice\":{{\"type\":\"tool\",\"name\":\"json_response\"}}",
        .{json_schema},
    );
}

fn openAIJsonResponseFormat(allocator: std.mem.Allocator, name: []const u8, json_schema: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        ",\"response_format\":{{\"type\":\"json_schema\",\"json_schema\":{{\"name\":{s},\"strict\":true,\"schema\":{s}}}}}",
        .{ try jsonString(allocator, name), json_schema },
    );
}

fn extractGoogleContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Response = struct {
        candidates: []struct {
            content: struct { parts: []struct { text: ?[]const u8 = null } },
        },
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    if (parsed.value.candidates.len == 0) return error.RemoteServiceFailed;
    for (parsed.value.candidates[0].content.parts) |part| {
        if (part.text) |text| return allocator.dupe(u8, text);
    }
    return error.RemoteServiceFailed;
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

test "psyche provider request schemas are strict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const openai_format = try openAIJsonResponseFormat(allocator, "psyche_id", idJsonSchema());
    try std.testing.expect(std.mem.indexOf(u8, openai_format, "\"type\":\"json_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, openai_format, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, openai_format, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, openai_format, "\"required\":[\"top_need\",\"urges\",\"random_thoughts\",\"desired_action_bias\",\"salience\",\"reason\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, openai_format, "\"type\":\"json_object\"") == null);

    const anthropic_tools = try anthropicJsonToolConfig(allocator, superegoJsonSchema());
    try std.testing.expect(std.mem.indexOf(u8, anthropic_tools, "\"input_schema\":{\"type\":\"object\",\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_tools, "\"required\":[\"concerns\",\"vetoes\",\"preferred_restraints\",\"values_to_preserve\",\"salience\",\"reason\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, anthropic_tools, "\"tool_choice\":{\"type\":\"tool\",\"name\":\"json_response\"}") != null);
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
