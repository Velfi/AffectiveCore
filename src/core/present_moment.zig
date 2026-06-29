const std = @import("std");
const brain_mod = @import("brain.zig");
const activity_mod = @import("activity.zig");
const ports = @import("ports.zig");
const awaited_host_request_mod = @import("awaited_host_request.zig");
const context_tier = @import("context_tier.zig");

const Brain = brain_mod.Brain;

pub const contact_window_seconds: i64 = 90;
pub const thread_window_seconds: i64 = 60;
pub const contact_open_summary_cap: usize = 2;

pub const DeliveryRelevance = enum {
    high,
    medium,
    low,
    stale,
};

pub const DeliveryMateriality = enum {
    high,
    low,
};

pub const RequestOverlap = struct {
    in_flight_kind: []const u8,
    confidence: f32,
};

pub const DeliveryAssessment = struct {
    relevance: DeliveryRelevance,
    materiality: DeliveryMateriality,
    bound_user_text: ?[]const u8,
};

pub fn contactWindowOpen(brain: *Brain) bool {
    const now = brain.now_seconds;
    if (brain.awaited_host_request != null) return true;
    if (brain.last_conversation_turn_seconds) |t| {
        if (now - t < contact_window_seconds) return true;
    }
    const active = brain.active_activity orelse return false;
    if (active.state.last_spoken_text != null and now - active.updated_at_seconds < contact_window_seconds) return true;
    if (active.kind == .conversation and now - active.updated_at_seconds < contact_window_seconds) return true;
    return false;
}

pub fn conversationSummaryCap(brain: *Brain) usize {
    if (contactWindowOpen(brain)) {
        return context_tier.effectiveConversationSummaryCap(true, brain.cfg.capacity.conversation_summaries_in_context_max, brain.last_conversation_effort_tier);
    }
    return context_tier.effectiveConversationSummaryCap(false, brain.cfg.capacity.conversation_summaries_in_context_max, brain.last_conversation_effort_tier);
}

fn lastUserText(brain: *Brain) ?[]const u8 {
    const active = brain.active_activity orelse return null;
    if (active.kind == .conversation and active.goal.len > 0) return active.goal;
    return null;
}

fn lastSpokenText(brain: *Brain) ?[]const u8 {
    const active = brain.active_activity orelse return null;
    return active.state.last_spoken_text;
}

fn secondsAgo(now: i64, at: i64) i64 {
    return @max(@as(i64, 0), now - at);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |needle_ch, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle_ch)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn asksIdentity(text: []const u8) bool {
    if (containsIgnoreCase(text, "who am i")) return true;
    if (containsIgnoreCase(text, "do you know me")) return true;
    if (containsIgnoreCase(text, "recognize me")) return true;
    if (containsIgnoreCase(text, "who is this")) return true;
    if (containsIgnoreCase(text, "see who")) return true;
    if (containsIgnoreCase(text, "can you see me")) return true;
    return false;
}

const recognize_keywords = [_][]const u8{ "see", "look", "recognize", "recognise", "who am", "who is", "know me", "see me", "see who" };

pub fn detectRequestOverlap(brain: *Brain, user_text: []const u8) ?RequestOverlap {
    const req = brain.awaited_host_request orelse return null;
    const trimmed = std.mem.trim(u8, user_text, " \r\n\t");
    if (trimmed.len == 0) return null;

    if (std.mem.eql(u8, req.purpose, "recognize")) {
        for (recognize_keywords) |kw| {
            if (containsIgnoreCase(trimmed, kw)) {
                return .{ .in_flight_kind = "recognize", .confidence = 0.82 };
            }
        }
        if (brain.active_activity) |active| {
            if (textsShareTopic(trimmed, active.goal)) {
                return .{ .in_flight_kind = "recognize", .confidence = 0.55 };
            }
        }
    }
    if (std.mem.eql(u8, req.purpose, "take_picture")) {
        if (containsIgnoreCase(trimmed, "picture") or containsIgnoreCase(trimmed, "photo")) {
            return .{ .in_flight_kind = "take_picture", .confidence = 0.75 };
        }
    }
    return null;
}

