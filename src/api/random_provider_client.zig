const std = @import("std");
const files = @import("../platform/common/files.zig");
const service_errors = @import("service_errors.zig");
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

const ProviderModel = struct {
    provider: Provider,
    model: []const u8,
};

const max_response_bytes: usize = 1024 * 1024;

const RouteFailure = struct {
    provider: Provider,
    model: []const u8,
    err: anyerror,
};

pub const RandomProviderClient = struct {
    io: std.Io,
    http: http_transport.Client,
    models_spec: []const u8,
    openai_api_key: ?[]const u8,
    anthropic_api_key: ?[]const u8,
    google_api_key: ?[]const u8,
    rng: std.Random.DefaultPrng,

    pub fn init(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, models_spec: []const u8) RandomProviderClient {
        return .{
            .io = io,
            .http = http,
            .models_spec = models_spec,
            .openai_api_key = env.get("OPENAI_API_KEY"),
            .anthropic_api_key = env.get("ANTHROPIC_API_KEY"),
            .google_api_key = env.get("GEMINI_API_KEY") orelse env.get("GOOGLE_API_KEY") orelse env.get("GOOGLE_AI_API_KEY"),
            .rng = std.Random.DefaultPrng.init(randomSeed(io)),
        };
    }

    pub fn completeText(self: *RandomProviderClient, allocator: std.mem.Allocator, request: TextRequest) ![]const u8 {
        const available = try self.availableModels(allocator);
        const start = self.rng.random().intRangeLessThan(usize, 0, available.len);
        var failures = std.ArrayList(RouteFailure).empty;
        for (0..available.len) |offset| {
            const selected = available[(start + offset) % available.len];
            const content = self.completeTextWithModel(allocator, selected, request) catch |err| {
                try failures.append(allocator, .{ .provider = selected.provider, .model = selected.model, .err = err });
                continue;
            };
            if (request.response_validator) |validate| {
                validate(allocator, content) catch |err| {
                    if (request.bad_response_logger) |logBadResponse| logBadResponse(request.subsystem, providerName(selected.provider), selected.model, err, content);
                    allocator.free(content);
                    try failures.append(allocator, .{ .provider = selected.provider, .model = selected.model, .err = err });
                    continue;
                };
            }
            return content;
        }
        logRouteFailures(request.subsystem, failures.items);
        if (failures.items.len > 0) return failures.items[failures.items.len - 1].err;
        return error.RemoteServiceFailed;
    }

    pub fn completeVision(self: *RandomProviderClient, allocator: std.mem.Allocator, request: VisionRequest) ![]const u8 {
        if (request.image_paths.len == 0) return error.NoImagesProvided;
        const selected = try self.selectAvailable(allocator);
        return switch (selected.provider) {
            .openai => try callOpenAIVision(allocator, self.io, self.http, self.openai_api_key.?, selected.model, request),
            .anthropic => try callAnthropicVision(allocator, self.io, self.http, self.anthropic_api_key.?, selected.model, request),
            .google => try callGoogleVision(allocator, self.io, self.http, self.google_api_key.?, selected.model, request),
        };
    }

    fn selectAvailable(self: *RandomProviderClient, allocator: std.mem.Allocator) !ProviderModel {
        const available = try self.availableModels(allocator);
        return available[self.rng.random().intRangeLessThan(usize, 0, available.len)];
    }

    fn availableModels(self: *RandomProviderClient, allocator: std.mem.Allocator) ![]ProviderModel {
        const models = try parseProviderModels(allocator, self.models_spec);
        var available = std.ArrayList(ProviderModel).empty;
        for (models) |model| {
            if (self.apiKeyFor(model.provider) != null) try available.append(allocator, model);
        }
        if (available.items.len == 0) return error.MissingRandomProviderApiKey;
        return try available.toOwnedSlice(allocator);
    }

    fn completeTextWithModel(self: *RandomProviderClient, allocator: std.mem.Allocator, selected: ProviderModel, request: TextRequest) ![]const u8 {
        return switch (selected.provider) {
            .openai => try callOpenAIText(allocator, self.http, self.openai_api_key.?, selected.model, request),
            .anthropic => try callAnthropicText(allocator, self.http, self.anthropic_api_key.?, selected.model, request),
            .google => try callGoogleText(allocator, self.http, self.google_api_key.?, selected.model, request),
        };
    }

    fn apiKeyFor(self: *RandomProviderClient, provider: Provider) ?[]const u8 {
        return switch (provider) {
            .openai => self.openai_api_key,
            .anthropic => self.anthropic_api_key,
            .google => self.google_api_key,
        };
    }

    pub fn checkTextRoutes(self: *RandomProviderClient, allocator: std.mem.Allocator, label: []const u8, models_spec: []const u8) !usize {
        const models = try parseProviderModels(allocator, models_spec);
        var checked: usize = 0;
        for (models) |model| {
            const route = try routeName(allocator, model.provider, model.model);
            std.debug.print("API_HEALTH start label={s} provider={s} model={s} route={s}\n", .{ label, providerName(model.provider), model.model, route });
            const content = try self.checkTextRoute(allocator, model);
            if (std.mem.trim(u8, content, " \r\n\t").len == 0) return error.EmptyHealthCheckResponse;
            std.debug.print("API_HEALTH ok label={s} provider={s} model={s} route={s}\n", .{ label, providerName(model.provider), model.model, route });
            checked += 1;
        }
        return checked;
    }

    fn checkTextRoute(self: *RandomProviderClient, allocator: std.mem.Allocator, model: ProviderModel) ![]const u8 {
        const request = TextRequest{
            .subsystem = "api_health",
            .system_prompt = "You are an API health check. Reply with ok.",
            .user_prompt = "Reply with ok.",
            .temperature = 0,
            .response_format = .text,
            .response_size = .small,
        };
        return switch (model.provider) {
            .openai => try callOpenAIText(allocator, self.http, self.openai_api_key orelse return error.MissingOpenAIAPIKey, model.model, request),
            .anthropic => try callAnthropicText(allocator, self.http, self.anthropic_api_key orelse return error.MissingAnthropicAPIKey, model.model, request),
            .google => try callGoogleText(allocator, self.http, self.google_api_key orelse return error.MissingGoogleAPIKey, model.model, request),
        };
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

fn logRouteFailures(subsystem: []const u8, failures: []const RouteFailure) void {
    std.debug.print("{s} random provider exhausted {d} route(s)\n", .{ subsystem, failures.len });
    for (failures) |failure| {
        std.debug.print(
            "{s} random provider failure provider={s} model={s} error={s}\n",
            .{ subsystem, providerName(failure.provider), failure.model, @errorName(failure.err) },
        );
    }
}

fn routeName(allocator: std.mem.Allocator, provider: Provider, model: []const u8) ![]const u8 {
    return switch (provider) {
        .openai => "https://api.openai.com/v1/chat/completions",
        .anthropic => "https://api.anthropic.com/v1/messages",
        .google => try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent", .{model}),
    };
}

fn callOpenAIText(allocator: std.mem.Allocator, http: http_transport.Client, api_key: []const u8, model: []const u8, request: TextRequest) ![]const u8 {
    const maybe_effort = if (request.reasoning_effort != null and supportsReasoningEffort(model))
        try std.fmt.allocPrint(allocator, ",\"reasoning_effort\":{s}", .{try jsonString(allocator, @tagName(request.reasoning_effort.?))})
    else
        "";
    const maybe_format = switch (request.response_format) {
        .text => "",
        .json_object => try openAIJsonResponseFormat(allocator, request.subsystem, request.json_schema),
    };
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s}{s},\"temperature\":{d:.3}{s},\"messages\":[{{\"role\":\"system\",\"content\":{s}}},{{\"role\":\"user\",\"content\":{s}}}]}}",
        .{ try jsonString(allocator, model), maybe_effort, request.temperature, maybe_format, try jsonString(allocator, request.system_prompt), try jsonString(allocator, request.user_prompt) },
    );
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    return callChatCompletionsWithRetry(allocator, http, request.subsystem, "openai", model, auth, body);
}

