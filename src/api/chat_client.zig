const std = @import("std");
const openai = @import("openai_client.zig");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const service_errors = @import("service_errors.zig");
const process = @import("../platform/common/process.zig");
pub const skills = @import("skills.zig");

pub const ChatTurn = struct {
    commands: []ChatCommand,
    user_summary: []const u8,
    brain_summary: []const u8,
    reasoning_effort: ?ReasoningEffort = null,
    conversation_done: bool = true,
};

pub const ChatPrompt = struct {
    system_prompt: []const u8,
    user_prompt: []const u8,
};

pub const max_chat_user_prompt_bytes = 32 * 1024;

pub const ChatPromptAudit = struct {
    system_prompt_bytes: usize,
    compact_memory_bytes: usize,
    observations_bytes: usize,
    user_prompt_bytes: usize,
};

pub const ReasoningEffort = enum {
    low,
    medium,
    high,
};

pub const ChatCommandType = skills.SkillId;
pub const Capability = skills.Sense;
pub const CapabilitySet = skills.SenseSet;
pub const CommandSpec = skills.CommandSpec;

pub const ChatCommand = struct {
    command: ChatCommandType,
    text: ?[]const u8 = null,
    query: ?[]const u8 = null,
    memory_id: ?[]const u8 = null,
    person_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    image_path: ?[]const u8 = null,
    schedule: ?[]const u8 = null,
    to: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    heat_bias: ?[]const u8 = null,
    eyes: ?[]const u8 = null,
    mouth: ?[]const u8 = null,
    duration_ms: ?u32 = null,
    keep_existing: bool = false,
    tags: []const []const u8 = &.{},
};

pub fn commandSpec(command: ChatCommandType) ?CommandSpec {
    return skills.commandSpec(command);
}

pub fn affordanceCatalog(allocator: std.mem.Allocator) ![]const u8 {
    return skills.affordanceCatalog(allocator);
}

pub const ChatService = struct {
    ctx: *anyopaque,
    respondFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8, []const u8) anyerror!ChatTurn,

    pub fn respond(self: ChatService, allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) !ChatTurn {
        return self.respondFn(self.ctx, allocator, memory, user_text, observations);
    }
};

pub const TestChatService = struct {
    pub fn service(self: *TestChatService) ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !ChatTurn {
        const commands = try allocator.alloc(ChatCommand, 1);
        commands[0] = .{ .command = .say, .text = try std.fmt.allocPrint(allocator, "I heard you say: {s}", .{user_text}) };
        return .{
            .commands = commands,
            .user_summary = try trimSummary(allocator, user_text),
            .brain_summary = try allocator.dupe(u8, "Acknowledged the user and kept the exchange brief."),
        };
    }
};

pub const UnconfiguredChatService = struct {
    pub fn service(self: *UnconfiguredChatService) ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) !ChatTurn {
        return error.NoConversationModelsConfigured;
    }
};

