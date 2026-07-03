const std = @import("std");
const embedded = @import("../affective_core_embedded.zig");
const embedded_config = @import("../affective_core_embedded_config.zig");
const direct_provider = @import("../harness/direct_provider_client.zig");
const hash_vector = @import("../core/hash_vector.zig");
const embedding_port = @import("../core/port_embedding.zig");
const http_transport = @import("../api/http_transport.zig");
const main_http_transport = @import("../main_http_transport.zig");

const AffectiveCoreEmbeddedString = embedded.AffectiveCoreEmbeddedString;

pub const HostResult = struct {
    response: []const u8,
    error_msg: []const u8,
};

const PendingRequest = struct {
    request_id: []const u8,
    url: []const u8,
    headers_json: []const u8,
    body: []const u8,
    completed: bool = false,
    response: []const u8 = "",
    error_msg: []const u8 = "",

    fn deinit(self: *PendingRequest) void {
        std.heap.page_allocator.free(self.request_id);
        std.heap.page_allocator.free(self.url);
        std.heap.page_allocator.free(self.headers_json);
        std.heap.page_allocator.free(self.body);
        if (self.response.len > 0) std.heap.page_allocator.free(self.response);
        if (self.error_msg.len > 0) std.heap.page_allocator.free(self.error_msg);
    }
};

