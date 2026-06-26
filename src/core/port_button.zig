const std = @import("std");

pub const ButtonAction = enum {
    short_touch,
    held_input,
    text_input,
};

pub const ButtonControl = struct {
    ctx: *anyopaque,
    waitForActionFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!?ButtonAction,
    waitForActionForFn: *const fn (*anyopaque, std.mem.Allocator, u64) anyerror!?ButtonAction,
    isPressedFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!bool,

    pub fn waitForAction(self: ButtonControl, allocator: std.mem.Allocator) !?ButtonAction {
        return self.waitForActionFn(self.ctx, allocator);
    }

    pub fn waitForActionFor(self: ButtonControl, allocator: std.mem.Allocator, timeout_ms: u64) !?ButtonAction {
        return self.waitForActionForFn(self.ctx, allocator, timeout_ms);
    }

    pub fn isPressed(self: ButtonControl, allocator: std.mem.Allocator) !bool {
        return self.isPressedFn(self.ctx, allocator);
    }
};
