const std = @import("std");
const context_salience = @import("context_salience.zig");
const chat = @import("port_chat.zig");

test "observationRank boosts heard speech sections" {
    const base = context_salience.observationRank(.read_models_snapshot, .heard_speech, false);
    const boosted = context_salience.observationRank(.present_moment, .heard_speech, false);
    const user = context_salience.observationRank(.user_text, .heard_speech, false);
    try std.testing.expect(boosted > base);
    try std.testing.expect(user >= 97);
}

test "memoryRank boosts speaker on heard speech" {
    const speaker = context_salience.memoryRank(.speaker, .heard_speech, false);
    const summaries = context_salience.memoryRank(.conversation_summaries, .heard_speech, false);
    try std.testing.expect(speaker > summaries);
}

test "contact open demotes conversation summaries" {
    const closed = context_salience.memoryRank(.conversation_summaries, .heard_speech, false);
    const open = context_salience.memoryRank(.conversation_summaries, .heard_speech, true);
    try std.testing.expect(open < closed);
}

test "host sense delivery boosts deferred coherence" {
    const rank = context_salience.observationRank(.deferred_coherence, .host_sense_delivery, false);
    try std.testing.expect(rank >= 98);
}

test "protected sections are marked" {
    try std.testing.expect(context_salience.isObservationProtected(.present_moment));
    try std.testing.expect(!context_salience.isObservationProtected(.read_models_snapshot));
    try std.testing.expect(context_salience.isMemoryProtected(.relevant_memories));
    try std.testing.expect(!context_salience.isMemoryProtected(.conversation_summaries));
}

test "orchestration boosts salient sense" {
    const rank = context_salience.observationRank(.salient_sense, .orchestration, false);
    try std.testing.expect(rank >= 75);
}
