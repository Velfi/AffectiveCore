const std = @import("std");

pub const default_duration_ms: u32 = 3000;
pub const max_duration_ms: u32 = 5000;

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

pub const ExpressionPreset = struct {
    id: []const u8,
    eyes: []const u8,
    mouth: []const u8,
};

pub const Catalog = struct {
    eye_names: []const []const u8,
    mouth_names: []const []const u8,
    presets: []const ExpressionPreset = &.{},

    pub fn isCustom(self: Catalog) bool {
        return self.eye_names.len > 0 and self.mouth_names.len > 0;
    }

    pub fn eyeAllowed(self: Catalog, name: []const u8) bool {
        for (self.eye_names) |sprite_name| {
            if (std.mem.eql(u8, sprite_name, name)) return true;
        }
        return false;
    }

    pub fn mouthAllowed(self: Catalog, name: []const u8) bool {
        for (self.mouth_names) |sprite_name| {
            if (std.mem.eql(u8, sprite_name, name)) return true;
        }
        return false;
    }

    pub fn lookupPreset(self: Catalog, name: []const u8) ?ExpressionPreset {
        const trimmed = std.mem.trim(u8, name, " \r\n\t");
        if (trimmed.len == 0) return null;
        for (self.presets) |preset| {
            if (std.mem.eql(u8, preset.id, trimmed)) return preset;
        }
        return null;
    }
};

pub const OwnedCatalog = struct {
    eye_names: []const []const u8,
    mouth_names: []const []const u8,
    presets: []ExpressionPreset = &.{},

    pub fn deinit(self: *OwnedCatalog, allocator: std.mem.Allocator) void {
        for (self.eye_names) |name| allocator.free(name);
        if (self.eye_names.len > 0) allocator.free(self.eye_names);
        for (self.mouth_names) |name| allocator.free(name);
        if (self.mouth_names.len > 0) allocator.free(self.mouth_names);
        for (self.presets) |preset| {
            allocator.free(preset.id);
            allocator.free(preset.eyes);
            allocator.free(preset.mouth);
        }
        if (self.presets.len > 0) allocator.free(self.presets);
        self.eye_names = &.{};
        self.mouth_names = &.{};
        self.presets = &.{};
    }

    pub fn view(self: *const OwnedCatalog) Catalog {
        return .{
            .eye_names = self.eye_names,
            .mouth_names = self.mouth_names,
            .presets = self.presets,
        };
    }
};

const AvatarSpriteEntry = struct {
    name: []const u8,
};

const AvatarExpressionLayer = struct {
    sprite: ?[]const u8 = null,
};

const AvatarExpressionEntry = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    layers: ?struct {
        eyes: ?AvatarExpressionLayer = null,
        mouth: ?AvatarExpressionLayer = null,
    } = null,
};

const AvatarManifestSprites = struct {
    eyeSprites: ?[]AvatarSpriteEntry = null,
    mouthSprites: ?[]AvatarSpriteEntry = null,
    expressions: ?[]AvatarExpressionEntry = null,
};

fn dupUniqueSpriteNames(allocator: std.mem.Allocator, sprites: []const AvatarSpriteEntry) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    for (sprites) |sprite| {
        if (sprite.name.len == 0) return error.MissingFacialExpressionCatalog;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, sprite.name)) return error.DuplicateFacialExpressionSpriteName;
        }
        try names.append(allocator, try allocator.dupe(u8, sprite.name));
    }
    return try names.toOwnedSlice(allocator);
}

