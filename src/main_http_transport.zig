const std = @import("std");
const http_transport = @import("api/http_transport.zig");

pub const StdHttpTransport = struct {
    io: std.Io,

    pub fn init(io: std.Io) StdHttpTransport {
        return .{ .io = io };
    }

    pub fn client(self: *StdHttpTransport) http_transport.Client {
        return .{ .ctx = self, .postJsonFn = postJson };
    }

    fn postJson(ctx: *anyopaque, allocator: std.mem.Allocator, request: http_transport.JsonPostRequest) ![]u8 {
        const self: *StdHttpTransport = @ptrCast(@alignCast(ctx));
        var client_impl = std.http.Client{ .allocator = allocator, .io = self.io };
        defer client_impl.deinit();

        var response = try std.Io.Writer.Allocating.initCapacity(allocator, 64 * 1024);
        errdefer response.deinit();

        var headers = try allocator.alloc(std.http.Header, request.headers.len);
        defer allocator.free(headers);
        for (request.headers, 0..) |header, index| {
            headers[index] = .{ .name = header.name, .value = header.value };
        }

        const result = try client_impl.fetch(.{
            .location = .{ .url = request.url },
            .method = .POST,
            .payload = request.body,
            .response_writer = &response.writer,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = headers,
            .keep_alive = false,
        });
        const status = @intFromEnum(result.status);
        if (status < 200 or status >= 300) return error.HttpStatusFailed;

        const bytes = try response.toOwnedSlice();
        errdefer allocator.free(bytes);
        if (bytes.len > request.max_response_bytes) return error.StreamTooLong;
        return bytes;
    }
};
