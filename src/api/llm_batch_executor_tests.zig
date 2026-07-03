const std = @import("std");
const http_transport = @import("http_transport.zig");
const random_provider = @import("random_provider_client.zig");
const llm_batch_executor = @import("llm_batch_executor.zig");
const llm_routing = @import("../core/llm_routing.zig");
const brain_context_stats = @import("../core/brain_context_stats.zig");

test "completeTextBatch runs concurrent host calls on multi-threaded targets" {
    if (comptime @import("builtin").single_threaded) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const DelayingHttpTransport = struct {
        delay_ns: u64 = 200 * std.time.ns_per_ms,
        active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        max_active: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        call_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn client(self: *@This()) http_transport.Client {
            return .{ .ctx = self, .postJsonFn = postJson };
        }

        fn postJson(ctx: *anyopaque, allocator: std.mem.Allocator, request: http_transport.JsonPostRequest) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = request;
            const active = self.active.fetchAdd(1, .monotonic) + 1;
            defer _ = self.active.fetchSub(1, .monotonic);
            var observed = self.max_active.load(.monotonic);
            while (active > observed) {
                if (self.max_active.cmpxchgWeak(observed, active, .monotonic, .monotonic)) |_| {} else {
                    observed = self.max_active.load(.monotonic);
                }
            }
            _ = self.call_count.fetchAdd(1, .monotonic);
            std.Thread.sleep(self.delay_ns);
            return try std.fmt.allocPrint(allocator, "completion-{d}", .{self.call_count.load(.monotonic)});
        }
    };

    var transport = DelayingHttpTransport{};
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = random_provider.RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);

    var items = [_]random_provider.TextBatchItem{
        .{ .request = .{ .subsystem = "a", .system_prompt = "s", .user_prompt = "u1", .response_format = .text } },
        .{ .request = .{ .subsystem = "b", .system_prompt = "s", .user_prompt = "u2", .response_format = .text } },
        .{ .request = .{ .subsystem = "c", .system_prompt = "s", .user_prompt = "u3", .response_format = .text } },
    };

    const started = std.time.nanoTimestamp();
    try client.completeTextBatch(allocator, &items);
    const elapsed_ms = @divTrunc(std.time.nanoTimestamp() - started, std.time.ns_per_ms);

    try std.testing.expect(items[0].content != null);
    try std.testing.expect(items[1].content != null);
    try std.testing.expect(items[2].content != null);
    try std.testing.expect(transport.max_active.load(.monotonic) >= 2);
    try std.testing.expect(elapsed_ms < 500);
}

test "completeTextBatch fails loudly when one host call fails" {
    if (comptime @import("builtin").single_threaded) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const FlakyHttpTransport = struct {
        calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn client(self: *@This()) http_transport.Client {
            return .{ .ctx = self, .postJsonFn = postJson };
        }

        fn postJson(ctx: *anyopaque, allocator: std.mem.Allocator, _: http_transport.JsonPostRequest) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const call = self.calls.fetchAdd(1, .monotonic) + 1;
            if (call == 2) return error.ConnectionRefused;
            return try allocator.dupe(u8, "ok");
        }
    };

    var transport = FlakyHttpTransport{};
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = random_provider.RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);

    var items = [_]random_provider.TextBatchItem{
        .{ .request = .{ .subsystem = "a", .system_prompt = "s", .user_prompt = "u1", .response_format = .text } },
        .{ .request = .{ .subsystem = "b", .system_prompt = "s", .user_prompt = "u2", .response_format = .text } },
    };

    const result = client.completeTextBatch(allocator, &items);
    try std.testing.expectError(error.ConnectionRefused, result);
    try std.testing.expect(items[0].content == null);
    try std.testing.expect(items[1].content == null);
}

test "completeTextBatch is unavailable on single-threaded targets without batch transport" {
    if (comptime !@import("builtin").single_threaded) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Transport = struct {
        fn client(_: *@This()) http_transport.Client {
            return .{ .ctx = @as(*anyopaque, @ptrFromInt(1)), .postJsonFn = postJson };
        }

        fn postJson(_: *anyopaque, _: std.mem.Allocator, _: http_transport.JsonPostRequest) ![]u8 {
            return error.Unreachable;
        }
    };

    var transport = Transport{};
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = random_provider.RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);

    var items = [_]random_provider.TextBatchItem{
        .{ .request = .{ .subsystem = "a", .system_prompt = "s", .user_prompt = "u1", .response_format = .text } },
        .{ .request = .{ .subsystem = "b", .system_prompt = "s", .user_prompt = "u2", .response_format = .text } },
    };

    try std.testing.expectError(error.LlmBatchUnavailable, client.completeTextBatch(allocator, &items));
}

