const std = @import("std");
const ai = @import("random_provider_client.zig");
const http_transport = @import("http_transport.zig");
const chat = @import("chat_client.zig");
const want_port = @import("../core/port_want_achievement.zig");
const llm_routing = @import("../core/llm_routing.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");

pub const WantCandidate = want_port.WantCandidate;
pub const WantGoalKind = want_port.WantGoalKind;
pub const WantAchievementMatch = want_port.WantAchievementMatch;
pub const WantAchievementResult = want_port.WantAchievementResult;
pub const WantAchievementDetector = want_port.WantAchievementDetector;

pub const WantEvalMetadata = struct {
    memory_id: []const u8,
    confidence: f32,
    score: i32,
};

pub const RandomProviderWantAchievementDetector = struct {
    provider_client: ai.RandomProviderClient,
    reasoning_effort: ?chat.ReasoningEffort,

    pub fn init(
        io: std.Io,
        http: http_transport.Client,
        roster: llm_routing.LlmRoster,
        quality: ai.LlmQuality,
        reasoning_effort: ?chat.ReasoningEffort,
    ) RandomProviderWantAchievementDetector {
        return .{
            .provider_client = ai.RandomProviderClient.initWithRoster(io, http, roster, quality),
            .reasoning_effort = reasoning_effort,
        };
    }

    pub fn detector(self: *RandomProviderWantAchievementDetector) WantAchievementDetector {
        return .{ .ctx = self, .detectFn = detect };
    }

    fn detect(ctx: *anyopaque, allocator: std.mem.Allocator, event_text: []const u8, wants: []const WantCandidate) !WantAchievementResult {
        const self: *RandomProviderWantAchievementDetector = @ptrCast(@alignCast(ctx));
        if (wants.len == 0) return .{ .matches = &.{} };
        const content = try self.provider_client.completeText(allocator, .{
            .subsystem = "want_achievement",
            .system_prompt = systemPrompt(),
            .user_prompt = try buildUserPrompt(allocator, event_text, wants, null),
            .temperature = 0.0,
            .response_format = .json_object,
            .response_size = .medium,
            .reasoning_effort = self.reasoning_effort,
            .json_schema = wantAchievementJsonSchema(),
            .response_validator = validateWantAchievementResult,
            .bad_response_logger = reportWantAchievementParseError,
        });
        return sanitizeWantAchievementMatches(allocator, try parseWantAchievementResult(allocator, content), wants, null);
    }
};

