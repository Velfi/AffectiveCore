const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat_port = @import("../core/port_chat.zig");
pub const skills = chat_port.skills;

pub const ChatTurn = chat_port.ChatTurn;
pub const ChatPrompt = chat_port.ChatPrompt;
pub const max_chat_user_prompt_bytes = chat_port.max_chat_user_prompt_bytes;
pub const ChatPromptAudit = chat_port.ChatPromptAudit;
pub const ReasoningEffort = chat_port.ReasoningEffort;
pub const ChatCommandType = chat_port.ChatCommandType;
pub const Capability = chat_port.Capability;
pub const CapabilitySet = chat_port.CapabilitySet;
pub const CommandSpec = chat_port.CommandSpec;
pub const ChatCommand = chat_port.ChatCommand;
pub const ChatService = chat_port.ChatService;
pub const commandSpec = chat_port.commandSpec;
pub const affordanceCatalog = chat_port.affordanceCatalog;

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

pub const RandomProviderChatService = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?ReasoningEffort,

    pub fn init(io: std.Io, http: http_transport.Client, models_spec: []const u8, reasoning_effort: ?ReasoningEffort) RandomProviderChatService {
        return .{
            .provider_client = ai.RandomProviderClient.init(io, http, models_spec),
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

fn reportChatParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nCHAT PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with keys commands, user_summary, brain_summary, reasoning_effort, conversation_done\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
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