pub fn scoreDeliveryRelevance(brain: *Brain, bound_activity_id: ?[]const u8) DeliveryRelevance {
    const req = brain.awaited_host_request orelse {
        if (bound_activity_id == null) return .stale;
        const active = brain.active_activity orelse return .stale;
        if (bound_activity_id) |id| {
            if (!std.mem.eql(u8, id, active.id)) return .stale;
        }
        return .medium;
    };
    _ = req;
    const active = brain.active_activity orelse return .low;
    if (bound_activity_id) |id| {
        if (!std.mem.eql(u8, id, active.id)) return .stale;
    }
    if (brain.last_conversation_turn_seconds) |t| {
        const idle = brain.now_seconds - t;
        if (idle > contact_window_seconds * 2) return .medium;
    }
    return .high;
}

pub fn scoreDeliveryMateriality(delivered_line: []const u8, bound_user_text: ?[]const u8) DeliveryMateriality {
    if (bound_user_text) |text| {
        if (asksIdentity(text)) return .high;
    }
    if (std.mem.indexOf(u8, delivered_line, "interpretation=face_known") != null or
        std.mem.indexOf(u8, delivered_line, "Current speaker recognition: known") != null or
        std.mem.indexOf(u8, delivered_line, "Current speaker recognition: soft_matched") != null)
    {
        return .high;
    }
    if (std.mem.indexOf(u8, delivered_line, "interpretation=face_unmatched") != null or
        std.mem.indexOf(u8, delivered_line, "Current speaker recognition: unknown") != null or
        std.mem.indexOf(u8, delivered_line, "interpretation=no_face_in_frame") != null)
    {
        return .low;
    }
    return .low;
}

pub fn assessHostDelivery(brain: *Brain, delivered_line: []const u8, bind: ?awaited_host_request_mod.BoundSnapshot) DeliveryAssessment {
    const bound_user = if (bind) |b| b.bound_user_text else if (brain.awaited_host_request) |req| req.bound_user_text else null;
    const bound_activity = if (bind) |b| b.bound_activity_id else if (brain.awaited_host_request) |req| req.bound_activity_id else null;
    return .{
        .relevance = scoreDeliveryRelevance(brain, bound_activity),
        .materiality = scoreDeliveryMateriality(delivered_line, bound_user),
        .bound_user_text = bound_user,
    };
}

pub fn shouldDeliberateAfterHostDelivery(brain: *Brain, assessment: DeliveryAssessment) bool {
    if (assessment.relevance == .stale or assessment.relevance == .low) return false;
    if (brain.active_activity) |active| {
        if (active.kind != .conversation) {
            return assessment.relevance == .high or assessment.relevance == .medium;
        }
    }
    return assessment.materiality == .high;
}

