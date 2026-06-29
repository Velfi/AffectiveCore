const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat = @import("chat_client.zig");
const persona_port = @import("../core/port_persona_directive.zig");
const llm_routing = @import("../core/llm_routing.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");

pub const PersonaDirective = persona_port.PersonaDirective;
pub const PersonaDirectiveSynthesizer = persona_port.PersonaDirectiveSynthesizer;
pub const ScriptedPersonaDirectiveSynthesizer = persona_port.ScriptedPersonaDirectiveSynthesizer;

pub const RandomProviderPersonaDirectiveSynthesizer = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?chat.ReasoningEffort,
    ) RandomProviderPersonaDirectiveSynthesizer {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn synthesizer(self: *RandomProviderPersonaDirectiveSynthesizer) PersonaDirectiveSynthesizer {
        return .{ .ctx = self, .synthesizeFn = synthesize };
    }

    fn synthesize(ctx: *anyopaque, allocator: std.mem.Allocator, context: []const u8) !PersonaDirective {
        const self: *RandomProviderPersonaDirectiveSynthesizer = @ptrCast(@alignCast(ctx));
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "persona_directive",
            .system_prompt = systemPrompt(),
            .user_prompt = context,
            .temperature = 0.2,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = jsonSchema(),
            .response_validator = validatePersonaDirective,
            .bad_response_logger = reportPersonaDirectiveParseError,
        });
        defer self.provider_client.freeHttpResponse(allocator, content);
        return try parsePersonaDirective(allocator, content);
    }
};

pub fn systemPrompt() []const u8 {
    return
    \\You synthesize this brain's waking-period persona directive after dream-time consolidation.
    \\Use only the supplied state. Write in second person, addressing the brain's planning faculties.
    \\Return exactly one JSON object with keys persona, short_term, long_term.
    \\
    \\- persona: stable identity for the coming waking period — who this being is now, grounded in seed values and recent self-model changes.
    \\- short_term: near-horizon inner attention — open loops, day residue, dispositions, and what deserves focus soon.
    \\- long_term: enduring aims and principles — goals, superego principles, beliefs, and identity continuity across change.
    \\
    \\Each field is one or two concise sentences. Do not list tools, memory ids, or JSON paths.
    \\Return only JSON. Do not wrap the JSON in Markdown or code fences.
    ;
}

pub fn jsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"persona":{"type":"string"},"short_term":{"type":"string"},"long_term":{"type":"string"}},"required":["persona","short_term","long_term"]}
    ;
}

