const std = @import("std");
const chat = @import("chat_client.zig");
const skills = @import("skills.zig");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const process = @import("../platform/common/process.zig");
const service_errors = @import("service_errors.zig");

pub const Salience = enum {
    low,
    medium,
    high,
};

pub const AutonomyTurn = struct {
    command: chat.ChatCommand,
    salience: Salience,
    reason: []const u8,
};

pub const AutonomyPlanner = struct {
    ctx: *anyopaque,
    planFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!AutonomyTurn,

    pub fn plan(self: AutonomyPlanner, allocator: std.mem.Allocator, context: []const u8) !AutonomyTurn {
        return self.planFn(self.ctx, allocator, context);
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

pub const RandomProviderAutonomyPlanner = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, models_spec: []const u8, reasoning_effort: ?chat.ReasoningEffort) RandomProviderAutonomyPlanner {
        return .{
            .provider_client = ai.RandomProviderClient.init(io, http, env, models_spec),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn planner(self: *RandomProviderAutonomyPlanner) AutonomyPlanner {
        return .{ .ctx = self, .planFn = plan };
    }

    fn plan(ctx: *anyopaque, allocator: std.mem.Allocator, context: []const u8) !AutonomyTurn {
        const self: *RandomProviderAutonomyPlanner = @ptrCast(@alignCast(ctx));
        const system_prompt = try autonomySystemPrompt(allocator);
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "autonomy",
            .system_prompt = system_prompt,
            .user_prompt = context,
            .temperature = 0.3,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = autonomyJsonSchema(),
            .response_validator = validateAutonomyTurn,
            .bad_response_logger = reportAutonomyProviderParseError,
        });
        return parseAutonomyTurn(allocator, content) catch |err| {
            reportAutonomyParseError(err, content);
            return err;
        };
    }
};

fn autonomySystemPrompt(allocator: std.mem.Allocator) ![]const u8 {
    const allowed = try skills.autonomySkillNames(allocator);
    return std.fmt.allocPrint(
        allocator,
        "You are the Ego of a stationary household robot.\n" ++
            "Reconcile Id short-term consequence simulation, Superego long-term consequence simulation, external reality, autonomy budget, and available commands.\n" ++
            "Both voices drink from the same shared state, but may assign different salience, causes, and meanings to the same stimulus; compare those disagreements before choosing.\n" ++
            "Autonomy budget is an internal daily action budget, not battery charge and not external power.\n" ++
            "Only use get_power or ask_human about shutdown when supplied power evidence shows a real low battery, missing external power, or a power-source change.\n" ++
            "Return exactly one JSON object with keys: command, text, query, memory_id, schedule, heat_bias, eyes, mouth, duration_ms, tags, salience, reason.\n" ++
            "Allowed commands: {s}.\n" ++
            "Never choose skills marked forbidden or invalid in the registry, including camera commands.\n" ++
            "When you choose ask_human, ask one concrete question and then expect autonomy to sleep until the human responds.\n" ++
            "Use say only for rare high-salience speech that respects the supplied gates.\n" ++
            "Prefer quiet self-work when Id and Superego disagree unless the shared state shows an urgent, actionable need.\n" ++
            "Use define_need or define_want when a stable self-definition should become part of memory. Use edit_need or edit_want only when introspection has provided a matching memory_id to revise.\n" ++
            "Use salience low, medium, or high.\n" ++
            "For facial_expression, choose eyes and mouth sprite names from the supplied skill description; duration_ms may not exceed 5000.\n" ++
            "For unused optional fields, use null. tags must always be an array. heat_bias may only be null, low, mixed, or high.\n" ++
            "Return only JSON.\n" ++
            "Do not wrap the JSON in Markdown or code fences.",
        .{allowed},
    );
}

pub const ScriptedAutonomyPlanner = struct {
    turns: []const AutonomyTurn,
    index: usize = 0,
    calls: usize = 0,

    pub fn planner(self: *ScriptedAutonomyPlanner) AutonomyPlanner {
        return .{ .ctx = self, .planFn = plan };
    }

    fn plan(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) !AutonomyTurn {
        _ = allocator;
        const self: *ScriptedAutonomyPlanner = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.index >= self.turns.len) return error.NoScriptedAutonomyTurn;
        const turn = self.turns[self.index];
        self.index += 1;
        return turn;
    }
};

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

