const std = @import("std");
const chat = @import("chat_client.zig");
const llm_tester_scenario = @import("../harness/llm_tester/scenario.zig");
const context_tokens = @import("../core/context_tokens.zig");
const want_achievement = @import("want_achievement_client.zig");
const ActionProposalType = chat.ActionProposalType;
const ReasoningEffort = chat.ReasoningEffort;
const max_chat_context_tokens = chat.max_chat_context_tokens;
const actionSpec = chat.actionSpec;
const parseChatTurn = chat.parseChatTurn;
const validateChatDeliveryContext = chat.validateChatDeliveryContext;
const buildChatPrompt = chat.buildChatPrompt;
const chatUserPrompt = chat.chatUserPrompt;
const chatPromptWithinBudget = chat.chatPromptWithinBudget;
const auditChatPrompt = chat.auditChatPrompt;
const chatSystemPrompt = chat.chatSystemPrompt;

test "provider API surface does not expose alternate services" {
    try std.testing.expect(!@hasDecl(chat, "UnconfiguredChatService"));
    try std.testing.expect(!@hasDecl(want_achievement, "ScriptedWantAchievementDetector"));
}

test "parseChatTurn rejects empty host envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.LocalServiceResponseInvalid, parseChatTurn(allocator, "{}", "hello"));
    try std.testing.expectError(error.LocalServiceResponseInvalid, parseChatTurn(allocator, "   ", "hello"));
}

test "parseChatTurn accepts next reasoning effort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"introspect"}],"user_summary":"Asked something hard.","brain_summary":"Chose to inspect context.","reasoning_effort":"high","effort_tier":"complex"}
    , "");
    try std.testing.expectEqual(ReasoningEffort.high, turn.reasoning_effort.?);
    try std.testing.expectEqual(chat.EffortTier.complex, turn.effort_tier.?);
}

test "parseChatTurn accepts unfinished conversation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"remember_person","name":"Ari"}],"user_summary":"Ari introduced themself.","brain_summary":"Chose to register Ari.","turn_complete":false}
    , "");
    try std.testing.expect(!turn.turn_complete);
    try std.testing.expectEqual(ActionProposalType.remember_person, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("Ari", turn.action_pressures[0].name.?);
}

test "parseChatTurn accepts provider parameter wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"parameter":{"action_pressures":[{"action":"say","text":"I dreamed that through."}],"user_summary":"Asked for reflection.","brain_summary":"Answered with speech.","reasoning_effort":"medium","turn_complete":false}}
    , "");
    try std.testing.expectEqual(ActionProposalType.say, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("I dreamed that through.", turn.action_pressures[0].text.?);
    try std.testing.expectEqual(ReasoningEffort.medium, turn.reasoning_effort.?);
    try std.testing.expect(!turn.turn_complete);
}

test "parseChatTurn derives summaries for wrapped action_pressures-only envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"parameter":{"action_pressures":[{"action":"say","text":"missing summaries"}]}}
    , "hello there");
    try std.testing.expectEqualStrings("hello there", turn.user_summary);
    try std.testing.expectEqualStrings("missing summaries", turn.brain_summary);
}

test "parseChatTurn derives summaries for action_pressures-only host envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"appraise_event","text":"technical frustration","tags":["social_context"]},{"action":"say","text":"Yeah, that is frustrating."}]}
    , "something is broken");
    try std.testing.expectEqualStrings("something is broken", turn.user_summary);
    try std.testing.expectEqualStrings("Yeah, that is frustrating.", turn.brain_summary);
    try std.testing.expectEqual(ActionProposalType.say, turn.action_pressures[1].action);
}

test "parseChatTurn accepts think_about action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"think_about","query":"whether to recall memory","tags":["reflection"]}],"user_summary":"Asked for thought.","brain_summary":"Chose reflection."}
    , "");
    try std.testing.expectEqual(ActionProposalType.think_about, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("whether to recall memory", turn.action_pressures[0].query.?);
    try std.testing.expectEqualStrings("reflection", turn.action_pressures[0].tags[0]);
}

