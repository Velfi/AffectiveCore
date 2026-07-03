const std = @import("std");

const replacement_utf8 = "\xef\xbf\xbd";

/// Always returns a JSON string literal for arbitrary bytes.
/// Invalid UTF-8 is replaced with U+FFFD before encoding so host decoders never see byte arrays.
pub fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) {
        return std.json.Stringify.valueAlloc(allocator, text, .{});
    }
    const sanitized = try sanitizeUtf8(allocator, text);
    defer allocator.free(sanitized);
    return std.json.Stringify.valueAlloc(allocator, sanitized, .{});
}

fn sanitizeUtf8(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        const remaining = text[index..];
        const len = std.unicode.utf8ByteSequenceLength(remaining[0]) catch {
            try out.appendSlice(allocator, replacement_utf8);
            index += 1;
            continue;
        };
        if (index + len > text.len) {
            try out.appendSlice(allocator, replacement_utf8);
            index += 1;
            continue;
        }
        const slice = remaining[0..len];
        _ = std.unicode.utf8Decode(slice) catch {
            try out.appendSlice(allocator, replacement_utf8);
            index += 1;
            continue;
        };
        try out.appendSlice(allocator, slice);
        index += len;
    }
    return out.toOwnedSlice(allocator);
}

test "jsonString encodes invalid utf8 as json string not byte array" {
    const bytes = [_]u8{ 0xFF, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    const encoded = try jsonString(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(encoded[0] == '"');
    try std.testing.expect(encoded[encoded.len - 1] == '"');
    try std.testing.expect(std.mem.indexOf(u8, encoded, "[") == null);
}

test "jsonString preserves valid utf8" {
    const encoded = try jsonString(std.testing.allocator, "hello");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("\"hello\"", encoded);
}
