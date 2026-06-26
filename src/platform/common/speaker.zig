const std = @import("std");
const speaker_port = @import("../../core/port_speaker.zig");

pub const Speaker = speaker_port.Speaker;

pub const TestSpeaker = struct {
    pub fn speaker(self: *TestSpeaker) Speaker {
        return .{ .ctx = self, .playFileFn = play };
    }

    fn play(_: *anyopaque, _: std.mem.Allocator, path: []const u8) !void {
        std.debug.print("SPEAKER TEST: {s}\n", .{path});
    }
};