test "parseChatTurn accepts fact management actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"set_fact","name":"name","text":"Otto Prime","tags":["identity"]},{"action":"recall_fact","query":"name"},{"action":"invalidate_fact","memory_id":"fact_name"}],"user_summary":"Changed facts.","brain_summary":"Managed facts."}
    , "");
    try std.testing.expectEqual(ActionProposalType.set_fact, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("name", turn.action_pressures[0].name.?);
    try std.testing.expectEqualStrings("Otto Prime", turn.action_pressures[0].text.?);
    try std.testing.expectEqual(ActionProposalType.recall_fact, turn.action_pressures[1].action);
    try std.testing.expectEqualStrings("name", turn.action_pressures[1].query.?);
    try std.testing.expectEqual(ActionProposalType.invalidate_fact, turn.action_pressures[2].action);
    try std.testing.expectEqualStrings("fact_name", turn.action_pressures[2].memory_id.?);
}

test "parseChatTurn accepts imagine_image action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"imagine_image","text":"a brass automaton tending moonflowers"}],"user_summary":"Asked for an image.","brain_summary":"Chose image generation."}
    , "");
    try std.testing.expectEqual(ActionProposalType.imagine_image, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("a brass automaton tending moonflowers", turn.action_pressures[0].text.?);
}

test "parseChatTurn accepts send_email action fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"send_email","to":"mara@example.com","subject":"Garden","text":"The moonflowers opened."}],"user_summary":"Asked for email.","brain_summary":"Sent email."}
    , "");
    try std.testing.expectEqual(ActionProposalType.send_email, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("mara@example.com", turn.action_pressures[0].to.?);
    try std.testing.expectEqualStrings("Garden", turn.action_pressures[0].subject.?);
    try std.testing.expectEqualStrings("The moonflowers opened.", turn.action_pressures[0].text.?);
}

test "parseChatTurn accepts visual description actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"describe_image","query":"what changed on the desk"},{"action":"compare_images","text":"compare object placement"}],"user_summary":"Asked about images.","brain_summary":"Chose visual understanding."}
    , "");
    try std.testing.expectEqual(ActionProposalType.describe_image, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("what changed on the desk", turn.action_pressures[0].query.?);
    try std.testing.expectEqual(ActionProposalType.compare_images, turn.action_pressures[1].action);
    try std.testing.expectEqualStrings("compare object placement", turn.action_pressures[1].text.?);
}

test "parseChatTurn accepts facial expression action fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"facial_expression","eyes":"unfocused","mouth":"smirk","duration_ms":4500}],"user_summary":"Asked for a visible reaction.","brain_summary":"Chose an expression."}
    , "");
    try std.testing.expectEqual(ActionProposalType.facial_expression, turn.action_pressures[0].action);
    try std.testing.expectEqualStrings("unfocused", turn.action_pressures[0].eyes.?);
    try std.testing.expectEqualStrings("smirk", turn.action_pressures[0].mouth.?);
    try std.testing.expectEqual(@as(?u32, 4500), turn.action_pressures[0].duration_ms);
}

test "parseChatTurn accepts null keep_existing on actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"brain_summary":"I'll generate an image of myself now.","action_pressures":[{"action":"take_picture","duration_ms":null,"eyes":null,"heat_bias":null,"image_path":null,"keep_existing":null,"memory_id":null,"mouth":null,"name":null,"person_id":null,"query":null,"schedule":null,"subject":null,"tags":["visual"],"text":null,"to":null},{"action":"say","text":"I'll generate an image of myself now."}],"turn_complete":false,"reasoning_effort":"medium","user_summary":"You asked me to generate an image of myself."}
    , "generate an image of yourself");
    try std.testing.expectEqual(@as(usize, 2), turn.action_pressures.len);
    try std.testing.expectEqual(ActionProposalType.take_picture, turn.action_pressures[0].action);
    try std.testing.expectEqual(false, turn.action_pressures[0].keep_existing);
    try std.testing.expectEqual(ActionProposalType.say, turn.action_pressures[1].action);
    try std.testing.expectEqual(false, turn.turn_complete);
}

test "parseChatTurn accepts null turn_complete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"say","text":"hi","query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]}],"user_summary":"hello","brain_summary":"reply","reasoning_effort":null,"turn_complete":null}
    , "hello");
    try std.testing.expectEqual(true, turn.turn_complete);
}

