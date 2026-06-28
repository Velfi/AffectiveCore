const std = @import("std");

/// Conservative UTF-8 heuristic for GPT-style BPE tokenizers (~4 bytes per token).
pub const chars_per_token_estimate: usize = 4;

/// Maximum rendered chat context (user prompt) sent to the language model.
pub const max_context_tokens: usize = 120_000;

pub fn estimateTokens(text: []const u8) usize {
    if (text.len == 0) return 0;
    return (text.len + chars_per_token_estimate - 1) / chars_per_token_estimate;
}

pub fn estimateTokensFromByteLength(byte_len: usize) usize {
    if (byte_len == 0) return 0;
    return (byte_len + chars_per_token_estimate - 1) / chars_per_token_estimate;
}

pub fn exceedsTokenBudget(text: []const u8, max_tokens: usize) bool {
    return estimateTokens(text) > max_tokens;
}

/// Minimum byte length whose token estimate is strictly greater than `max_tokens`.
pub fn minBytesExceedingTokenBudget(max_tokens: usize) usize {
    return max_tokens * chars_per_token_estimate + 1;
}

test "estimateTokens uses conservative byte heuristic" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("a"));
    try std.testing.expectEqual(@as(usize, 1), estimateTokens("abcd"));
    try std.testing.expectEqual(@as(usize, 2), estimateTokens("abcde"));
}

test "minBytesExceedingTokenBudget matches estimateTokens" {
    const oversized = minBytesExceedingTokenBudget(max_context_tokens);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try arena.allocator().alloc(u8, oversized);
    @memset(text, 'x');
    try std.testing.expect(exceedsTokenBudget(text, max_context_tokens));
    try std.testing.expect(!exceedsTokenBudget(text[0 .. oversized - 1], max_context_tokens));
}
