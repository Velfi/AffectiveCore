const std = @import("std");
const brain_mod = @import("brain.zig");
const read_models = @import("read_models.zig");

const Brain = brain_mod.Brain;

pub const WorkTicket = enum {
    foreground_chat,
    host_follow_up,
    process_advance,
    cotext_integrate,
    coalesce_hold,
    hold,
};

/// True while the user still seems to be composing the next fragment: a
/// typing signal arrived within the quiescence window while speech is
/// pending. Only typing holds — a lone message without typing evidence gets
/// an immediate turn, because nothing re-drives the scheduler at window
/// expiry. Bounded by the max-wait cap measured from the oldest unanswered
/// fragment so the brain always responds even if typing never goes quiet.
pub fn coalesceWindowOpen(self: *Brain) bool {
    const quiescence: i64 = @intCast(self.cfg.stimulus_quiescence_seconds);
    const max_wait: i64 = @intCast(self.cfg.stimulus_coalesce_max_wait_seconds);
    var newest_typing_at: ?i64 = null;
    var oldest_speech_at: ?i64 = null;
    for (self.stimulus_inbox.entries.items) |entry| {
        if (entry.handled) continue;
        switch (entry.kind) {
            .typing => {
                newest_typing_at = @max(newest_typing_at orelse entry.received_at_seconds, entry.received_at_seconds);
            },
            .heard_speech => {
                oldest_speech_at = @min(oldest_speech_at orelse entry.received_at_seconds, entry.received_at_seconds);
            },
            else => {},
        }
    }
    const typing_at = newest_typing_at orelse return false;
    const speech_at = oldest_speech_at orelse return false;
    if (self.now_seconds - speech_at >= max_wait) return false;
    return self.now_seconds - typing_at < quiescence;
}

pub fn chooseNextWork(self: *Brain) WorkTicket {
    const inbox_pending = self.stimulus_inbox.pendingCount();
    const snapshot = read_models.readModelsSnapshot(self, self.allocator) catch {
        return if (inbox_pending > 0) .foreground_chat else .hold;
    };

    if (self.awaitedHostRequestActive()) {
        for (self.stimulus_inbox.entries.items) |entry| {
            if (entry.handled) continue;
            if (entry.kind == .sense_delivery) return .host_follow_up;
        }
        return .host_follow_up;
    }

    if (self.active_process != null) {
        for (self.stimulus_inbox.entries.items) |entry| {
            if (entry.handled) continue;
            if (entry.kind == .heard_speech and entry.salience >= 0.80) {
                return if (coalesceWindowOpen(self)) .coalesce_hold else .foreground_chat;
            }
        }
        return .process_advance;
    }

    if (inbox_pending > 0) {
        var has_speech = false;
        var has_high_salience = false;
        var urgent = false;
        for (self.stimulus_inbox.entries.items) |entry| {
            if (entry.handled) continue;
            if (entry.kind == .heard_speech) has_speech = true;
            if (entry.kind != .typing and entry.salience >= 0.75) has_high_salience = true;
            if (entry.kind != .heard_speech and entry.kind != .typing and entry.salience >= 0.90) urgent = true;
        }
        if (has_speech and !urgent and coalesceWindowOpen(self)) return .coalesce_hold;
        if (has_speech or has_high_salience) return .foreground_chat;
        if (snapshot.capacity_model.under_pressure) return .hold;
        return .cotext_integrate;
    }

    if (self.pending_deferred_heard_speech != null) return .foreground_chat;
    return .hold;
}

pub fn shouldRunFullChatPass(self: *Brain, stimulus_kind: @import("port_chat.zig").StimulusKind) bool {
    const ticket = chooseNextWork(self);
    return switch (ticket) {
        .foreground_chat, .host_follow_up, .process_advance => true,
        .cotext_integrate => stimulus_kind != .host_sense_delivery,
        .coalesce_hold, .hold => false,
    };
}

pub fn deprioritizeLowMaterialityEcho(_: *Brain, user_text: []const u8, say_text: []const u8) bool {
    _ = user_text;
    _ = say_text;
    return false;
}

test "scheduler prefers speech over cotext when inbox has speech" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    try brain.stimulus_inbox.enqueue(arena.allocator(), .heard_speech, brain.now_seconds, 0.85, null, "Do you recognize me?");
    try std.testing.expectEqual(WorkTicket.foreground_chat, chooseNextWork(&brain));
}

test "scheduler holds a burst while typing evidence is fresh" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    brain.now_seconds = 1000;
    try brain.stimulus_inbox.enqueue(arena.allocator(), .heard_speech, 999, 0.85, null, "so I was thinking");
    try brain.stimulus_inbox.enqueue(arena.allocator(), .typing, 1000, 0.15, null, "…");
    try std.testing.expectEqual(WorkTicket.coalesce_hold, chooseNextWork(&brain));
}

test "scheduler opens the turn once typing goes quiet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    brain.now_seconds = 1000;
    try brain.stimulus_inbox.enqueue(arena.allocator(), .heard_speech, 995, 0.85, null, "so I was thinking");
    try brain.stimulus_inbox.enqueue(arena.allocator(), .heard_speech, 996, 0.85, null, "about the garden");
    try brain.stimulus_inbox.enqueue(arena.allocator(), .typing, 996, 0.15, null, "…");
    try std.testing.expectEqual(WorkTicket.foreground_chat, chooseNextWork(&brain));
}

test "lone speech without typing evidence gets an immediate turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    brain.now_seconds = 1000;
    try brain.stimulus_inbox.enqueue(arena.allocator(), .heard_speech, 1000, 0.85, null, "hello?");
    try std.testing.expectEqual(WorkTicket.foreground_chat, chooseNextWork(&brain));
}

test "max wait caps coalescing even with fresh typing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    brain.now_seconds = 1000;
    try brain.stimulus_inbox.enqueue(arena.allocator(), .heard_speech, 990, 0.85, null, "oldest unanswered fragment");
    try brain.stimulus_inbox.enqueue(arena.allocator(), .typing, 1000, 0.15, null, "…");
    try std.testing.expectEqual(WorkTicket.foreground_chat, chooseNextWork(&brain));
}

test "urgent stimulus skips the coalesce window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const support = @import("brain_test_support.zig");
    var store = @import("brain_test_store.zig").TestStore.init(arena.allocator());
    var desc = @import("../api/openai_client.zig").TestDescriptionService{};
    var brain = support.makeBrain(arena.allocator(), "img.jpg", &.{}, &store, &desc);
    brain.now_seconds = 1000;
    try brain.stimulus_inbox.enqueue(arena.allocator(), .heard_speech, 999, 0.85, null, "wait");
    try brain.stimulus_inbox.enqueue(arena.allocator(), .typing, 1000, 0.15, null, "…");
    try brain.stimulus_inbox.enqueue(arena.allocator(), .interrupt, 1000, 0.95, null, "reason=user_interrupt");
    try std.testing.expectEqual(WorkTicket.foreground_chat, chooseNextWork(&brain));
}
