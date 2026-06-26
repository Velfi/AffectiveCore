const std = @import("std");
pub const skills = @import("port_skills.zig");

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
    \\Do not return multiple say commands that restate the same answer. Multiple say commands are only for genuinely distinct speech acts, such as a brief acknowledgement followed by a separate necessary question.
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