fn randomSeed(io: std.Io) u64 {
    const now = std.Io.Clock.now(.boot, io).nanoseconds;
    return @as(u64, @truncate(@as(u128, @intCast(@abs(now)))));
}

fn autonomyJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"command":{"type":"string"},"text":{"type":["string","null"]},"query":{"type":["string","null"]},"memory_id":{"type":["string","null"]},"schedule":{"type":["string","null"]},"heat_bias":{"type":["string","null"],"enum":["low","mixed","high",null]},"eyes":{"type":["string","null"]},"mouth":{"type":["string","null"]},"duration_ms":{"type":["integer","null"]},"tags":{"type":"array","items":{"type":"string"}},"salience":{"type":"string","enum":["low","medium","high"]},"reason":{"type":"string"}},"required":["command","text","query","memory_id","schedule","heat_bias","eyes","mouth","duration_ms","tags","salience","reason"]}
    ;
}

fn validateAutonomyTurn(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseAutonomyTurn(allocator, content);
}

fn parseProviderModels(allocator: std.mem.Allocator, spec: []const u8) ![]ProviderModel {
    const text = std.mem.trim(u8, spec, " \r\n\t");
    if (text.len == 0) return error.NoAutonomyModels;

    var out = std.ArrayList(ProviderModel).empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \r\n\t");
        if (part.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, part, ':');
        const provider_text = if (sep) |i| std.mem.trim(u8, part[0..i], " \r\n\t") else "openai";
        const model_text = if (sep) |i| std.mem.trim(u8, part[i + 1 ..], " \r\n\t") else part;
        if (model_text.len == 0) continue;
        try out.append(allocator, .{
            .provider = parseProvider(provider_text) orelse return error.InvalidAutonomyProvider,
            .model = model_text,
        });
    }
    if (out.items.len == 0) return error.NoAutonomyModels;
    return try out.toOwnedSlice(allocator);
}