pub const LiveHost = struct {
    io: std.Io,
    env: *const std.process.Environ.Map,
    models_spec: []const u8,
    http_transport_impl: main_http_transport.StdHttpTransport,
    next_request_id: u64 = 1,
    pending_request: ?PendingRequest = null,
    llm_calls: usize = 0,
    vision_calls: usize = 0,
    deterministic_calls: usize = 0,

    pub fn init(io: std.Io, env: *const std.process.Environ.Map, models_spec: []const u8) LiveHost {
        return .{
            .io = io,
            .env = env,
            .models_spec = models_spec,
            .http_transport_impl = main_http_transport.StdHttpTransport.init(io),
        };
    }

    pub fn hostServices(self: *LiveHost) embedded.AffectiveCoreEmbeddedHostServices {
        return .{
            .ctx = self,
            .http_post_json_begin = httpPostJsonBegin,
            .http_post_json_poll = httpPostJsonPoll,
            .free_string = freeHostString,
            .on_host_events = null,
        };
    }

    pub fn deinit(self: *LiveHost) void {
        if (self.pending_request) |*pending| {
            pending.deinit();
            self.pending_request = null;
        }
    }

    fn httpPostJsonBegin(
        ctx: ?*anyopaque,
        url: AffectiveCoreEmbeddedString,
        headers_json: AffectiveCoreEmbeddedString,
        body: AffectiveCoreEmbeddedString,
        out_request_id: ?*AffectiveCoreEmbeddedString,
        out_error: ?*AffectiveCoreEmbeddedString,
    ) callconv(.c) c_int {
        const self: *LiveHost = @ptrCast(@alignCast(ctx orelse {
            return hostFailure(out_error, out_request_id, "missing live host context");
        }));
        const url_slice = embedded_config.stringSlice(url) orelse "";
        const headers_slice = embedded_config.stringSlice(headers_json) orelse "";
        const body_slice = embedded_config.stringSlice(body) orelse "";

        if (self.pending_request != null) {
            return hostFailure(out_error, out_request_id, "live host already has a pending HTTP request");
        }

        const request_id = std.fmt.allocPrint(std.heap.page_allocator, "live-req-{d}", .{self.next_request_id}) catch {
            return hostFailure(out_error, out_request_id, "could not allocate live request id");
        };
        self.next_request_id += 1;

        self.pending_request = .{
            .request_id = request_id,
            .url = std.heap.page_allocator.dupe(u8, url_slice) catch return hostFailure(out_error, out_request_id, "could not store live request url"),
            .headers_json = std.heap.page_allocator.dupe(u8, headers_slice) catch return hostFailure(out_error, out_request_id, "could not store live request headers"),
            .body = std.heap.page_allocator.dupe(u8, body_slice) catch return hostFailure(out_error, out_request_id, "could not store live request body"),
        };

        if (out_error) |err_out| err_out.* = .{};
        if (out_request_id) |id_out| {
            const owned = std.heap.page_allocator.dupe(u8, request_id) catch {
                id_out.* = .{};
                return 1;
            };
            id_out.* = .{ .ptr = owned.ptr, .len = owned.len };
        }
        return 0;
    }

    fn httpPostJsonPoll(
        ctx: ?*anyopaque,
        request_id: AffectiveCoreEmbeddedString,
        out_data: ?*AffectiveCoreEmbeddedString,
        out_error: ?*AffectiveCoreEmbeddedString,
    ) callconv(.c) c_int {
        const self: *LiveHost = @ptrCast(@alignCast(ctx orelse {
            return hostFailure(out_error, out_data, "missing live host context");
        }));
        const request_id_slice = embedded_config.stringSlice(request_id) orelse {
            return hostFailure(out_error, out_data, "missing live request id");
        };
        const pending = self.pending_request orelse {
            return hostFailure(out_error, out_data, "unknown live request id");
        };
        if (!std.mem.eql(u8, pending.request_id, request_id_slice)) {
            return hostFailure(out_error, out_data, "unknown live request id");
        }

        var entry = self.pending_request.?;
        if (!entry.completed) {
            const result = self.completePendingRequest(&entry);
            entry.completed = true;
            entry.response = std.heap.page_allocator.dupe(u8, result.response) catch "";
            if (result.error_msg.len > 0) {
                entry.error_msg = std.heap.page_allocator.dupe(u8, result.error_msg) catch "";
            }
            self.pending_request = entry;
        }

        const active = self.pending_request.?;
        defer {
            var finished = self.pending_request.?;
            finished.deinit();
            self.pending_request = null;
        }
        if (active.error_msg.len > 0) {
            return hostFailure(out_error, out_data, active.error_msg);
        }
        return hostSuccess(out_data, out_error, active.response);
    }

    pub fn completeRequest(self: *LiveHost, url: []const u8, body: []const u8) HostResult {
        var pending = PendingRequest{
            .request_id = "tcp-host-request",
            .url = @constCast(url),
            .headers_json = "{}",
            .body = @constCast(body),
        };
        return self.completePendingRequest(&pending);
    }

    fn completePendingRequest(self: *LiveHost, pending: *PendingRequest) HostResult {
        if (std.mem.endsWith(u8, pending.url, "/llm/complete")) {
            self.llm_calls += 1;
            return self.completeText(pending.body);
        }
        if (std.mem.endsWith(u8, pending.url, "/vision/complete")) {
            self.vision_calls += 1;
            return self.completeVision(pending.body);
        }
        self.deterministic_calls += 1;
        if (std.mem.endsWith(u8, pending.url, "/embed/compute")) {
            return .{ .response = embedResponse(pending.body), .error_msg = "" };
        }
        if (std.mem.eql(u8, pending.url, "affective-host://system/power")) {
            return .{ .response = "{\"supplies\":[]}", .error_msg = "" };
        }
        if (std.mem.eql(u8, pending.url, "affective-host://system/storage")) {
            return .{ .response = "{\"volumes\":[]}", .error_msg = "" };
        }
        if (std.mem.endsWith(u8, pending.url, "/recognize/identify")) {
            return .{ .response = "{\"person_present\":false,\"match_status\":\"none\",\"confidence\":0.0,\"people_count\":0}", .error_msg = "" };
        }
        if (std.mem.endsWith(u8, pending.url, "/recognize/enroll")) {
            return .{ .response = "{\"person_id\":\"person_e2e\",\"display_name\":\"Fixture Person\",\"representative_image_path\":\"/tmp/brain-quality-e2e.jpg\",\"embedding_path\":\"/tmp/brain-quality-e2e.embedding\",\"quality_score\":0.82,\"removed_embeddings\":0,\"kept_existing\":false}", .error_msg = "" };
        }
        return .{
            .response = "",
            .error_msg = std.fmt.allocPrint(std.heap.page_allocator, "unsupported live host route: {s}", .{pending.url}) catch "unsupported live host route",
        };
    }

    fn completeText(self: *LiveHost, body: []const u8) HostResult {
        const Wire = struct {
            subsystem: []const u8 = "conversation",
            system_prompt: []const u8 = "",
            user_prompt: []const u8 = "",
            response_format: []const u8 = "json_object",
            response_size: []const u8 = "medium",
            temperature: f32 = 0.2,
            json_schema: []const u8 = direct_provider.default_json_schema,
        };
        const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch |err| {
            return .{ .response = "", .error_msg = std.fmt.allocPrint(std.heap.page_allocator, "invalid live llm request: {s}", .{@errorName(err)}) catch "invalid live llm request" };
        };
        defer parsed.deinit();
        var client = direct_provider.DirectRandomProviderClient.initDirectFromEnv(self.io, httpClient(self), self.env, self.models_spec);
        const response = client.completeText(std.heap.page_allocator, .{
            .subsystem = parsed.value.subsystem,
            .system_prompt = parsed.value.system_prompt,
            .user_prompt = parsed.value.user_prompt,
            .temperature = parsed.value.temperature,
            .response_format = parseTextResponseFormat(parsed.value.response_format),
            .response_size = parseResponseSize(parsed.value.response_size),
            .json_schema = parsed.value.json_schema,
        }) catch |err| {
            return .{ .response = "", .error_msg = std.fmt.allocPrint(std.heap.page_allocator, "live llm failed: {s}", .{@errorName(err)}) catch "live llm failed" };
        };
        return .{ .response = response, .error_msg = "" };
    }

    fn completeVision(self: *LiveHost, body: []const u8) HostResult {
        const Wire = struct {
            subsystem: []const u8 = "vision",
            prompt: []const u8 = "",
            image_paths: []const []const u8 = &.{},
            response_format: []const u8 = "text",
            response_size: []const u8 = "medium",
            temperature: f32 = 0.2,
            json_schema: []const u8 = direct_provider.default_json_schema,
        };
        const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch |err| {
            return .{ .response = "", .error_msg = std.fmt.allocPrint(std.heap.page_allocator, "invalid live vision request: {s}", .{@errorName(err)}) catch "invalid live vision request" };
        };
        defer parsed.deinit();
        var client = direct_provider.DirectRandomProviderClient.initDirectFromEnv(self.io, httpClient(self), self.env, self.models_spec);
        const response = client.completeVision(std.heap.page_allocator, .{
            .subsystem = parsed.value.subsystem,
            .prompt = parsed.value.prompt,
            .image_paths = parsed.value.image_paths,
            .temperature = parsed.value.temperature,
            .response_format = parseVisionResponseFormat(parsed.value.response_format),
            .response_size = parseResponseSize(parsed.value.response_size),
            .json_schema = parsed.value.json_schema,
        }) catch |err| {
            return .{ .response = "", .error_msg = std.fmt.allocPrint(std.heap.page_allocator, "live vision failed: {s}", .{@errorName(err)}) catch "live vision failed" };
        };
        return .{ .response = response, .error_msg = "" };
    }
};

