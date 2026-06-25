const std = @import("std");
const process = @import("../platform/common/process.zig");

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

pub const SmtpCurlEmailService = struct {
    io: std.Io,
    smtp_url: []const u8,
    from: []const u8,
    username: []const u8,
    password: []const u8,

    pub fn init(io: std.Io, smtp_url: []const u8, from: []const u8, username: []const u8, password: []const u8) SmtpCurlEmailService {
        return .{
            .io = io,
            .smtp_url = smtp_url,
            .from = from,
            .username = username,
            .password = password,
        };
    }

    pub fn service(self: *SmtpCurlEmailService) EmailService {
        return .{ .ctx = self, .sendFn = send };
    }

    fn send(ctx: *anyopaque, allocator: std.mem.Allocator, message: EmailMessage) ![]const u8 {
        const self: *SmtpCurlEmailService = @ptrCast(@alignCast(ctx));
        if (self.smtp_url.len == 0) return error.MissingEmailSmtpUrl;
        if (self.from.len == 0) return error.MissingEmailFrom;
        try validateAddress(self.from);
        try validateAddress(message.to);
        try validateHeaderValue(message.subject);
        if (message.body.len == 0) return error.MissingEmailBody;
        if (self.password.len > 0 and self.username.len == 0) return error.MissingEmailUsername;
        if (self.username.len > 0 and self.password.len == 0) return error.MissingEmailPassword;

        const path = try writeEmailFile(allocator, self.io, self.from, message);
        defer std.Io.Dir.cwd().deleteFile(self.io, path) catch {};

        var argv = std.ArrayList([]const u8).empty;
        try argv.append(allocator, "curl");
        try argv.append(allocator, "-sS");
        try argv.append(allocator, "--url");
        try argv.append(allocator, self.smtp_url);
        try argv.append(allocator, "--mail-from");
        try argv.append(allocator, self.from);
        try argv.append(allocator, "--mail-rcpt");
        try argv.append(allocator, message.to);
        if (self.username.len > 0) {
            const auth = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.username, self.password });
            try argv.append(allocator, "--user");
            try argv.append(allocator, auth);
        }
        try argv.append(allocator, "--upload-file");
        try argv.append(allocator, path);

        const out = try process.runCapture(allocator, self.io, argv.items);
        defer allocator.free(out);
        return std.fmt.allocPrint(allocator, "email_sent: to={s} subject={s}\n", .{ message.to, message.subject });
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

fn writeEmailFile(allocator: std.mem.Allocator, io: std.Io, from: []const u8, message: EmailMessage) ![]const u8 {
    try std.Io.Dir.cwd().createDirPath(io, "data/generated/email");
    const unique = std.Io.Clock.real.now(io).nanoseconds;
    const path = try std.fmt.allocPrint(allocator, "data/generated/email/email_{d}_{d}.eml", .{ unique, message.body.len });
    const data = try std.fmt.allocPrint(
        allocator,
        "From: {s}\r\nTo: {s}\r\nSubject: {s}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n{s}\r\n",
        .{ from, message.to, message.subject, message.body },
    );
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data, .flags = .{ .truncate = true } });
    return path;
}

fn validateAddress(value: []const u8) !void {
    try validateHeaderValue(value);
    if (std.mem.indexOfScalar(u8, value, '@') == null) return error.InvalidEmailAddress;
}

fn validateHeaderValue(value: []const u8) !void {
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
