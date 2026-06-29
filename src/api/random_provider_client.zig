const std = @import("std");
const chat = @import("chat_client.zig");
const http_transport = @import("http_transport.zig");
const http_log = @import("http_log.zig");
const llm_routing = @import("../core/llm_routing.zig");
const brain_context_stats = @import("../core/brain_context_stats.zig");
pub const Provider = llm_routing.Provider;
pub const EffortTier = llm_routing.EffortTier;
pub const LlmQuality = llm_routing.LlmQuality;
pub const LlmBatchUnavailable = http_transport.LlmBatchUnavailable;

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
    effort_tier: ?EffortTier = null,
    reasoning_effort: ?chat.ReasoningEffort = null,
    json_schema: []const u8 = default_json_schema,
    response_validator: ?*const fn (std.mem.Allocator, []const u8) anyerror!void = null,
    bad_response_logger: ?*const fn ([]const u8, []const u8, []const u8, anyerror, []const u8) void = null,
};

pub const TextBatchItem = struct {
    request: TextRequest,
    /// Filled by completeTextBatch on success; caller frees via freeHttpResponse.
    content: ?[]const u8 = null,
    /// Wall time for this item's HTTP attempt (filled by batch coordinator).
    latency_ms: u64 = 0,
};

pub const VisionRequest = struct {
    subsystem: []const u8,
    prompt: []const u8,
    image_paths: []const []const u8,
    temperature: f32 = 0.2,
    response_format: ResponseFormat = .text,
    response_size: ResponseSize = .medium,
    effort_tier: ?EffortTier = null,
    json_schema: []const u8 = default_json_schema,
};

const default_json_schema = "{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{},\"required\":[]}";

pub const ProviderModel = struct {
    provider: Provider,
    model: []const u8,
};

pub const max_response_bytes: usize = 1024 * 1024;

pub const PreparedTextRequest = struct {
    routed: TextRequest,
    models_spec: []const u8,
    primary_provider: []const u8,
    primary_model: []const u8,
    tier_name: []const u8,
    reasoning_effort_name: ?[]const u8,
    request_bytes: usize,

    pub fn deinit(self: PreparedTextRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.models_spec);
        allocator.free(self.primary_model);
    }
};

pub const LlmStatsRecorder = struct {
    ctx: *anyopaque,
    record_fn: *const fn (ctx: *anyopaque, record: brain_context_stats.LlmCompletionRecord) void,

    pub fn record(self: LlmStatsRecorder, completion: brain_context_stats.LlmCompletionRecord) void {
        self.record_fn(self.ctx, completion);
    }
};