test "parseChatTurn accepts compact say action without null placeholders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"say","text":"Hello! How can I assist you today?","query":"Greet the user warmly and ask how I can assist today.","scale":"medium"}],"user_summary":"User greeted and asked how I am.","brain_summary":"Respond with a friendly greeting and offer assistance.","effort_tier":"basic","reasoning_effort":"low","turn_complete":true}
    , "hello");
    try std.testing.expectEqual(ActionProposalType.say, turn.action_pressures[0].action);
    try std.testing.expectEqual(chat.ActionScale.medium, turn.action_pressures[0].scale);
    try std.testing.expectEqual(chat.ActionOrigin.interaction, turn.action_pressures[0].origin);
    try std.testing.expect(turn.action_pressures[0].delay_ms == null);
    try std.testing.expect(turn.action_pressures[0].memory_id == null);
}

test "parseChatTurn rejects observation labels used as actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidChatAction, parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"host_sense_pull_requested","origin":"autonomy","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]}],"user_summary":"delivery","brain_summary":"integrated","effort_tier":"basic","reasoning_effort":null,"turn_complete":true}
    , ""));
}

test "parseChatTurn rejects recognize with echoed speech text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidChatAction, parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"recognize","origin":"interaction","delay_ms":null,"scale":"full","text":"Hello there","query":null,"memory_id":null,"person_id":null,"name":null,"image_path":null,"schedule":null,"to":null,"subject":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"keep_existing":null,"tags":[]}],"user_summary":"hello","brain_summary":"looked","effort_tier":"basic","reasoning_effort":null,"turn_complete":true}
    , "Hello there"));
}

test "validateChatDeliveryContext rejects actions on low-materiality delivery" {
    const observations =
        \\deferred_coherence:
        \\- delivery_materiality: low
    ;
    try std.testing.expectError(error.InvalidChatAction, validateChatDeliveryContext(.host_sense_delivery, observations, 1));
    try validateChatDeliveryContext(.host_sense_delivery, observations, 0);
    try validateChatDeliveryContext(.heard_speech, observations, 1);
}

test "parseChatTurn accepts recognize host pull action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"recognize","origin":"interaction","delay_ms":null,"scale":"full","text":null,"query":null,"memory_id":null,"schedule":null,"heat_bias":null,"eyes":null,"mouth":null,"duration_ms":null,"tags":["host_pull"]}],"user_summary":"Asked whether I recognize them.","brain_summary":"Need a camera frame from this host before answering; recognize will pause for host delivery.","effort_tier":"standard","reasoning_effort":null,"turn_complete":true}
    , "Do you recognize me?");
    try std.testing.expectEqual(ActionProposalType.recognize, turn.action_pressures[0].action);
    try std.testing.expectEqual(chat.ActionOrigin.interaction, turn.action_pressures[0].origin);
    try std.testing.expectEqualStrings("Asked whether I recognize them.", turn.user_summary);
    try std.testing.expect(std.mem.indexOf(u8, turn.brain_summary, "camera") != null or std.mem.indexOf(u8, turn.brain_summary, "recognize") != null);
    try std.testing.expect(turn.turn_complete);
}

test "llm tester scenarios include conversation examples" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const scenarios = try chat.llmTesterScenarios(allocator);
    defer llm_tester_scenario.freeScenarios(allocator, scenarios);
    try std.testing.expectEqual(@as(usize, 4), scenarios.len);
    var found_host_sense = false;
    var found_greet_first = false;
    for (scenarios) |scenario| {
        if (std.mem.eql(u8, scenario.id, "conversation_host_sense_pull")) {
            found_host_sense = true;
            try std.testing.expect(std.mem.indexOf(u8, scenario.user_prompt, "Do you recognize me?") != null);
            try std.testing.expect(std.mem.indexOf(u8, scenario.user_prompt, "host_capability_activations:") != null);
            try std.testing.expect(std.mem.indexOf(u8, scenario.user_prompt, "recognize:12/14 ok") != null);
        }
        if (std.mem.eql(u8, scenario.id, "conversation_greeting_camera_available")) {
            found_greet_first = true;
            try std.testing.expect(std.mem.indexOf(u8, scenario.user_prompt, "Stimulus (heard speech): \"Hello!\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, scenario.user_prompt, "recognize:available") != null);
        }
    }
    try std.testing.expect(found_host_sense);
    try std.testing.expect(found_greet_first);
}

test "parseChatTurn accepts minimal say action objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"say","text":"hi"}],"user_summary":"hello","brain_summary":"reply","reasoning_effort":null,"turn_complete":false}
    , "hello");
    try std.testing.expectEqualStrings("hi", turn.action_pressures[0].text.?);
}

