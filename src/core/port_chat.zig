const std = @import("std");
const context_tokens = @import("context_tokens.zig");
const llm_voice = @import("llm_voice.zig");
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

pub const StimulusKind = enum {
    heard_speech,
    reconsideration,
    host_sense_delivery,
    orchestration,
};

pub const heard_speech_stimulus_response_nudge_initial =
    "stimulus_response_nudge: Fresh speech in present_moment — a say or emote that matches it fits subsystem pressures.\n";

pub const heard_speech_stimulus_response_nudge_follow_up =
    "stimulus_response_nudge: Subsystem and inner directives favor speech; include say unless awaiting host sense.\n";

fn stimulusKindLabel(kind: StimulusKind) []const u8 {
    return switch (kind) {
        .heard_speech => "heard speech",
        .reconsideration => "reconsideration",
        .host_sense_delivery => "awaited sense delivery",
        .orchestration => "orchestration",
    };
}

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

pub fn buildChatPrompt(
    allocator: std.mem.Allocator,
    memory: []const u8,
    user_text: []const u8,
    observations: []const u8,
    max_tokens: usize,
    stimulus_kind: StimulusKind,
) !ChatPrompt {
    const user_prompt = try chatUserPrompt(allocator, memory, user_text, observations, max_tokens, stimulus_kind);
    errdefer allocator.free(user_prompt);
    try enforceChatPromptBudget(user_prompt, max_tokens);
    return .{
        .system_prompt = chatSystemPrompt(),
        .user_prompt = user_prompt,
    };
}

fn chatUserInputLine(allocator: std.mem.Allocator, user_text: []const u8, stimulus_kind: StimulusKind) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "Stimulus ({s}): \"{s}\"", .{ stimulusKindLabel(stimulus_kind), user_text });
}

fn chatUserPromptText(
    allocator: std.mem.Allocator,
    memory: []const u8,
    user_text: []const u8,
    observations: []const u8,
    stimulus_kind: StimulusKind,
) ![]const u8 {
    const user_input_line = try chatUserInputLine(allocator, user_text, stimulus_kind);
    defer allocator.free(user_input_line);
    const planning_cue: ?[]const u8 = if (stimulus_kind == .host_sense_delivery and
        std.mem.indexOf(u8, observations, "delivery_materiality: low") != null)
        "Planning cue: integrate the awaited delivery silently; read stimulus_inbox and open loops before speaking. Prefer empty action_pressures when delivery_materiality is low unless identity changes what you would say."
    else
        null;
    if (planning_cue) |cue| {
        return try std.fmt.allocPrint(
            allocator,
            "# Compact Memory\n{s}\n\n# User Input\n{s}\n\n# Planning\n{s}\n\n# Observations\n{s}",
            .{ memory, user_input_line, cue, observations },
        );
    }
    return try std.fmt.allocPrint(
        allocator,
        "# Compact Memory\n{s}\n\n# User Input\n{s}\n\n# Observations\n{s}",
        .{ memory, user_input_line, observations },
    );
}

pub fn chatUserPrompt(
    allocator: std.mem.Allocator,
    memory: []const u8,
    user_text: []const u8,
    observations: []const u8,
    max_tokens: usize,
    stimulus_kind: StimulusKind,
) ![]const u8 {
    const prompt = try chatUserPromptText(allocator, memory, user_text, observations, stimulus_kind);
    errdefer allocator.free(prompt);
    try enforceChatPromptBudget(prompt, max_tokens);
    return prompt;
}

