const std = @import("std");
const facial_expression = @import("port_facial_expression.zig");

pub const default_duration_ms = facial_expression.default_duration_ms;
pub const max_duration_ms = facial_expression.max_duration_ms;
pub const max_text_bytes: usize = 256;

pub const Emote = struct {
    text: []const u8,
    display_text: []const u8,
    duration_ms: u32,
};

pub const Output = struct {
    ctx: *anyopaque,
    showFn: *const fn (*anyopaque, Emote) anyerror!void,

    pub fn show(self: Output, emote: Emote) !void {
        return self.showFn(self.ctx, emote);
    }
};

pub fn normalizeDuration(duration_ms: ?u32) !u32 {
    return facial_expression.normalizeDuration(duration_ms);
}

pub fn normalizeText(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\n') != null) return error.InvalidEmoteText;
    if (std.mem.indexOfScalar(u8, raw, '\r') != null) return error.InvalidEmoteText;
    var trimmed = std.mem.trim(u8, raw, " \r\n\t");
    if (trimmed.len == 0) return error.MissingEmoteText;
    if (trimmed.len >= 2 and trimmed[0] == '*' and trimmed[trimmed.len - 1] == '*') {
        trimmed = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \r\n\t");
    }
    if (trimmed.len == 0) return error.MissingEmoteText;
    if (trimmed.len > max_text_bytes) return error.EmoteTextTooLong;
    return allocator.dupe(u8, trimmed);
}

test "normalizeText strips surrounding asterisks" {
    const text = try normalizeText(std.testing.allocator, "*waves*");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("waves", text);
}

test "normalizeText rejects empty and newline text" {
    try std.testing.expectError(error.MissingEmoteText, normalizeText(std.testing.allocator, "  "));
    try std.testing.expectError(error.InvalidEmoteText, normalizeText(std.testing.allocator, "waves\n"));
}