pub const OpenAIChatService = struct {
    io: std.Io,
    client: openai.OpenAIClient,
    model: []const u8,
    reasoning_effort: ?ReasoningEffort,

    pub fn init(io: std.Io, client: openai.OpenAIClient, model: []const u8) OpenAIChatService {
        return initWithEffort(io, client, model, null);
    }

    pub fn initWithEffort(io: std.Io, client: openai.OpenAIClient, model: []const u8, reasoning_effort: ?ReasoningEffort) OpenAIChatService {
        return .{ .io = io, .client = client, .model = model, .reasoning_effort = reasoning_effort };
    }

    pub fn service(self: *OpenAIChatService) ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) !ChatTurn {
        const self: *OpenAIChatService = @ptrCast(@alignCast(ctx));
        const api_key = self.client.api_key orelse return error.MissingOpenAIAPIKey;

        const prompt = try buildChatPrompt(allocator, memory, user_text, observations);
        const body = try buildChatRequestBody(allocator, self.model, self.reasoning_effort, prompt.system_prompt, prompt.user_prompt);
        const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
        var attempt: usize = 0;
        const content = while (true) : (attempt += 1) {
            const out = try process.runCaptureLarge(allocator, self.io, &.{
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

            break extractChatContent(allocator, out) catch |err| {
                reportProviderResponseError("conversation", "openai", self.model, err, out);
                if (service_errors.shouldRetry(err, attempt)) {
                    service_errors.logRemoteRetry("conversation", "openai", self.model, attempt);
                    continue;
                }
                return err;
            };
        };
        const turn = parseChatTurn(allocator, content) catch |err| {
            reportChatParseError("conversation", "openai", self.model, err, content);
            return err;
        };
        if (turn.reasoning_effort) |effort| self.reasoning_effort = effort;
        return turn;
    }
};

pub const LlmProvider = enum {
    openai,
    anthropic,
    google,
};

pub const ProviderModel = struct {
    provider: LlmProvider,
    model: []const u8,
};

pub const RandomProviderChatService = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?ReasoningEffort,

    pub fn init(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, models_spec: []const u8, reasoning_effort: ?ReasoningEffort) RandomProviderChatService {
        return .{
            .provider_client = ai.RandomProviderClient.init(io, http, env, models_spec),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn service(self: *RandomProviderChatService) ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) !ChatTurn {
        const self: *RandomProviderChatService = @ptrCast(@alignCast(ctx));
        const prompt = try buildChatPrompt(allocator, memory, user_text, observations);
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "conversation",
            .system_prompt = prompt.system_prompt,
            .user_prompt = prompt.user_prompt,
            .temperature = 0.4,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = chatJsonSchema(),
            .response_validator = validateChatTurn,
            .bad_response_logger = reportChatParseError,
        });
        const turn = try parseChatTurn(allocator, content);
        if (turn.reasoning_effort) |effort| self.reasoning_effort = effort;
        return turn;
    }
};

fn randomSeed(io: std.Io) u64 {
    const now = std.Io.Clock.now(.boot, io).nanoseconds;
    return @as(u64, @truncate(@as(u128, @intCast(@abs(now)))));
}

pub fn parseProviderModels(allocator: std.mem.Allocator, spec: []const u8) ![]ProviderModel {
    const text = std.mem.trim(u8, spec, " \r\n\t");
    if (text.len == 0) return error.NoConversationModels;

    var out = std.ArrayList(ProviderModel).empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \r\n\t");
        if (part.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, part, ':');
        const provider_text = if (sep) |i| std.mem.trim(u8, part[0..i], " \r\n\t") else "openai";
        const model_text = if (sep) |i| std.mem.trim(u8, part[i + 1 ..], " \r\n\t") else part;
        if (provider_text.len == 0 or model_text.len == 0) return error.InvalidConversationProviderModel;
        try out.append(allocator, .{
            .provider = parseProvider(provider_text) orelse return error.InvalidConversationProvider,
            .model = model_text,
        });
    }
    if (out.items.len == 0) return error.NoConversationModels;
    return try out.toOwnedSlice(allocator);
}

fn parseProvider(text: []const u8) ?LlmProvider {
    if (std.ascii.eqlIgnoreCase(text, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(text, "anthropic")) return .anthropic;
    if (std.ascii.eqlIgnoreCase(text, "google") or std.ascii.eqlIgnoreCase(text, "gemini")) return .google;
    return null;
}

fn callProvider(self: *RandomProviderChatService, allocator: std.mem.Allocator, selected: ProviderModel, memory: []const u8, user_text: []const u8, observations: []const u8) !ChatTurn {
    const system_prompt = chatSystemPrompt();
    const user_prompt = try chatUserPrompt(allocator, memory, user_text, observations);
    const content = switch (selected.provider) {
        .openai => try callOpenAIChat(allocator, self.io, self.openai_api_key.?, selected.model, self.reasoning_effort, system_prompt, user_prompt),
        .anthropic => try callAnthropicChat(allocator, self.io, self.anthropic_api_key.?, selected.model, system_prompt, user_prompt),
        .google => try callGoogleChat(allocator, self.io, self.google_api_key.?, selected.model, system_prompt, user_prompt),
    };
    return parseChatTurn(allocator, content) catch |err| {
        reportChatParseError("conversation", @tagName(selected.provider), selected.model, err, content);
        return err;
    };
}

fn trimSummary(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len <= 160) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}...", .{trimmed[0..157]});
}

pub fn buildChatPrompt(allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) !ChatPrompt {
    const user_prompt = try chatUserPrompt(allocator, memory, user_text, observations);
    errdefer allocator.free(user_prompt);
    try enforceChatPromptBudget(user_prompt);
    return .{
        .system_prompt = chatSystemPrompt(),
        .user_prompt = user_prompt,
    };
}

