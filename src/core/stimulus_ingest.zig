const std = @import("std");
const brain_mod = @import("brain.zig");
const brain_lifecycle = @import("brain_lifecycle.zig");
const stimulus_mod = @import("stimulus.zig");
const stimulus_inbox_mod = @import("stimulus_inbox.zig");
const input_mod = @import("ports.zig").input;
const brain_process = @import("brain_process.zig");

const Brain = brain_mod.Brain;

/// One event shape for every stimulus that can reach the brain. All ingress
/// funnels through ingestStimulus so salience, adaptation (habituation and
/// sensitization), and queueing follow a single policy.
pub const StimulusEvent = struct {
    kind: stimulus_mod.Kind,
    source: []const u8,
    signature: []const u8,
    payload: []const u8 = "",
    raw_magnitude: f32,
    threat: f32 = 0,
    curiosity: f32 = 0,
    safety_relevant: bool = false,
    metadata: []const u8 = "",
};

pub fn inboxKindFor(kind: stimulus_mod.Kind) stimulus_inbox_mod.Kind {
    return switch (kind) {
        .speech => .heard_speech,
        .interrupt => .interrupt,
        .typing => .typing,
        .timer, .reminder => .timer,
        .reaction => .emoji_reaction,
        else => .sense_delivery,
    };
}

/// Salience is the adapted attention intensity from the dual-process model,
/// bounded per kind: floors guarantee direct address always reaches
/// deliberation even when habituated; the typing ceiling keeps composition
/// evidence from ever triggering a turn on its own.
pub fn salienceFloor(kind: stimulus_mod.Kind) f32 {
    return switch (kind) {
        .speech => 0.85,
        .interrupt => 0.90,
        .timer, .reminder => 0.70,
        .reaction => 0.55,
        else => 0.0,
    };
}

pub fn salienceCeiling(kind: stimulus_mod.Kind) f32 {
    return switch (kind) {
        .typing => 0.15,
        else => 1.0,
    };
}

pub const IngestedStimulus = struct {
    packet: stimulus_mod.Packet,
    /// Experience log event id; empty for kinds that are not logged (typing).
    event_id: []const u8,
    salience: f32,
};

pub fn ingestStimulus(self: *Brain, event: StimulusEvent) !IngestedStimulus {
    const input = stimulus_mod.Input{
        .kind = event.kind,
        .source = event.source,
        .signature = event.signature,
        .raw_magnitude = event.raw_magnitude,
        .threat = event.threat,
        .curiosity = event.curiosity,
        .safety_relevant = event.safety_relevant,
        .metadata = event.metadata,
    };
    // Typing is composition evidence, not an experience: score it without
    // writing an event log entry or replacing the current stimulus context.
    var event_id: []const u8 = "";
    const packet = if (event.kind == .typing)
        try self.scoreSenseStimulus(input)
    else blk: {
        const record = try self.observeSenseStimulus(input);
        event_id = record.event_id;
        break :blk record.packet;
    };
    const salience = std.math.clamp(packet.attention_intensity, salienceFloor(event.kind), salienceCeiling(event.kind));
    const payload = if (event.payload.len > 0) event.payload else event.metadata;
    try enqueueInbox(self, inboxKindFor(event.kind), salience, payload);
    return .{ .packet = packet, .event_id = event_id, .salience = salience };
}

pub fn shouldDeferHeardSpeech(self: *Brain) bool {
    return self.awaitedHostRequestActive() or self.current_dispatch_request_id != null;
}

pub fn stashDeferredSpeech(self: *Brain, heard_speech: input_mod.HeardSpeech) !void {
    try brain_lifecycle.stashDeferredSpeech(self, heard_speech);
}

pub fn enqueueInbox(
    self: *Brain,
    kind: stimulus_inbox_mod.Kind,
    salience: f32,
    payload: []const u8,
) !void {
    const activity_id = brain_process.activeActivityId(self);
    try self.stimulus_inbox.enqueue(
        self.allocator,
        kind,
        self.now_seconds,
        salience,
        activity_id,
        payload,
    );
}