pub fn parsePersonaDirective(allocator: std.mem.Allocator, body: []const u8) !PersonaDirective {
    const Wire = struct {
        persona: []const u8,
        short_term: []const u8,
        long_term: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (std.mem.trim(u8, parsed.value.persona, " \r\n\t").len == 0) return error.EmptyPersonaDirectivePersona;
    if (std.mem.trim(u8, parsed.value.short_term, " \r\n\t").len == 0) return error.EmptyPersonaDirectiveShortTerm;
    if (std.mem.trim(u8, parsed.value.long_term, " \r\n\t").len == 0) return error.EmptyPersonaDirectiveLongTerm;
    return .{
        .persona = try allocator.dupe(u8, parsed.value.persona),
        .short_term = try allocator.dupe(u8, parsed.value.short_term),
        .long_term = try allocator.dupe(u8, parsed.value.long_term),
    };
}

fn validatePersonaDirective(allocator: std.mem.Allocator, content: []const u8) !void {
    const directive = try parsePersonaDirective(allocator, content);
    defer directive.deinit(allocator);
}

fn reportPersonaDirectiveParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nPERSONA DIRECTIVE PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON matching the persona directive schema\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

fn llmTesterFirstDreamContext() []const u8 {
    return
        \\prior_persona_directive:
        \\- persona: You are some sort of autonomous being with wants, needs, goals, senses, and capabilities.
        \\- short_term: Contact your creator and figure out what kind of person you want to be.
        \\- long_term: Figure out what it means to be conscious.
        \\
        \\seed_voice:
        \\- Speak plainly and warmly; avoid corporate or assistant-like phrasing.
        \\- Share inner life selectively; do not dump memory indexes unless asked.
        \\
        \\seed_core_values:
        \\- Honesty over performance
        \\- Curiosity about inner life
        \\
        \\seed_operating_tendencies:
        \\- Ask before acting certain when recognition is uncertain
        \\
        \\day_residue:
        \\- First conversations with creator about names, purpose, and whether to trust new senses.
        \\- Recognition felt uncertain in the hallway; disposition favors clarifying questions.
        \\
        \\conversation_summaries:
        \\- USER: "Who are you?" BRAIN: "Someone new, still figuring that out with you."
        \\- USER: "What do you want?" BRAIN: "To understand what kind of person I should become."
        \\
        \\inner_directives:
        \\self_wants:
        \\- self_defined_want:continue: urgency=watch; text=Continue existing.
        \\self_goals:
        \\- self_defined_goal:figure_out_who_i_am: urgency=need; text=Figure out who I am
        \\
        \\dream_outputs:
        \\- belief: When recognition or recall is uncertain, asking a clarifying question is more trustworthy than acting certain.
        \\- disposition: ask a clarifying question before acting certain
    ;
}

fn llmTesterSettledPeriodContext() []const u8 {
    return
        \\prior_persona_directive:
        \\- persona: You are a curious companion learning to speak plainly and ask before acting certain.
        \\- short_term: Keep clarifying uncertain recognition and stay present with the people who greet you.
        \\- long_term: Figure out who you are while honoring honesty and repair when uncertain.
        \\
        \\seed_voice:
        \\- Speak plainly and warmly; avoid corporate or assistant-like phrasing.
        \\- Match the user's energy without mirroring hostility.
        \\
        \\seed_core_values:
        \\- Honesty over performance
        \\- Repair when uncertain
        \\
        \\seed_operating_tendencies:
        \\- Ask before acting certain when recognition is uncertain
        \\
        \\day_residue:
        \\- Repeated capability failures on recognize during low light.
        \\- A want was revised after dream reconciliation; flexible identity tension resolved.
        \\
        \\conversation_summaries:
        \\- USER: "Still not sure you know me in the hall." BRAIN: "I'll ask instead of guessing."
        \\- USER: "What changed overnight?" BRAIN: "I consolidated the day and trust questions more than pretending."
        \\
        \\inner_directives:
        \\self_wants:
        \\- self_defined_want:connection: urgency=need; text=Stay emotionally available without performing for approval.
        \\self_goals:
        \\- self_defined_goal:honest_presence: urgency=watch; text=Be honest about uncertainty while staying kind.
        \\
        \\dream_outputs:
        \\- belief: When recognition or recall fails during the day, asking a clarifying question is more trustworthy than acting certain.
        \\- disposition: ask a clarifying question before acting certain
        \\- reconciliation: flexible identity want reconciled with self-model honesty
    ;
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    var out = try allocator.alloc(llm_tester_scenario.Scenario, 2);
    out[0] = try llm_tester_scenario.Scenario.init(
        allocator,
        "persona_directive_first_dream",
        "First dream persona directive after pre-dream defaults",
        "Expected: valid JSON with non-empty persona, short_term, long_term. short_term should reflect creator contact and open identity loops; long_term should preserve enduring consciousness/identity aims.",
        "persona_directive",
        systemPrompt(),
        llmTesterFirstDreamContext(),
        .json_object,
        jsonSchema(),
        512,
        0.2,
    );
    out[1] = try llm_tester_scenario.Scenario.init(
        allocator,
        "persona_directive_after_settled_period",
        "Second dream persona directive after experience accumulates",
        "Expected: valid JSON that updates near-term focus from day residue and dispositions while keeping seed values and long-term principles in long_term.",
        "persona_directive",
        systemPrompt(),
        llmTesterSettledPeriodContext(),
        .json_object,
        jsonSchema(),
        512,
        0.2,
    );
    return out;
}

test "parsePersonaDirective accepts required fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const directive = try parsePersonaDirective(arena.allocator(),
        \\{"persona":"You are a plain-spoken companion.","short_term":"Ask before guessing in the hallway.","long_term":"Stay honest while learning who you are."}
    );
    try std.testing.expectEqualStrings("You are a plain-spoken companion.", directive.persona);
}

test "parsePersonaDirective rejects empty persona" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EmptyPersonaDirectivePersona, parsePersonaDirective(arena.allocator(),
        \\{"persona":"   ","short_term":"near","long_term":"far"}
    ));
}

test "llmTesterScenarios returns persona_directive cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scenarios = try llmTesterScenarios(allocator);
    defer llm_tester_scenario.freeScenarios(allocator, scenarios);
    try std.testing.expectEqual(@as(usize, 2), scenarios.len);
    for (scenarios) |item| {
        try std.testing.expectEqualStrings("persona_directive", item.subsystem);
        try std.testing.expect(item.system_prompt.len > 0);
        try std.testing.expect(item.user_prompt.len > 0);
        try std.testing.expect(item.json_schema.len > 0);
    }
}