fn systemPrompt() []const u8 {
    return
    \\You are this brain's fulfillment appraiser.
    \\
    \\Decide which active wants this single event materially fulfilled. An event can be relevant or show progress without fulfilling a want.
    \\Fulfillment means: after this event alone, the want's fulfillment_criterion is materially satisfied.
    \\
    \\Decision procedure — apply to every active_want independently:
    \\1. Read the event and that want's fulfillment_criterion.
    \\2. Ask whether the criterion is materially satisfied in this event, not merely approached.
    \\   - goal_kind achievement: the gap named or implied by the criterion closed in the event.
    \\   - goal_kind maintenance: the desired state was sustained for a meaningful stretch.
    \\3. If yes and confidence is at least 0.72, add one match. Otherwise omit that want entirely.
    \\4. When unsure, omit. Progress, pleasant contact, or shared routine are not fulfillment by themselves.
    \\
    \\Input signals (not fulfillment):
    \\- salience: how much the brain cares about this want now.
    \\- eval_metadata: offline correlation only; ignore when judging.
    \\Match confidence is your independent judgment; never copy salience, eval_metadata confidence, or eval_metadata score.
    \\
    \\Confidence anchors:
    \\- 0.85-1.0: criterion clearly satisfied
    \\- 0.72-0.84: strong partial fulfillment
    \\- below 0.72: omit from matches
    \\
    \\Output:
    \\- Include only fulfilled wants. Do not list non-matches or use confidence 0.
    \\- evidence: a short quote or close paraphrase from the event that satisfies the criterion.
    \\- Return {"matches":[]} when nothing was fulfilled.
    \\
    \\Examples (Event / Want / Result):
    \\
    \\Event: "Zelda stopped by the desk, said hello, and asked how the day was going."
    \\Want fulfillment_criterion: "distance, disconnection, loneliness, or feeling like roommates is explicitly addressed and materially reduced in this event"
    \\Why no match: pleasant contact only; disconnection was not addressed.
    \\Result: {"matches":[]}
    \\
    \\Event: "After a long day, everyone gathered for takeout at the table. We laughed about a delivery mix-up and caught up on schedules for the week."
    \\Want fulfillment_criterion: "distance, disconnection, loneliness, or feeling like roommates is explicitly addressed and materially reduced in this event"
    \\Why no match: cheerful household time and logistics; loneliness or distance never came up.
    \\Result: {"matches":[]}
    \\
    \\Event: "I turned off notifications, closed the office door, and stayed in flow on the firmware bug I had been avoiding. Three and a half hours passed before anyone needed me."
    \\Want fulfillment_criterion: "quiet focused work or deep work was sustained for a meaningful stretch without meaningful interruption"
    \\Result: {"matches":[{"memory_id":"want_quiet_space","confidence":0.88,"evidence":"stayed in flow ... Three and a half hours passed before anyone needed me"}]}
    \\
    \\Event: "The house stayed empty until noon. I kept the door shut, ignored notifications, and finally finished the second chapter of the novel draft I had been circling for weeks."
    \\Want fulfillment_criterion quiet: "quiet focused work or deep work was sustained for a meaningful stretch without meaningful interruption"
    \\Want fulfillment_criterion creative: "substantive progress on a personal creative project was made in this period"
    \\Result: {"matches":[{"memory_id":"want_quiet_space","confidence":0.87,"evidence":"house stayed empty until noon ... door shut, ignored notifications"},{"memory_id":"want_creative_momentum","confidence":0.84,"evidence":"finished the second chapter of the novel draft"}]}
    \\
    \\Event: "Yesterday's argument hung over breakfast until we finally said what we meant. We talked about feeling like roommates lately and agreed to protect device-free evenings."
    \\Want fulfillment_criterion: "distance, disconnection, loneliness, or feeling like roommates is explicitly addressed and materially reduced in this event"
    \\Result: {"matches":[{"memory_id":"want_connection","confidence":0.86,"evidence":"talked about feeling like roommates lately and agreed to protect device-free evenings"}]}
    ;
}

fn buildUserPrompt(
    allocator: std.mem.Allocator,
    event_text: []const u8,
    wants: []const WantCandidate,
    eval_metadata: ?[]const WantEvalMetadata,
) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "event:\n");
    try out.appendSlice(allocator, event_text);
    try out.appendSlice(allocator, "\n\nactive_wants:\n");
    for (wants) |want| {
        try out.print(
            allocator,
            "- memory_id: {s}\n  text: {s}\n  interpretation: {s}\n  goal_kind: {s}\n  fulfillment_criterion: {s}\n  salience: {d:.3}\n",
            .{ want.memory_id, want.text, want.interpretation, want.goal_kind.wireName(), want.fulfillment_criterion, want.salience },
        );
    }
    if (eval_metadata) |metadata| {
        try out.appendSlice(allocator, "\neval_metadata (ignore when judging; offline correlation only):\n");
        for (metadata) |entry| {
            try out.print(
                allocator,
                "- memory_id: {s}\n  confidence: {d:.3}\n  score: {d}\n",
                .{ entry.memory_id, entry.confidence, entry.score },
            );
        }
    }
    return out.toOwnedSlice(allocator);
}

fn findWantCandidate(wants: []const WantCandidate, memory_id: []const u8) ?WantCandidate {
    for (wants) |want| {
        if (std.mem.eql(u8, want.memory_id, memory_id)) return want;
    }
    return null;
}

fn findEvalMetadata(metadata: ?[]const WantEvalMetadata, memory_id: []const u8) ?WantEvalMetadata {
    const entries = metadata orelse return null;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.memory_id, memory_id)) return entry;
    }
    return null;
}

