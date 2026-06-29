const std = @import("std");
const chat = @import("port_chat.zig");

pub const ContextTierProfile = struct {
    target_prompt_tokens: usize,
    conversation_summaries_max: usize,
    memory_selected_max: usize,
};

pub fn profileForEffortTier(tier: ?chat.EffortTier) ContextTierProfile {
    return switch (tier orelse .standard) {
        .basic => .{
            .target_prompt_tokens = 4_000,
            .conversation_summaries_max = 3,
            .memory_selected_max = 2,
        },
        .standard => .{
            .target_prompt_tokens = 8_000,
            .conversation_summaries_max = 6,
            .memory_selected_max = 4,
        },
        .complex => .{
            .target_prompt_tokens = 16_000,
            .conversation_summaries_max = 8,
            .memory_selected_max = 5,
        },
    };
}

pub fn effectiveMemorySelectedMax(cfg_selected_max: usize, tier: ?chat.EffortTier) usize {
    return @min(cfg_selected_max, profileForEffortTier(tier).memory_selected_max);
}

pub fn effectiveConversationSummaryCap(contact_open: bool, cfg_max: usize, tier: ?chat.EffortTier) usize {
    if (contact_open) return @min(2, profileForEffortTier(tier).conversation_summaries_max);
    return @min(cfg_max, profileForEffortTier(tier).conversation_summaries_max);
}

pub fn effectiveChatContextTokenMax(cfg_max: usize, tier: ?chat.EffortTier) usize {
    return @min(cfg_max, profileForEffortTier(tier).target_prompt_tokens);
}

/// Picks the smallest tier cap that fits `prompt_token_estimate`, escalating from the
/// preferred tier when compact memory and observations already exceed a basic budget.
pub fn resolveChatContextTokenMax(
    cfg_max: usize,
    preferred_tier: ?chat.EffortTier,
    prompt_token_estimate: usize,
) usize {
    const preferred = preferred_tier orelse .standard;
    inline for ([_]chat.EffortTier{ preferred, .standard, .complex }) |tier| {
        const cap = effectiveChatContextTokenMax(cfg_max, tier);
        if (prompt_token_estimate <= cap) return cap;
    }
    return effectiveChatContextTokenMax(cfg_max, .complex);
}

test "resolveChatContextTokenMax keeps preferred tier when prompt fits" {
    try std.testing.expectEqual(@as(usize, 4_000), resolveChatContextTokenMax(120_000, .basic, 3_000));
    try std.testing.expectEqual(@as(usize, 8_000), resolveChatContextTokenMax(120_000, .standard, 7_000));
}

test "resolveChatContextTokenMax escalates when basic cap is too small" {
    try std.testing.expectEqual(@as(usize, 8_000), resolveChatContextTokenMax(120_000, .basic, 5_922));
    try std.testing.expectEqual(@as(usize, 8_000), resolveChatContextTokenMax(120_000, null, 5_922));
}

test "resolveChatContextTokenMax escalates to complex when standard cap is too small" {
    try std.testing.expectEqual(@as(usize, 16_000), resolveChatContextTokenMax(120_000, .basic, 9_500));
}