fn httpClient(self: *LiveHost) http_transport.Client {
    return self.http_transport_impl.client();
}

fn parseTextResponseFormat(value: []const u8) direct_provider.ResponseFormat {
    if (std.mem.eql(u8, value, "text")) return .text;
    return .json_object;
}

fn parseVisionResponseFormat(value: []const u8) direct_provider.ResponseFormat {
    if (std.mem.eql(u8, value, "json_object")) return .json_object;
    return .text;
}

fn parseResponseSize(value: []const u8) direct_provider.ResponseSize {
    if (std.mem.eql(u8, value, "small")) return .small;
    if (std.mem.eql(u8, value, "large")) return .large;
    return .medium;
}

fn embedResponse(request_body: []const u8) []const u8 {
    const Wire = struct { texts: []const []const u8 = &.{} };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, request_body, .{ .ignore_unknown_fields = true }) catch {
        return "{\"dimensions\":512,\"vectors\":[]}";
    };
    defer parsed.deinit();
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.heap.page_allocator);
    out.appendSlice(std.heap.page_allocator, "{\"dimensions\":512,\"vectors\":[") catch return "{\"dimensions\":512,\"vectors\":[]}";
    for (parsed.value.texts, 0..) |text, i| {
        if (i > 0) out.append(std.heap.page_allocator, ',') catch {};
        const compact = hash_vector.embed(std.heap.page_allocator, text, &.{}) catch continue;
        defer std.heap.page_allocator.free(compact);
        out.append(std.heap.page_allocator, '[') catch {};
        var dim: usize = 0;
        while (dim < embedding_port.test_embedding_dimensions) : (dim += 1) {
            if (dim > 0) out.append(std.heap.page_allocator, ',') catch {};
            const value: f32 = if (dim < compact.len) compact[dim] else 0;
            const piece = std.fmt.allocPrint(std.heap.page_allocator, "{d:.6}", .{value}) catch continue;
            defer std.heap.page_allocator.free(piece);
            out.appendSlice(std.heap.page_allocator, piece) catch {};
        }
        out.append(std.heap.page_allocator, ']') catch {};
    }
    out.appendSlice(std.heap.page_allocator, "]}") catch {};
    return std.heap.page_allocator.dupe(u8, out.items) catch "{\"dimensions\":512,\"vectors\":[]}";
}

fn hostSuccess(out_data: ?*AffectiveCoreEmbeddedString, out_error: ?*AffectiveCoreEmbeddedString, body: []const u8) c_int {
    if (out_error) |err_out| err_out.* = .{};
    if (out_data) |data| {
        const owned = std.heap.page_allocator.dupe(u8, body) catch {
            data.* = .{};
            return embedded.host_http_poll_failed;
        };
        data.* = .{ .ptr = owned.ptr, .len = owned.len };
    }
    return embedded.host_http_poll_complete;
}

fn hostFailure(
    out_error: ?*AffectiveCoreEmbeddedString,
    out_data: ?*AffectiveCoreEmbeddedString,
    message: []const u8,
) c_int {
    if (out_data) |data| data.* = .{};
    if (out_error) |err_out| {
        const owned = std.heap.page_allocator.dupe(u8, message) catch {
            err_out.* = .{};
            return embedded.host_http_poll_failed;
        };
        err_out.* = .{ .ptr = owned.ptr, .len = owned.len };
    }
    return embedded.host_http_poll_failed;
}

fn freeHostString(_: ?*anyopaque, string: AffectiveCoreEmbeddedString) callconv(.c) void {
    const slice = embedded_config.stringSlice(string) orelse return;
    std.heap.page_allocator.free(slice);
}

test "live host routes llm requests through env provider path" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var host = LiveHost.init(std.Io.Threaded.global_single_threaded.io(), &env, "openai:gpt-4.1-nano");
    var pending = PendingRequest{
        .request_id = "test",
        .url = "affective-host://system/power",
        .headers_json = "{}",
        .body = "{}",
    };
    const result = host.completePendingRequest(&pending);
    try std.testing.expect(std.mem.indexOf(u8, result.response, "supplies") != null);
    try std.testing.expectEqual(@as(usize, 1), host.deterministic_calls);
}
