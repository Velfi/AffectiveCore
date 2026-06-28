const std = @import("std");
const chat = @import("port_chat.zig");

pub const EffortTier = chat.EffortTier;
pub const ReasoningEffort = chat.ReasoningEffort;

pub const LlmQuality = enum {
    frugal,
    auto,
    best,

    pub fn parse(text: []const u8) !LlmQuality {
        const trimmed = std.mem.trim(u8, text, " \r\n\t");
        inline for (@typeInfo(LlmQuality).@"enum".fields) |field| {
            if (std.mem.eql(u8, trimmed, field.name)) return @field(LlmQuality, field.name);
        }
        return error.InvalidLlmQuality;
    }

    pub fn tagName(self: LlmQuality) []const u8 {
        return @tagName(self);
    }
};

pub const Provider = enum {
    openai,
    anthropic,
    google,
    deepseek,
};

pub const RosterEntry = struct {
    provider: Provider,
    model: []const u8,
    tier: EffortTier,
};

pub const LlmRoster = struct {
    entries: []const RosterEntry,

    pub fn deinit(self: LlmRoster, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.model);
        allocator.free(self.entries);
    }

    pub fn toModelsSpec(self: LlmRoster, allocator: std.mem.Allocator) ![]const u8 {
        var out = std.ArrayList(u8).empty;
        for (self.entries, 0..) |entry, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, providerName(entry.provider));
            try out.append(allocator, ':');
            try out.appendSlice(allocator, entry.model);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub fn parseProvider(text: []const u8) !Provider {
    if (std.ascii.eqlIgnoreCase(text, "openai")) return .openai;
    if (std.ascii.eqlIgnoreCase(text, "anthropic")) return .anthropic;
    if (std.ascii.eqlIgnoreCase(text, "google") or std.ascii.eqlIgnoreCase(text, "gemini")) return .google;
    if (std.ascii.eqlIgnoreCase(text, "deepseek")) return .deepseek;
    return error.InvalidRandomProvider;
}

pub fn providerName(provider: Provider) []const u8 {
    return switch (provider) {
        .openai => "openai",
        .anthropic => "anthropic",
        .google => "google",
        .deepseek => "deepseek",
    };
}

pub fn parseEffortTier(text: ?[]const u8) EffortTier {
    if (text) |value| {
        const trimmed = std.mem.trim(u8, value, " \r\n\t");
        inline for (@typeInfo(EffortTier).@"enum".fields) |field| {
            if (std.mem.eql(u8, trimmed, field.name)) return @field(EffortTier, field.name);
        }
    }
    return .basic;
}

pub const RosterModelEntry = struct {
    provider: []const u8,
    model: []const u8,
    tier: ?[]const u8 = null,
};

pub fn parseRosterFromJsonEntries(allocator: std.mem.Allocator, models: []const RosterModelEntry) !LlmRoster {
    var out = std.ArrayList(RosterEntry).empty;
    var saw_non_basic_tier = false;
    for (models) |entry| {
        const provider_text = std.mem.trim(u8, entry.provider, " \r\n\t");
        const model_text = std.mem.trim(u8, entry.model, " \r\n\t");
        if (provider_text.len == 0 or model_text.len == 0) continue;
        const tier = parseEffortTier(entry.tier);
        if (tier != .basic) saw_non_basic_tier = true;
        try out.append(allocator, .{
            .provider = try parseProvider(provider_text),
            .model = try allocator.dupe(u8, model_text),
            .tier = tier,
        });
    }
    if (out.items.len == 0) return error.NoRandomProviderModels;
    if (saw_non_basic_tier) {
        var tier_counts = std.EnumArray(EffortTier, usize).initFill(0);
        for (out.items) |item| tier_counts.set(item.tier, tier_counts.get(item.tier) + 1);
        inline for (@typeInfo(EffortTier).@"enum".fields) |field| {
            const tier = @field(EffortTier, field.name);
            if (tier_counts.get(tier) == 0) return error.MissingLlmTierModels;
        }
    }
    return .{ .entries = try out.toOwnedSlice(allocator) };
}

