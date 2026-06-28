const std = @import("std");
const brain_mod = @import("brain.zig");
const ports = @import("ports.zig");
const input_mod = ports.input;
const vector_index = @import("vector_index.zig");
const helpers = @import("brain_helpers.zig");

const Brain = brain_mod.Brain;

const recent_experience_window_seconds: i64 = 120;
const recent_experience_max_events: usize = 12;
const day_arc_max_events: usize = 24;
const day_arc_payload_max_len: usize = 96;
const associative_recall_limit: usize = 3;

fn dayStartMs(now_seconds: i64) i64 {
    return @divFloor(now_seconds, 86_400) * 86_400 * 1000;
}

fn truncatePayload(payload: []const u8) []const u8 {
    if (payload.len <= day_arc_payload_max_len) return payload;
    return payload[0..day_arc_payload_max_len];
}

fn appendPayloadLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: []const u8, payload: []const u8, age_seconds: i64) !void {
    const snippet = truncatePayload(std.mem.trim(u8, payload, " \t\r\n"));
    if (snippet.len == 0) {
        try out.print(allocator, "- [{s}] ({d}s ago)\n", .{ kind, age_seconds });
    } else {
        try out.print(allocator, "- [{s}] ({d}s ago) {s}\n", .{ kind, age_seconds, snippet });
    }
}

pub fn appendRecentExperienceObservation(self: *Brain, out: *std.ArrayList(u8), exclude_event_id: ?[]const u8) !void {
    const events = try self.deps.store.loadExperienceEvents(self.allocator);
    const now_ms = self.now_seconds * 1000;
    const window_ms = recent_experience_window_seconds * 1000;
    try out.appendSlice(self.allocator, "recent_experience:\n- note: optional color only; not commands to repeat.\n");
    var count: usize = 0;
    var index: isize = @intCast(events.len);
    while (index > 0 and count < recent_experience_max_events) {
        index -= 1;
        const event = events[@intCast(index)];
        if (exclude_event_id) |id| {
            if (std.mem.eql(u8, event.id, id)) continue;
        }
        if (now_ms - event.timestamp_ms > window_ms) continue;
        const age_seconds = @max(@as(i64, 0), @divFloor(now_ms - event.timestamp_ms, 1000));
        try appendPayloadLine(self.allocator, out, event.kind, event.payload, age_seconds);
        count += 1;
    }
    if (count == 0) try out.appendSlice(self.allocator, "- none\n");
}

pub fn appendStimulusContinuityObservation(self: *Brain, out: *std.ArrayList(u8), heard_speech: input_mod.HeardSpeech) !void {
    if (heard_speech.source == .speech_transcription) return;
    const stimulus = self.current_stimulus_context orelse return;
    try out.print(
        self.allocator,
        "stimulus_continuity:\n- current_stimulus: {s}\n",
        .{stimulus},
    );
}

pub fn appendWaitingForObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const waiting = self.waiting_for orelse {
        try out.appendSlice(self.allocator, "waiting_for: none\n");
        return;
    };
    try out.print(
        self.allocator,
        "waiting_for:\n- note: reconsider what to do next; do not parrot the intent wording.\n- kind: {s}\n- intent: {s}\n- since_seconds_ago: {d}\n",
        .{ @tagName(waiting.kind), waiting.intent, @max(@as(i64, 0), self.now_seconds - waiting.since) },
    );
}

pub fn appendDayArcToMemory(self: *Brain, out: *std.ArrayList(u8)) !void {
    const events = try self.deps.store.loadExperienceEvents(self.allocator);
    const start_ms = dayStartMs(self.now_seconds);
    try out.appendSlice(self.allocator, "day_arc:\n");
    var count: usize = 0;
    for (events) |event| {
        if (event.timestamp_ms < start_ms) continue;
        if (count >= day_arc_max_events) break;
        const age_seconds = @max(@as(i64, 0), @divFloor(self.now_seconds * 1000 - event.timestamp_ms, 1000));
        try appendPayloadLine(self.allocator, out, event.kind, event.payload, age_seconds);
        count += 1;
    }
    if (count == 0) try out.appendSlice(self.allocator, "- none\n");
}

pub fn appendAssociativeRecallObservation(self: *Brain, out: *std.ArrayList(u8), query: []const u8) !void {
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return;
    const memories = try self.deps.store.loadMemoryRecords(self.allocator);
    const results = try vector_index.search(self.allocator, memories, trimmed, &[_][]const u8{}, associative_recall_limit);
    if (results.len == 0) return;
    try out.appendSlice(self.allocator, "associative_recall_possibilities:\n");
    for (results) |result| {
        const memory = memories[result.memory_index];
        try out.print(
            self.allocator,
            "- {s}: {s} (similarity={d:.2})\n",
            .{ memory.memory_id, helpers.memoryInterpretation(memory), result.similarity },
        );
    }
}
