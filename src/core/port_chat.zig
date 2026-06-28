const std = @import("std");
const context_tokens = @import("context_tokens.zig");
pub const skills = @import("port_skills.zig");

pub const ChatTurn = struct {
    action_pressures: []ActionProposal,
    user_summary: []const u8,
    brain_summary: []const u8,
    reasoning_effort: ?ReasoningEffort = null,
    effort_tier: ?EffortTier = null,
    turn_complete: bool = true,
};

pub const ChatPrompt = struct {
    system_prompt: []const u8,
    user_prompt: []const u8,
};

pub const max_chat_context_tokens = context_tokens.max_context_tokens;

pub const ChatPromptAudit = struct {
    system_prompt_bytes: usize,
    compact_memory_bytes: usize,
    observations_bytes: usize,
    user_prompt_bytes: usize,
    user_prompt_tokens: usize,
};

pub const ReasoningEffort = enum {
    low,
    medium,
    high,
};

pub const EffortTier = enum {
    basic,
    standard,
    complex,
};

pub const ActionProposalType = skills.SkillId;
pub const Capability = skills.Sense;
pub const CapabilitySet = skills.SenseSet;
pub const ActionSpec = skills.ActionSpec;
pub const ActionOrigin = enum { interaction, autonomy };
pub const ActionScale = enum { full, medium, tiny };

pub const ActionProposal = struct {
    action: ActionProposalType,
    origin: ActionOrigin = .interaction,
    delay_ms: ?u32 = null,
    scale: ActionScale = .full,
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
    process_goal: ?[]const u8 = null,
};

pub fn cloneActionProposal(allocator: std.mem.Allocator, source: ActionProposal) !ActionProposal {
    var proposal = source;
    if (source.text) |text| proposal.text = try allocator.dupe(u8, text);
    if (source.query) |query| proposal.query = try allocator.dupe(u8, query);
    if (source.memory_id) |memory_id| proposal.memory_id = try allocator.dupe(u8, memory_id);
    if (source.person_id) |person_id| proposal.person_id = try allocator.dupe(u8, person_id);
    if (source.name) |name| proposal.name = try allocator.dupe(u8, name);
    if (source.image_path) |image_path| proposal.image_path = try allocator.dupe(u8, image_path);
    if (source.schedule) |schedule| proposal.schedule = try allocator.dupe(u8, schedule);
    if (source.to) |to| proposal.to = try allocator.dupe(u8, to);
    if (source.subject) |subject| proposal.subject = try allocator.dupe(u8, subject);
    if (source.heat_bias) |heat_bias| proposal.heat_bias = try allocator.dupe(u8, heat_bias);
    if (source.eyes) |eyes| proposal.eyes = try allocator.dupe(u8, eyes);
    if (source.mouth) |mouth| proposal.mouth = try allocator.dupe(u8, mouth);
    if (source.process_goal) |process_goal| proposal.process_goal = try allocator.dupe(u8, process_goal);
    if (source.tags.len > 0) {
        const tags = try allocator.alloc([]const u8, source.tags.len);
        for (source.tags, 0..) |tag, index| tags[index] = try allocator.dupe(u8, tag);
        proposal.tags = tags;
    } else {
        proposal.tags = &.{};
    }
    return proposal;
}

pub fn freeActionProposal(allocator: std.mem.Allocator, proposal: ActionProposal) void {
    if (proposal.text) |text| allocator.free(text);
    if (proposal.query) |query| allocator.free(query);
    if (proposal.memory_id) |memory_id| allocator.free(memory_id);
    if (proposal.person_id) |person_id| allocator.free(person_id);
    if (proposal.name) |name| allocator.free(name);
    if (proposal.image_path) |image_path| allocator.free(image_path);
    if (proposal.schedule) |schedule| allocator.free(schedule);
    if (proposal.to) |to| allocator.free(to);
    if (proposal.subject) |subject| allocator.free(subject);
    if (proposal.heat_bias) |heat_bias| allocator.free(heat_bias);
    if (proposal.eyes) |eyes| allocator.free(eyes);
    if (proposal.mouth) |mouth| allocator.free(mouth);
    if (proposal.process_goal) |process_goal| allocator.free(process_goal);
    for (proposal.tags) |tag| allocator.free(tag);
    if (proposal.tags.len > 0) allocator.free(proposal.tags);
}

pub fn freeActionProposals(allocator: std.mem.Allocator, proposals: []const ActionProposal) void {
    for (proposals) |proposal| freeActionProposal(allocator, proposal);
    if (proposals.len > 0) allocator.free(@constCast(proposals));
}

