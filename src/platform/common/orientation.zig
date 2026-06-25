const std = @import("std");

pub const Query = struct {
    ctx: *anyopaque,
    requestFn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,

    pub fn request(self: Query, title: []const u8, body: []const u8) !void {
        try self.requestFn(self.ctx, title, body);
    }
};