pub fn ingestHeardSpeech(self: *Brain, text: []const u8, source: input_mod.HeardSpeechSource) !void {
    const preview = if (text.len > 96) text[0..96] else text;
    const metadata = try std.fmt.allocPrint(self.allocator, "text={s}", .{preview});
    defer self.allocator.free(metadata);
    _ = try ingestStimulus(self, .{
        .kind = .speech,
        .source = @tagName(source),
        .signature = "user_speech",
        .payload = text,
        .raw_magnitude = 0.85,
        .curiosity = 0.60,
        .metadata = metadata,
    });
}

pub fn ingestInterrupt(
    self: *Brain,
    reason: []const u8,
    interrupted_action: []const u8,
    preview_text: []const u8,
    canceled_count: i64,
) !void {
    const metadata = try std.fmt.allocPrint(self.allocator, "reason={s} interrupted_action={s} canceled={d} text={s}", .{
        reason,
        interrupted_action,
        canceled_count,
        preview_text,
    });
    defer self.allocator.free(metadata);
    _ = try ingestStimulus(self, .{
        .kind = .interrupt,
        .source = "affective_host",
        .signature = reason,
        .raw_magnitude = 0.70,
        .curiosity = 0.35,
        .metadata = metadata,
    });
    try self.handleUserInterruptFromHost(.{
        .reason = reason,
        .interrupted_action = interrupted_action,
        .preview_text = preview_text,
        .canceled_queued_action_count = @intCast(canceled_count),
    });
}

pub fn ingestTyping(self: *Brain, text: []const u8) !void {
    _ = try ingestStimulus(self, .{
        .kind = .typing,
        .source = "affective_host",
        .signature = "typing_activity",
        .payload = text,
        .raw_magnitude = 0.15,
    });
}

pub fn ingestSenseDeliverySummary(self: *Brain, summary: []const u8) !void {
    _ = try ingestStimulus(self, .{
        .kind = .sense_delivery,
        .source = "affective_host",
        .signature = "sense_delivery",
        .payload = summary,
        .raw_magnitude = 0.70,
        .curiosity = 0.30,
    });
    if (brain_process.activeConversationPresent(self)) {
        try brain_process.recordSenseDuringConversation(self, "sense_delivery", summary, "");
    }
}

/// Mark pending speech consumed by a turn that folded it into its context,
/// so mid-turn inbox polls do not stash the same fragments for a second
/// deliberation.
pub fn markPendingHeardSpeechHandled(self: *Brain) void {
    for (self.stimulus_inbox.entries.items, 0..) |entry, index| {
        if (!entry.handled and entry.kind == .heard_speech) self.stimulus_inbox.markHandled(index);
    }
}

/// All unhandled speech fragments joined oldest-first, so a burst of small
/// messages reads as one utterance in a single deliberation. Caller owns the
/// returned slice.
pub fn pendingHeardSpeechCoalesced(self: *Brain) !?[]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(self.allocator);
    var found = false;
    for (self.stimulus_inbox.entries.items) |entry| {
        if (entry.handled or entry.kind != .heard_speech) continue;
        if (found) try out.appendSlice(self.allocator, "\n");
        try out.appendSlice(self.allocator, entry.payload);
        found = true;
    }
    if (!found) {
        out.deinit(self.allocator);
        return null;
    }
    return try out.toOwnedSlice(self.allocator);
}

pub fn pollInbox(self: *Brain) !void {
    while (self.stimulus_inbox.nextUnhandledIndex()) |index| {
        const entry = self.stimulus_inbox.entries.items[index];
        switch (entry.kind) {
            .heard_speech => {
                if (shouldDeferHeardSpeech(self)) {
                    const heard = input_mod.HeardSpeech.typed(self.allocator, entry.payload) catch continue;
                    try stashDeferredSpeech(self, heard);
                }
            },
            .interrupt, .typing, .sense_delivery, .timer, .emoji_reaction => {},
        }
        self.stimulus_inbox.markHandled(index);
    }
}