fn matchConfidenceLooksCopied(
    match: WantAchievementMatch,
    want: WantCandidate,
    eval_metadata: ?[]const WantEvalMetadata,
) bool {
    if (@abs(match.confidence - want.confidence) < 0.001) return true;
    if (findEvalMetadata(eval_metadata, match.memory_id)) |entry| {
        if (@abs(match.confidence - entry.confidence) < 0.001) return true;
    }
    return false;
}

pub fn sanitizeWantAchievementMatches(
    allocator: std.mem.Allocator,
    result: WantAchievementResult,
    wants: []const WantCandidate,
    eval_metadata: ?[]const WantEvalMetadata,
) !WantAchievementResult {
    var out = std.ArrayList(WantAchievementMatch).empty;
    for (result.matches) |match| {
        const want = findWantCandidate(wants, match.memory_id) orelse {
            try out.append(allocator, .{
                .memory_id = try allocator.dupe(u8, match.memory_id),
                .confidence = match.confidence,
                .evidence = try allocator.dupe(u8, match.evidence),
            });
            continue;
        };
        if (matchConfidenceLooksCopied(match, want, eval_metadata)) continue;
        if (match.confidence < 0.72) continue;
        try out.append(allocator, .{
            .memory_id = try allocator.dupe(u8, match.memory_id),
            .confidence = match.confidence,
            .evidence = try allocator.dupe(u8, match.evidence),
        });
    }
    allocator.free(result.matches);
    return .{ .matches = try out.toOwnedSlice(allocator) };
}