fn callAnthropicText(allocator: std.mem.Allocator, http: http_transport.Client, api_key: []const u8, model: []const u8, request: TextRequest) ![]const u8 {
    const maybe_tools = if (request.response_format == .json_object) try anthropicJsonToolConfig(allocator, request.json_schema) else "";
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s},\"max_tokens\":{d},\"temperature\":{d:.3},\"system\":{s},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]{s}}}",
        .{ try jsonString(allocator, model), maxTokens(request.response_size), request.temperature, try jsonString(allocator, request.system_prompt), try jsonString(allocator, request.user_prompt), maybe_tools },
    );
    const auth = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
    return callAnthropicMessagesWithRetry(allocator, http, request.subsystem, model, auth, body, request.response_format);
}

fn callGoogleText(allocator: std.mem.Allocator, http: http_transport.Client, api_key: []const u8, model: []const u8, request: TextRequest) ![]const u8 {
    const maybe_mime = switch (request.response_format) {
        .text => "",
        .json_object => ",\"responseMimeType\":\"application/json\"",
    };
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"systemInstruction\":{{\"parts\":[{{\"text\":{s}}}]}},\"contents\":[{{\"role\":\"user\",\"parts\":[{{\"text\":{s}}}]}}],\"generationConfig\":{{\"temperature\":{d:.3},\"maxOutputTokens\":{d}{s}}}}}",
        .{ try jsonString(allocator, request.system_prompt), try jsonString(allocator, request.user_prompt), request.temperature, maxTokens(request.response_size), maybe_mime },
    );
    return callGoogleGenerateContentWithRetry(allocator, http, request.subsystem, model, api_key, body);
}