pub fn parseCatalogFromAvatarJson(allocator: std.mem.Allocator, json_bytes: []const u8) !OwnedCatalog {
    const parsed = try std.json.parseFromSlice(AvatarManifestSprites, allocator, json_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const eyes = parsed.value.eyeSprites orelse &[_]AvatarSpriteEntry{};
    const mouths = parsed.value.mouthSprites orelse &[_]AvatarSpriteEntry{};
    if (eyes.len == 0 or mouths.len == 0) return error.MissingFacialExpressionCatalog;

    const eye_names = try dupUniqueSpriteNames(allocator, eyes);
    errdefer {
        for (eye_names) |name| allocator.free(name);
        allocator.free(eye_names);
    }
    const mouth_names = try dupUniqueSpriteNames(allocator, mouths);
    errdefer {
        for (mouth_names) |name| allocator.free(name);
        allocator.free(mouth_names);
    }
    const presets = try parseExpressionPresets(allocator, parsed.value.expressions orelse &[_]AvatarExpressionEntry{});
    errdefer freeExpressionPresets(allocator, presets);

    return .{
        .eye_names = eye_names,
        .mouth_names = mouth_names,
        .presets = presets,
    };
}

fn freeExpressionPresets(allocator: std.mem.Allocator, presets: []ExpressionPreset) void {
    for (presets) |preset| {
        allocator.free(preset.id);
        allocator.free(preset.eyes);
        allocator.free(preset.mouth);
    }
    if (presets.len > 0) allocator.free(presets);
}

fn parseExpressionPresets(allocator: std.mem.Allocator, entries: []const AvatarExpressionEntry) ![]ExpressionPreset {
    var presets = std.ArrayList(ExpressionPreset).empty;
    errdefer {
        for (presets.items) |preset| {
            allocator.free(preset.id);
            allocator.free(preset.eyes);
            allocator.free(preset.mouth);
        }
        presets.deinit(allocator);
    }
    for (entries) |entry| {
        const id_source = entry.id orelse entry.name orelse continue;
        const trimmed_id = std.mem.trim(u8, id_source, " \r\n\t");
        if (trimmed_id.len == 0) continue;
        const layers = entry.layers orelse continue;
        const eyes_layer = layers.eyes orelse continue;
        const mouth_layer = layers.mouth orelse continue;
        const eyes_sprite = eyes_layer.sprite orelse continue;
        const mouth_sprite = mouth_layer.sprite orelse continue;
        const trimmed_eyes = std.mem.trim(u8, eyes_sprite, " \r\n\t");
        const trimmed_mouth = std.mem.trim(u8, mouth_sprite, " \r\n\t");
        if (trimmed_eyes.len == 0 or trimmed_mouth.len == 0) continue;
        for (presets.items) |existing| {
            if (std.mem.eql(u8, existing.id, trimmed_id)) return error.DuplicateFacialExpressionPreset;
        }
        try presets.append(allocator, .{
            .id = try allocator.dupe(u8, trimmed_id),
            .eyes = try allocator.dupe(u8, trimmed_eyes),
            .mouth = try allocator.dupe(u8, trimmed_mouth),
        });
    }
    return try presets.toOwnedSlice(allocator);
}

pub const Output = struct {
    ctx: *anyopaque,
    showFn: *const fn (*anyopaque, Expression) anyerror!void,

    pub fn show(self: Output, expression: Expression) !void {
        try self.showFn(self.ctx, expression);
    }
};

pub fn validateWithCatalog(expression: Expression, catalog: Catalog) !void {
    if (!catalog.eyeAllowed(expression.eyes)) return error.UnknownFacialExpressionEyes;
    if (!catalog.mouthAllowed(expression.mouth)) return error.UnknownFacialExpressionMouth;
    if (expression.duration_ms > max_duration_ms) return error.FacialExpressionDurationTooLong;
}

pub fn normalizeDuration(duration_ms: ?u32) !u32 {
    const duration = duration_ms orelse default_duration_ms;
    if (duration > max_duration_ms) return error.FacialExpressionDurationTooLong;
    return duration;
}

pub const default_eye_sprite_name = "neutral";
pub const default_mouth_sprite_names = [_][]const u8{ "neutral", "neutral_closed" };

pub fn defaultEyeName(catalog: Catalog) ?[]const u8 {
    if (catalog.eyeAllowed(default_eye_sprite_name)) return default_eye_sprite_name;
    return null;
}

pub fn defaultMouthName(catalog: Catalog) ?[]const u8 {
    for (default_mouth_sprite_names) |name| {
        if (catalog.mouthAllowed(name)) return name;
    }
    return null;
}

pub const ResolvedExpression = struct {
    eyes: []const u8,
    mouth: []const u8,
    duration_ms: u32,
};

pub fn resolveFromProposal(
    eyes_raw: ?[]const u8,
    mouth_raw: ?[]const u8,
    text_raw: ?[]const u8,
    duration_ms_opt: ?u32,
    catalog: Catalog,
) !ResolvedExpression {
    const duration_ms = try normalizeDuration(duration_ms_opt);
    const eyes_trimmed = std.mem.trim(u8, eyes_raw orelse "", " \r\n\t");
    const mouth_trimmed = std.mem.trim(u8, mouth_raw orelse "", " \r\n\t");

    if (eyes_trimmed.len > 0 and mouth_trimmed.len > 0) {
        return .{ .eyes = eyes_trimmed, .mouth = mouth_trimmed, .duration_ms = duration_ms };
    }
    if (eyes_trimmed.len > 0 or mouth_trimmed.len > 0) {
        const resolved_eyes = if (eyes_trimmed.len > 0) eyes_trimmed else defaultEyeName(catalog) orelse return error.MissingDefaultFacialExpressionEyes;
        const resolved_mouth = if (mouth_trimmed.len > 0) mouth_trimmed else defaultMouthName(catalog) orelse return error.MissingDefaultFacialExpressionMouth;
        return .{ .eyes = resolved_eyes, .mouth = resolved_mouth, .duration_ms = duration_ms };
    }

    const preset_name = text_raw orelse return error.MissingFacialExpressionSprites;
    const trimmed_preset = std.mem.trim(u8, preset_name, " \r\n\t");
    if (trimmed_preset.len == 0) return error.MissingFacialExpressionSprites;
    const preset = catalog.lookupPreset(trimmed_preset) orelse return error.UnknownFacialExpressionPreset;
    return .{ .eyes = preset.eyes, .mouth = preset.mouth, .duration_ms = duration_ms };
}

pub fn proposalCatalogIncompleteReason(
    eyes_raw: ?[]const u8,
    mouth_raw: ?[]const u8,
    text_raw: ?[]const u8,
    duration_ms_opt: ?u32,
    catalog: Catalog,
) ?[]const u8 {
    if (duration_ms_opt) |duration| {
        if (duration > max_duration_ms) return "duration_ms exceeds maximum";
    }
    const eyes_trimmed = std.mem.trim(u8, eyes_raw orelse "", " \r\n\t");
    const mouth_trimmed = std.mem.trim(u8, mouth_raw orelse "", " \r\n\t");
    if (eyes_trimmed.len > 0 or mouth_trimmed.len > 0) {
        if (eyes_trimmed.len == 0 and defaultEyeName(catalog) == null) return "catalog missing neutral eyes sprite for default";
        if (mouth_trimmed.len == 0 and defaultMouthName(catalog) == null) return "catalog missing neutral mouth sprite for default";
        const resolved_eyes = if (eyes_trimmed.len > 0) eyes_trimmed else defaultEyeName(catalog).?;
        const resolved_mouth = if (mouth_trimmed.len > 0) mouth_trimmed else defaultMouthName(catalog).?;
        if (!catalog.eyeAllowed(resolved_eyes)) return "unknown eyes sprite name";
        if (!catalog.mouthAllowed(resolved_mouth)) return "unknown mouth sprite name";
        return null;
    }
    const preset_name = text_raw orelse return null;
    const trimmed_preset = std.mem.trim(u8, preset_name, " \r\n\t");
    if (trimmed_preset.len == 0) return null;
    if (catalog.lookupPreset(trimmed_preset) == null) return "unknown facial expression preset";
    return null;
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

pub fn appendCatalogObservation(allocator: std.mem.Allocator, out: *std.ArrayList(u8), catalog: Catalog) !void {
    try out.appendSlice(allocator, "facial_expression_catalog:\n");
    try out.appendSlice(allocator, "- eyes:");
    for (catalog.eye_names) |name| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, name);
    }
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, "- mouths:");
    for (catalog.mouth_names) |name| {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, name);
    }
    try out.append(allocator, '\n');
    if (catalog.presets.len > 0) {
        try out.appendSlice(allocator, "- presets:");
        for (catalog.presets) |preset| {
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, preset.id);
            try out.appendSlice(allocator, "=");
            try out.appendSlice(allocator, preset.eyes);
            try out.appendSlice(allocator, "/");
            try out.appendSlice(allocator, preset.mouth);
        }
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "- note: facial_expression may set eyes, mouth, or both; unspecified eyes or mouth default to neutral sprites from this catalog, or set text to a preset id.\n");
}