fn parseProvider(text: []const u8) ?LlmProvider {
    if (std.ascii.eqlIgnoreCase(text, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(text, "anthropic")) return .anthropic;
    if (std.ascii.eqlIgnoreCase(text, "google") or std.ascii.eqlIgnoreCase(text, "gemini")) return .google;
    return null;
}

fn callOpenAI(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, effort: ?chat.ReasoningEffort, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const body = try buildOpenAIAutonomyRequestBody(allocator, model, effort, system_prompt, user_prompt);
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCapture(allocator, io, &.{
            "curl",
            "-sS",
            "https://api.openai.com/v1/chat/completions",
            "-H",
            auth,
            "-H",
            "Content-Type: application/json",
            "-d",
            body,
        });
        defer allocator.free(out);
        return extractChatContent(allocator, out) catch |err| {
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("autonomy", "openai", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn buildOpenAIAutonomyRequestBody(allocator: std.mem.Allocator, model: []const u8, effort: ?chat.ReasoningEffort, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const maybe_effort = if (effort != null and supportsReasoningEffort(model))
        try std.fmt.allocPrint(allocator, ",\"reasoning_effort\":{s}", .{try jsonString(allocator, @tagName(effort.?))})
    else
        "";
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s}{s},\"temperature\":0.3,\"response_format\":{s},\"messages\":[{{\"role\":\"system\",\"content\":{s}}},{{\"role\":\"user\",\"content\":{s}}}]}}",
        .{
            try jsonString(allocator, model),
            maybe_effort,
            try autonomyResponseFormat(allocator),
            try jsonString(allocator, system_prompt),
            try jsonString(allocator, user_prompt),
        },
    );
}

fn autonomyResponseFormat(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"json_schema\",\"json_schema\":{{\"name\":\"autonomy_turn\",\"strict\":true,\"schema\":{{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{{\"command\":{{\"type\":\"string\",\"enum\":{s}}},\"text\":{{\"type\":[\"string\",\"null\"]}},\"query\":{{\"type\":[\"string\",\"null\"]}},\"memory_id\":{{\"type\":[\"string\",\"null\"]}},\"schedule\":{{\"type\":[\"string\",\"null\"]}},\"heat_bias\":{{\"type\":[\"string\",\"null\"],\"enum\":[\"low\",\"mixed\",\"high\",null]}},\"eyes\":{{\"type\":[\"string\",\"null\"]}},\"mouth\":{{\"type\":[\"string\",\"null\"]}},\"duration_ms\":{{\"type\":[\"integer\",\"null\"]}},\"tags\":{{\"type\":\"array\",\"items\":{{\"type\":\"string\"}}}},\"salience\":{{\"type\":\"string\",\"enum\":[\"low\",\"medium\",\"high\"]}},\"reason\":{{\"type\":\"string\"}}}},\"required\":[\"command\",\"text\",\"query\",\"memory_id\",\"schedule\",\"heat_bias\",\"eyes\",\"mouth\",\"duration_ms\",\"tags\",\"salience\",\"reason\"]}}}}}}",
        .{try skills.autonomyCommandEnumJson(allocator)},
    );
}

fn callAnthropic(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s},\"max_tokens\":800,\"temperature\":0.3,\"system\":{s},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]{s}}}",
        .{
            try jsonString(allocator, model),
            try jsonString(allocator, system_prompt),
            try jsonString(allocator, user_prompt),
            try anthropicJsonToolConfig(allocator),
        },
    );
    const auth = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCapture(allocator, io, &.{
            "curl",
            "-sS",
            "https://api.anthropic.com/v1/messages",
            "-H",
            auth,
            "-H",
            "anthropic-version: 2023-06-01",
            "-H",
            "Content-Type: application/json",
            "-d",
            body,
        });
        defer allocator.free(out);
        return extractAnthropicContent(allocator, out) catch |err| {
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("autonomy", "anthropic", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn callGoogle(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"systemInstruction\":{{\"parts\":[{{\"text\":{s}}}]}},\"contents\":[{{\"role\":\"user\",\"parts\":[{{\"text\":{s}}}]}}],\"generationConfig\":{{\"temperature\":0.3,\"maxOutputTokens\":800,\"responseMimeType\":\"application/json\"}}}}",
        .{
            try jsonString(allocator, system_prompt),
            try jsonString(allocator, user_prompt),
        },
    );
    const url = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{ model, api_key });
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCapture(allocator, io, &.{
            "curl",
            "-sS",
            url,
            "-H",
            "Content-Type: application/json",
            "-d",
            body,
        });
        defer allocator.free(out);
        return extractGoogleContent(allocator, out) catch |err| {
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("autonomy", "google", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn supportsReasoningEffort(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "o") or std.mem.startsWith(u8, model, "gpt-5");
}

fn extractChatContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Response = struct {
        choices: []struct {
            message: struct {
                content: []const u8,
            },
        },
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return error.RemoteServiceFailed;
    return try allocator.dupe(u8, parsed.value.choices[0].message.content);
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

fn anthropicJsonToolConfig(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        ",\"tools\":[{{\"name\":\"json_response\",\"description\":\"Return exactly the requested autonomy turn.\",\"input_schema\":{s}}}],\"tool_choice\":{{\"type\":\"tool\",\"name\":\"json_response\"}}",
        .{autonomyJsonSchema()},
    );
}

fn extractGoogleContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Response = struct {
        candidates: []struct {
            content: struct {
                parts: []struct {
                    text: ?[]const u8 = null,
                },
            },
        },
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    if (parsed.value.candidates.len == 0) return error.RemoteServiceFailed;
    for (parsed.value.candidates[0].content.parts) |part| {
        if (part.text) |text| return try allocator.dupe(u8, text);
    }
    return error.RemoteServiceFailed;
}

pub fn parseAutonomyTurn(allocator: std.mem.Allocator, body: []const u8) !AutonomyTurn {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidAutonomyJson;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidAutonomyJson,
    };
    const command_text = try requiredStringField(object, "command");
    const salience_text = try requiredStringField(object, "salience");
    const reason = try requiredStringField(object, "reason");
    const command = parseCommand(command_text) orelse return error.InvalidAutonomyCommand;
    if (command == .take_picture or command == .describe_image or command == .compare_images or command == .recognize or command == .unknown) return error.InvalidAutonomyCommand;
    return .{
        .command = .{
            .command = command,
            .text = try dupeOptionalString(allocator, try optionalStringField(object, "text")),
            .query = try dupeOptionalString(allocator, try optionalStringField(object, "query")),
            .memory_id = try dupeOptionalString(allocator, try optionalStringField(object, "memory_id")),
            .schedule = try dupeOptionalString(allocator, try optionalStringField(object, "schedule")),
            .heat_bias = try dupeOptionalString(allocator, try optionalHeatBiasField(object)),
            .eyes = try dupeOptionalString(allocator, try optionalStringField(object, "eyes")),
            .mouth = try dupeOptionalString(allocator, try optionalStringField(object, "mouth")),
            .duration_ms = try optionalIntegerField(object, "duration_ms"),
            .tags = try cloneTagsField(allocator, object),
        },
        .salience = parseSalience(salience_text) orelse return error.InvalidAutonomySalience,
        .reason = try allocator.dupe(u8, reason),
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
    const value = object.get(name) orelse return error.MissingAutonomyField;
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidAutonomyField,
    };
}

fn optionalIntegerField(object: std.json.ObjectMap, name: []const u8) !?u32 {
    const value = object.get(name) orelse return error.MissingAutonomyField;
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
    const value = object.get("tags") orelse return error.MissingAutonomyField;
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
        "\nAUTONOMY PARSE ERROR\nPROVIDER: random selected\nERROR: {s}\nEXPECTED: strict JSON object with command/text/query/memory_id/schedule/heat_bias/tags/salience/reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ @errorName(err), content },
    );
}

