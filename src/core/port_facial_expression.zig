const std = @import("std");

pub const default_duration_ms: u32 = 3000;
pub const max_duration_ms: u32 = 5000;
pub const autonomy_cooldown_seconds: i64 = 5;

pub const EyeSprite = struct {
    name: []const u8,
    column: u8,
    row: u8,
};

pub const MouthSprite = struct {
    name: []const u8,
    column: u8,
    row: u8,
};

pub const eye_sprites = [_]EyeSprite{
    .{ .name = "neutral", .column = 1, .row = 3 },
    .{ .name = "stern", .column = 1, .row = 0 },
    .{ .name = "narrow", .column = 0, .row = 1 },
    .{ .name = "surprised", .column = 1, .row = 1 },
    .{ .name = "upward", .column = 0, .row = 2 },
    .{ .name = "concerned", .column = 1, .row = 2 },
    .{ .name = "unfocused", .column = 0, .row = 3 },
    .{ .name = "focused", .column = 0, .row = 0 },
};

pub const mouth_sprites = [_]MouthSprite{
    .{ .name = "smile_closed", .column = 0, .row = 0 },
    .{ .name = "smile_teeth", .column = 1, .row = 0 },
    .{ .name = "frown", .column = 2, .row = 0 },
    .{ .name = "kiss", .column = 0, .row = 1 },
    .{ .name = "grimace", .column = 1, .row = 1 },
    .{ .name = "open", .column = 2, .row = 1 },
    .{ .name = "disgust", .column = 0, .row = 2 },
    .{ .name = "smirk", .column = 1, .row = 2 },
    .{ .name = "uneasy_right", .column = 2, .row = 2 },
    .{ .name = "flat", .column = 0, .row = 3 },
    .{ .name = "parted", .column = 1, .row = 3 },
    .{ .name = "neutral_closed", .column = 2, .row = 3 },
};

pub const Expression = struct {
    eyes: []const u8,
    mouth: []const u8,
    duration_ms: u32 = default_duration_ms,
};

pub const Output = struct {
    ctx: *anyopaque,
    showFn: *const fn (*anyopaque, Expression) anyerror!void,

    pub fn show(self: Output, expression: Expression) !void {
        try validate(expression);
        try self.showFn(self.ctx, expression);
    }
};

pub fn validate(expression: Expression) !void {
    _ = eye(expression.eyes) orelse return error.UnknownFacialExpressionEyes;
    _ = mouth(expression.mouth) orelse return error.UnknownFacialExpressionMouth;
    if (expression.duration_ms > max_duration_ms) return error.FacialExpressionDurationTooLong;
}

pub fn normalizeDuration(duration_ms: ?u32) !u32 {
    const duration = duration_ms orelse default_duration_ms;
    if (duration > max_duration_ms) return error.FacialExpressionDurationTooLong;
    return duration;
}

pub fn eye(name: []const u8) ?EyeSprite {
    for (eye_sprites) |sprite| {
        if (std.mem.eql(u8, name, sprite.name)) return sprite;
    }
    return null;
}

pub fn mouth(name: []const u8) ?MouthSprite {
    for (mouth_sprites) |sprite| {
        if (std.mem.eql(u8, name, sprite.name)) return sprite;
    }
    return null;
}

pub fn eyeNames(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (eye_sprites, 0..) |sprite, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, sprite.name);
    }
    return out.toOwnedSlice(allocator);
}

pub fn mouthNames(allocator: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (mouth_sprites, 0..) |sprite, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, sprite.name);
    }
    return out.toOwnedSlice(allocator);
}

test "facial expression validates known sprites and duration" {
    try validate(.{ .eyes = "unfocused", .mouth = "smirk", .duration_ms = 5000 });
    try validate(.{ .eyes = "neutral", .mouth = "flat" });
    try validate(.{ .eyes = "neutral", .mouth = "parted" });
    try validate(.{ .eyes = "neutral", .mouth = "neutral_closed" });
    try std.testing.expectError(error.UnknownFacialExpressionEyes, validate(.{ .eyes = "bogus", .mouth = "smirk" }));
    try std.testing.expectError(error.UnknownFacialExpressionMouth, validate(.{ .eyes = "unfocused", .mouth = "bogus" }));
    try std.testing.expectError(error.FacialExpressionDurationTooLong, validate(.{ .eyes = "unfocused", .mouth = "smirk", .duration_ms = 5001 }));
}

test "facial expression duration defaults and caps" {
    try std.testing.expectEqual(@as(u32, default_duration_ms), try normalizeDuration(null));
    try std.testing.expectEqual(@as(u32, 42), try normalizeDuration(42));
    try std.testing.expectError(error.FacialExpressionDurationTooLong, normalizeDuration(max_duration_ms + 1));
}
