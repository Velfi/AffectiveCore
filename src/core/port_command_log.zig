const std = @import("std");

pub const CommandLog = struct {
    ctx: *anyopaque,
    appendFn: *const fn (*anyopaque, []const u8, []const u8, []const u8) anyerror!void,
    setSendEnabledFn: ?*const fn (*anyopaque, bool) anyerror!void = null,

    pub fn append(self: CommandLog, kind: []const u8, title: []const u8, body: []const u8) !void {
        try self.appendFn(self.ctx, kind, title, body);
    }

    pub fn setSendEnabled(self: CommandLog, enabled: bool) !void {
        const setFn = self.setSendEnabledFn orelse return;
        try setFn(self.ctx, enabled);
    }
};

test "command log interface calls append callback" {
    const State = struct {
        called: bool = false,

        fn append(ctx: *anyopaque, kind: []const u8, title: []const u8, body: []const u8) !void {
            const state: *@This() = @ptrCast(@alignCast(ctx));
            state.called = std.mem.eql(u8, kind, "sent") and
                std.mem.eql(u8, title, "say") and
                std.mem.eql(u8, body, "text=hello");
        }
    };

    var state = State{};
    const log = CommandLog{ .ctx = &state, .appendFn = State.append };
    try log.append("sent", "say", "text=hello");
    try std.testing.expect(state.called);
}
