const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat_port = @import("../core/port_chat.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");
const llm_routing = @import("../core/llm_routing.zig");
const capability_registry = @import("../core/capability_registry.zig");
const action_pressure_json_schema = @import("action_pressure_json_schema.zig");
const brain_mod = @import("../core/brain.zig");
pub const skills = chat_port.skills;

pub const ChatTurn = chat_port.ChatTurn;
pub const ChatPrompt = chat_port.ChatPrompt;
pub const max_chat_context_tokens = chat_port.max_chat_context_tokens;
pub const ChatPromptAudit = chat_port.ChatPromptAudit;
pub const ReasoningEffort = chat_port.ReasoningEffort;
pub const EffortTier = chat_port.EffortTier;
pub const ActionProposalType = chat_port.ActionProposalType;
pub const ActionProposal = chat_port.ActionProposal;
pub const ActionOrigin = chat_port.ActionOrigin;
pub const ActionScale = chat_port.ActionScale;
pub const Capability = chat_port.Capability;
pub const CapabilitySet = chat_port.CapabilitySet;
pub const ActionSpec = chat_port.ActionSpec;
pub const ChatService = chat_port.ChatService;
pub const actionSpec = chat_port.actionSpec;
pub const affordanceCatalog = chat_port.affordanceCatalog;
pub const buildChatPrompt = chat_port.buildChatPrompt;
pub const chatUserPrompt = chat_port.chatUserPrompt;
pub const chatPromptWithinBudget = chat_port.chatPromptWithinBudget;
pub const auditChatPrompt = chat_port.auditChatPrompt;
pub const chatSystemPrompt = chat_port.chatSystemPrompt;

pub const TestChatService = struct {
    pub fn service(self: *TestChatService) ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, user_text: []const u8, _: []const u8) !ChatTurn {
        const action_pressures = try allocator.alloc(ActionProposal, 1);
        action_pressures[0] = .{ .action = .say, .text = try std.fmt.allocPrint(allocator, "I heard you say: {s}", .{user_text}) };
        return .{
            .action_pressures = action_pressures,
            .user_summary = try trimSummary(allocator, user_text),
            .brain_summary = try allocator.dupe(u8, "Heard them and kept the moment light."),
        };
    }
};

pub const RandomProviderChatService = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?ReasoningEffort,
    effort_tier: ?EffortTier,
    parse_failure_brain: ?*brain_mod.Brain = null,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?ReasoningEffort,
    ) RandomProviderChatService {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
            .effort_tier = null,
        };
    }

    pub fn initFromModelsSpec(
        io: std.Io,
        http: http_transport.Client,
        models_spec: []const u8,
        _: ai.LlmQuality,
        reasoning_effort: ?ReasoningEffort,
    ) RandomProviderChatService {
        return .{
            .provider_client = ai.RandomProviderClient.init(io, http, models_spec),
            .reasoning_effort = reasoning_effort,
            .effort_tier = null,
        };
    }

    pub fn service(self: *RandomProviderChatService) ChatService {
        return .{ .ctx = self, .respondFn = respond };
    }

    fn respond(ctx: *anyopaque, allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) !ChatTurn {
        const self: *RandomProviderChatService = @ptrCast(@alignCast(ctx));
        const prompt = try buildChatPrompt(allocator, memory, user_text, observations, max_chat_context_tokens);
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "conversation",
            .system_prompt = prompt.system_prompt,
            .user_prompt = prompt.user_prompt,
            .temperature = 0.4,
            .response_format = .json_object,
            .response_size = .medium,
            .effort_tier = self.effort_tier,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = chatJsonSchema(),
        });
        defer allocator.free(content);
        var turn = parseChatTurn(allocator, content, user_text) catch |err| {
            reportChatParseError("conversation", "host", "host_llm_complete", err, content);
            if (self.parse_failure_brain) |brain| brain.rememberChatParseFailure(content) catch {};
            return err;
        };
        turn = applyQualityPolicy(self.provider_client.llm_quality, turn);
        if (turn.reasoning_effort) |effort| self.reasoning_effort = effort;
        if (turn.effort_tier) |tier| self.effort_tier = tier;
        return turn;
    }
};