pub fn appendSkillDescription(allocator: std.mem.Allocator, out: *std.ArrayList(u8), catalog: Catalog) !void {
    try out.appendSlice(allocator, "silently show a facial expression on the avatar. Set eyes, mouth, or both from facial_expression_catalog");
    try out.print(allocator, " (eyes: ", .{});
    for (catalog.eye_names, 0..) |name, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, name);
    }
    try out.print(allocator, "; mouths: ", .{});
    for (catalog.mouth_names, 0..) |name, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, name);
    }
    try out.appendSlice(allocator, "); optional duration_ms defaults to 3000 and may not exceed 5000. Or set text to a preset id from facial_expression_catalog.");
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

const test_avatar_json_unfocused_smirk =
    \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"frame":0,"row":0,"column":0,"name":"unfocused"}],"mouthSprites":[{"frame":0,"row":0,"column":0,"name":"smirk"}]}
;

test "facial expression catalog parses avatar.json expression presets" {
    const json =
        \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"name":"neutral_open"}],"mouthSprites":[{"name":"neutral_closed"},{"name":"smirk"}],"expressions":[{"id":"neutral","layers":{"eyes":{"sprite":"neutral_open"},"mouth":{"sprite":"neutral_closed"}}},{"name":"happy","layers":{"eyes":{"sprite":"neutral_open"},"mouth":{"sprite":"smirk"}}}]}
    ;
    var catalog = try parseCatalogFromAvatarJson(std.testing.allocator, json);
    defer catalog.deinit(std.testing.allocator);
    const view = catalog.view();
    try std.testing.expectEqual(@as(usize, 2), view.presets.len);
    const neutral = view.lookupPreset("neutral").?;
    try std.testing.expectEqualStrings("neutral_open", neutral.eyes);
    try std.testing.expectEqualStrings("neutral_closed", neutral.mouth);
    const happy = view.lookupPreset("happy").?;
    try std.testing.expectEqualStrings("smirk", happy.mouth);
}