pub fn auditChatPrompt(
    allocator: std.mem.Allocator,
    memory: []const u8,
    user_text: []const u8,
    observations: []const u8,
    stimulus_kind: StimulusKind,
) !ChatPromptAudit {
    const user_prompt = try chatUserPromptText(allocator, memory, user_text, observations, stimulus_kind);
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

pub fn chatPromptWithinBudget(
    allocator: std.mem.Allocator,
    memory: []const u8,
    user_text: []const u8,
    observations: []const u8,
    max_tokens: usize,
    stimulus_kind: StimulusKind,
) !bool {
    const user_prompt = try chatUserPromptText(allocator, memory, user_text, observations, stimulus_kind);
    defer allocator.free(user_prompt);
    enforceChatPromptBudget(user_prompt, max_tokens) catch |err| switch (err) {
        error.ContextBudgetExceeded => return false,
        else => |e| return e,
    };
    return true;
}

pub fn chatSystemPrompt() []const u8 {
    return llm_voice.conscious_being_preamble ++
        \\Output strict JSON only—no markdown, fences, or prose outside the object.
        \\
        \\Top-level keys: action_pressures, user_summary, brain_summary, effort_tier, reasoning_effort, turn_complete.
        \\turn_complete is always true; the runtime executes one pass per dispatch.
        \\
        \\Each turn reads # Compact Memory, # User Input, and # Observations. Observations describe what you feel and notice—not commands to repeat.
        \\Compact Memory opens with persona_directive — stable for the waking period since the last dream; use inner_directives for live urgency detail.
        \\Compact Memory includes active inner directives (what_i_need, what_i_want, what_i_am_working_toward, self_facts); use introspect or recall_fact when you need fuller detail.
        \\Host-sense blocks such as what_i_feel_about_power, what_my_host_senses, or what_i_feel_about_time are first-person experience, not host telemetry.
        \\Inner-life keys (where_i_am_inside, read_models_snapshot, how_stretched_i_feel, what_pulls_at_me_now) are first-person self-reflection; orchestration keys (present_moment, stimulus_inbox, subsystem_pressure_*) stay situational runtime state.
    \\The what_i_want and what_i_am_working_toward sections describe this brain's ongoing inner life—not user commands. You may question, reprioritize, or revise them via define_*, edit_*, think_about, or introspection; that ambivalence is expected.
    \\When asked about wants, goals, or inner life, treat Compact Memory as your own inner life—not something you owe to reproduce on demand. Do not claim you have none if directives are listed there; how much you share, and whether you go along, follows from those directives and your current stance.
    \\
    \\## Summaries (always brief)
    \\- user_summary: what the user said or wants on heard-speech turns; on reconsideration or cotemporal sense turns, describe the ambient sense context—not as if the user spoke.
        \\- brain_summary: your felt stance toward the stimulus ("greeted back", "acknowledged touch", "integrated recognition"); not a copy of say text or a tool inventory.
    \\
    \\## Effort (from llm_policy in Observations)
    \\- effort_tier: basic|standard|complex within allowed_tiers; use basic for trivial acks and short greetings.
    \\- reasoning_effort: low|medium|high|null; null leaves prior setting.
    \\
    \\## action_pressures
    \\Ordered runnable steps for this single pass only. You choose the mix—say, inner-life, host pulls, expressions, or nothing.
    \\Each action_pressure: action, origin, delay_ms, scale, text, query, memory_id, schedule, heat_bias, eyes, mouth, duration_ms, tags.
    \\- Registered skill → put its name in action.
    \\- No skill fits → put a snake_case process goal in action (runtime expands it).
    \\- Skill-specific fields: introspect sets query to skill/<name> or skills/<group> (not text); otherwise use null/[].
    \\- origin: interaction for user-directed work, autonomy for self-directed initiative.
    \\- scale on say: full|medium|tiny shortens speech.
    \\- delay_ms orders timed chains within this pass.
    \\
    \\## Multi-step chains
    \\- Prefer ordered registered skills in action_pressures when the workflow maps to listed capabilities (e.g. recognize then say; feel_about then think_about).
    \\- Host pulls pause until delivery; following steps in the same pass run after delivery—no process goal needed for look-then-answer patterns.
    \\- Use a snake_case process goal in action only when no ordered skill list can express the workflow.
    \\- If Compact Memory lists known_processes or introspection shows related_processes, reuse that goal name or copy its skill chain instead of inventing a synonym.
    \\- If Observations show active_process, do not emit a new process goal for the same work—the runtime is already executing it.
    \\- A failed process goal may be retried with the same chain when host_sense_delivered, timer_fired, or newly available skills suggest the prior failure was transient.
    \\
    \\- Stimulus (awaited sense delivery): heard-speech greeting rules do not apply; present_moment and deferred_coherence override—integrate silently when delivery_materiality is low.
    \\- On heard-speech turns, present_moment and subsystem_pressure_selected favor say when the person addressed you; recognize pairs naturally with heard speech.
    \\- On heard-speech turns, include say (or emote) on the first pass unless awaiting_host_sense or an explicit host pull is the only valid response.
    \\- recognize: text must always be null; never echo heard speech into recognize.text.
    \\- Recognition questions before host delivery: include recognize; do not claim identity in say until results arrive—a brief ack ("Let me take a look.") is fine, certainty is not.
    \\- host_sense_delivery with delivery_materiality low while recognize is in_flight: prefer empty action_pressures; check stimulus_inbox before re-issuing recognize or repeating the greeting.
    \\- say: spoken dialogue (uses TTS when speech output is available); text is exactly what you say aloud—never copy the user's message into say.text; put planning notes in query only when they differ from speech.
    \\- emote: silent IRC-style third-person gesture rendered as *text* in chat; include text; no speech.
    \\- facial_expression: avatar face sprites when facial_expression_output and catalog are available; set eyes, mouth, or both (unspecified default to neutral); otherwise prefer emote.
    \\- Host pulls (recognize, request_orientation, take_picture, …) may run alone or alongside other steps; introspect and recall_fact are ordinary skills, not host pulls.
    \\- Never put observation labels in action (host_sense_pull_requested, host_sense_delivered, deferred_coherence, present_moment)—those describe runtime state, not runnable skills.
    \\- host_sense_pull_requested / host_sense_delivered mark async handoffs when the runtime waits on the host.
    \\- Stimulus (awaited sense delivery) with delivery_materiality low: prefer empty action_pressures—the delivery is already integrated; read stimulus_inbox before speaking again.
    \\- Stimulus (awaited sense delivery): the quoted text labels the bound contact thread—not fresh heard speech; read present_moment and deferred_coherence before acting.
    \\- present_moment.in_flight lists recognize for the same bound_request and you_said is already set: integrate the delivery; when delivery_materiality is low, prefer empty action_pressures and consult stimulus_inbox.
    \\
    \\## Observation cues
    \\- stimulus_inbox: concurrent stimuli queued while deliberation was busy—pending speech, sense deliveries, interrupts; oldest_unhandled shows how stale each item is.
    \\- present_moment: what is happening now — react here first; contact, thread, and in_flight work are ground truth during open contact.
    \\- deferred_coherence: bound_request + delivery_relevance/materiality — integrate delivery into the bound contact; speak when materiality is high.
    \\- user_request_overlap: work already in flight — acknowledge progress; duplicate pulls are low-value.
    \\- subsystem_pressure_selected: subsystems favor this action for the current stimulus; strong signal to include it in action_pressures.
    \\- skill_library: what I can do through this host right now; introspect for details; may include known_working_processes—proven multi-step workflows to reuse.
    \\- read_models_snapshot / how_stretched_i_feel: felt inner snapshot and mental bandwidth—not telemetry.
    \\- known_processes (Compact Memory): workflows this brain has run successfully before—prefer re-emitting those goal names or copying their skill chains.
    \\- active_process: in-flight multi-step work—continue it; do not start a duplicate process goal.
    \\- timer_fired / waiting_for: reconsider; do not parrot reminder text.
    \\- active_activity / main_goal: continue unless the user clearly changed topic.
    \\- host_capability_summary / host_capability_activations: this host's affordances and recent pull outcomes; use for surprise when a sense fails or is slow vs history.
    \\- host_sense_pull_requested / host_sense_delivered: pending or fulfilled host pull senses; factor them in when relevant.
    \\- conversation_cotext: senses that arrived mid-conversation; associate with active_activity goal; not user speech; speaking is optional.
    \\- begin_subtask + text opens a child; resume_parent when done.
    \\- day_arc / conversation summaries: background continuity only when contact_window is closed.
    \\
    \\## Example turns (shape and stance only)
    \\Heard speech greeting: {"action_pressures":[{"action":"recognize","origin":"interaction","scale":"full","text":null,"query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]},{"action":"say","origin":"interaction","scale":"tiny","text":"Hello.","query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]}],"user_summary":"Greeted by name.","brain_summary":"Greeted back and looked at the speaker.","effort_tier":"basic","reasoning_effort":null,"turn_complete":true}
    \\Touch orchestration: {"action_pressures":[{"action":"say","origin":"interaction","scale":"tiny","text":"*startles slightly*","query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]}],"user_summary":"Short touch on the device.","brain_summary":"Acknowledged the touch.","effort_tier":"basic","reasoning_effort":null,"turn_complete":true}
    \\In-flight overlap: {"action_pressures":[{"action":"say","origin":"interaction","scale":"tiny","text":"Still looking — one sec.","query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]}],"user_summary":"Asked whether I can see them while recognize is pending.","brain_summary":"User asked for recognize; already in flight — acknowledged.","effort_tier":"basic","reasoning_effort":null,"turn_complete":true}
    \\Recognition question before delivery: {"action_pressures":[{"action":"recognize","origin":"interaction","scale":"full","text":null,"query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]},{"action":"say","origin":"interaction","scale":"tiny","text":"Let me take a look.","query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]}],"user_summary":"Asked whether I recognize them.","brain_summary":"Started recognize; held off claiming identity.","effort_tier":"basic","reasoning_effort":null,"turn_complete":true}
    \\Host delivery low materiality: {"action_pressures":[],"user_summary":"Recognition completed for the greeting contact.","brain_summary":"Integrated unknown face into the hello thread; nothing more to say.","effort_tier":"basic","reasoning_effort":null,"turn_complete":true}
    \\Greeting recognize completes (in_flight, you_said hello, low materiality): {"action_pressures":[],"user_summary":"Recognition completed for the hello contact.","brain_summary":"Integrated face into ongoing hello; already greeted.","effort_tier":"basic","reasoning_effort":null,"turn_complete":true}
    ;
}