pub fn applyQualityPolicy(quality: ai.LlmQuality, turn: ChatTurn) ChatTurn {
    var out = turn;
    if (out.effort_tier) |tier| {
        out.effort_tier = llm_routing.clampEffortTier(quality, tier);
    }
    out.reasoning_effort = llm_routing.clampReasoningEffort(quality, out.reasoning_effort);
    return out;
}

fn trimSummary(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len <= 160) return allocator.dupe(u8, trimmed);
    return std.fmt.allocPrint(allocator, "{s}...", .{trimmed[0..157]});
}

fn reportChatParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nCHAT PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with keys action_pressures, user_summary, brain_summary, reasoning_effort, effort_tier, turn_complete\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const memory =
        \\- belief: User prefers tea in the afternoon.
        \\- preference: User likes quiet mornings.
    ;
    const observations =
        \\- host_sense: orientation=upright
        \\- host_sense: ambient_light=moderate
    ;
    const prompt = try buildChatPrompt(allocator, memory, "Hello, how are you today?", observations, max_chat_context_tokens);
    defer allocator.free(prompt.user_prompt);
    const scenario = try llm_tester_scenario.Scenario.init(
        allocator,
        "conversation_greeting",
        "Conversation turn with compact memory and observations",
        "Checks that the model returns conversational reply JSON grounded in compact retrieved memories and host observations rather than echoing the greeting alone.",
        "conversation",
        prompt.system_prompt,
        prompt.user_prompt,
        .json_object,
        chatJsonSchema(),
        512,
        0.2,
    );
    const out = try allocator.alloc(llm_tester_scenario.Scenario, 1);
    out[0] = scenario;
    return out;
}

fn chatJsonSchema() []const u8 {
    return action_pressure_json_schema.strictChatTurnSchema();
}

const ActionPressureWire = struct {
    action: []const u8,
    origin: ?[]const u8 = null,
    delay_ms: ?u32 = null,
    scale: ?[]const u8 = null,
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
    keep_existing: ?bool = null,
    tags: []const []const u8 = &.{},
};

const ChatWire = struct {
    action_pressures: []ActionPressureWire,
    user_summary: ?[]const u8 = null,
    brain_summary: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    effort_tier: ?[]const u8 = null,
    turn_complete: ?bool = null,
};

pub fn parseChatTurn(allocator: std.mem.Allocator, body: []const u8, user_text: []const u8) !ChatTurn {
    const trimmed = std.mem.trim(u8, body, " \r\n\t");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "{}")) return error.LocalServiceResponseInvalid;
    const parsed = std.json.parseFromSlice(ChatWire, allocator, body, .{ .ignore_unknown_fields = true }) catch |err| {
        if (err != error.MissingField) return err;
        const Wrapped = struct {
            parameter: ChatWire,
        };
        const wrapped = std.json.parseFromSlice(Wrapped, allocator, body, .{ .ignore_unknown_fields = true }) catch |wrap_err| return wrap_err;
        defer wrapped.deinit();
        return chatTurnFromWire(allocator, wrapped.value.parameter, user_text);
    };
    defer parsed.deinit();
    return chatTurnFromWire(allocator, parsed.value, user_text);
}

fn deriveBrainSummaryFromActionPressures(allocator: std.mem.Allocator, action_pressures: []const ActionPressureWire) ![]const u8 {
    var i = action_pressures.len;
    while (i > 0) {
        i -= 1;
        if (action_pressures[i].text) |text| {
            const trimmed = std.mem.trim(u8, text, " \r\n\t");
            if (trimmed.len > 0) return trimSummary(allocator, trimmed);
        }
    }
    return allocator.dupe(u8, "Proposed action pressures without an outward say summary.");
}