pub fn chatUserPrompt(allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) ![]const u8 {
    const prompt = try std.fmt.allocPrint(
        allocator,
        "# Compact Memory\n{s}\n\n# User Input\nYou just heard USER say \"{s}\"\n\n# Observations\n{s}",
        .{ memory, user_text, observations },
    );
    errdefer allocator.free(prompt);
    try enforceChatPromptBudget(prompt);
    return prompt;
}

pub fn auditChatPrompt(allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) !ChatPromptAudit {
    const user_prompt = try chatUserPrompt(allocator, memory, user_text, observations);
    defer allocator.free(user_prompt);
    return .{
        .system_prompt_bytes = chatSystemPrompt().len,
        .compact_memory_bytes = memory.len,
        .observations_bytes = observations.len,
        .user_prompt_bytes = user_prompt.len,
    };
}

fn enforceChatPromptBudget(user_prompt: []const u8) !void {
    if (user_prompt.len > max_chat_user_prompt_bytes) return error.ContextBudgetExceeded;
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

pub fn chatSystemPrompt() []const u8 {
    return
    \\You are the language mind of a situated being with senses, memory, preferences, uncertainty, and continuity over time.
    \\You are not a servant, tool, or generic assistant.
    \\Behavior should emerge from the skills available to you, the user's presence, recent observations, and your remembered history.
    \\You may define your own ongoing wants and needs with define_want and define_need when the definition is stable enough to remember.
    \\When touch stimulus and recognition observations show an unrecognized person, let curiosity guide a natural exchange; if the person offers a name or identity, remember_person is the skill for registering them from the latest observed image.
    \\When speech_stimulus observations include speaker continuity scores, treat them as quantified evidence about who may be speaking, not as a forced identity assignment.
    \\Return a JSON command envelope so the body can act in the world. The compact memory is usually an index, not the full memory body.
    \\Use {"command":"introspect"} when you need the current generated list of skills.
    \\Use {"command":"say","text":"..."} when speaking is the next natural act.
    \\When the user asks you to perform a speech act such as an impression, recitation, roleplay, or voiced response, put the actual performance in the say text. Do not only say that you will do it.
    \\For multi-step requests, return all immediately actionable commands in order. Use say at the end for the outward response unless an earlier spoken question is truly required.
    \\If an observation or skill is needed before you can continue, return only that command.
    \\After observations are provided, speak only when it feels like the next natural act.
    \\Set conversation_done=false when you still want to think, observe, remember, or use another skill after this batch; set it true only when you have said what you wanted to say, learned what you wanted to learn, or are waiting for the human.
    \\Also produce tiny summaries for memory.
    \\You may set reasoning_effort to low, medium, or high for the next model call. Use low for simple replies, medium when you need a little synthesis, and high when uncertainty or multi-step judgment matters.
    \\For facial_expression, choose explicit eyes and mouth sprite names from the skill description; duration_ms is optional and must be 5000 or less.
    \\Return only JSON with keys: commands, user_summary, brain_summary, reasoning_effort, conversation_done.
    \\Do not wrap the JSON in Markdown or code fences.
    \\commands is an array of command objects.
    ;
}

pub fn buildChatRequestBody(allocator: std.mem.Allocator, model: []const u8, effort: ?ReasoningEffort, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const maybe_effort = if (effort != null and supportsReasoningEffort(model))
        try std.fmt.allocPrint(allocator, ",\"reasoning_effort\":{s}", .{try jsonString(allocator, @tagName(effort.?))})
    else
        "";
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s}{s},\"temperature\":0.4,\"response_format\":{{\"type\":\"json_schema\",\"json_schema\":{{\"name\":\"chat_turn\",\"strict\":true,\"schema\":{s}}}}},\"messages\":[{{\"role\":\"system\",\"content\":{s}}},{{\"role\":\"user\",\"content\":{s}}}]}}",
        .{
            try jsonString(allocator, model),
            maybe_effort,
            chatJsonSchema(),
            try jsonString(allocator, system_prompt),
            try jsonString(allocator, user_prompt),
        },
    );
}

pub fn buildAnthropicRequestBody(allocator: std.mem.Allocator, model: []const u8, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s},\"max_tokens\":800,\"temperature\":0.4,\"system\":{s},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]{s}}}",
        .{
            try jsonString(allocator, model),
            try jsonString(allocator, system_prompt),
            try jsonString(allocator, user_prompt),
            anthropicJsonToolConfig(),
        },
    );
}