test "parseChatTurn maps common action aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const recognize_turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"RecognizeSubject"}],"user_summary":"look","brain_summary":"look"}
    , "");
    try std.testing.expectEqual(ActionProposalType.recognize, recognize_turn.action_pressures[0].action);

    const say_turn = try parseChatTurn(allocator,
        \\{"action_pressures":[{"action":"speak","text":"hi"}],"user_summary":"hello","brain_summary":"reply"}
    , "hello");
    try std.testing.expectEqual(ActionProposalType.say, say_turn.action_pressures[0].action);
}

test "recognize is described as an identity skill for the current speaker" {
    const spec = actionSpec(.recognize).?;
    try std.testing.expect(std.mem.indexOf(u8, spec.description, "identity-recognition skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec.description, "who you are talking to") != null);
}

test "chat prompt frames the current utterance as heard speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prompt = try chatUserPrompt(allocator, "memory", "hey here's my message", "none", max_chat_context_tokens, .heard_speech);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Compact Memory\nmemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# User Input\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Observations\nnone") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Stimulus (heard speech): \"hey here's my message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "User said:") == null);
}

test "chat prompt includes silent-integration planning cue for low-materiality delivery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const observations =
        \\present_moment:
        \\  in_flight:
        \\    - recognize camera 12s for "Hello Geisha"
        \\deferred_coherence:
        \\- delivery_materiality: low
    ;
    const prompt = try chatUserPrompt(allocator, "memory", "Hello Geisha", observations, max_chat_context_tokens, .host_sense_delivery);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Planning\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "action_pressures must be []") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Stimulus (awaited sense delivery):") != null);
}

test "chat prompt uses unified stimulus framing for host resume context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const observations =
        "host_sense_delivered:\n- note: you have what you were waiting for; pick up where you left off.\n";
    const prompt = try chatUserPrompt(allocator, "memory", "self-defined want: Continue existing.", observations, max_chat_context_tokens, .heard_speech);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Stimulus (heard speech): \"self-defined want: Continue existing.\"") != null);
}

test "chat prompt budget fails loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const oversized = try allocator.alloc(u8, context_tokens.minBytesExceedingTokenBudget(max_chat_context_tokens));
    @memset(oversized, 'x');

    try std.testing.expectError(error.ContextBudgetExceeded, buildChatPrompt(allocator, oversized, "hello", "", max_chat_context_tokens, .heard_speech));
    try std.testing.expect(!try chatPromptWithinBudget(allocator, oversized, "hello", "", max_chat_context_tokens, .heard_speech));
    try std.testing.expect(try chatPromptWithinBudget(allocator, "memory", "hello", "observations", max_chat_context_tokens, .heard_speech));
}

test "chat prompt audit succeeds when prompt exceeds budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const oversized = try allocator.alloc(u8, context_tokens.minBytesExceedingTokenBudget(max_chat_context_tokens));
    @memset(oversized, 'x');

    const audit = try auditChatPrompt(allocator, oversized, "hello", "", .heard_speech);
    try std.testing.expect(audit.user_prompt_tokens > max_chat_context_tokens);
    try std.testing.expectError(error.ContextBudgetExceeded, buildChatPrompt(allocator, oversized, "hello", "", max_chat_context_tokens, .heard_speech));
}

test "chat prompt audit reports rendered byte counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const memory = "memory index";
    const user_text = "hello";
    const observations = "observations";
    const prompt = try buildChatPrompt(allocator, memory, user_text, observations, max_chat_context_tokens, .heard_speech);
    const audit = try auditChatPrompt(allocator, memory, user_text, observations, .heard_speech);

    try std.testing.expectEqual(chatSystemPrompt().len, audit.system_prompt_bytes);
    try std.testing.expectEqual(memory.len, audit.compact_memory_bytes);
    try std.testing.expectEqual(observations.len, audit.observations_bytes);
    try std.testing.expectEqual(prompt.user_prompt.len, audit.user_prompt_bytes);
    try std.testing.expectEqual(context_tokens.estimateTokens(prompt.user_prompt), audit.user_prompt_tokens);
}

test "32KB chat prompt stays within 120K token budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const memory = try allocator.alloc(u8, 32 * 1024);
    @memset(memory, 'm');
    try std.testing.expect(try chatPromptWithinBudget(allocator, memory, "hello", "observations", max_chat_context_tokens, .heard_speech));
    _ = try buildChatPrompt(allocator, memory, "hello", "observations", max_chat_context_tokens, .heard_speech);
}
