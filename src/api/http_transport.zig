const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const JsonPostRequest = struct {
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8,
    max_response_bytes: usize = 1024 * 1024,
};

pub const Client = struct {
    ctx: *anyopaque,
    postJsonFn: *const fn (*anyopaque, std.mem.Allocator, JsonPostRequest) anyerror![]u8,

    pub fn postJson(self: Client, allocator: std.mem.Allocator, request: JsonPostRequest) ![]u8 {
        return self.postJsonFn(self.ctx, allocator, request);
    }
};
