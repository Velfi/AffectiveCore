const std = @import("std");
const chat = @import("chat_client.zig");
const ChatCommandType = chat.ChatCommandType;
const ReasoningEffort = chat.ReasoningEffort;
const LlmProvider = chat.LlmProvider;
const max_chat_user_prompt_bytes = chat.max_chat_user_prompt_bytes;
const commandSpec = chat.commandSpec;
const parseChatTurn = chat.parseChatTurn;
const buildChatPrompt = chat.buildChatPrompt;
const chatUserPrompt = chat.chatUserPrompt;
const auditChatPrompt = chat.auditChatPrompt;
const chatSystemPrompt = chat.chatSystemPrompt;
const buildChatRequestBody = chat.buildChatRequestBody;
const buildAnthropicRequestBody = chat.buildAnthropicRequestBody;
const parseProviderModels = chat.parseProviderModels;
const extractAnthropicContent = chat.extractAnthropicContent;
const extractGoogleContent = chat.extractGoogleContent;

test "parseChatTurn accepts next reasoning effort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"commands":[{"command":"introspect"}],"user_summary":"Asked something hard.","brain_summary":"Chose to inspect context.","reasoning_effort":"high"}
    );
    try std.testing.expectEqual(ReasoningEffort.high, turn.reasoning_effort.?);
}

test "parseChatTurn accepts unfinished conversation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"commands":[{"command":"remember_person","name":"Ari"}],"user_summary":"Ari introduced themself.","brain_summary":"Chose to register Ari.","conversation_done":false}
    );
    try std.testing.expect(!turn.conversation_done);
    try std.testing.expectEqual(ChatCommandType.remember_person, turn.commands[0].command);
    try std.testing.expectEqualStrings("Ari", turn.commands[0].name.?);
}

test "parseChatTurn accepts provider parameter wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"parameter":{"commands":[{"command":"say","text":"I dreamed that through."}],"user_summary":"Asked for dream skill.","brain_summary":"Used dream skill.","reasoning_effort":"medium","conversation_done":false}}
    );
    try std.testing.expectEqual(ChatCommandType.say, turn.commands[0].command);
    try std.testing.expectEqualStrings("I dreamed that through.", turn.commands[0].text.?);
    try std.testing.expectEqual(ReasoningEffort.medium, turn.reasoning_effort.?);
    try std.testing.expect(!turn.conversation_done);
}

test "parseChatTurn rejects wrapper without chat envelope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.MissingField, parseChatTurn(allocator,
        \\{"parameter":{"commands":[{"command":"say","text":"missing summaries"}]}}
    ));
}

test "parseChatTurn accepts think_about command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"commands":[{"command":"think_about","query":"whether to recall memory","tags":["reflection"]}],"user_summary":"Asked for thought.","brain_summary":"Chose reflection."}
    );
    try std.testing.expectEqual(ChatCommandType.think_about, turn.commands[0].command);
    try std.testing.expectEqualStrings("whether to recall memory", turn.commands[0].query.?);
    try std.testing.expectEqualStrings("reflection", turn.commands[0].tags[0]);
}

test "parseChatTurn accepts fact management commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"commands":[{"command":"set_fact","name":"name","text":"Otto Prime","tags":["identity"]},{"command":"recall_fact","query":"name"},{"command":"invalidate_fact","memory_id":"fact_name"}],"user_summary":"Changed facts.","brain_summary":"Managed facts."}
    );
    try std.testing.expectEqual(ChatCommandType.set_fact, turn.commands[0].command);
    try std.testing.expectEqualStrings("name", turn.commands[0].name.?);
    try std.testing.expectEqualStrings("Otto Prime", turn.commands[0].text.?);
    try std.testing.expectEqual(ChatCommandType.recall_fact, turn.commands[1].command);
    try std.testing.expectEqualStrings("name", turn.commands[1].query.?);
    try std.testing.expectEqual(ChatCommandType.invalidate_fact, turn.commands[2].command);
    try std.testing.expectEqualStrings("fact_name", turn.commands[2].memory_id.?);
}

test "parseChatTurn accepts imagine_image command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"commands":[{"command":"imagine_image","text":"a brass automaton tending moonflowers"}],"user_summary":"Asked for an image.","brain_summary":"Chose image generation."}
    );
    try std.testing.expectEqual(ChatCommandType.imagine_image, turn.commands[0].command);
    try std.testing.expectEqualStrings("a brass automaton tending moonflowers", turn.commands[0].text.?);
}

test "parseChatTurn accepts send_email command fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"commands":[{"command":"send_email","to":"mara@example.com","subject":"Garden","text":"The moonflowers opened."}],"user_summary":"Asked for email.","brain_summary":"Sent email."}
    );
    try std.testing.expectEqual(ChatCommandType.send_email, turn.commands[0].command);
    try std.testing.expectEqualStrings("mara@example.com", turn.commands[0].to.?);
    try std.testing.expectEqualStrings("Garden", turn.commands[0].subject.?);
    try std.testing.expectEqualStrings("The moonflowers opened.", turn.commands[0].text.?);
}