fn callOpenAIVision(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, api_key: []const u8, model: []const u8, request: VisionRequest) ![]const u8 {
    var content = std.ArrayList(u8).empty;
    try content.appendSlice(allocator, "[{\"type\":\"text\",\"text\":");
    try content.appendSlice(allocator, try jsonString(allocator, request.prompt));
    try content.appendSlice(allocator, "}");
    for (request.image_paths) |image_path| {
        const data_url = try imageDataUrl(allocator, io, image_path);
        try content.appendSlice(allocator, ",{\"type\":\"image_url\",\"image_url\":{\"url\":");
        try content.appendSlice(allocator, try jsonString(allocator, data_url));
        try content.appendSlice(allocator, "}}");
    }
    try content.appendSlice(allocator, "]");
    const maybe_format = switch (request.response_format) {
        .text => "",
        .json_object => try openAIJsonResponseFormat(allocator, request.subsystem, request.json_schema),
    };
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s},\"temperature\":{d:.3}{s},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]}}",
        .{ try jsonString(allocator, model), request.temperature, maybe_format, content.items },
    );
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    return callChatCompletionsWithRetry(allocator, http, request.subsystem, "openai", model, auth, body);
}

fn callAnthropicVision(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, api_key: []const u8, model: []const u8, request: VisionRequest) ![]const u8 {
    var content = std.ArrayList(u8).empty;
    try content.appendSlice(allocator, "[{\"type\":\"text\",\"text\":");
    try content.appendSlice(allocator, try jsonString(allocator, request.prompt));
    try content.appendSlice(allocator, "}");
    for (request.image_paths) |image_path| {
        const encoded = try imageBase64(allocator, io, image_path);
        try content.print(allocator, ",{{\"type\":\"image\",\"source\":{{\"type\":\"base64\",\"media_type\":{s},\"data\":{s}}}}}", .{ try jsonString(allocator, try mimeTypeForPath(image_path)), try jsonString(allocator, encoded) });
    }
    try content.appendSlice(allocator, "]");
    const maybe_tools = if (request.response_format == .json_object) try anthropicJsonToolConfig(allocator, request.json_schema) else "";
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"model\":{s},\"max_tokens\":{d},\"temperature\":{d:.3},\"messages\":[{{\"role\":\"user\",\"content\":{s}}}]{s}}}",
        .{ try jsonString(allocator, model), maxTokens(request.response_size), request.temperature, content.items, maybe_tools },
    );
    const auth = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
    return callAnthropicMessagesWithRetry(allocator, http, request.subsystem, model, auth, body, request.response_format);
}