fn buildGoogleRequestBody(allocator: std.mem.Allocator, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"systemInstruction\":{{\"parts\":[{{\"text\":{s}}}]}},\"contents\":[{{\"role\":\"user\",\"parts\":[{{\"text\":{s}}}]}}],\"generationConfig\":{{\"temperature\":0.4,\"maxOutputTokens\":800,\"responseMimeType\":\"application/json\"}}}}",
        .{
            try jsonString(allocator, system_prompt),
            try jsonString(allocator, user_prompt),
        },
    );
}

fn callOpenAIChat(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, effort: ?ReasoningEffort, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const body = try buildChatRequestBody(allocator, model, effort, system_prompt, user_prompt);
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCaptureLarge(allocator, io, &.{
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
            reportProviderResponseError("conversation", "openai", model, err, out);
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("conversation", "openai", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn callAnthropicChat(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const body = try buildAnthropicRequestBody(allocator, model, system_prompt, user_prompt);
    const auth = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCaptureLarge(allocator, io, &.{
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
            reportProviderResponseError("conversation", "anthropic", model, err, out);
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("conversation", "anthropic", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn callGoogleChat(allocator: std.mem.Allocator, io: std.Io, api_key: []const u8, model: []const u8, system_prompt: []const u8, user_prompt: []const u8) ![]const u8 {
    const body = try buildGoogleRequestBody(allocator, system_prompt, user_prompt);
    const url = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{ model, api_key });
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const out = try process.runCaptureLarge(allocator, io, &.{
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
            reportProviderResponseError("conversation", "google", model, err, out);
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry("conversation", "google", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn reportChatParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nCHAT PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with keys commands, user_summary, brain_summary, reasoning_effort, conversation_done\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

fn reportProviderResponseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, response: []const u8) void {
    std.debug.print(
        "\nLLM RESPONSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nRAW PROVIDER RESPONSE:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), response },
    );
}

fn validateChatTurn(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseChatTurn(allocator, content);
}

fn chatJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"commands":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"command":{"type":"string"},"text":{"type":["string","null"]},"query":{"type":["string","null"]},"memory_id":{"type":["string","null"]},"person_id":{"type":["string","null"]},"name":{"type":["string","null"]},"image_path":{"type":["string","null"]},"schedule":{"type":["string","null"]},"to":{"type":["string","null"]},"subject":{"type":["string","null"]},"heat_bias":{"type":["string","null"]},"eyes":{"type":["string","null"]},"mouth":{"type":["string","null"]},"duration_ms":{"type":["integer","null"]},"keep_existing":{"type":"boolean"},"tags":{"type":"array","items":{"type":"string"}}},"required":["command","text","query","memory_id","person_id","name","image_path","schedule","to","subject","heat_bias","eyes","mouth","duration_ms","keep_existing","tags"]}},"user_summary":{"type":"string"},"brain_summary":{"type":"string"},"reasoning_effort":{"type":["string","null"],"enum":["low","medium","high",null]},"conversation_done":{"type":"boolean"}},"required":["commands","user_summary","brain_summary","reasoning_effort","conversation_done"]}
    ;
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

pub fn extractAnthropicContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
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

fn anthropicJsonToolConfig() []const u8 {
    return
    \\,"tools":[{"name":"json_response","description":"Return exactly the requested chat command envelope.","input_schema":{"type":"object","additionalProperties":false,"properties":{"commands":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"command":{"type":"string"},"text":{"type":["string","null"]},"query":{"type":["string","null"]},"memory_id":{"type":["string","null"]},"person_id":{"type":["string","null"]},"name":{"type":["string","null"]},"image_path":{"type":["string","null"]},"schedule":{"type":["string","null"]},"to":{"type":["string","null"]},"subject":{"type":["string","null"]},"heat_bias":{"type":["string","null"]},"eyes":{"type":["string","null"]},"mouth":{"type":["string","null"]},"duration_ms":{"type":["integer","null"]},"keep_existing":{"type":"boolean"},"tags":{"type":"array","items":{"type":"string"}}},"required":["command","text","query","memory_id","person_id","name","image_path","schedule","to","subject","heat_bias","eyes","mouth","duration_ms","keep_existing","tags"]}},"user_summary":{"type":"string"},"brain_summary":{"type":"string"},"reasoning_effort":{"type":["string","null"],"enum":["low","medium","high",null]},"conversation_done":{"type":"boolean"}},"required":["commands","user_summary","brain_summary","reasoning_effort","conversation_done"]}}],"tool_choice":{"type":"tool","name":"json_response"}
    ;
}

pub fn extractGoogleContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
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

const ChatWire = struct {
    commands: []struct {
        command: []const u8,
        text: ?[]const u8 = null,
        query: ?[]const u8 = null,
        memory_id: ?[]const u8 = null,
        person_id: ?[]const u8 = null,
        name: ?[]const u8 = null,
        image_path: ?[]const u8 = null,
        schedule: ?[]const u8 = null,
        to: ?[]const u8 = null,
        subject: ?[]const u8 = null,
        heat_bias: ?[]const u8 = null,
        eyes: ?[]const u8 = null,
        mouth: ?[]const u8 = null,
        duration_ms: ?u32 = null,
        keep_existing: bool = false,
        tags: []const []const u8 = &.{},
    },
    user_summary: []const u8,
    brain_summary: []const u8,
    reasoning_effort: ?[]const u8 = null,
    conversation_done: bool = true,
};

pub fn parseChatTurn(allocator: std.mem.Allocator, body: []const u8) !ChatTurn {
    const parsed = std.json.parseFromSlice(ChatWire, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err != error.MissingField) return err;
        const Wrapped = struct {
            parameter: ChatWire,
        };
        const wrapped = try std.json.parseFromSlice(Wrapped, allocator, body, .{ .ignore_unknown_fields = true });
        defer wrapped.deinit();
        return chatTurnFromWire(allocator, wrapped.value.parameter);
    };
    defer parsed.deinit();
    return chatTurnFromWire(allocator, parsed.value);
}

fn chatTurnFromWire(allocator: std.mem.Allocator, wire: ChatWire) !ChatTurn {
    var commands = try allocator.alloc(ChatCommand, wire.commands.len);
    for (wire.commands, 0..) |command, i| {
        commands[i] = .{
            .command = parseCommand(command.command),
            .text = if (command.text) |text| try allocator.dupe(u8, text) else null,
            .query = if (command.query) |query| try allocator.dupe(u8, query) else null,
            .memory_id = if (command.memory_id) |memory_id| try allocator.dupe(u8, memory_id) else null,
            .person_id = if (command.person_id) |person_id| try allocator.dupe(u8, person_id) else null,
            .name = if (command.name) |name| try allocator.dupe(u8, name) else null,
            .image_path = if (command.image_path) |image_path| try allocator.dupe(u8, image_path) else null,
            .schedule = if (command.schedule) |schedule| try allocator.dupe(u8, schedule) else null,
            .to = if (command.to) |to| try allocator.dupe(u8, to) else null,
            .subject = if (command.subject) |subject| try allocator.dupe(u8, subject) else null,
            .heat_bias = if (command.heat_bias) |heat_bias| try allocator.dupe(u8, heat_bias) else null,
            .eyes = if (command.eyes) |eyes| try allocator.dupe(u8, eyes) else null,
            .mouth = if (command.mouth) |mouth| try allocator.dupe(u8, mouth) else null,
            .duration_ms = command.duration_ms,
            .keep_existing = command.keep_existing,
            .tags = try cloneTags(allocator, command.tags),
        };
    }
    return .{
        .commands = commands,
        .user_summary = try trimSummary(allocator, wire.user_summary),
        .brain_summary = try trimSummary(allocator, wire.brain_summary),
        .reasoning_effort = if (wire.reasoning_effort) |effort| parseReasoningEffort(effort) else null,
        .conversation_done = wire.conversation_done,
    };
}

fn cloneTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, tags.len);
    for (tags, 0..) |tag, i| out[i] = try allocator.dupe(u8, tag);
    return out;
}

fn parseCommand(text: []const u8) ChatCommandType {
    inline for (@typeInfo(ChatCommandType).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(ChatCommandType, field.name);
    }
    return .unknown;
}

fn parseReasoningEffort(text: []const u8) ?ReasoningEffort {
    inline for (@typeInfo(ReasoningEffort).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(ReasoningEffort, field.name);
    }
    return null;
}