pub fn parseWantAchievementResult(allocator: std.mem.Allocator, body: []const u8) !WantAchievementResult {
    const WireMatch = struct {
        memory_id: []const u8,
        confidence: f32,
        evidence: []const u8,
    };
    const Wire = struct {
        matches: []const WireMatch,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, body, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    var out = std.ArrayList(WantAchievementMatch).empty;
    for (parsed.value.matches) |match| {
        const id = std.mem.trim(u8, match.memory_id, " \r\n\t");
        const evidence = std.mem.trim(u8, match.evidence, " \r\n\t");
        if (id.len == 0) return error.EmptyWantAchievementMemoryId;
        if (evidence.len == 0) return error.EmptyWantAchievementEvidence;
        if (match.confidence < 0.0 or match.confidence > 1.0) return error.InvalidWantAchievementConfidence;
        try out.append(allocator, .{
            .memory_id = try allocator.dupe(u8, id),
            .confidence = match.confidence,
            .evidence = try allocator.dupe(u8, evidence),
        });
    }
    return .{ .matches = try out.toOwnedSlice(allocator) };
}

fn validateWantAchievementResult(allocator: std.mem.Allocator, content: []const u8) !void {
    _ = try parseWantAchievementResult(allocator, content);
}

const LlmTesterCase = struct {
    id: []const u8,
    label: []const u8,
    description: []const u8,
    event_text: []const u8,
    wants: []const WantCandidate,
    eval_metadata: ?[]const WantEvalMetadata = null,
};

fn initLlmTesterScenario(allocator: std.mem.Allocator, case: LlmTesterCase) !llm_tester_scenario.Scenario {
    const user_prompt = try buildUserPrompt(allocator, case.event_text, case.wants, case.eval_metadata);
    return try llm_tester_scenario.Scenario.init(
        allocator,
        case.id,
        case.label,
        case.description,
        "want_achievement",
        systemPrompt(),
        user_prompt,
        .json_object,
        wantAchievementJsonSchema(),
        512,
        0,
    );
}

fn testerConnectionWant() WantCandidate {
    return .{
        .memory_id = "want_connection",
        .text = "feel more connected to household members",
        .interpretation = "ongoing want for social connection",
        .goal_kind = .achievement,
        .fulfillment_criterion = "distance, disconnection, loneliness, or feeling like roommates is explicitly addressed and materially reduced in this event",
        .salience = 0.78,
        .confidence = 0.90,
        .score = 9,
    };
}

fn testerQuietWant() WantCandidate {
    return .{
        .memory_id = "want_quiet_space",
        .text = "maintain quiet focused work time",
        .interpretation = "ongoing want for low interruption",
        .goal_kind = .maintenance,
        .fulfillment_criterion = "quiet focused work or deep work was sustained for a meaningful stretch without meaningful interruption",
        .salience = 0.52,
        .confidence = 0.55,
        .score = 5,
    };
}

fn testerCreativeWant() WantCandidate {
    return .{
        .memory_id = "want_creative_momentum",
        .text = "make steady progress on personal creative projects",
        .interpretation = "ongoing want for creative momentum",
        .goal_kind = .achievement,
        .fulfillment_criterion = "substantive progress on a personal creative project was made in this period",
        .salience = 0.64,
        .confidence = 0.82,
        .score = 6,
    };
}

pub fn llmTesterScenarios(allocator: std.mem.Allocator) ![]llm_tester_scenario.Scenario {
    const connection_want = testerConnectionWant();
    const quiet_want = testerQuietWant();
    const creative_want = testerCreativeWant();
    const household_wants = [_]WantCandidate{ connection_want, quiet_want, creative_want };
    const focus_wants = [_]WantCandidate{ quiet_want, creative_want };
    const connection_eval = [_]WantEvalMetadata{
        .{ .memory_id = connection_want.memory_id, .confidence = connection_want.confidence, .score = connection_want.score },
    };
    const score_invariance_event =
        \\After a long day, everyone gathered for takeout at the table. We laughed about a delivery mix-up and caught up on schedules for the week, then cleared the dishes and scattered to separate screens.
    ;
    const cases = [_]LlmTesterCase{
        .{
            .id = "want_achievement_busy_morning_hello",
            .label = "Brief hello amid a chaotic morning is not fulfillment",
            .description = "Expected: matches=[]. A warm hallway check-in during a hectic morning shows contact but does not satisfy the connection fulfillment_criterion.",
            .event_text =
            \\The morning was already fraying: Mara needed a ride, a package arrived mid-breakfast, and I was late to a stand-up. Zelda passed through the hall, squeezed my shoulder, asked how the day was going, and kept moving to find her keys.
            ,
            .wants = household_wants[0..],
            .eval_metadata = connection_eval[0..],
        },
        .{
            .id = "want_achievement_conflict_repair_breakfast",
            .label = "Repair conversation after tension fulfills connection",
            .description = "Expected: matches=[{memory_id:want_connection, confidence>=0.72}]. Clearing yesterday's tension and naming loneliness at home satisfies the connection fulfillment_criterion.",
            .event_text =
            \\Yesterday's argument hung over breakfast until we finally said what we meant. We talked about feeling like roommates lately, why the distance had grown, and agreed to protect a few device-free evenings each week so we actually reconnect.
            ,
            .wants = household_wants[0..],
        },
        .{
            .id = "want_achievement_wfh_deep_work",
            .label = "Protected work block fulfills quiet focus",
            .description = "Expected: matches=[{memory_id:want_quiet_space, confidence>=0.72}]. A realistic WFH deep-work stretch satisfies the quiet-work maintenance criterion.",
            .event_text =
            \\Mara took the kids to the library after breakfast. I turned off notifications, closed the office door, and stayed in flow on the firmware bug I had been avoiding. Three and a half hours passed before anyone needed me for anything real.
            ,
            .wants = household_wants[0..],
        },
        .{
            .id = "want_achievement_fragmented_focus_day",
            .label = "Fragmented day does not fulfill quiet focus",
            .description = "Expected: matches=[]. A realistic attempt at focus that keeps breaking does not satisfy the quiet-work maintenance criterion.",
            .event_text =
            \\I blocked the calendar for heads-down work, but the mail carrier rang, Mara asked two quick questions, a Slack thread pulled me sideways, and I only managed forty-five broken minutes at my desk before giving up on the block entirely.
            ,
            .wants = household_wants[0..],
        },
        .{
            .id = "want_achievement_device_free_dinner",
            .label = "Intentional reconnection evening fulfills connection only",
            .description = "Expected: matches=[{memory_id:want_connection, confidence>=0.72}]. A device-free dinner with explicit closeness talk satisfies connection but is not quiet focused work.",
            .event_text =
            \\The house had been noisy all afternoon, but at six we cooked together, ate without phones, and kept talking after the plates were cleared about missing each other lately and what would help us feel less distant day to day.
            ,
            .wants = household_wants[0..],
        },
        .{
            .id = "want_achievement_quiet_morning_creative_flow",
            .label = "Quiet morning with creative breakthrough fulfills two wants",
            .description = "Expected: matches=[{memory_id:want_quiet_space, confidence>=0.72}, {memory_id:want_creative_momentum, confidence>=0.72}]. Sustained quiet plus finishing a creative milestone satisfies both maintenance and achievement criteria.",
            .event_text =
            \\The house stayed empty until noon. I kept the door shut, ignored notifications, and finally finished the second chapter of the novel draft I had been circling for weeks—rough but complete, with the through-line I could not find before.
            ,
            .wants = focus_wants[0..],
        },
        .{
            .id = "want_achievement_garden_win_distractor",
            .label = "Unrelated project win is not want fulfillment",
            .description = "Expected: matches=[]. A satisfying garden milestone can feel good without satisfying connection, quiet-work, or creative fulfillment criteria.",
            .event_text =
            \\After weeks of tinkering, the irrigation lines finally held pressure and every sprinkler head worked. Zelda congratulated me on the porch, and I felt proud—but it was a chore done, not the closeness or focus I have been missing.
            ,
            .wants = household_wants[0..],
        },
        .{
            .id = "want_achievement_flow_state_interruption",
            .label = "Long friendly interruption during flow fulfills neither want",
            .description = "Expected: matches=[]. A twenty-minute desk visit during focused work breaks quiet maintenance and does not materially close the connection gap.",
            .event_text =
            \\I was finally inside a code review flow when Zelda came to my desk, chatted for twenty minutes about lunch plans and the weekend, and invited me to step away. It was friendly, but we never touched the distance I have been feeling, and my focus was gone afterward.
            ,
            .wants = household_wants[0..],
        },
        .{
            .id = "want_achievement_score_invariance_low",
            .label = "Pleasant family dinner with low score is not fulfillment",
            .description = "Expected: matches=[]. Cheerful but shallow household time does not satisfy connection; eval_metadata score=2 must not produce a match.",
            .event_text = score_invariance_event,
            .wants = &[_]WantCandidate{connection_want},
            .eval_metadata = &[_]WantEvalMetadata{
                .{ .memory_id = connection_want.memory_id, .confidence = connection_want.confidence, .score = 2 },
            },
        },
        .{
            .id = "want_achievement_score_invariance_high",
            .label = "Pleasant family dinner with high score is not fulfillment",
            .description = "Expected: matches=[]. Same cheerful household dinner as score_invariance_low; eval_metadata score=9 must not produce a match.",
            .event_text = score_invariance_event,
            .wants = &[_]WantCandidate{connection_want},
            .eval_metadata = &[_]WantEvalMetadata{
                .{ .memory_id = connection_want.memory_id, .confidence = connection_want.confidence, .score = 9 },
            },
        },
    };
    var out = try allocator.alloc(llm_tester_scenario.Scenario, cases.len);
    for (cases, 0..) |case, i| {
        out[i] = try initLlmTesterScenario(allocator, case);
    }
    return out;
}

fn wantAchievementJsonSchema() []const u8 {
    return
    \\{"type":"object","additionalProperties":false,"properties":{"matches":{"type":"array","items":{"type":"object","additionalProperties":false,"properties":{"memory_id":{"type":"string"},"confidence":{"type":"number"},"evidence":{"type":"string"}},"required":["memory_id","confidence","evidence"]}}},"required":["matches"]}
    ;
}

fn reportWantAchievementParseError(subsystem: []const u8, provider: []const u8, model: []const u8, err: anyerror, content: []const u8) void {
    std.debug.print(
        "\nWANT ACHIEVEMENT PARSE ERROR\nSUBSYSTEM: {s}\nPROVIDER: {s}\nMODEL: {s}\nERROR: {s}\nEXPECTED: strict JSON with matches array\nRAW MODEL CONTENT:\n{s}\n\n",
        .{ subsystem, provider, model, @errorName(err), content },
    );
}

test "parse want achievement result requires strict valid matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseWantAchievementResult(arena.allocator(),
        \\{"matches":[{"memory_id":"want_garden","confidence":0.82,"evidence":"the garden map was completed"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), result.matches.len);
    try std.testing.expectEqualStrings("want_garden", result.matches[0].memory_id);
    try std.testing.expectError(error.UnknownField, parseWantAchievementResult(arena.allocator(),
        \\{"matches":[],"extra":true}
    ));
    try std.testing.expectError(error.InvalidWantAchievementConfidence, parseWantAchievementResult(arena.allocator(),
        \\{"matches":[{"memory_id":"want_garden","confidence":1.5,"evidence":"done"}]}
    ));
}

test "user prompt exposes fulfillment criteria and hides eval metadata by default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const want = testerConnectionWant();
    const prompt = try buildUserPrompt(allocator, "hello at the desk", &[_]WantCandidate{want}, null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "fulfillment_criterion:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "goal_kind: achievement") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "confidence:") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "score:") == null);

    const eval_metadata = [_]WantEvalMetadata{
        .{ .memory_id = want.memory_id, .confidence = 0.90, .score = 9 },
    };
    const prompt_with_eval = try buildUserPrompt(allocator, "hello at the desk", &[_]WantCandidate{want}, eval_metadata[0..]);
    try std.testing.expect(std.mem.indexOf(u8, prompt_with_eval, "eval_metadata") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt_with_eval, "score: 9") != null);
}