fn callGoogleVision(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, api_key: []const u8, model: []const u8, request: VisionRequest) ![]const u8 {
    var parts = std.ArrayList(u8).empty;
    try parts.appendSlice(allocator, "[{\"text\":");
    try parts.appendSlice(allocator, try jsonString(allocator, request.prompt));
    try parts.appendSlice(allocator, "}");
    for (request.image_paths) |image_path| {
        const encoded = try imageBase64(allocator, io, image_path);
        try parts.print(allocator, ",{{\"inlineData\":{{\"mimeType\":{s},\"data\":{s}}}}}", .{ try jsonString(allocator, try mimeTypeForPath(image_path)), try jsonString(allocator, encoded) });
    }
    try parts.appendSlice(allocator, "]");
    const maybe_mime = switch (request.response_format) {
        .text => "",
        .json_object => ",\"responseMimeType\":\"application/json\"",
    };
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"contents\":[{{\"role\":\"user\",\"parts\":{s}}}],\"generationConfig\":{{\"temperature\":{d:.3},\"maxOutputTokens\":{d}{s}}}}}",
        .{ parts.items, request.temperature, maxTokens(request.response_size), maybe_mime },
    );
    return callGoogleGenerateContentWithRetry(allocator, http, request.subsystem, model, api_key, body);
}

fn callChatCompletionsWithRetry(allocator: std.mem.Allocator, http: http_transport.Client, subsystem: []const u8, provider: []const u8, model: []const u8, auth: []const u8, body: []const u8) ![]const u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const transport_allocator = std.heap.page_allocator;
        const out = try postJson(transport_allocator, http, "https://api.openai.com/v1/chat/completions", &.{
            .{ .name = "Authorization", .value = authHeaderValue(auth) },
        }, body);
        defer transport_allocator.free(out);
        return extractOpenAIContent(allocator, out) catch |err| {
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry(subsystem, provider, model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn callAnthropicMessagesWithRetry(allocator: std.mem.Allocator, http: http_transport.Client, subsystem: []const u8, model: []const u8, auth: []const u8, body: []const u8, response_format: ResponseFormat) ![]const u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const transport_allocator = std.heap.page_allocator;
        const out = try postJson(transport_allocator, http, "https://api.anthropic.com/v1/messages", &.{
            .{ .name = "x-api-key", .value = authHeaderValue(auth) },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        }, body);
        defer transport_allocator.free(out);
        return extractAnthropicContent(allocator, out, response_format) catch |err| {
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry(subsystem, "anthropic", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn callGoogleGenerateContentWithRetry(allocator: std.mem.Allocator, http: http_transport.Client, subsystem: []const u8, model: []const u8, api_key: []const u8, body: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent?key={s}", .{ model, api_key });
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const transport_allocator = std.heap.page_allocator;
        const out = try postJson(transport_allocator, http, url, &.{}, body);
        defer transport_allocator.free(out);
        return extractGoogleContent(allocator, out) catch |err| {
            if (service_errors.shouldRetry(err, attempt)) {
                service_errors.logRemoteRetry(subsystem, "google", model, attempt);
                continue;
            }
            return err;
        };
    }
}

fn postJson(allocator: std.mem.Allocator, http: http_transport.Client, url: []const u8, extra_headers: []const http_transport.Header, body: []const u8) ![]u8 {
    std.debug.print("HTTP start method=POST url={s} payload_bytes={d} response_limit={d}\n", .{ redactedUrl(url), body.len, max_response_bytes });
    const bytes = try http.postJson(allocator, .{
        .url = url,
        .headers = extra_headers,
        .body = body,
        .max_response_bytes = max_response_bytes,
    });
    errdefer allocator.free(bytes);
    if (bytes.len > max_response_bytes) {
        std.debug.print("HTTP response_too_large url={s} response_bytes={d} response_limit={d}\n", .{ redactedUrl(url), bytes.len, max_response_bytes });
        return error.StreamTooLong;
    }
    return bytes;
}

fn authHeaderValue(header: []const u8) []const u8 {
    const sep = std.mem.indexOfScalar(u8, header, ':') orelse return header;
    return std.mem.trim(u8, header[sep + 1 ..], " \t");
}

fn redactedUrl(url: []const u8) []const u8 {
    const query_start = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    const query = url[query_start + 1 ..];
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const key_end = std.mem.indexOfScalar(u8, part, '=') orelse part.len;
        if (isSensitiveQueryKey(part[0..key_end])) return url[0..query_start];
    }
    return url;
}

fn isSensitiveQueryKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "key") or
        std.ascii.eqlIgnoreCase(key, "api_key") or
        std.ascii.eqlIgnoreCase(key, "apikey") or
        std.ascii.eqlIgnoreCase(key, "access_token") or
        std.ascii.eqlIgnoreCase(key, "token");
}

