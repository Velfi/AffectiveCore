const std = @import("std");
const process = @import("process.zig");
const speaker_port = @import("../../core/port_speaker.zig");

pub const CommandSpeaker = struct {
    io: std.Io,
    command: []const u8,

    pub fn init(io: std.Io, command: []const u8) CommandSpeaker {
        return .{ .io = io, .command = command };
    }

    pub fn speaker(self: *CommandSpeaker) speaker_port.Speaker {
        return .{
            .ctx = self,
            .playFileFn = play,
            .playFileBackgroundFn = playBackground,
        };
    }

    fn play(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) !void {
        const self: *CommandSpeaker = @ptrCast(@alignCast(ctx));
        try process.runCommand(allocator, self.io, &.{ self.command, path });
    }

    fn playBackground(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) !void {
        const self: *CommandSpeaker = @ptrCast(@alignCast(ctx));
        const script = try std.fmt.allocPrint(allocator, "{s} {s} &", .{ self.command, path });
        defer allocator.free(script);
        try process.runCommand(allocator, self.io, &.{ "sh", "-c", script });
    }
};