pub fn appendStimulusInboxObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const pending = self.stimulus_inbox.pendingCount();
    if (pending == 0) return;
    const oldest = self.stimulus_inbox.oldestUnhandledAgeSeconds(self.now_seconds) orelse 0;
    try out.print(
        self.allocator,
        "stimulus_inbox:\n- pending: {d}\n- oldest_unhandled: {d}s\n- items:\n",
        .{ pending, oldest },
    );
    for (self.stimulus_inbox.entries.items) |entry| {
        if (entry.handled) continue;
        const age = @max(@as(i64, 0), self.now_seconds - entry.received_at_seconds);
        const preview = if (entry.payload.len > 96) entry.payload[0..96] else entry.payload;
        try out.print(
            self.allocator,
            "  - id={s} ({d}s) {s}: {s}\n",
            .{ entry.id, age, stimulus_inbox_mod.kindLabel(entry.kind), preview },
        );
    }
}

test "ingested speech uses inbox as the single pending input path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    brain.current_dispatch_request_id = try arena.allocator().dupe(u8, "dispatch_1");
    try ingestHeardSpeech(&brain, "hello while waiting", .typed_text);
    try std.testing.expect(brain.pending_deferred_heard_speech == null);
    try std.testing.expectEqual(@as(usize, 1), brain.stimulus_inbox.pendingCount());
}

test "inbox polling defers heard speech while a turn is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    brain.current_dispatch_request_id = try arena.allocator().dupe(u8, "dispatch_1");
    try ingestHeardSpeech(&brain, "so I was thinking", .typed_text);
    try ingestHeardSpeech(&brain, "about the garden", .typed_text);
    try ingestHeardSpeech(&brain, "can you remind me at 5", .typed_text);
    try std.testing.expect(brain.pending_deferred_heard_speech == null);
    try pollInbox(&brain);
    const deferred = brain.pending_deferred_heard_speech orelse return error.TestExpectedDeferredSpeech;
    try std.testing.expectEqualStrings("so I was thinking\nabout the garden\ncan you remind me at 5", deferred.text);
    try std.testing.expectEqual(@as(usize, 0), brain.stimulus_inbox.pendingCount());
}

test "ingested speech salience never drops below the address floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    // Repeats habituate the dual-process model; the floor must keep direct
    // address at deliberation strength anyway.
    try ingestHeardSpeech(&brain, "hello", .typed_text);
    try ingestHeardSpeech(&brain, "hello", .typed_text);
    try ingestHeardSpeech(&brain, "hello", .typed_text);
    for (brain.stimulus_inbox.entries.items) |entry| {
        try std.testing.expectEqual(stimulus_inbox_mod.Kind.heard_speech, entry.kind);
        try std.testing.expect(entry.salience >= 0.85);
    }
}

test "typing is capped as composition evidence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    try ingestTyping(&brain, "typing preview");
    try std.testing.expectEqual(@as(usize, 1), brain.stimulus_inbox.entries.items.len);
    const entry = brain.stimulus_inbox.entries.items[0];
    try std.testing.expectEqual(stimulus_inbox_mod.Kind.typing, entry.kind);
    try std.testing.expect(entry.salience <= 0.15);
}

test "pending heard speech coalesces fragments oldest first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    try ingestHeardSpeech(&brain, "first fragment", .typed_text);
    try ingestTyping(&brain, "…");
    try ingestHeardSpeech(&brain, "second fragment", .typed_text);
    const joined = (try pendingHeardSpeechCoalesced(&brain)) orelse return error.TestExpectedPendingSpeech;
    try std.testing.expectEqualStrings("first fragment\nsecond fragment", joined);
    markPendingHeardSpeechHandled(&brain);
    try std.testing.expectEqual(@as(?[]const u8, null), try pendingHeardSpeechCoalesced(&brain));
}

test "stimulus inbox observation includes stable entry ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    try ingestHeardSpeech(&brain, "tracked speech", .typed_text);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(arena.allocator());
    try appendStimulusInboxObservation(&brain, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "id=stimulus_1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "tracked speech") != null);
}
