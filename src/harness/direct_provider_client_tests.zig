const std = @import("std");
const provider = @import("direct_provider_client.zig");
const http_transport = @import("../api/http_transport.zig");

const Provider = provider.Provider;
const ResponseFormat = provider.ResponseFormat;
const TextRequest = provider.TextRequest;
const DirectRandomProviderClient = provider.DirectRandomProviderClient;
const parseProviderModels = provider.parseProviderModels;
const routeName = provider.routeName;
const anthropicJsonToolConfig = provider.anthropicJsonToolConfig;
const openAIJsonResponseFormat = provider.openAIJsonResponseFormat;
const extractAnthropicContent = provider.extractAnthropicContent;
const maxTokens = provider.maxTokens;
const jsonString = provider.jsonString;
const default_json_schema = provider.default_json_schema;

test "provider roster accepts all configured providers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const models = try parseProviderModels(arena.allocator(), "openai:gpt-4.1-nano,anthropic:claude-haiku-4-5-20251001,google:gemini-3.1-flash-lite");
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqual(Provider.openai, models[0].provider);
    try std.testing.expectEqual(Provider.anthropic, models[1].provider);
    try std.testing.expectEqual(Provider.google, models[2].provider);
}

test "provider roster rejects invalid entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidRandomProvider, parseProviderModels(allocator, "bogus:model"));
    try std.testing.expectError(error.InvalidRandomProviderModel, parseProviderModels(allocator, "openai:"));
    try std.testing.expectError(error.NoRandomProviderModels, parseProviderModels(allocator, ""));
}

test "provider route names are exact API endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", try routeName(allocator, .openai, "gpt-4.1-nano"));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", try routeName(allocator, .anthropic, "claude-haiku-4-5-20251001"));
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent", try routeName(allocator, .google, "gemini-3.1-flash-lite"));
    try std.testing.expectEqualStrings("https://api.deepseek.com/v1/chat/completions", try routeName(allocator, .deepseek, "deepseek-chat"));
}

test "direct random provider skips models whose provider key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    try env.put("ANTHROPIC_API_KEY", "test-anthropic-key");
    var transport = CapturingHttpTransport{};
    const models_spec = "openai:gpt-4.1-nano,anthropic:claude-haiku-4-5-20251001,google:gemini-3.1-flash-lite";
    var client = DirectRandomProviderClient.initDirectFromEnv(
        io_threaded.io(),
        transport.client(),
        &env,
        models_spec,
    );

    const available = try client.availableModels(allocator, models_spec);

    try std.testing.expectEqual(@as(usize, 1), available.len);
    try std.testing.expectEqual(Provider.anthropic, available[0].provider);
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", available[0].model);
}

test "direct random provider reports when every configured provider key is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    var transport = CapturingHttpTransport{};
    const models_spec = "openai:gpt-4.1-nano,anthropic:claude-haiku-4-5-20251001";
    var client = DirectRandomProviderClient.initDirectFromEnv(
        io_threaded.io(),
        transport.client(),
        &env,
        models_spec,
    );

    try std.testing.expectError(error.MissingRandomProviderApiKey, client.availableModels(allocator, models_spec));
}

const CapturingHttpTransport = struct {
    url: []const u8 = "",
    body: []const u8 = "",

    fn client(self: *CapturingHttpTransport) http_transport.Client {
        return .{ .ctx = self, .postJsonFn = CapturingHttpTransport.postJson };
    }

    fn postJson(ctx: *anyopaque, allocator: std.mem.Allocator, request: http_transport.JsonPostRequest) ![]u8 {
        const self: *CapturingHttpTransport = @ptrCast(@alignCast(ctx));
        self.url = request.url;
        self.body = try allocator.dupe(u8, request.body);
        return try allocator.dupe(u8, "host completion");
    }
};

test "default random provider construction ignores credentials and routes text through host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    try env.put("OPENAI_API_KEY", "should-not-enter-core-routing");
    var transport = CapturingHttpTransport{};
    var client = DirectRandomProviderClient.init(io_threaded.io(), transport.client(), &env, "openai:gpt-4.1-nano");

    const text = try client.completeText(allocator, .{
        .subsystem = "conversation",
        .system_prompt = "system rules",
        .user_prompt = "hello",
        .response_format = .text,
        .response_size = .small,
        .reasoning_effort = .medium,
    });

    try std.testing.expectEqualStrings("host completion", text);
    try std.testing.expectEqualStrings("affective-host://llm/complete", transport.url);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"models\":[{\"provider\":\"openai\",\"model\":\"gpt-4.1-nano\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"system_prompt\":\"system rules\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"user_prompt\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"reasoning_effort\":\"medium\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "api.openai.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "should-not-enter-core-routing") == null);
}

test "default random provider construction routes vision through host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    var env = std.process.Environ.Map.init(allocator);
    var transport = CapturingHttpTransport{};
    var client = DirectRandomProviderClient.init(io_threaded.io(), transport.client(), &env, "google:gemini-3.1-flash-lite");

    const text = try client.completeVision(allocator, .{
        .subsystem = "vision_description",
        .prompt = "describe this",
        .image_paths = &[_][]const u8{"/tmp/does-not-need-to-exist.png"},
        .response_format = .text,
        .response_size = .medium,
    });

    try std.testing.expectEqualStrings("host completion", text);
    try std.testing.expectEqualStrings("affective-host://vision/complete", transport.url);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"models\":[{\"provider\":\"google\",\"model\":\"gemini-3.1-flash-lite\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"prompt\":\"describe this\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "\"image_paths\":[\"/tmp/does-not-need-to-exist.png\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, transport.body, "generativelanguage.googleapis.com") == null);
}

test "anthropic json requests force tool use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const request = TextRequest{
        .subsystem = "test",
        .system_prompt = "system",
        .user_prompt = "user",
        .response_format = .json_object,
        .json_schema = "{\"type\":\"object\",\"required\":[\"action\"]}",
    };
    const maybe_tools = if (request.response_format == .json_object) try anthropicJsonToolConfig(allocator, request.json_schema) else "";
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s},\"max_tokens\":{d},\"temperature\":{d:.3},\"system\":{s},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]{s}}}",
        .{ try jsonString(allocator, "claude-haiku-4-5-20251001"), maxTokens(request.response_size), request.temperature, try jsonString(allocator, request.system_prompt), try jsonString(allocator, request.user_prompt), maybe_tools },
    );

    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"required\":[\"action\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":{\"type\":\"tool\",\"name\":\"json_response\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"assistant\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"{\"") == null);
}

test "openai json response format uses supplied schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const format = try openAIJsonResponseFormat(allocator, "api_health", "{\"type\":\"object\",\"required\":[\"ok\"]}");
    try std.testing.expect(std.mem.indexOf(u8, format, "\"type\":\"json_schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, format, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, format, "\"required\":[\"ok\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, format, "\"type\":\"json_object\"") == null);
}

test "default json schema is strict-openai compatible" {
    try std.testing.expect(std.mem.indexOf(u8, default_json_schema, "\"additionalProperties\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json_schema, "\"properties\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_json_schema, "\"required\":[]") != null);
}

test "anthropic extractor accepts text and forced json tool input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text = try extractAnthropicContent(allocator,
        \\{"content":[{"type":"text","text":"ok"}]}
    , .text);
    try std.testing.expectEqualStrings("ok", text);

    const content = try extractAnthropicContent(allocator,
        \\{"content":[{"type":"tool_use","id":"toolu_1","name":"json_response","input":{"action":"unknown","value":null}}]}
    , .json_object);
    try std.testing.expectEqualStrings("{\"action\":\"unknown\",\"value\":null}", content);
}
