const std = @import("std");
const events = @import("../../core/events.zig");

pub const Camera = struct {
    ctx: *anyopaque,
    captureFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!events.ImageCapture,

    pub fn capture(self: Camera, allocator: std.mem.Allocator) !events.ImageCapture {
        return self.captureFn(self.ctx, allocator);
    }
};
