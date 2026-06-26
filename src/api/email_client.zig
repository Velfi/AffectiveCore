const std = @import("std");
const process = @import("../platform/common/process.zig");
const email_port = @import("../core/port_email.zig");

pub const EmailMessage = email_port.EmailMessage;
pub const EmailService = email_port.EmailService;
pub const TestEmailService = email_port.TestEmailService;

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
        try email_port.validateAddress(self.from);
        try email_port.validateAddress(message.to);
        try email_port.validateHeaderValue(message.subject);
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