test "facial expression catalog rejects duplicate expression presets" {
    const json =
        \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"name":"neutral_open"}],"mouthSprites":[{"name":"neutral_closed"}],"expressions":[{"id":"neutral","layers":{"eyes":{"sprite":"neutral_open"},"mouth":{"sprite":"neutral_closed"}}},{"id":"neutral","layers":{"eyes":{"sprite":"neutral_open"},"mouth":{"sprite":"neutral_closed"}}}]}
    ;
    try std.testing.expectError(error.DuplicateFacialExpressionPreset, parseCatalogFromAvatarJson(std.testing.allocator, json));
}

test "facial expression validates known sprites and duration" {
    const json =
        \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"name":"unfocused"},{"name":"neutral"}],"mouthSprites":[{"name":"smirk"},{"name":"flat"},{"name":"parted"},{"name":"neutral_closed"}]}
    ;
    var catalog = try parseCatalogFromAvatarJson(std.testing.allocator, json);
    defer catalog.deinit(std.testing.allocator);
    const view = catalog.view();
    try validateWithCatalog(.{ .eyes = "unfocused", .mouth = "smirk", .duration_ms = 5000 }, view);
    try validateWithCatalog(.{ .eyes = "neutral", .mouth = "flat" }, view);
    try validateWithCatalog(.{ .eyes = "neutral", .mouth = "parted" }, view);
    try validateWithCatalog(.{ .eyes = "neutral", .mouth = "neutral_closed" }, view);
    try std.testing.expectError(error.UnknownFacialExpressionEyes, validateWithCatalog(.{ .eyes = "bogus", .mouth = "smirk" }, view));
    try std.testing.expectError(error.UnknownFacialExpressionMouth, validateWithCatalog(.{ .eyes = "unfocused", .mouth = "bogus" }, view));
    try std.testing.expectError(error.FacialExpressionDurationTooLong, validateWithCatalog(.{ .eyes = "unfocused", .mouth = "smirk", .duration_ms = 5001 }, view));
}

