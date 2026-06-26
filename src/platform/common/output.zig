const std = @import("std");

const output_port = @import("../../core/port_output.zig");

pub const Output = output_port.Output;

pub const LocalOutput = struct {
    pub fn output(self: *LocalOutput) Output {
        return .{ .ctx = self, .writeFn = write };
    }

    fn write(_: *anyopaque, text: []const u8) !void {
        std.debug.print("{s}", .{text});
    }
};
