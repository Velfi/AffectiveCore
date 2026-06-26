const std = @import("std");

pub const EmailMessage = struct {
    to: []const u8,
    subject: []const u8,
    body: []const u8,
};

pub const EmailService = struct {
    ctx: *anyopaque,
    sendFn: *const fn (*anyopaque, std.mem.Allocator, EmailMessage) anyerror![]const u8,

    pub fn send(self: EmailService, allocator: std.mem.Allocator, message: EmailMessage) ![]const u8 {
        return self.sendFn(self.ctx, allocator, message);
    }
};

pub const TestEmailService = struct {
    sent: std.ArrayList(EmailMessage) = .empty,

    pub fn service(self: *TestEmailService) EmailService {
        return .{ .ctx = self, .sendFn = send };
    }

    fn send(ctx: *anyopaque, allocator: std.mem.Allocator, message: EmailMessage) ![]const u8 {
        const self: *TestEmailService = @ptrCast(@alignCast(ctx));
        try validateAddress(message.to);
        try validateHeaderValue(message.subject);
        if (message.body.len == 0) return error.MissingEmailBody;
        try self.sent.append(allocator, .{
            .to = try allocator.dupe(u8, message.to),
            .subject = try allocator.dupe(u8, message.subject),
            .body = try allocator.dupe(u8, message.body),
        });
        return std.fmt.allocPrint(allocator, "email_sent: to={s} subject={s}\n", .{ message.to, message.subject });
    }
};

pub fn validateAddress(value: []const u8) !void {
    try validateHeaderValue(value);
    if (std.mem.indexOfScalar(u8, value, '@') == null) return error.InvalidEmailAddress;
}

pub fn validateHeaderValue(value: []const u8) !void {
    if (value.len == 0) return error.EmptyEmailHeader;
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidEmailHeader;
}

test "test email service records sent mail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var service_impl = TestEmailService{};
    const result = try service_impl.service().send(allocator, .{
        .to = "mara@example.com",
        .subject = "Hello",
        .body = "A small note.",
    });
    try std.testing.expectEqualStrings("email_sent: to=mara@example.com subject=Hello\n", result);
    try std.testing.expectEqual(@as(usize, 1), service_impl.sent.items.len);
    try std.testing.expectEqualStrings("A small note.", service_impl.sent.items[0].body);
}
