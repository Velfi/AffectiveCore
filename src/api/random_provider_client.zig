const std = @import("std");
const chat = @import("chat_client.zig");
const http_transport = @import("http_transport.zig");

pub const Provider = enum {
    openai,
    anthropic,
    google,
};

pub const ResponseFormat = enum {
    text,
    json_object,
};

pub const ResponseSize = enum {
    small,
    medium,
    large,
};

pub const TextRequest = struct {
    subsystem: []const u8,
    system_prompt: []const u8,
    user_prompt: []const u8,
    temperature: f32 = 0.2,
    response_format: ResponseFormat = .json_object,
    response_size: ResponseSize = .medium,
    reasoning_effort: ?chat.ReasoningEffort = null,
    json_schema: []const u8 = default_json_schema,
    response_validator: ?*const fn (std.mem.Allocator, []const u8) anyerror!void = null,
    bad_response_logger: ?*const fn ([]const u8, []const u8, []const u8, anyerror, []const u8) void = null,
};

pub const VisionRequest = struct {
    subsystem: []const u8,
    prompt: []const u8,
    image_paths: []const []const u8,
    temperature: f32 = 0.2,
    response_format: ResponseFormat = .text,
    response_size: ResponseSize = .medium,
    json_schema: []const u8 = default_json_schema,
};

const default_json_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"required\":[]}";

pub const ProviderModel = struct {
    provider: Provider,
    model: []const u8,
};

const max_response_bytes: usize = 1024 * 1024;

pub const RandomProviderClient = struct {
    io: std.Io,
    http: http_transport.Client,
    models_spec: []const u8,

    pub fn init(io: std.Io, http: http_transport.Client, models_spec: []const u8) RandomProviderClient {
        return initHostManaged(io, http, models_spec);
    }

    pub fn initHostManaged(io: std.Io, http: http_transport.Client, models_spec: []const u8) RandomProviderClient {
        return .{
            .io = io,
            .http = http,
            .models_spec = models_spec,
        };
    }

    pub fn completeText(self: *RandomProviderClient, allocator: std.mem.Allocator, request: TextRequest) ![]const u8 {
        _ = self.io;
        const content = try callHostLLMComplete(allocator, self.http, self.models_spec, request);
        if (request.response_validator) |validate| {
            validate(allocator, content) catch |err| {
                if (request.bad_response_logger) |logBadResponse| logBadResponse(request.subsystem, "host", "host_llm_complete", err, content);
                allocator.free(content);
                return err;
            };
        }
        return content;
    }

    pub fn completeVision(self: *RandomProviderClient, allocator: std.mem.Allocator, request: VisionRequest) ![]const u8 {
        _ = self.io;
        if (request.image_paths.len == 0) return error.NoImagesProvided;
        return try callHostVisionComplete(allocator, self.http, self.models_spec, request);
    }
};

pub fn parseProviderModels(allocator: std.mem.Allocator, spec: []const u8) ![]ProviderModel {
    const text = std.mem.trim(u8, spec, " \r\n\t");
    if (text.len == 0) return error.NoRandomProviderModels;

    var out = std.ArrayList(ProviderModel).empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \r\n\t");
        if (part.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidRandomProviderModel;
        const provider_text = std.mem.trim(u8, part[0..sep], " \r\n\t");
        const model_text = std.mem.trim(u8, part[sep + 1 ..], " \r\n\t");
        if (provider_text.len == 0 or model_text.len == 0) return error.InvalidRandomProviderModel;
        try out.append(allocator, .{
            .provider = parseProvider(provider_text) orelse return error.InvalidRandomProvider,
            .model = model_text,
        });
    }
    if (out.items.len == 0) return error.NoRandomProviderModels;
    return out.toOwnedSlice(allocator);
}

fn parseProvider(text: []const u8) ?Provider {
    if (std.ascii.eqlIgnoreCase(text, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(text, "anthropic")) return .anthropic;
    if (std.ascii.eqlIgnoreCase(text, "google") or std.ascii.eqlIgnoreCase(text, "gemini")) return .google;
    return null;
}

fn providerName(provider: Provider) []const u8 {
    return switch (provider) {
        .openai => "openai",
        .anthropic => "anthropic",
        .google => "google",
    };
}

fn callHostLLMComplete(allocator: std.mem.Allocator, http: http_transport.Client, models_spec: []const u8, request: TextRequest) ![]const u8 {
    const models_json = try providerModelsJson(allocator, models_spec);
    const reasoning_effort_json = if (request.reasoning_effort) |effort|
        try jsonString(allocator, @tagName(effort))
    else
        "null";
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"subsystem\":{s},\"models\":{s},\"system_prompt\":{s},\"user_prompt\":{s},\"response_format\":{s},\"response_size\":{s},\"reasoning_effort\":{s},\"temperature\":{d:.3},\"max_tokens\":{d},\"json_schema\":{s}}}",
        .{
            try jsonString(allocator, request.subsystem),
            models_json,
            try jsonString(allocator, request.system_prompt),
            try jsonString(allocator, request.user_prompt),
            try jsonString(allocator, @tagName(request.response_format)),
            try jsonString(allocator, @tagName(request.response_size)),
            reasoning_effort_json,
            request.temperature,
            maxTokens(request.response_size),
            try jsonString(allocator, request.json_schema),
        },
    );
    return postJson(allocator, http, "affective-host://llm/complete", &.{}, body);
}