pub fn parseRosterFromModelsSpec(allocator: std.mem.Allocator, spec: []const u8) !LlmRoster {
    const text = std.mem.trim(u8, spec, " \r\n\t");
    if (text.len == 0) return error.NoRandomProviderModels;

    var out = std.ArrayList(RosterEntry).empty;
    var parts = std.mem.splitScalar(u8, text, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \r\n\t");
        if (part.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, part, ':') orelse return error.InvalidRandomProviderModel;
        const provider_text = std.mem.trim(u8, part[0..sep], " \r\n\t");
        const model_text = std.mem.trim(u8, part[sep + 1 ..], " \r\n\t");
        if (provider_text.len == 0 or model_text.len == 0) return error.InvalidRandomProviderModel;
        try out.append(allocator, .{
            .provider = try parseProvider(provider_text),
            .model = try allocator.dupe(u8, model_text),
            .tier = .basic,
        });
    }
    if (out.items.len == 0) return error.NoRandomProviderModels;
    return .{ .entries = try out.toOwnedSlice(allocator) };
}

pub fn defaultEffortTierForSubsystem(subsystem: []const u8) EffortTier {
    if (std.mem.eql(u8, subsystem, "greeting")) return .basic;
    if (std.mem.eql(u8, subsystem, "intent")) return .basic;
    if (std.mem.eql(u8, subsystem, "want_achievement")) return .basic;
    if (std.mem.eql(u8, subsystem, "psyche_id")) return .basic;
    if (std.mem.eql(u8, subsystem, "psyche_superego")) return .basic;
    if (std.mem.eql(u8, subsystem, "memory_extraction")) return .standard;
    if (std.mem.eql(u8, subsystem, "memory_selection")) return .standard;
    if (std.mem.eql(u8, subsystem, "autonomy")) return .standard;
    if (std.mem.eql(u8, subsystem, "conversation")) return .standard;
    if (std.mem.eql(u8, subsystem, "identity_comparison")) return .standard;
    if (std.mem.eql(u8, subsystem, "description")) return .standard;
    return .standard;
}

pub fn clampEffortTier(quality: LlmQuality, requested: EffortTier) EffortTier {
    return switch (quality) {
        .frugal => .basic,
        .auto, .best => requested,
    };
}

pub fn clampReasoningEffort(quality: LlmQuality, requested: ?ReasoningEffort) ?ReasoningEffort {
    const effort = requested orelse return null;
    return switch (quality) {
        .frugal => switch (effort) {
            .low => .low,
            .medium, .high => .low,
        },
        .auto, .best => effort,
    };
}

pub fn allowedTiers(quality: LlmQuality) []const EffortTier {
    return switch (quality) {
        .frugal => &.{.basic},
        .auto, .best => &.{ .basic, .standard, .complex },
    };
}

pub fn rosterHasTier(roster: LlmRoster, tier: EffortTier) bool {
    for (roster.entries) |entry| {
        if (entry.tier == tier) return true;
    }
    return false;
}

pub fn rosterIsBasicOnly(roster: LlmRoster) bool {
    if (roster.entries.len == 0) return false;
    for (roster.entries) |entry| {
        if (entry.tier != .basic) return false;
    }
    return true;
}

pub fn resolveModels(
    allocator: std.mem.Allocator,
    roster: LlmRoster,
    quality: LlmQuality,
    requested_tier: EffortTier,
) ![]RosterEntry {
    var tier = clampEffortTier(quality, requested_tier);
    if (!rosterHasTier(roster, tier) and rosterIsBasicOnly(roster)) tier = .basic;
    var out = std.ArrayList(RosterEntry).empty;
    for (roster.entries) |entry| {
        if (entry.tier == tier) {
            try out.append(allocator, .{
                .provider = entry.provider,
                .model = try allocator.dupe(u8, entry.model),
                .tier = entry.tier,
            });
        }
    }
    if (out.items.len == 0) return error.NoModelsForEffortTier;
    return try out.toOwnedSlice(allocator);
}