fn oneLinePreview(text: []const u8, buffer: []u8) []const u8 {
    const len = @min(text.len, buffer.len);
    for (text[0..len], 0..) |byte, i| {
        buffer[i] = switch (byte) {
            '\n', '\r', '\t' => ' ',
            else => if (std.ascii.isPrint(byte)) byte else ' ',
        };
    }
    return buffer[0..len];
}

fn extractOpenAIContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Response = struct { choices: []struct { message: struct { content: []const u8 } } };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    if (parsed.value.choices.len == 0) return error.RemoteServiceFailed;
    return allocator.dupe(u8, parsed.value.choices[0].message.content);
}

fn extractAnthropicContent(allocator: std.mem.Allocator, body: []const u8, response_format: ResponseFormat) ![]const u8 {
    const Response = struct {
        content: []struct {
            type: []const u8 = "",
            text: ?[]const u8 = null,
            name: ?[]const u8 = null,
            input: ?std.json.Value = null,
        },
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    for (parsed.value.content) |part| {
        switch (response_format) {
            .text => if (part.text) |text| return allocator.dupe(u8, text),
            .json_object => {
                if (!std.mem.eql(u8, part.type, "tool_use")) continue;
                const name = part.name orelse return error.RemoteServiceFailed;
                if (!std.mem.eql(u8, name, "json_response")) return error.RemoteServiceFailed;
                const input = part.input orelse return error.RemoteServiceFailed;
                return std.json.Stringify.valueAlloc(allocator, input, .{});
            },
        }
    }
    return error.RemoteServiceFailed;
}

fn extractGoogleContent(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const Response = struct {
        candidates: []struct { content: struct { parts: []struct { text: ?[]const u8 = null } } },
    };
    const parsed = std.json.parseFromSlice(Response, allocator, body, .{ .ignore_unknown_fields = true }) catch return service_errors.responseShapeError(allocator, body);
    defer parsed.deinit();
    if (parsed.value.candidates.len == 0) return error.RemoteServiceFailed;
    for (parsed.value.candidates[0].content.parts) |part| {
        if (part.text) |text| return allocator.dupe(u8, text);
    }
    return error.RemoteServiceFailed;
}

fn anthropicJsonToolConfig(allocator: std.mem.Allocator, json_schema: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        ",\"tools\":[{{\"name\":\"json_response\",\"description\":\"Return exactly the requested JSON object.\",\"input_schema\":{s}}}],\"tool_choice\":{{\"type\":\"tool\",\"name\":\"json_response\"}}",
        .{json_schema},
    );
}

fn imageDataUrl(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ try mimeTypeForPath(image_path), try imageBase64(allocator, io, image_path) });
}

fn imageBase64(allocator: std.mem.Allocator, io: std.Io, image_path: []const u8) ![]const u8 {
    const bytes = try files.readFileAllocPath(io, image_path, allocator, .limited(20 * 1024 * 1024));
    const size = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, size);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn mimeTypeForPath(path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".webp")) return "image/webp";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    return error.UnsupportedImageType;
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

test "provider route names are exact API endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", try routeName(allocator, .openai, "gpt-4.1-nano"));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", try routeName(allocator, .anthropic, "claude-haiku-4-5-20251001"));
    try std.testing.expectEqualStrings("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent", try routeName(allocator, .google, "gemini-3.1-flash-lite"));
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
