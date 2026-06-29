const std = @import("std");
const http_transport = @import("http_transport.zig");
const random_provider = @import("random_provider_client.zig");
const brain_context_stats = @import("../core/brain_context_stats.zig");

pub const max_concurrent_threads: usize = 8;

pub const host_llm_complete_batch_url = "affective-host://llm/complete_batch";

pub const InvalidBatchTransportResponse = error{InvalidBatchTransportResponse};

pub fn executeTextBatch(
    client: *random_provider.RandomProviderClient,
    allocator: std.mem.Allocator,
    items: []random_provider.TextBatchItem,
) !void {
    if (items.len <= 1) return error.InvalidBatchSize;

    if (client.http_response_allocator != null) {
        try executeSequentiallyOnCallerThread(client, allocator, items);
        return;
    }

    if (client.http.supportsBatch()) {
        try executeViaBatchTransport(client, allocator, items);
        return;
    }

    if (comptime builtin.single_threaded) {
        return error.LlmBatchUnavailable;
    } else {
        try executeViaThreads(client, allocator, items);
    }
}

fn executeSequentiallyOnCallerThread(
    client: *random_provider.RandomProviderClient,
    allocator: std.mem.Allocator,
    items: []random_provider.TextBatchItem,
) !void {
    for (items) |*item| {
        item.content = try client.completeTextOnce(allocator, item.request);
    }
}

fn batchLatencyMs(io: std.Io, started_ms: i64) u64 {
    return @intCast(@max(std.Io.Clock.real.now(io).toMilliseconds() - started_ms, 0));
}

fn executeViaBatchTransport(
    client: *random_provider.RandomProviderClient,
    allocator: std.mem.Allocator,
    items: []random_provider.TextBatchItem,
) !void {
    var bodies = try allocator.alloc([]const u8, items.len);
    defer {
        for (bodies) |body| allocator.free(body);
        allocator.free(bodies);
    }

    for (items, 0..) |*item, index| {
        const prepared = try random_provider.prepareTextRequest(client, allocator, item.request);
        defer prepared.deinit(allocator);
        bodies[index] = try random_provider.buildHostLLMCompleteBody(allocator, prepared.models_spec, prepared.routed);
    }

    const batch_started_ms = std.Io.Clock.real.now(client.io).toMilliseconds();
    const response_body = try client.http.postJsonBatch(allocator, .{
        .url = host_llm_complete_batch_url,
        .bodies = bodies,
        .max_response_bytes = random_provider.max_response_bytes,
    });
    defer allocator.free(response_body);
    const batch_ms = batchLatencyMs(client.io, batch_started_ms);
    const per_item_ms: u64 = if (items.len > 0) @intCast(@divFloor(batch_ms, items.len)) else 0;

    const parsed = try std.json.parseFromSlice(BatchTransportEnvelope, allocator, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.responses.len != items.len) return error.InvalidBatchTransportResponse;

    for (items, parsed.value.responses) |*item, content| {
        const prepared = try random_provider.prepareTextRequest(client, allocator, item.request);
        defer prepared.deinit(allocator);

        if (item.request.response_validator) |validate| {
            validate(allocator, content) catch |err| {
                if (item.request.bad_response_logger) |logBadResponse| logBadResponse(item.request.subsystem, "host", "host_llm_complete_batch", err, content);
                item.latency_ms = per_item_ms;
                client.recordLlmCompletionPublic(.{
                    .subsystem = item.request.subsystem,
                    .provider = prepared.primary_provider,
                    .model = prepared.primary_model,
                    .effort_tier = prepared.tier_name,
                    .reasoning_effort = prepared.reasoning_effort_name,
                    .request_bytes = prepared.request_bytes,
                    .response_bytes = content.len,
                    .outcome = .validation_error,
                    .latency_ms = per_item_ms,
                });
                return err;
            };
        }

        item.content = try allocator.dupe(u8, content);
        item.latency_ms = per_item_ms;
        client.recordLlmCompletionPublic(.{
            .subsystem = item.request.subsystem,
            .provider = prepared.primary_provider,
            .model = prepared.primary_model,
            .effort_tier = prepared.tier_name,
            .reasoning_effort = prepared.reasoning_effort_name,
            .request_bytes = prepared.request_bytes,
            .response_bytes = content.len,
            .outcome = .success,
            .latency_ms = per_item_ms,
        });
    }
}

const BatchTransportEnvelope = struct {
    responses: []const []const u8,
};

const ThreadShared = struct {
    mutex: std.atomic.Mutex = .unlocked,
    first_err: ?anyerror = null,

    fn recordError(self: *ThreadShared, err: anyerror) void {
        while (!self.mutex.tryLock()) {
            std.Thread.yield() catch {};
        }
        defer self.mutex.unlock();
        if (self.first_err == null) self.first_err = err;
    }
};

const ThreadSlot = struct {
    client: *random_provider.RandomProviderClient,
    allocator: std.mem.Allocator,
    request: random_provider.TextRequest,
    item: *random_provider.TextBatchItem,
    shared: *ThreadShared,
    latency_ms: u64 = 0,
};

fn threadWorker(slot: *ThreadSlot) void {
    const started_ms = std.Io.Clock.real.now(slot.client.io).toMilliseconds();
    const content = random_provider.completeTextOnceForBatch(slot.client, slot.allocator, slot.request) catch |err| {
        slot.shared.recordError(err);
        return;
    };
    slot.latency_ms = batchLatencyMs(slot.client.io, started_ms);
    slot.item.latency_ms = slot.latency_ms;
    slot.item.content = content;
}