pub const RandomProviderClient = struct {
    io: std.Io,
    http: http_transport.Client,
    roster: llm_routing.LlmRoster,
    llm_quality: LlmQuality,
    models_spec: []const u8,
    stats_recorder: ?LlmStatsRecorder = null,
    /// When set, HTTP response bodies from `completeText` / `completeVision` are allocated here.
    /// Free with `freeHttpResponse`, not the caller's persistent allocator.
    http_response_allocator: ?std.mem.Allocator = null,

    pub fn init(io: std.Io, http: http_transport.Client, models_spec: []const u8) RandomProviderClient {
        return initConfigured(io, http, .{ .entries = &.{} }, .auto, models_spec);
    }

    pub fn initWithRoster(io: std.Io, http: http_transport.Client, roster: llm_routing.LlmRoster, quality: LlmQuality) RandomProviderClient {
        return initConfigured(io, http, roster, quality, "");
    }

    fn initConfigured(io: std.Io, http: http_transport.Client, roster: llm_routing.LlmRoster, quality: LlmQuality, models_spec: []const u8) RandomProviderClient {
        return .{
            .io = io,
            .http = http,
            .roster = roster,
            .llm_quality = quality,
            .models_spec = models_spec,
        };
    }

    pub fn initHostManaged(io: std.Io, http: http_transport.Client, roster: llm_routing.LlmRoster, quality: LlmQuality) RandomProviderClient {
        return initWithRoster(io, http, roster, quality, "");
    }

    fn responseAllocator(self: *RandomProviderClient, allocator: std.mem.Allocator) std.mem.Allocator {
        return self.http_response_allocator orelse allocator;
    }

    pub fn freeHttpResponse(self: *RandomProviderClient, allocator: std.mem.Allocator, content: []const u8) void {
        self.responseAllocator(allocator).free(content);
    }

    fn effectiveRoster(self: *RandomProviderClient, allocator: std.mem.Allocator) !llm_routing.LlmRoster {
        if (self.roster.entries.len > 0) return self.roster;
        return llm_routing.parseRosterFromModelsSpec(allocator, self.models_spec);
    }

    fn resolvedModelsSpec(self: *RandomProviderClient, allocator: std.mem.Allocator, subsystem: []const u8, effort_tier: ?EffortTier) ![]const u8 {
        const roster = try self.effectiveRoster(allocator);
        const tier = effort_tier orelse llm_routing.defaultEffortTierForSubsystem(subsystem);
        return llm_routing.resolveModelsSpec(allocator, roster, self.llm_quality, tier);
    }

    /// Records one stats entry per HTTP attempt (see brain_context_stats module doc).
    pub fn completeText(self: *RandomProviderClient, allocator: std.mem.Allocator, request: TextRequest) ![]const u8 {
        return self.completeTextOnce(allocator, request);
    }

    pub fn completeTextBatch(self: *RandomProviderClient, allocator: std.mem.Allocator, items: []TextBatchItem) !void {
        if (items.len == 0) return;
        if (items.len == 1) {
            items[0].content = try self.completeTextOnce(allocator, items[0].request);
            return;
        }
        try @import("llm_batch_executor.zig").executeTextBatch(self, allocator, items);
    }

    pub fn completeTextOnce(self: *RandomProviderClient, allocator: std.mem.Allocator, request: TextRequest) ![]const u8 {
        const started_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        const response_alloc = self.responseAllocator(allocator);
        const prepared = try prepareTextRequest(self, allocator, request);
        defer prepared.deinit(allocator);

        const content = callHostLLMComplete(response_alloc, self.http, prepared.models_spec, prepared.routed) catch |err| {
            const latency_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.io).toMilliseconds() - started_ms, 0));
            self.recordLlmCompletion(.{
                .subsystem = request.subsystem,
                .provider = prepared.primary_provider,
                .model = prepared.primary_model,
                .effort_tier = prepared.tier_name,
                .reasoning_effort = prepared.reasoning_effort_name,
                .request_bytes = prepared.request_bytes,
                .response_bytes = 0,
                .outcome = .provider_error,
                .latency_ms = latency_ms,
            });
            return err;
        };
        const success_latency_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.io).toMilliseconds() - started_ms, 0));
        if (request.response_validator) |validate| {
            validate(allocator, content) catch |err| {
                if (request.bad_response_logger) |logBadResponse| logBadResponse(request.subsystem, "host", "host_llm_complete", err, content);
                self.recordLlmCompletion(.{
                    .subsystem = request.subsystem,
                    .provider = prepared.primary_provider,
                    .model = prepared.primary_model,
                    .effort_tier = prepared.tier_name,
                    .reasoning_effort = prepared.reasoning_effort_name,
                    .request_bytes = prepared.request_bytes,
                    .response_bytes = content.len,
                    .outcome = .validation_error,
                    .latency_ms = success_latency_ms,
                });
                response_alloc.free(content);
                return err;
            };
        }
        self.recordLlmCompletion(.{
            .subsystem = request.subsystem,
            .provider = prepared.primary_provider,
            .model = prepared.primary_model,
            .effort_tier = prepared.tier_name,
            .reasoning_effort = prepared.reasoning_effort_name,
            .request_bytes = prepared.request_bytes,
            .response_bytes = content.len,
            .outcome = .success,
            .latency_ms = success_latency_ms,
        });
        return content;
    }

    pub fn recordLlmCompletionPublic(self: *RandomProviderClient, record: brain_context_stats.LlmCompletionRecord) void {
        self.recordLlmCompletion(record);
    }

    pub fn completeVision(self: *RandomProviderClient, allocator: std.mem.Allocator, request: VisionRequest) ![]const u8 {
        if (request.image_paths.len == 0) return error.NoImagesProvided;
        const started_ms = std.Io.Clock.real.now(self.io).toMilliseconds();
        const response_alloc = self.responseAllocator(allocator);
        const models_spec = try self.resolvedModelsSpec(allocator, request.subsystem, request.effort_tier);
        defer allocator.free(models_spec);
        const tier = request.effort_tier orelse llm_routing.defaultEffortTierForSubsystem(request.subsystem);
        const primary = try primaryResolvedModel(allocator, models_spec);
        defer allocator.free(primary.model);
        var request_bytes: usize = request.prompt.len;
        for (request.image_paths) |path| request_bytes += path.len;
        const content = callHostVisionComplete(response_alloc, self.http, models_spec, request) catch |err| {
            const latency_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.io).toMilliseconds() - started_ms, 0));
            self.recordLlmCompletion(.{
                .subsystem = request.subsystem,
                .provider = primary.provider,
                .model = primary.model,
                .effort_tier = @tagName(tier),
                .reasoning_effort = null,
                .request_bytes = request_bytes,
                .response_bytes = 0,
                .outcome = .provider_error,
                .latency_ms = latency_ms,
            });
            return err;
        };
        const latency_ms: u64 = @intCast(@max(std.Io.Clock.real.now(self.io).toMilliseconds() - started_ms, 0));
        self.recordLlmCompletion(.{
            .subsystem = request.subsystem,
            .provider = primary.provider,
            .model = primary.model,
            .effort_tier = @tagName(tier),
            .reasoning_effort = null,
            .request_bytes = request_bytes,
            .response_bytes = content.len,
            .outcome = .success,
            .latency_ms = latency_ms,
        });
        return content;
    }

    fn recordLlmCompletion(self: *RandomProviderClient, record: brain_context_stats.LlmCompletionRecord) void {
        if (self.stats_recorder) |recorder| recorder.record(record);
    }
};

