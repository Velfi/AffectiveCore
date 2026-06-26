const std = @import("std");

pub const CommandError = error{
    CommandFailed,
};

pub const ProcessRunner = struct {
    ctx: *anyopaque,
    runCommandFn: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const []const u8) anyerror!void,
    runOptionalCommandFn: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const []const u8) anyerror!void,
    runCaptureFn: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const []const u8) anyerror![]u8,
    runCaptureLargeFn: *const fn (*anyopaque, std.mem.Allocator, std.Io, []const []const u8) anyerror![]u8,

    pub fn runCommand(self: ProcessRunner, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
        return self.runCommandFn(self.ctx, allocator, io, argv);
    }

    pub fn runOptionalCommand(self: ProcessRunner, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
        return self.runOptionalCommandFn(self.ctx, allocator, io, argv);
    }

    pub fn runCapture(self: ProcessRunner, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
        return self.runCaptureFn(self.ctx, allocator, io, argv);
    }

    pub fn runCaptureLarge(self: ProcessRunner, allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]u8 {
        return self.runCaptureLargeFn(self.ctx, allocator, io, argv);
    }
};
