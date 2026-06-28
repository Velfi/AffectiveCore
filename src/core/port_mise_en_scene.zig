pub const Output = struct {
    ctx: *anyopaque,
    applyFn: *const fn (*anyopaque, []const u8, ?[]const u8) anyerror!void,

    pub fn apply(self: Output, name: []const u8, theme_color: ?[]const u8) !void {
        try self.applyFn(self.ctx, name, theme_color);
    }
};