fn callHostVisionComplete(allocator: std.mem.Allocator, http: http_transport.Client, models_spec: []const u8, request: VisionRequest) ![]const u8 {
    const models_json = try providerModelsJson(allocator, models_spec);
    var image_paths = std.ArrayList(u8).empty;
    try image_paths.append(allocator, '[');
    for (request.image_paths, 0..) |path, i| {
        if (i > 0) try image_paths.append(allocator, ',');
        try image_paths.appendSlice(allocator, try jsonString(allocator, path));
    }
    try image_paths.append(allocator, ']');
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"subsystem\":{s},\"models\":{s},\"prompt\":{s},\"image_paths\":{s},\"response_format\":{s},\"response_size\":{s},\"temperature\":{d:.3},\"max_tokens\":{d},\"json_schema\":{s}}}",
        .{
            try jsonString(allocator, request.subsystem),
            models_json,
            try jsonString(allocator, request.prompt),
            image_paths.items,
            try jsonString(allocator, @tagName(request.response_format)),
            try jsonString(allocator, @tagName(request.response_size)),
            request.temperature,
            maxTokens(request.response_size),
            try jsonString(allocator, request.json_schema),
        },
    );
    return postJson(allocator, http, "affective-host://vision/complete", &.{}, body);
}

fn providerModelsJson(allocator: std.mem.Allocator, models_spec: []const u8) ![]const u8 {
    const models = try parseProviderModels(allocator, models_spec);
    var out = std.ArrayList(u8).empty;
    try out.append(allocator, '[');
    for (models, 0..) |model, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.print(
            allocator,
            "{{\"provider\":{s},\"model\":{s}}}",
            .{ try jsonString(allocator, providerName(model.provider)), try jsonString(allocator, model.model) },
        );
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

fn postJson(allocator: std.mem.Allocator, http: http_transport.Client, url: []const u8, extra_headers: []const http_transport.Header, body: []const u8) ![]u8 {
    std.debug.print("HTTP start method=POST url={s} payload_bytes={d} response_limit={d}\n", .{ url, body.len, max_response_bytes });
    const bytes = try http.postJson(allocator, .{
        .url = url,
        .headers = extra_headers,
        .body = body,
        .max_response_bytes = max_response_bytes,
    });
    errdefer allocator.free(bytes);
    if (bytes.len > max_response_bytes) {
        std.debug.print("HTTP response_too_large url={s} response_bytes={d} response_limit={d}\n", .{ url, bytes.len, max_response_bytes });
        return error.StreamTooLong;
    }
    return bytes;
}

fn maxTokens(size: ResponseSize) u32 {
    return switch (size) {
        .small => 240,
        .medium => 800,
        .large => 1600,
    };
}

fn openAIJsonResponseFormat(allocator: std.mem.Allocator, name: []const u8, json_schema: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        ",\"response_format\":{{\"type\":\"json_schema\",\"json_schema\":{{\"name\":{s},\"strict\":true,\"schema\":{s}}}}}",
        .{ try jsonString(allocator, name), json_schema },
    );
}

fn supportsReasoningEffort(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "o") or std.mem.startsWith(u8, model, "gpt-5");
}

fn randomSeed(io: std.Io) u64 {
    const now = std.Io.Clock.now(.boot, io).nanoseconds;
    return @as(u64, @truncate(@as(u128, @intCast(@abs(now)))));
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}

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

test "default random provider construction routes text through host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    var transport = CapturingHttpTransport{};
    var client = RandomProviderClient.init(io_threaded.io(), transport.client(), "openai:gpt-4.1-nano");

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
}

test "default random provider construction routes vision through host" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    var transport = CapturingHttpTransport{};
    var client = RandomProviderClient.init(io_threaded.io(), transport.client(), "google:gemini-3.1-flash-lite");

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
}