pub fn appendObservation(
    brain: *Brain,
    out: *std.ArrayList(u8),
    user_text: ?[]const u8,
    overlap: ?RequestOverlap,
) !void {
    const now = brain.now_seconds;
    const user = user_text orelse lastUserText(brain);
    const spoken = lastSpokenText(brain);
    const contact_open = contactWindowOpen(brain);

    try out.appendSlice(brain.allocator, "present_moment:\n");
    try out.appendSlice(brain.allocator, "  contact:\n");
    if (user) |text| {
        const age = if (brain.last_conversation_turn_seconds) |t| secondsAgo(now, t) else if (brain.active_activity) |a| secondsAgo(now, a.updated_at_seconds) else 0;
        try out.print(brain.allocator, "    last_user: \"{s}\" ({d}s ago)\n", .{ text, age });
    } else {
        try out.appendSlice(brain.allocator, "    last_user: none\n");
    }
    if (spoken) |text| {
        const age = if (brain.active_activity) |a| secondsAgo(now, a.updated_at_seconds) else 0;
        try out.print(brain.allocator, "    you_said: \"{s}\" ({d}s ago)\n", .{ text, age });
    } else {
        try out.appendSlice(brain.allocator, "    you_said: none\n");
    }
    try out.print(brain.allocator, "    contact_window: {s}\n", .{if (contact_open) "open" else "closed"});

    if (brain.current_focus) |focus| {
        try out.appendSlice(brain.allocator, "  attention:\n");
        try out.print(brain.allocator, "    focus: \"{s}\" ({s})\n", .{ focus.text, @tagName(focus.source) });
    }
    if (brain.active_activity) |active| {
        try out.print(
            brain.allocator,
            "    activity: {s} / \"{s}\" / {s}\n",
            .{ @tagName(active.kind), active.goal, activity_mod.statusTag(active.status) },
        );
    }

    try appendThreadEvents(brain, out);
    try appendInFlight(brain, out);

    if (overlap) |o| {
        try out.print(
            brain.allocator,
            "  user_request_overlap: {s} (confidence {d:.2})\n",
            .{ o.in_flight_kind, o.confidence },
        );
    }
}

pub fn appendDeferredCoherenceObservation(
    brain: *Brain,
    out: *std.ArrayList(u8),
    delivered_line: []const u8,
    assessment: DeliveryAssessment,
    bind: ?awaited_host_request_mod.BoundSnapshot,
) !void {
    try out.appendSlice(brain.allocator, "deferred_coherence:\n");
    if (bind) |snapshot| {
        try out.print(
            brain.allocator,
            "- bound_request: {s}/{s} for \"{s}\"\n",
            .{
                snapshot.sense,
                snapshot.purpose,
                snapshot.bound_user_text orelse snapshot.bound_goal orelse "unknown",
            },
        );
    } else if (brain.awaited_host_request) |req| {
        try out.print(
            brain.allocator,
            "- bound_request: {s}/{s} for \"{s}\"\n",
            .{
                req.sense,
                req.purpose,
                req.bound_user_text orelse req.bound_goal orelse "unknown",
            },
        );
    }
    try out.print(brain.allocator, "- delivery_relevance: {s}\n", .{@tagName(assessment.relevance)});
    try out.print(brain.allocator, "- delivery_materiality: {s}\n", .{@tagName(assessment.materiality)});
    const snippet = if (delivered_line.len > 160) delivered_line[0..160] else delivered_line;
    try out.print(brain.allocator, "- delivery: {s}\n", .{snippet});
    if (assessment.relevance == .high and assessment.materiality == .low) {
        try out.appendSlice(brain.allocator, "- note: integrate into the contact thread; speech is optional unless identity changes what you'd say.\n");
    }
}

fn appendThreadEvents(brain: *Brain, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(brain.allocator, "  thread (last 60s):\n");
    var count: usize = 0;
    const now = brain.now_seconds;
    if (brain.active_activity) |active| {
        var i: isize = @intCast(active.timeline.len);
        while (i > 0 and count < 8) {
            i -= 1;
            const event = active.timeline[@intCast(i)];
            if (now - event.at_seconds > thread_window_seconds) continue;
            try out.print(brain.allocator, "    - {s}: {s}\n", .{ @tagName(event.kind), event.body });
            count += 1;
        }
    }
    const events = brain.deps.store.loadExperienceEvents(brain.allocator) catch {
        if (count == 0) try out.appendSlice(brain.allocator, "    - none\n");
        return;
    };
    var idx: isize = @intCast(events.len);
    while (idx > 0 and count < 12) {
        idx -= 1;
        const event = events[@intCast(idx)];
        const age_seconds = @max(@as(i64, 0), @divFloor(now * 1000 - event.timestamp_ms, 1000));
        if (age_seconds > thread_window_seconds) continue;
        try out.print(brain.allocator, "    - [{s}] ({d}s ago) {s}\n", .{ event.kind, age_seconds, truncatePayload(event.payload) });
        count += 1;
    }
    if (count == 0) try out.appendSlice(brain.allocator, "    - none\n");
}