test "facial expression duration defaults and caps" {
    try std.testing.expectEqual(@as(u32, default_duration_ms), try normalizeDuration(null));
    try std.testing.expectEqual(@as(u32, 42), try normalizeDuration(42));
    try std.testing.expectError(error.FacialExpressionDurationTooLong, normalizeDuration(max_duration_ms + 1));
}

test "resolveFromProposal defaults unspecified eyes or mouth to neutral" {
    const json =
        \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"name":"neutral"},{"name":"unfocused"}],"mouthSprites":[{"name":"smirk"},{"name":"neutral_closed"}]}
    ;
    var catalog = try parseCatalogFromAvatarJson(std.testing.allocator, json);
    defer catalog.deinit(std.testing.allocator);
    const view = catalog.view();

    const mouth_only = try resolveFromProposal(null, "smirk", null, null, view);
    try std.testing.expectEqualStrings("neutral", mouth_only.eyes);
    try std.testing.expectEqualStrings("smirk", mouth_only.mouth);

    const eyes_only = try resolveFromProposal("unfocused", null, null, null, view);
    try std.testing.expectEqualStrings("unfocused", eyes_only.eyes);
    try std.testing.expectEqualStrings("neutral_closed", eyes_only.mouth);

    const no_neutral_eyes_json =
        \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"name":"unfocused"}],"mouthSprites":[{"name":"smirk"}]}
    ;
    var no_neutral = try parseCatalogFromAvatarJson(std.testing.allocator, no_neutral_eyes_json);
    defer no_neutral.deinit(std.testing.allocator);
    try std.testing.expectError(error.MissingDefaultFacialExpressionEyes, resolveFromProposal(null, "smirk", null, null, no_neutral.view()));
    try std.testing.expectEqualStrings("catalog missing neutral eyes sprite for default", proposalCatalogIncompleteReason(null, "smirk", null, null, no_neutral.view()).?);
}

test "facial expression catalog parses avatar.json sprite names" {
    const json =
        \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"frame":0,"row":0,"column":0,"name":"bright_eyes"},{"frame":1,"row":0,"column":1,"name":"sleepy_eyes"}],"mouthSprites":[{"frame":0,"row":0,"column":0,"name":"small_smile"},{"frame":1,"row":0,"column":1,"name":"open_mouth"}]}
    ;
    var catalog = try parseCatalogFromAvatarJson(std.testing.allocator, json);
    defer catalog.deinit(std.testing.allocator);
    const view = catalog.view();
    try std.testing.expect(view.isCustom());
    try std.testing.expect(view.eyeAllowed("bright_eyes"));
    try std.testing.expect(view.mouthAllowed("small_smile"));
    try std.testing.expect(!view.eyeAllowed("unfocused"));
    try validateWithCatalog(.{ .eyes = "bright_eyes", .mouth = "small_smile" }, view);
    try std.testing.expectError(error.UnknownFacialExpressionEyes, validateWithCatalog(.{ .eyes = "unfocused", .mouth = "small_smile" }, view));
}

test "facial expression catalog rejects duplicate sprite names" {
    const json =
        \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"frame":0,"row":0,"column":0,"name":"bright_eyes"},{"frame":1,"row":0,"column":1,"name":"bright_eyes"}],"mouthSprites":[{"frame":0,"row":0,"column":0,"name":"small_smile"}]}
    ;
    try std.testing.expectError(error.DuplicateFacialExpressionSpriteName, parseCatalogFromAvatarJson(std.testing.allocator, json));
}

test "facial expression catalog rejects invalid json without leaking eye names" {
    const good_json =
        \\{"canvas":{"width":512,"height":512},"layers":[],"eyeSprites":[{"frame":0,"row":0,"column":0,"name":"bright_eyes"}],"mouthSprites":[{"frame":0,"row":0,"column":0,"name":""}]}
    ;
    try std.testing.expectError(error.MissingFacialExpressionCatalog, parseCatalogFromAvatarJson(std.testing.allocator, good_json));
}