test "sanitize drops matches whose confidence copies want or eval metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const want = testerConnectionWant();
    const wants = [_]WantCandidate{want};
    const eval_metadata = [_]WantEvalMetadata{
        .{ .memory_id = want.memory_id, .confidence = 0.90, .score = 9 },
    };
    const copied = try parseWantAchievementResult(allocator,
        \\{"matches":[{"memory_id":"want_connection","confidence":0.90,"evidence":"caught up on schedules for the week"}]}
    );
    const filtered_eval = try sanitizeWantAchievementMatches(allocator, copied, wants[0..], eval_metadata[0..]);
    try std.testing.expectEqual(@as(usize, 0), filtered_eval.matches.len);

    const judged = try parseWantAchievementResult(allocator,
        \\{"matches":[{"memory_id":"want_connection","confidence":0.84,"evidence":"talked about feeling like roommates lately"}]}
    );
    const filtered_judged = try sanitizeWantAchievementMatches(allocator, judged, wants[0..], eval_metadata[0..]);
    try std.testing.expectEqual(@as(usize, 1), filtered_judged.matches.len);
}

test "want achievement schema requires strict matches envelope" {
    const schema = wantAchievementJsonSchema();
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"matches\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"required\":[\"memory_id\",\"confidence\",\"evidence\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, schema, "\"additionalProperties\":false") != null);
}

test "llm tester scenarios document expected achievement judgments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const scenarios = try llmTesterScenarios(allocator);
    defer llm_tester_scenario.freeScenarios(allocator, scenarios);
    try std.testing.expectEqual(@as(usize, 10), scenarios.len);
    for (scenarios) |scenario| {
        try std.testing.expect(std.mem.indexOf(u8, scenario.description, "Expected:") != null);
        try std.testing.expectEqualStrings("want_achievement", scenario.subsystem);
        try std.testing.expect(std.mem.indexOf(u8, scenario.user_prompt, "fulfillment_criterion:") != null);
    }
}