test "completeTextBatch runs sequentially when dispatch scratch allocator is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const Transport = struct {
        calls: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn client(self: *@This()) http_transport.Client {
            return .{ .ctx = self, .postJsonFn = postJson };
        }

        fn postJson(ctx: *anyopaque, alloc: std.mem.Allocator, _: http_transport.JsonPostRequest) ![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const call = self.calls.fetchAdd(1, .monotonic) + 1;
            return try std.fmt.allocPrint(alloc, "ok-{d}", .{call});
        }
    };

    var transport = Transport{};
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = random_provider.RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);
    client.http_response_allocator = scratch.allocator();

    var items = [_]random_provider.TextBatchItem{
        .{ .request = .{ .subsystem = "a", .system_prompt = "s", .user_prompt = "u1", .response_format = .text } },
        .{ .request = .{ .subsystem = "b", .system_prompt = "s", .user_prompt = "u2", .response_format = .text } },
    };

    try client.completeTextBatch(allocator, &items);
    try std.testing.expectEqualStrings("ok-1", items[0].content.?);
    try std.testing.expectEqualStrings("ok-2", items[1].content.?);
    try std.testing.expectEqual(@as(usize, 2), transport.calls.load(.monotonic));
}

test "freeHttpResponse skips scratch frees so arena reset stays safe" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();

    const Transport = struct {
        fn client(_: *@This()) http_transport.Client {
            return .{ .ctx = @as(*anyopaque, @ptrFromInt(1)), .postJsonFn = postJson };
        }

        fn postJson(_: *anyopaque, alloc: std.mem.Allocator, _: http_transport.JsonPostRequest) ![]u8 {
            return try alloc.dupe(u8, "llm-body");
        }
    };

    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const roster = try llm_routing.parseRosterFromModelsSpec(std.testing.allocator, "openai:gpt-4.1-nano");
    var client = random_provider.RandomProviderClient.initWithRoster(io_threaded.io(), Transport.client(), roster, .auto);
    client.http_response_allocator = scratch.allocator();

    const content = try client.completeTextOnce(std.testing.allocator, .{
        .subsystem = "chat",
        .system_prompt = "s",
        .user_prompt = "u",
        .response_format = .text,
    });
    client.freeHttpResponse(std.testing.allocator, content);
    _ = scratch.reset(.free_all);
}

test "completeTextBatch records stats for each successful item" {
    if (comptime @import("builtin").single_threaded) return;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Transport = struct {
        fn client(_: *@This()) http_transport.Client {
            return .{ .ctx = @as(*anyopaque, @ptrFromInt(1)), .postJsonFn = postJson };
        }

        fn postJson(_: *anyopaque, alloc: std.mem.Allocator, _: http_transport.JsonPostRequest) ![]u8 {
            return try alloc.dupe(u8, "ok");
        }
    };

    const Stats = struct {
        count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn recorder(self: *@This()) random_provider.LlmStatsRecorder {
            return .{ .ctx = self, .record_fn = record };
        }

        fn record(ctx: *anyopaque, _: brain_context_stats.LlmCompletionRecord) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = self.count.fetchAdd(1, .monotonic);
        }
    };

    var transport = Transport{};
    var stats = Stats{};
    var io_threaded: std.Io.Threaded = .init_single_threaded;
    defer io_threaded.deinit();
    const roster = try llm_routing.parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    var client = random_provider.RandomProviderClient.initWithRoster(io_threaded.io(), transport.client(), roster, .auto);
    client.stats_recorder = stats.recorder();

    var items = [_]random_provider.TextBatchItem{
        .{ .request = .{ .subsystem = "a", .system_prompt = "s", .user_prompt = "u1", .response_format = .text } },
        .{ .request = .{ .subsystem = "b", .system_prompt = "s", .user_prompt = "u2", .response_format = .text } },
    };

    try client.completeTextBatch(allocator, &items);
    try std.testing.expectEqual(@as(usize, 2), stats.count.load(.monotonic));
}