fn clearBatchContents(allocator: std.mem.Allocator, items: []random_provider.TextBatchItem) void {
    for (items) |*item| {
        if (item.content) |content| {
            allocator.free(content);
            item.content = null;
        }
    }
}

fn recordBatchSuccessStats(
    client: *random_provider.RandomProviderClient,
    allocator: std.mem.Allocator,
    items: []random_provider.TextBatchItem,
) !void {
    for (items) |*item| {
        const content = item.content orelse return error.LlmBatchIncomplete;
        const prepared = try random_provider.prepareTextRequest(client, allocator, item.request);
        defer prepared.deinit(allocator);
        client.recordLlmCompletionPublic(.{
            .subsystem = item.request.subsystem,
            .provider = prepared.primary_provider,
            .model = prepared.primary_model,
            .effort_tier = prepared.tier_name,
            .reasoning_effort = prepared.reasoning_effort_name,
            .request_bytes = prepared.request_bytes,
            .response_bytes = content.len,
            .outcome = .success,
            .latency_ms = item.latency_ms,
        });
    }
}

fn executeViaThreads(
    client: *random_provider.RandomProviderClient,
    allocator: std.mem.Allocator,
    items: []random_provider.TextBatchItem,
) !void {
    var shared = ThreadShared{};
    var index: usize = 0;
    while (index < items.len) {
        if (shared.first_err != null) break;
        const wave = @min(items.len - index, max_concurrent_threads);
        var threads: [max_concurrent_threads]std.Thread = undefined;
        var slots: [max_concurrent_threads]ThreadSlot = undefined;

        for (0..wave) |wave_index| {
            const item_index = index + wave_index;
            slots[wave_index] = .{
                .client = client,
                .allocator = allocator,
                .request = items[item_index].request,
                .item = &items[item_index],
                .shared = &shared,
            };
            threads[wave_index] = try std.Thread.spawn(.{}, threadWorker, .{&slots[wave_index]});
        }

        for (0..wave) |wave_index| threads[wave_index].join();
        if (shared.first_err != null) break;
        index += wave;
    }

    if (shared.first_err) |err| {
        clearBatchContents(allocator, items);
        return err;
    }

    try recordBatchSuccessStats(client, allocator, items);
}

pub const LlmBatchIncomplete = error{LlmBatchIncomplete};

const builtin = @import("builtin");

pub fn buildBatchTransportRequestBody(allocator: std.mem.Allocator, bodies: []const []const u8) ![]u8 {
    var batch_body = std.ArrayList(u8).empty;
    defer batch_body.deinit(allocator);
    try batch_body.append(allocator, '{');
    try batch_body.appendSlice(allocator, "\"requests\":[");
    for (bodies, 0..) |body, body_index| {
        if (body_index > 0) try batch_body.append(allocator, ',');
        try batch_body.appendSlice(allocator, body);
    }
    try batch_body.appendSlice(allocator, "]}");
    return batch_body.toOwnedSlice(allocator);
}

pub fn parseBatchTransportResponse(allocator: std.mem.Allocator, response_body: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice(BatchTransportEnvelope, allocator, response_body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const out = try allocator.alloc([]const u8, parsed.value.responses.len);
    for (parsed.value.responses, 0..) |response, index| {
        out[index] = try allocator.dupe(u8, response);
    }
    return out;
}

test "batch transport request envelope shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body = try buildBatchTransportRequestBody(allocator, &.{ "{\"a\":1}", "{\"b\":2}" });
    try std.testing.expectEqualStrings("{\"requests\":[{\"a\":1},{\"b\":2}]}", body);
}

test "batch transport parses responses array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const BatchTransport = struct {
        responses: []const []const u8,

        fn client(self: *@This()) http_transport.Client {
            return .{
                .ctx = self,
                .postJsonFn = unreachablePostJson,
                .postJsonBatchFn = postJsonBatch,
            };
        }

        fn unreachablePostJson(_: *anyopaque, _: std.mem.Allocator, _: http_transport.JsonPostRequest) ![]u8 {
            unreachable;
        }

        fn postJsonBatch(ctx: *anyopaque, alloc: std.mem.Allocator, request: http_transport.JsonPostBatchRequest) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = request;
            var parts = std.ArrayList(u8).empty;
            defer parts.deinit(alloc);
            try parts.appendSlice(alloc, "{\"responses\":[");
            for (self.responses, 0..) |response, index| {
                if (index > 0) try parts.append(alloc, ',');
                try parts.appendSlice(alloc, try std.json.Stringify.valueAlloc(alloc, response, .{}));
            }
            try parts.append(alloc, ']');
            try parts.append(alloc, '}');
            return parts.toOwnedSlice(alloc);
        }
    };

    var transport = BatchTransport{ .responses = &.{ "{\"ok\":1}", "{\"ok\":2}" } };
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const roster = try @import("../core/llm_routing.zig").parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = random_provider.RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);

    var items = [_]random_provider.TextBatchItem{
        .{ .request = .{ .subsystem = "a", .system_prompt = "s", .user_prompt = "u", .response_format = .text } },
        .{ .request = .{ .subsystem = "b", .system_prompt = "s", .user_prompt = "u", .response_format = .text } },
    };

    try executeTextBatch(&client, allocator, &items);
    try std.testing.expectEqualStrings("{\"ok\":1}", items[0].content.?);
    try std.testing.expectEqualStrings("{\"ok\":2}", items[1].content.?);
}
