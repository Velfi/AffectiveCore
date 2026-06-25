const std = @import("std");

const signal_none: u32 = 0;

var pending_signal: std.atomic.Value(u32) = .init(signal_none);

pub fn install() void {
    installOne(.INT);
    installOne(.TERM);
}

pub fn consume() ?std.posix.SIG {
    const raw = pending_signal.swap(signal_none, .acq_rel);
    if (raw == signal_none) return null;
    return @enumFromInt(raw);
}

pub fn signalName(sig: std.posix.SIG) []const u8 {
    return switch (sig) {
        .INT => "SIGINT",
        .TERM => "SIGTERM",
        else => "signal",
    };
}

pub fn exitCode(sig: std.posix.SIG) u8 {
    return @as(u8, 128) + @as(u8, @intCast(@intFromEnum(sig)));
}

fn installOne(sig: std.posix.SIG) void {
    var action = std.posix.Sigaction{
        .handler = .{ .handler = handle },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(sig, &action, null);
}

fn handle(sig: std.posix.SIG) callconv(.c) void {
    pending_signal.store(@intFromEnum(sig), .release);
}

test "consume returns pending signal once" {
    pending_signal.store(@intFromEnum(std.posix.SIG.TERM), .release);
    try std.testing.expectEqual(std.posix.SIG.TERM, consume().?);
    try std.testing.expect(consume() == null);
}

test "exitCode follows conventional signal status" {
    try std.testing.expectEqual(@as(u8, 130), exitCode(.INT));
    try std.testing.expectEqual(@as(u8, 143), exitCode(.TERM));
}