fn appendInFlight(brain: *Brain, out: *std.ArrayList(u8)) !void {
    if (brain.awaited_host_request) |req| {
        const since = secondsAgo(brain.now_seconds, req.since_seconds);
        try out.print(
            brain.allocator,
            "  in_flight:\n    - {s} {s} {d}s for \"{s}\"\n",
            .{
                req.purpose,
                req.sense,
                since,
                req.bound_user_text orelse req.bound_goal orelse "",
            },
        );
    }
}

fn truncatePayload(payload: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len <= 120) return trimmed;
    return trimmed[0..120];
}

fn textsShareTopic(a: []const u8, b: []const u8) bool {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    const wa = firstWord(a, &buf_a);
    const wb = firstWord(b, &buf_b);
    if (wa.len >= 3 and wb.len >= 3 and std.ascii.eqlIgnoreCase(wa, wb)) return true;
    return false;
}

fn firstWord(text: []const u8, buf: *[64]u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n\"");
    var len: usize = 0;
    for (trimmed) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) break;
        if (len >= buf.len) break;
        buf[len] = std.ascii.toLower(ch);
        len += 1;
    }
    return buf[0..len];
}

test "contact window open when awaited host request pending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_store.zig").TestStore.init(allocator);
    var desc = @import("ports.zig").openai.TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try brain.setAwaitedHostRequest("camera", "recognize");
    try std.testing.expect(contactWindowOpen(&brain));
}

test "detect recognize overlap from user text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_store.zig").TestStore.init(allocator);
    var desc = @import("ports.zig").openai.TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try @import("brain_process.zig").ensureActiveActivity(&brain, "Hello", "req_test", .user_speech);
    try brain.setAwaitedHostRequest("camera", "recognize");
    const overlap = detectRequestOverlap(&brain, "Can you see who I am?");
    try std.testing.expect(overlap != null);
    try std.testing.expectEqualStrings("recognize", overlap.?.in_flight_kind);
}

test "unknown face after hello is low materiality" {
    const line = "Current speaker recognition: unknown; name=unknown; person_id=none; interpretation=face_unmatched.\n";
    try std.testing.expect(scoreDeliveryMateriality(line, "Hello Geisha") == .low);
}

test "matched identity is high materiality when user asked" {
    const line = "Current speaker recognition: known; name=Mara\n";
    try std.testing.expect(scoreDeliveryMateriality(line, "Do you know who I am?") == .high);
}

test "deferred coherence observation uses bound snapshot after fulfill clears awaited" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_store.zig").TestStore.init(allocator);
    var desc = @import("ports.zig").openai.TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    try @import("brain_process.zig").ensureActiveActivity(&brain, "Hello Geisha", "req_test", .user_speech);
    try brain.setAwaitedHostRequest("camera", "recognize");
    const bind = try awaited_host_request_mod.BoundSnapshot.capture(&brain);
    defer if (bind) |snapshot| snapshot.deinit(allocator);
    _ = brain.fulfillAwaitedHostRequestIfMatches("camera", "recognize");
    try std.testing.expect(!brain.awaitedHostRequestActive());

    const delivered = "Current speaker recognition: unknown; interpretation=face_unmatched.\n";
    const assessment = assessHostDelivery(&brain, delivered, bind);
    var observations = std.ArrayList(u8).empty;
    defer observations.deinit(allocator);
    try appendDeferredCoherenceObservation(&brain, &observations, delivered, assessment, bind);
    try std.testing.expect(std.mem.indexOf(u8, observations.items, "bound_request: camera/recognize for \"Hello Geisha\"") != null);
}
