const std = @import("std");

pub const Clock = struct {
    ctx: *anyopaque,
    nowSecondsFn: *const fn (*anyopaque, std.Io) anyerror!i64,

    pub fn nowSeconds(self: Clock, io: std.Io) !i64 {
        return self.nowSecondsFn(self.ctx, io);
    }
};