fn reportAutonomyProviderParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nAUTONOMY PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON object with command/text/query/memory_id/schedule/heat_bias/tags/salience/reason\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

fn parseCommand(text: []const u8) ?chat.ChatCommandType {
    inline for (@typeInfo(chat.ChatCommandType).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(chat.ChatCommandType, field.name);
    }
    return null;
}

fn parseSalience(text: []const u8) ?Salience {
    inline for (@typeInfo(Salience).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(Salience, field.name);
    }
    return null;
}

test "parseAutonomyTurn rejects proactive camera capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidAutonomyCommand, parseAutonomyTurn(allocator,
        \\{"command":"take_picture","salience":"high","reason":"curious"}
    ));
}

test "random-provider autonomy schema matches strict required envelope" {
    const schema = autonomyJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"command\",\"text\",\"query\",\"memory_id\",\"schedule\",\"heat_bias\",\"eyes\",\"mouth\",\"duration_ms\",\"tags\",\"salience\",\"reason\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"additionalProperties\":false") != null);
}

test "parseAutonomyTurn accepts a reflective command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"command":"think_about","text":null,"query":"energy","memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":["self"],"salience":"medium","reason":"checking limits"}
    );
    try std.testing.expectEqual(chat.ChatCommandType.think_about, turn.command.command);
    try std.testing.expectEqual(Salience.medium, turn.salience);
}

test "parseAutonomyTurn rejects wrong optional field type clearly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidAutonomyField, parseAutonomyTurn(allocator,
        \\{"command":"dream","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":0.5,"eyes":null,"mouth":null,"duration_ms":null,"tags":[],"salience":"low","reason":"resting"}
    ));
}

test "parseAutonomyTurn accepts facial expression fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseAutonomyTurn(allocator,
        \\{"command":"facial_expression","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":"neutral","mouth":"open","duration_ms":5000,"tags":["visible_affect"],"salience":"low","reason":"visible reaction"}
    );
    try std.testing.expectEqual(chat.ChatCommandType.facial_expression, turn.command.command);
    try std.testing.expectEqualStrings("neutral", turn.command.eyes.?);
    try std.testing.expectEqualStrings("open", turn.command.mouth.?);
    try std.testing.expectEqual(@as(?u32, 5000), turn.command.duration_ms);
}

test "OpenAI autonomy request uses strict response schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body = try buildOpenAIAutonomyRequestBody(allocator, "gpt-4.1-nano", null, "system", "user");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"json_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"heat_bias\":{\"type\":[\"string\",\"null\"]") != null);
}

test "Anthropic autonomy request uses strict tool schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = try anthropicJsonToolConfig(allocator);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"input_schema\":{\"type\":\"object\",\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"required\":[\"command\",\"text\",\"query\",\"memory_id\",\"schedule\",\"heat_bias\",\"eyes\",\"mouth\",\"duration_ms\",\"tags\",\"salience\",\"reason\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"tool_choice\":{\"type\":\"tool\",\"name\":\"json_response\"}") != null);
}