test "parseChatTurn accepts visual description commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"commands":[{"command":"describe_image","query":"what changed on the desk"},{"command":"compare_images","text":"compare object placement"}],"user_summary":"Asked about images.","brain_summary":"Chose visual understanding."}
    );
    try std.testing.expectEqual(ChatCommandType.describe_image, turn.commands[0].command);
    try std.testing.expectEqualStrings("what changed on the desk", turn.commands[0].query.?);
    try std.testing.expectEqual(ChatCommandType.compare_images, turn.commands[1].command);
    try std.testing.expectEqualStrings("compare object placement", turn.commands[1].text.?);
}

test "parseChatTurn accepts facial expression command fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const turn = try parseChatTurn(allocator,
        \\{"commands":[{"command":"facial_expression","eyes":"unfocused","mouth":"smirk","duration_ms":4500}],"user_summary":"Asked for a visible reaction.","brain_summary":"Chose an expression."}
    );
    try std.testing.expectEqual(ChatCommandType.facial_expression, turn.commands[0].command);
    try std.testing.expectEqualStrings("unfocused", turn.commands[0].eyes.?);
    try std.testing.expectEqualStrings("smirk", turn.commands[0].mouth.?);
    try std.testing.expectEqual(@as(?u32, 4500), turn.commands[0].duration_ms);
}

test "recognize is described as an identity skill for the current speaker" {
    const spec = commandSpec(.recognize).?;
    try std.testing.expect(std.mem.indexOf(u8, spec.description, "identity-recognition skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec.description, "who you are talking to") != null);
}

test "reasoning effort is only sent to reasoning-capable models" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const reasoning_body = try buildChatRequestBody(allocator, "gpt-5-mini", .high, "system", "user");
    const classic_body = try buildChatRequestBody(allocator, "gpt-4.1-nano", .high, "system", "user");
    try std.testing.expect(std.mem.indexOf(u8, reasoning_body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, classic_body, "\"reasoning_effort\":\"high\"") == null);
}

test "chat prompt frames the current utterance as heard speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prompt = try chatUserPrompt(allocator, "memory", "hey here's my message", "none");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Compact Memory\nmemory") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# User Input\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "# Observations\nnone") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "You just heard USER say \"hey here's my message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "User said:") == null);
}

test "chat prompt budget fails loudly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const oversized = try allocator.alloc(u8, max_chat_user_prompt_bytes + 1);
    @memset(oversized, 'x');

    try std.testing.expectError(error.ContextBudgetExceeded, buildChatPrompt(allocator, oversized, "hello", ""));
}

test "chat prompt audit reports rendered byte counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const memory = "memory index";
    const user_text = "hello";
    const observations = "observations";
    const prompt = try buildChatPrompt(allocator, memory, user_text, observations);
    const audit = try auditChatPrompt(allocator, memory, user_text, observations);

    try std.testing.expectEqual(chatSystemPrompt().len, audit.system_prompt_bytes);
    try std.testing.expectEqual(memory.len, audit.compact_memory_bytes);
    try std.testing.expectEqual(observations.len, audit.observations_bytes);
    try std.testing.expectEqual(prompt.user_prompt.len, audit.user_prompt_bytes);
}

test "anthropic chat request forces json tool use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body = try buildAnthropicRequestBody(allocator, "claude-haiku-4-5-20251001", "system", "user");
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input_schema\":{\"type\":\"object\",\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"required\":[\"commands\",\"user_summary\",\"brain_summary\",\"reasoning_effort\",\"conversation_done\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"required\":[\"command\",\"text\",\"query\",\"memory_id\",\"person_id\",\"name\",\"image_path\",\"schedule\",\"to\",\"subject\",\"heat_bias\",\"eyes\",\"mouth\",\"duration_ms\",\"keep_existing\",\"tags\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":{\"type\":[\"string\",\"null\"]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":{\"type\":[\"string\",\"null\"],\"enum\":[\"low\",\"medium\",\"high\",null]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":{\"type\":\"tool\",\"name\":\"json_response\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"{\"") == null);
}

test "provider model roster accepts explicit providers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const models = try parseProviderModels(allocator, "openai:gpt-4.1-nano, anthropic:claude-haiku-4-5-20251001, gemini:gemini-3.1-flash-lite");
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqual(LlmProvider.openai, models[0].provider);
    try std.testing.expectEqual(LlmProvider.anthropic, models[1].provider);
    try std.testing.expectEqual(LlmProvider.google, models[2].provider);
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", models[1].model);
    try std.testing.expectEqualStrings("gemini-3.1-flash-lite", models[2].model);
}

test "provider model roster rejects invalid providers and empty configured roster" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidConversationProvider, parseProviderModels(allocator, "bogus:gpt-4.1-nano"));
    try std.testing.expectError(error.InvalidConversationProviderModel, parseProviderModels(allocator, "openai:"));
    try std.testing.expectError(error.NoConversationModels, parseProviderModels(allocator, " , "));
}

test "provider model roster rejects missing configured roster" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.NoConversationModels, parseProviderModels(allocator, ""));
}

test "provider content extractors read structured payloads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const anthropic_text = try extractAnthropicContent(allocator,
        \\{"content":[{"type":"tool_use","id":"toolu_1","name":"json_response","input":{"commands":[]}}]}
    );
    const google_text = try extractGoogleContent(allocator,
        \\{"candidates":[{"content":{"parts":[{"text":"{\"commands\":[]}"}]}}]}
    );
    try std.testing.expectEqualStrings("{\"commands\":[]}", anthropic_text);
    try std.testing.expectEqualStrings("{\"commands\":[]}", google_text);
}
