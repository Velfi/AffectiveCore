const std = @import("std");

pub const Output = struct {
    ctx: *anyopaque,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn write(self: Output, text: []const u8) !void {
        try self.writeFn(self.ctx, text);
    }
};

test "output interface calls write callback" {
    const State = struct {
        text: []const u8 = "",

        fn write(ctx: *anyopaque, text: []const u8) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.text = text;
        }
    };

    var state = State{};
    const output = Output{ .ctx = &state, .writeFn = State.write };
    try output.write("hello");
    try std.testing.expectEqualStrings("hello", state.text);
}