pub fn prepareTextRequest(client: *RandomProviderClient, allocator: std.mem.Allocator, request: TextRequest) !PreparedTextRequest {
    const models_spec = try client.resolvedModelsSpec(allocator, request.subsystem, request.effort_tier);
    const tier = request.effort_tier orelse llm_routing.defaultEffortTierForSubsystem(request.subsystem);
    const primary = try primaryResolvedModel(allocator, models_spec);
    const reasoning_effort = llm_routing.clampReasoningEffort(client.llm_quality, request.reasoning_effort);
    var routed = request;
    routed.reasoning_effort = reasoning_effort;
    return .{
        .routed = routed,
        .models_spec = models_spec,
        .primary_provider = primary.provider,
        .primary_model = primary.model,
        .tier_name = @tagName(tier),
        .reasoning_effort_name = if (reasoning_effort) |effort| @tagName(effort) else null,
        .request_bytes = request.system_prompt.len + request.user_prompt.len,
    };
}

/// HTTP + validation only; stats are recorded by the batch coordinator on the main thread.
pub fn completeTextOnceForBatch(client: *RandomProviderClient, allocator: std.mem.Allocator, request: TextRequest) ![]const u8 {
    const prepared = try prepareTextRequest(client, allocator, request);
    defer prepared.deinit(allocator);
    const content = try callHostLLMComplete(allocator, client.http, prepared.models_spec, prepared.routed);
    if (request.response_validator) |validate| {
        validate(allocator, content) catch |err| {
            if (request.bad_response_logger) |logBadResponse| logBadResponse(request.subsystem, "host", "host_llm_complete", err, content);
            allocator.free(content);
            return err;
        };
    }
    return content;
}

pub fn buildHostLLMCompleteBody(allocator: std.mem.Allocator, models_spec: []const u8, request: TextRequest) ![]const u8 {
    const models_json = try providerModelsJson(allocator, models_spec);
    defer allocator.free(models_json);
    const reasoning_effort_json = if (request.reasoning_effort) |effort|
        try jsonString(allocator, @tagName(effort))
    else
        "null";
    defer if (request.reasoning_effort != null) allocator.free(reasoning_effort_json);
    return std.fmt.allocPrint(
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
}

pub fn parseProviderModels(allocator: std.mem.Allocator, spec: []const u8) ![]ProviderModel {
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, spec);
    defer roster.deinit(allocator);
    var out = try allocator.alloc(ProviderModel, roster.entries.len);
    errdefer allocator.free(out);
    for (roster.entries, 0..) |entry, i| {
        out[i] = .{
            .provider = entry.provider,
            .model = try allocator.dupe(u8, entry.model),
        };
    }
    return out;
}

fn providerName(provider: Provider) []const u8 {
    return llm_routing.providerName(provider);
}

fn primaryResolvedModel(allocator: std.mem.Allocator, models_spec: []const u8) !struct { provider: []const u8, model: []const u8 } {
    const models = try parseProviderModels(allocator, models_spec);
    defer {
        for (models) |model| allocator.free(model.model);
        allocator.free(models);
    }
    if (models.len == 0) return error.NoRandomProviderModels;
    return .{
        .provider = providerName(models[0].provider),
        .model = try allocator.dupe(u8, models[0].model),
    };
}