fn chatTurnFromWire(allocator: std.mem.Allocator, wire: ChatWire, user_text: []const u8) !ChatTurn {
    var action_pressures = try allocator.alloc(ActionProposal, wire.action_pressures.len);
    for (wire.action_pressures, 0..) |pressure, i| {
        const resolved_action = capability_registry.actionForCapabilityId(pressure.action);
        const action = resolved_action orelse chat_port.ActionProposalType.unknown;
        const process_goal = if (resolved_action == null) try allocator.dupe(u8, pressure.action) else null;
        action_pressures[i] = .{
            .action = action,
            .origin = parseOrigin(pressure.origin orelse "interaction"),
            .delay_ms = pressure.delay_ms,
            .scale = parseScale(pressure.scale orelse "full"),
            .text = if (pressure.text) |text| try allocator.dupe(u8, text) else null,
            .query = if (pressure.query) |query| try allocator.dupe(u8, query) else null,
            .memory_id = if (pressure.memory_id) |memory_id| try allocator.dupe(u8, memory_id) else null,
            .person_id = if (pressure.person_id) |person_id| try allocator.dupe(u8, person_id) else null,
            .name = if (pressure.name) |name| try allocator.dupe(u8, name) else null,
            .image_path = if (pressure.image_path) |image_path| try allocator.dupe(u8, image_path) else null,
            .schedule = if (pressure.schedule) |schedule| try allocator.dupe(u8, schedule) else null,
            .to = if (pressure.to) |to| try allocator.dupe(u8, to) else null,
            .subject = if (pressure.subject) |subject| try allocator.dupe(u8, subject) else null,
            .heat_bias = if (pressure.heat_bias) |heat_bias| try allocator.dupe(u8, heat_bias) else null,
            .eyes = if (pressure.eyes) |eyes| try allocator.dupe(u8, eyes) else null,
            .mouth = if (pressure.mouth) |mouth| try allocator.dupe(u8, mouth) else null,
            .duration_ms = pressure.duration_ms,
            .keep_existing = pressure.keep_existing orelse false,
            .tags = try cloneTags(allocator, pressure.tags),
            .process_goal = process_goal,
        };
    }
    const user_summary = if (wire.user_summary) |summary|
        try trimSummary(allocator, summary)
    else
        try trimSummary(allocator, user_text);
    const brain_summary = if (wire.brain_summary) |summary|
        try trimSummary(allocator, summary)
    else
        try deriveBrainSummaryFromActionPressures(allocator, wire.action_pressures);
    return .{
        .action_pressures = action_pressures,
        .user_summary = user_summary,
        .brain_summary = brain_summary,
        .reasoning_effort = if (wire.reasoning_effort) |effort| parseReasoningEffort(effort) else null,
        .effort_tier = if (wire.effort_tier) |tier| parseEffortTier(tier) else null,
        .turn_complete = wire.turn_complete orelse true,
    };
}

fn cloneTags(allocator: std.mem.Allocator, tags: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, tags.len);
    for (tags, 0..) |tag, i| out[i] = try allocator.dupe(u8, tag);
    return out;
}

fn parseAction(text: []const u8) ActionProposalType {
    return capability_registry.actionForCapabilityId(text) orelse .unknown;
}

fn parseReasoningEffort(text: []const u8) ?ReasoningEffort {
    inline for (@typeInfo(ReasoningEffort).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(ReasoningEffort, field.name);
    }
    return null;
}

fn parseEffortTier(text: []const u8) ?EffortTier {
    inline for (@typeInfo(EffortTier).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(EffortTier, field.name);
    }
    return null;
}

fn parseOrigin(text: []const u8) ActionOrigin {
    if (std.mem.eql(u8, text, "autonomy")) return .autonomy;
    return .interaction;
}

fn parseScale(text: []const u8) ActionScale {
    if (std.mem.eql(u8, text, "tiny")) return .tiny;
    if (std.mem.eql(u8, text, "medium")) return .medium;
    return .full;
}

test "chat schema matches OpenAI strict envelope" {
    const schema = chatJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"type\":[\"string\",\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"action\",\"origin\",\"delay_ms\",\"scale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"action_pressures\",\"user_summary\",\"brain_summary\",\"reasoning_effort\",\"effort_tier\",\"turn_complete\"]") != null);
}