pub fn resolveModelsSpec(
    allocator: std.mem.Allocator,
    roster: LlmRoster,
    quality: LlmQuality,
    requested_tier: EffortTier,
) ![]const u8 {
    const models = try resolveModels(allocator, roster, quality, requested_tier);
    defer {
        for (models) |entry| allocator.free(entry.model);
        allocator.free(models);
    }
    var out = std.ArrayList(u8).empty;
    for (models, 0..) |entry, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, providerName(entry.provider));
        try out.append(allocator, ':');
        try out.appendSlice(allocator, entry.model);
    }
    return out.toOwnedSlice(allocator);
}

pub fn formatAllowedTiers(allocator: std.mem.Allocator, quality: LlmQuality) ![]const u8 {
    const tiers = allowedTiers(quality);
    var out = std.ArrayList(u8).empty;
    for (tiers, 0..) |tier, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, @tagName(tier));
    }
    return out.toOwnedSlice(allocator);
}

pub fn formatLlmPolicyObservation(
    allocator: std.mem.Allocator,
    quality: LlmQuality,
    last_effort_tier: ?EffortTier,
) ![]const u8 {
    const allowed = try formatAllowedTiers(allocator, quality);
    defer allocator.free(allowed);
    if (last_effort_tier) |tier| {
        return std.fmt.allocPrint(
            allocator,
            "llm_policy:\n- user_quality: {s}\n- allowed_tiers: {s}\n- last_effort_tier: {s}\n",
            .{ quality.tagName(), allowed, @tagName(tier) },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "llm_policy:\n- user_quality: {s}\n- allowed_tiers: {s}\n",
        .{ quality.tagName(), allowed },
    );
}

test "frugal clamps tier and reasoning" {
    try std.testing.expectEqual(EffortTier.basic, clampEffortTier(.frugal, .complex));
    try std.testing.expectEqual(ReasoningEffort.low, clampReasoningEffort(.frugal, .high).?);
}

test "auto passes requested tier through" {
    try std.testing.expectEqual(EffortTier.complex, clampEffortTier(.auto, .complex));
    try std.testing.expectEqual(ReasoningEffort.high, clampReasoningEffort(.auto, .high).?);
}

test "resolveModels filters by tier" {
    const allocator = std.testing.allocator;
    const roster = try parseRosterFromJsonEntries(allocator, &.{
        .{ .provider = "openai", .model = "gpt-4.1-nano", .tier = "basic" },
        .{ .provider = "openai", .model = "gpt-4.1-mini", .tier = "standard" },
        .{ .provider = "openai", .model = "gpt-4.1", .tier = "complex" },
    });
    defer roster.deinit(allocator);

    const basic = try resolveModels(allocator, roster, .auto, .basic);
    defer {
        for (basic) |entry| allocator.free(entry.model);
        allocator.free(basic);
    }
    try std.testing.expectEqual(@as(usize, 1), basic.len);
    try std.testing.expectEqualStrings("gpt-4.1-nano", basic[0].model);

    const standard = try resolveModels(allocator, roster, .auto, .standard);
    defer {
        for (standard) |entry| allocator.free(entry.model);
        allocator.free(standard);
    }
    try std.testing.expectEqual(@as(usize, 1), standard.len);
    try std.testing.expectEqualStrings("gpt-4.1-mini", standard[0].model);
}

test "basic-only roster serves any requested tier" {
    const allocator = std.testing.allocator;
    const roster = try parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano");
    defer roster.deinit(allocator);

    const resolved = try resolveModels(allocator, roster, .auto, .standard);
    defer {
        for (resolved) |entry| allocator.free(entry.model);
        allocator.free(resolved);
    }
    try std.testing.expectEqual(@as(usize, 1), resolved.len);
    try std.testing.expectEqualStrings("gpt-4.1-nano", resolved[0].model);
}

test "legacy flat roster defaults to basic" {
    const allocator = std.testing.allocator;
    const roster = try parseRosterFromModelsSpec(allocator, "openai:gpt-4.1-nano,anthropic:claude-haiku");
    defer roster.deinit(allocator);
    try std.testing.expectEqual(EffortTier.basic, roster.entries[0].tier);
    try std.testing.expectEqual(@as(usize, 2), roster.entries.len);
}