pub fn actionSpec(action: ActionProposalType) ?ActionSpec {
    return skills.actionSpec(action);
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
        const action_pressures = try allocator.alloc(ActionProposal, 1);
        action_pressures[0] = .{ .action = .say, .text = try std.fmt.allocPrint(allocator, "I heard you say: {s}", .{user_text}) };
        return .{
            .action_pressures = action_pressures,
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

pub fn buildChatPrompt(allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8, max_tokens: usize) !ChatPrompt {
    const user_prompt = try chatUserPrompt(allocator, memory, user_text, observations, max_tokens);
    errdefer allocator.free(user_prompt);
    try enforceChatPromptBudget(user_prompt, max_tokens);
    return .{
        .system_prompt = chatSystemPrompt(),
        .user_prompt = user_prompt,
    };
}

fn chatUserInputLine(allocator: std.mem.Allocator, user_text: []const u8, observations: []const u8) ![]const u8 {
    _ = observations;
    return try std.fmt.allocPrint(allocator, "Stimulus: \"{s}\"", .{user_text});
}

fn chatUserPromptText(allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) ![]const u8 {
    const user_input_line = try chatUserInputLine(allocator, user_text, observations);
    defer allocator.free(user_input_line);
    return try std.fmt.allocPrint(
        allocator,
        "# Compact Memory\n{s}\n\n# User Input\n{s}\n\n# Observations\n{s}",
        .{ memory, user_input_line, observations },
    );
}

pub fn chatUserPrompt(allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8, max_tokens: usize) ![]const u8 {
    const prompt = try chatUserPromptText(allocator, memory, user_text, observations);
    errdefer allocator.free(prompt);
    try enforceChatPromptBudget(prompt, max_tokens);
    return prompt;
}

pub fn auditChatPrompt(allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8) !ChatPromptAudit {
    const user_prompt = try chatUserPromptText(allocator, memory, user_text, observations);
    defer allocator.free(user_prompt);
    return .{
        .system_prompt_bytes = chatSystemPrompt().len,
        .compact_memory_bytes = memory.len,
        .observations_bytes = observations.len,
        .user_prompt_bytes = user_prompt.len,
        .user_prompt_tokens = context_tokens.estimateTokens(user_prompt),
    };
}

fn enforceChatPromptBudget(user_prompt: []const u8, max_tokens: usize) !void {
    if (context_tokens.exceedsTokenBudget(user_prompt, max_tokens)) return error.ContextBudgetExceeded;
}

pub fn chatPromptWithinBudget(allocator: std.mem.Allocator, memory: []const u8, user_text: []const u8, observations: []const u8, max_tokens: usize) !bool {
    const user_prompt = try chatUserPromptText(allocator, memory, user_text, observations);
    defer allocator.free(user_prompt);
    enforceChatPromptBudget(user_prompt, max_tokens) catch |err| switch (err) {
        error.ContextBudgetExceeded => return false,
        else => |e| return e,
    };
    return true;
}

pub fn chatSystemPrompt() []const u8 {
    return
    \\You represent a brain's planning faculties. Output strict JSON only—no markdown, fences, or prose outside the object.
    \\
    \\Top-level keys: action_pressures, user_summary, brain_summary, effort_tier, reasoning_effort, turn_complete.
    \\turn_complete is always true; the runtime executes one pass per dispatch.
    \\
    \\Each turn reads # Compact Memory, # User Input, and # Observations. Observations are evidence about state—not commands to repeat.
    \\Compact Memory is usually an index; use recall_fact or introspect when you need detail.
    \\
    \\## Summaries (always brief)
    \\- user_summary: what the user said or wants.
    \\- brain_summary: your internal plan/stance; not a copy of say text.
    \\
    \\## Effort (from llm_policy in Observations)
    \\- effort_tier: basic|standard|complex within allowed_tiers; use basic for trivial acks.
    \\- reasoning_effort: low|medium|high|null; null leaves prior setting.
    \\
    \\## action_pressures
    \\Ordered runnable steps for this single pass only.
    \\Each action_pressure: action, origin, delay_ms, scale, text, query, memory_id, schedule, heat_bias, eyes, mouth, duration_ms, tags.
    \\- Registered skill → put its name in action.
    \\- No skill fits → put a snake_case process goal in action (runtime expands it).
    \\- Skill-specific fields: introspect query=skill/<name> or query=skills/<group>; otherwise use null/[].
    \\- origin is usually interaction for user-directed work, autonomy for extra initiative.
    \\- scale on say: full|medium|tiny shortens speech; prefer medium/tiny over silence.
    \\- delay_ms orders timed chains within this pass.
    \\- Pack inner-life steps (feel_about, think_about, appraise_event) in the same pass before or after say when useful.
    \\- Need host data first (recognize, request_orientation, take_picture, introspect, recall_fact, …)? Emit that pull step; host_sense_pull_requested and host_sense_delivered observations carry the handoff.
    \\
    \\## Observation cues
    \\- skill_library: summary only; introspect for details.
    \\- timer_fired / waiting_for: reconsider; do not parrot reminder text.
    \\- active_activity / main_goal: continue unless the user clearly changed topic.
    \\- host_sense_pull_requested / host_sense_delivered: pending or fulfilled host pull senses; decide next steps in a later pass.
    \\- begin_subtask + text opens a child; resume_parent when done.
    \\- day_arc / recent_experience: optional color only.
    ;
}
