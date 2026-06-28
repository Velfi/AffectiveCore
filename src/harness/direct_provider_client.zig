const std = @import("std");
const files = @import("../platform/common/files.zig");
const service_errors = @import("../api/service_errors.zig");
const chat = @import("../api/chat_client.zig");
const http_transport = @import("../api/http_transport.zig");
const http_log = @import("../api/http_log.zig");
const llm_routing = @import("../core/llm_routing.zig");
const random_provider_client = @import("../api/random_provider_client.zig");
const brain_context_stats = @import("../core/brain_context_stats.zig");

pub const Provider = enum {
    openai,
    anthropic,
    google,
    deepseek,
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
    effort_tier: ?llm_routing.EffortTier = null,
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
    effort_tier: ?llm_routing.EffortTier = null,
    json_schema: []const u8 = default_json_schema,
};

pub const default_json_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"required\":[]}";

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

pub const DirectRandomProviderClient = struct {
    io: std.Io,
    http: http_transport.Client,
    models_spec: []const u8,
    llm_quality: llm_routing.LlmQuality,
    openai_api_key: ?[]const u8,
    anthropic_api_key: ?[]const u8,
    google_api_key: ?[]const u8,
    deepseek_api_key: ?[]const u8,
    host_provider_routing: bool,
    rng: std.Random.DefaultPrng,
    stats_recorder: ?random_provider_client.LlmStatsRecorder = null,

    pub fn init(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, models_spec: []const u8) DirectRandomProviderClient {
        _ = env;
        return initHostManaged(io, http, models_spec);
    }

    pub fn initHostManaged(io: std.Io, http: http_transport.Client, models_spec: []const u8) DirectRandomProviderClient {
        return initHostManagedWithQuality(io, http, models_spec, .auto);
    }

    pub fn initHostManagedWithQuality(io: std.Io, http: http_transport.Client, models_spec: []const u8, quality: llm_routing.LlmQuality) DirectRandomProviderClient {
        return .{
            .io = io,
            .http = http,
            .models_spec = models_spec,
            .llm_quality = quality,
            .openai_api_key = null,
            .anthropic_api_key = null,
            .google_api_key = null,
            .deepseek_api_key = null,
            .host_provider_routing = true,
            .rng = std.Random.DefaultPrng.init(randomSeed(io)),
        };
    }

    pub fn initDirectFromEnv(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, models_spec: []const u8) DirectRandomProviderClient {
        return initDirectFromEnvWithQuality(io, http, env, models_spec, .auto);
    }

    pub fn initDirectFromEnvWithQuality(io: std.Io, http: http_transport.Client, env: *const std.process.Environ.Map, models_spec: []const u8, quality: llm_routing.LlmQuality) DirectRandomProviderClient {
        return .{
            .io = io,
            .http = http,
            .models_spec = models_spec,
            .llm_quality = quality,
            .openai_api_key = env.get("OPENAI_API_KEY"),
            .anthropic_api_key = env.get("ANTHROPIC_API_KEY"),
            .google_api_key = env.get("GEMINI_API_KEY") orelse env.get("GOOGLE_API_KEY") orelse env.get("GOOGLE_AI_API_KEY"),
            .deepseek_api_key = env.get("DEEPSEEK_API_KEY"),
            .host_provider_routing = env.get("AFFECTIVE_HOST_PROVIDER_ROUTING") != null,
            .rng = std.Random.DefaultPrng.init(randomSeed(io)),
        };
    }

    fn resolvedModelsSpec(self: *DirectRandomProviderClient, allocator: std.mem.Allocator, subsystem: []const u8, effort_tier: ?llm_routing.EffortTier) ![]const u8 {
        const roster = try llm_routing.parseRosterFromModelsSpec(allocator, self.models_spec);
        defer roster.deinit(allocator);
        const tier = effort_tier orelse llm_routing.defaultEffortTierForSubsystem(subsystem);
        return llm_routing.resolveModelsSpec(allocator, roster, self.llm_quality, tier);
    }

    pub fn completeText(self: *DirectRandomProviderClient, allocator: std.mem.Allocator, request: TextRequest) ![]const u8 {
        // Each route attempt and validation failure records separately (see brain_context_stats).
        const models_spec = try self.resolvedModelsSpec(allocator, request.subsystem, request.effort_tier);
        defer allocator.free(models_spec);
        const tier = request.effort_tier orelse llm_routing.defaultEffortTierForSubsystem(request.subsystem);
        const primary = try primaryResolvedModel(allocator, models_spec);
        defer allocator.free(primary.model);
        var routed = request;
        routed.reasoning_effort = llm_routing.clampReasoningEffort(self.llm_quality, request.reasoning_effort);
        const request_bytes = request.system_prompt.len + request.user_prompt.len;
        const reasoning_effort = routed.reasoning_effort;
        if (self.usesHostManagedRouting()) {
            const content = callHostLLMComplete(allocator, self.http, models_spec, routed) catch |err| {
                self.recordLlmCompletion(.{
                    .subsystem = request.subsystem,
                    .provider = primary.provider,
                    .model = primary.model,
                    .effort_tier = @tagName(tier),
                    .reasoning_effort = if (reasoning_effort) |effort| @tagName(effort) else null,
                    .request_bytes = request_bytes,
                    .response_bytes = 0,
                    .outcome = .provider_error,
                });
                return err;
            };
            if (request.response_validator) |validate| {
                validate(allocator, content) catch |err| {
                    if (request.bad_response_logger) |logBadResponse| logBadResponse(request.subsystem, "host", "host_llm_complete", err, content);
                    self.recordLlmCompletion(.{
                        .subsystem = request.subsystem,
                        .provider = primary.provider,
                        .model = primary.model,
                        .effort_tier = @tagName(tier),
                        .reasoning_effort = if (reasoning_effort) |effort| @tagName(effort) else null,
                        .request_bytes = request_bytes,
                        .response_bytes = content.len,
                        .outcome = .validation_error,
                    });
                    allocator.free(content);
                    return err;
                };
            }
            self.recordLlmCompletion(.{
                .subsystem = request.subsystem,
                .provider = primary.provider,
                .model = primary.model,
                .effort_tier = @tagName(tier),
                .reasoning_effort = if (reasoning_effort) |effort| @tagName(effort) else null,
                .request_bytes = request_bytes,
                .response_bytes = content.len,
                .outcome = .success,
            });
            return content;
        }

        const available = try self.availableModels(allocator, models_spec);
        const start = self.rng.random().intRangeLessThan(usize, 0, available.len);
        var failures = std.ArrayList(RouteFailure).empty;
        for (0..available.len) |offset| {
            const selected = available[(start + offset) % available.len];
            const content = self.completeTextWithModel(allocator, selected, routed) catch |err| {
                try failures.append(allocator, .{ .provider = selected.provider, .model = selected.model, .err = err });
                continue;
            };
            if (request.response_validator) |validate| {
                validate(allocator, content) catch |err| {
                    if (request.bad_response_logger) |logBadResponse| logBadResponse(request.subsystem, providerName(selected.provider), selected.model, err, content);
                    self.recordLlmCompletion(.{
                        .subsystem = request.subsystem,
                        .provider = providerName(selected.provider),
                        .model = selected.model,
                        .effort_tier = @tagName(tier),
                        .reasoning_effort = if (reasoning_effort) |effort| @tagName(effort) else null,
                        .request_bytes = request_bytes,
                        .response_bytes = content.len,
                        .outcome = .validation_error,
                    });
                    allocator.free(content);
                    try failures.append(allocator, .{ .provider = selected.provider, .model = selected.model, .err = err });
                    continue;
                };
            }
            self.recordLlmCompletion(.{
                .subsystem = request.subsystem,
                .provider = providerName(selected.provider),
                .model = selected.model,
                .effort_tier = @tagName(tier),
                .reasoning_effort = if (reasoning_effort) |effort| @tagName(effort) else null,
                .request_bytes = request_bytes,
                .response_bytes = content.len,
                .outcome = .success,
            });
            return content;
        }
        logRouteFailures(request.subsystem, failures.items);
        if (failures.items.len > 0) {
            const last = failures.items[failures.items.len - 1];
            self.recordLlmCompletion(.{
                .subsystem = request.subsystem,
                .provider = providerName(last.provider),
                .model = last.model,
                .effort_tier = @tagName(tier),
                .reasoning_effort = if (reasoning_effort) |effort| @tagName(effort) else null,
                .request_bytes = request_bytes,
                .response_bytes = 0,
                .outcome = .provider_error,
            });
            return last.err;
        }
        return error.RemoteServiceFailed;
    }

    pub fn completeVision(self: *DirectRandomProviderClient, allocator: std.mem.Allocator, request: VisionRequest) ![]const u8 {
        if (request.image_paths.len == 0) return error.NoImagesProvided;
        const models_spec = try self.resolvedModelsSpec(allocator, request.subsystem, request.effort_tier);
        defer allocator.free(models_spec);
        const tier = request.effort_tier orelse llm_routing.defaultEffortTierForSubsystem(request.subsystem);
        const primary = try primaryResolvedModel(allocator, models_spec);
        defer allocator.free(primary.model);
        var request_bytes: usize = request.prompt.len;
        for (request.image_paths) |path| request_bytes += path.len;
        if (self.usesHostManagedRouting()) {
            const content = callHostVisionComplete(allocator, self.http, models_spec, request) catch |err| {
                self.recordLlmCompletion(.{
                    .subsystem = request.subsystem,
                    .provider = primary.provider,
                    .model = primary.model,
                    .effort_tier = @tagName(tier),
                    .reasoning_effort = null,
                    .request_bytes = request_bytes,
                    .response_bytes = 0,
                    .outcome = .provider_error,
                });
                return err;
            };
            self.recordLlmCompletion(.{
                .subsystem = request.subsystem,
                .provider = primary.provider,
                .model = primary.model,
                .effort_tier = @tagName(tier),
                .reasoning_effort = null,
                .request_bytes = request_bytes,
                .response_bytes = content.len,
                .outcome = .success,
            });
            return content;
        }
        const selected = try self.selectAvailable(allocator, models_spec);
        const content = switch (selected.provider) {
            .openai => callOpenAIVision(allocator, self.io, self.http, self.openai_api_key.?, selected.model, request),
            .anthropic => callAnthropicVision(allocator, self.io, self.http, self.anthropic_api_key.?, selected.model, request),
            .google => callGoogleVision(allocator, self.io, self.http, self.google_api_key.?, selected.model, request),
            .deepseek => callDeepSeekVision(allocator, self.io, self.http, self.deepseek_api_key.?, selected.model, request),
        } catch |err| {
            self.recordLlmCompletion(.{
                .subsystem = request.subsystem,
                .provider = providerName(selected.provider),
                .model = selected.model,
                .effort_tier = @tagName(tier),
                .reasoning_effort = null,
                .request_bytes = request_bytes,
                .response_bytes = 0,
                .outcome = .provider_error,
            });
            return err;
        };
        self.recordLlmCompletion(.{
            .subsystem = request.subsystem,
            .provider = providerName(selected.provider),
            .model = selected.model,
            .effort_tier = @tagName(tier),
            .reasoning_effort = null,
            .request_bytes = request_bytes,
            .response_bytes = content.len,
            .outcome = .success,
        });
        return content;
    }

    fn recordLlmCompletion(self: *DirectRandomProviderClient, record: brain_context_stats.LlmCompletionRecord) void {
        if (self.stats_recorder) |recorder| recorder.record(record);
    }

    fn selectAvailable(self: *DirectRandomProviderClient, allocator: std.mem.Allocator, models_spec: []const u8) !ProviderModel {
        const available = try self.availableModels(allocator, models_spec);
        return available[self.rng.random().intRangeLessThan(usize, 0, available.len)];
    }

    pub fn availableModels(self: *DirectRandomProviderClient, allocator: std.mem.Allocator, models_spec: []const u8) ![]ProviderModel {
        const models = try parseProviderModels(allocator, models_spec);
        if (self.host_provider_routing) return models;
        var available = std.ArrayList(ProviderModel).empty;
        for (models) |model| {
            if (self.apiKeyFor(model.provider) != null) try available.append(allocator, model);
        }
        if (available.items.len == 0) return error.MissingRandomProviderApiKey;
        return try available.toOwnedSlice(allocator);
    }

    fn completeTextWithModel(self: *DirectRandomProviderClient, allocator: std.mem.Allocator, selected: ProviderModel, request: TextRequest) ![]const u8 {
        return switch (selected.provider) {
            .openai => try callOpenAIText(allocator, self.http, self.openai_api_key.?, selected.model, request),
            .anthropic => try callAnthropicText(allocator, self.http, self.anthropic_api_key.?, selected.model, request),
            .google => try callGoogleText(allocator, self.http, self.google_api_key.?, selected.model, request),
            .deepseek => try callDeepSeekText(allocator, self.http, self.deepseek_api_key.?, selected.model, request),
        };
    }

    fn apiKeyFor(self: *DirectRandomProviderClient, provider: Provider) ?[]const u8 {
        return switch (provider) {
            .openai => self.openai_api_key,
            .anthropic => self.anthropic_api_key,
            .google => self.google_api_key,
            .deepseek => self.deepseek_api_key,
        };
    }

    fn usesHostManagedRouting(self: *DirectRandomProviderClient) bool {
        if (self.host_provider_routing) return true;
        for ([_]?[]const u8{ self.openai_api_key, self.anthropic_api_key, self.google_api_key, self.deepseek_api_key }) |maybe_key| {
            if (maybe_key) |key| {
                if (std.mem.startsWith(u8, key, "host-managed:")) return true;
            }
        }
        return false;
    }

    pub fn checkTextRoutes(self: *DirectRandomProviderClient, allocator: std.mem.Allocator, label: []const u8, models_spec: []const u8) !usize {
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

    fn checkTextRoute(self: *DirectRandomProviderClient, allocator: std.mem.Allocator, model: ProviderModel) ![]const u8 {
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
            .deepseek => try callDeepSeekText(allocator, self.http, self.deepseek_api_key orelse return error.MissingDeepSeekAPIKey, model.model, request),
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
    if (std.ascii.eqlIgnoreCase(text, "deepseek")) return .deepseek;
    return null;
}

fn providerName(provider: Provider) []const u8 {
    return switch (provider) {
        .openai => "openai",
        .anthropic => "anthropic",
        .google => "google",
        .deepseek => "deepseek",
    };
}

fn primaryResolvedModel(allocator: std.mem.Allocator, models_spec: []const u8) !struct { provider: []const u8, model: []const u8 } {
    const models = try parseProviderModels(allocator, models_spec);
    defer allocator.free(models);
    if (models.len == 0) return error.NoRandomProviderModels;
    return .{
        .provider = providerName(models[0].provider),
        .model = try allocator.dupe(u8, models[0].model),
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

pub fn routeName(allocator: std.mem.Allocator, provider: Provider, model: []const u8) ![]const u8 {
    return switch (provider) {
        .openai => "https://api.openai.com/v1/chat/completions",
        .anthropic => "https://api.anthropic.com/v1/messages",
        .google => try std.fmt.allocPrint(allocator, "https://generativelanguage.googleapis.com/v1beta/models/{s}:generateContent", .{model}),
        .deepseek => "https://api.deepseek.com/v1/chat/completions",
    };
}

fn callOpenAIText(allocator: std.mem.Allocator, http: http_transport.Client, api_key: []const u8, model: []const u8, request: TextRequest) ![]const u8 {
    return callOpenAICompatText(allocator, http, "https://api.openai.com/v1/chat/completions", "openai", api_key, model, request);
}

fn callDeepSeekText(allocator: std.mem.Allocator, http: http_transport.Client, api_key: []const u8, model: []const u8, request: TextRequest) ![]const u8 {
    return callOpenAICompatText(allocator, http, "https://api.deepseek.com/v1/chat/completions", "deepseek", api_key, model, request);
}

fn callOpenAICompatText(allocator: std.mem.Allocator, http: http_transport.Client, url: []const u8, provider: []const u8, api_key: []const u8, model: []const u8, request: TextRequest) ![]const u8 {
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
    return callChatCompletionsWithRetry(allocator, http, request.subsystem, provider, model, url, auth, body);
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

fn callOpenAIVision(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, api_key: []const u8, model: []const u8, request: VisionRequest) ![]const u8 {
    return callOpenAICompatVision(allocator, io, http, "https://api.openai.com/v1/chat/completions", "openai", api_key, model, request);
}

fn callDeepSeekVision(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, api_key: []const u8, model: []const u8, request: VisionRequest) ![]const u8 {
    return callOpenAICompatVision(allocator, io, http, "https://api.deepseek.com/v1/chat/completions", "deepseek", api_key, model, request);
}

fn callOpenAICompatVision(allocator: std.mem.Allocator, io: std.Io, http: http_transport.Client, url: []const u8, provider: []const u8, api_key: []const u8, model: []const u8, request: VisionRequest) ![]const u8 {
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
    return callChatCompletionsWithRetry(allocator, http, request.subsystem, provider, model, url, auth, body);
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

fn callChatCompletionsWithRetry(allocator: std.mem.Allocator, http: http_transport.Client, subsystem: []const u8, provider: []const u8, model: []const u8, url: []const u8, auth: []const u8, body: []const u8) ![]const u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const transport_allocator = std.heap.page_allocator;
        const out = try postJson(transport_allocator, http, url, &.{
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
    const logged_url = redactedUrl(url);
    http_log.logStart(logged_url, body.len, max_response_bytes);
    const bytes = http.postJson(allocator, .{
        .url = url,
        .headers = extra_headers,
        .body = body,
        .max_response_bytes = max_response_bytes,
    }) catch |err| {
        http_log.logError(logged_url, err);
        return err;
    };
    errdefer allocator.free(bytes);
    if (bytes.len > max_response_bytes) {
        http_log.logResponseTooLarge(logged_url, bytes.len, max_response_bytes);
        return error.StreamTooLong;
    }
    http_log.logDone(logged_url, bytes.len);
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

pub fn extractAnthropicContent(allocator: std.mem.Allocator, body: []const u8, response_format: ResponseFormat) ![]const u8 {
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

pub fn anthropicJsonToolConfig(allocator: std.mem.Allocator, json_schema: []const u8) ![]const u8 {
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

pub fn maxTokens(size: ResponseSize) u32 {
    return switch (size) {
        .small => 240,
        .medium => 800,
        .large => 1600,
    };
}

pub fn openAIJsonResponseFormat(allocator: std.mem.Allocator, name: []const u8, json_schema: []const u8) ![]const u8 {
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

pub fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, text, .{});
}