fn callHostLLMComplete(allocator: std.mem.Allocator, http: http_transport.Client, models_spec: []const u8, request: TextRequest) ![]const u8 {
    const body = try buildHostLLMCompleteBody(allocator, models_spec, request);
    defer allocator.free(body);
    return postJson(allocator, http, "affective-host://llm/complete", &.{}, body);
}

fn callHostVisionComplete(allocator: std.mem.Allocator, http: http_transport.Client, models_spec: []const u8, request: VisionRequest) ![]const u8 {
    const models_json = try providerModelsJson(allocator, models_spec);
    defer allocator.free(models_json);
    var image_paths = std.ArrayList(u8).empty;
    defer image_paths.deinit(allocator);
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
    defer allocator.free(body);
    return postJson(allocator, http, "affective-host://vision/complete", &.{}, body);
}

fn providerModelsJson(allocator: std.mem.Allocator, models_spec: []const u8) ![]const u8 {
    const models = try parseProviderModels(allocator, models_spec);
    defer {
        for (models) |model| allocator.free(model.model);
        allocator.free(models);
    }
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
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
    http_log.logStart(url, body.len, max_response_bytes);
    const bytes = http.postJson(allocator, .{
        .url = url,
        .headers = extra_headers,
        .body = body,
        .max_response_bytes = max_response_bytes,
    }) catch |err| {
        http_log.logError(url, err);
        return err;
    };
    errdefer allocator.free(bytes);
    if (bytes.len > max_response_bytes) {
        http_log.logResponseTooLarge(url, bytes.len, max_response_bytes);
        return error.StreamTooLong;
    }
    http_log.logDone(url, bytes.len);
    return bytes;
}

fn maxTokens(size: ResponseSize) u32 {
    return switch (size) {
        .small => 240,
        .medium => 800,
        .large => 1600,
    };
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
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);

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
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "google:gemini-3.1-flash-lite");
    var client = RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);

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

const MockLlmStats = struct {
    count: u64 = 0,
    last_outcome: brain_context_stats.LlmCompletionOutcome = .success,
    last_response_bytes: usize = 0,

    fn recorder(self: *MockLlmStats) LlmStatsRecorder {
        return .{
            .ctx = self,
            .record_fn = MockLlmStats.record,
        };
    }

    fn record(ctx: *anyopaque, completion: brain_context_stats.LlmCompletionRecord) void {
        const self: *MockLlmStats = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.last_outcome = completion.outcome;
        self.last_response_bytes = completion.response_bytes;
    }
};

test "completeText records success and error outcomes via stats recorder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();

    const FailingHttpTransport = struct {
        fn client(_: *@This()) http_transport.Client {
            return .{ .ctx = @as(*anyopaque, @ptrFromInt(1)), .postJsonFn = failingPostJson };
        }

        fn failingPostJson(_: *anyopaque, _: std.mem.Allocator, _: http_transport.JsonPostRequest) ![]u8 {
            return error.ConnectionRefused;
        }
    };
    var failing_transport = FailingHttpTransport{};
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = RandomProviderClient.initWithRoster(io_threaded.io(), failing_transport.client(), roster, .auto);
    var stats = MockLlmStats{};
    client.stats_recorder = stats.recorder();

    const err_result = client.completeText(allocator, .{
        .subsystem = "conversation",
        .system_prompt = "system",
        .user_prompt = "user",
        .response_format = .text,
    });
    try std.testing.expectError(error.ConnectionRefused, err_result);
    try std.testing.expectEqual(@as(u64, 1), stats.count);
    try std.testing.expectEqual(brain_context_stats.LlmCompletionOutcome.provider_error, stats.last_outcome);

    var transport = CapturingHttpTransport{};
    client = RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);
    client.stats_recorder = stats.recorder();
    stats.count = 0;

    const text = try client.completeText(allocator, .{
        .subsystem = "conversation",
        .system_prompt = "system",
        .user_prompt = "user",
        .response_format = .text,
    });
    try std.testing.expectEqualStrings("host completion", text);
    try std.testing.expectEqual(@as(u64, 1), stats.count);
    try std.testing.expectEqual(brain_context_stats.LlmCompletionOutcome.success, stats.last_outcome);
    try std.testing.expectEqual(@as(usize, "host completion".len), stats.last_response_bytes);
}
