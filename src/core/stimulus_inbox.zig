const std = @import("std");

pub const Kind = enum {
    heard_speech,
    sense_delivery,
    interrupt,
    typing,
    timer,
    emoji_reaction,
};

pub const Entry = struct {
    id: []const u8,
    kind: Kind,
    received_at_seconds: i64,
    salience: f32,
    bound_activity_id: ?[]const u8,
    payload: []const u8,
    handled: bool,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.bound_activity_id) |id| allocator.free(id);
        allocator.free(self.payload);
    }
};

pub const Inbox = struct {
    entries: std.ArrayList(Entry),
    max_entries: usize,
    next_id: u64,

    pub fn init(_: std.mem.Allocator, max_entries: usize) Inbox {
        return .{
            .entries = .empty,
            .max_entries = max_entries,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *Inbox, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
    }

    pub fn pendingCount(self: *const Inbox) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (!entry.handled) count += 1;
        }
        return count;
    }

    pub fn oldestUnhandledAgeSeconds(self: *const Inbox, now_seconds: i64) ?i64 {
        var oldest: ?i64 = null;
        for (self.entries.items) |entry| {
            if (entry.handled) continue;
            const age = @max(@as(i64, 0), now_seconds - entry.received_at_seconds);
            oldest = if (oldest) |current| @min(current, age) else age;
        }
        return oldest;
    }

    pub fn enqueue(
        self: *Inbox,
        allocator: std.mem.Allocator,
        kind: Kind,
        now_seconds: i64,
        salience: f32,
        bound_activity_id: ?[]const u8,
        payload: []const u8,
    ) !void {
        while (self.entries.items.len >= self.max_entries) {
            var dropped = self.entries.orderedRemove(0);
            dropped.deinit(allocator);
        }
        const owned_payload = try allocator.dupe(u8, payload);
        errdefer allocator.free(owned_payload);
        const owned_activity_id = if (bound_activity_id) |id| try allocator.dupe(u8, id) else null;
        errdefer if (owned_activity_id) |id| allocator.free(id);
        const id = try std.fmt.allocPrint(allocator, "stimulus_{d}", .{self.next_id});
        errdefer allocator.free(id);
        self.next_id += 1;
        try self.entries.append(allocator, .{
            .id = id,
            .kind = kind,
            .received_at_seconds = now_seconds,
            .salience = salience,
            .bound_activity_id = owned_activity_id,
            .payload = owned_payload,
            .handled = false,
        });
    }

    pub fn markAllHandled(self: *Inbox) void {
        for (self.entries.items) |*entry| entry.handled = true;
    }

    pub fn nextUnhandledIndex(self: *const Inbox) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (!entry.handled) return index;
        }
        return null;
    }

    pub fn markHandled(self: *Inbox, index: usize) void {
        if (index >= self.entries.items.len) return;
        self.entries.items[index].handled = true;
    }
};

pub fn kindLabel(kind: Kind) []const u8 {
    return switch (kind) {
        .heard_speech => "speech",
        .sense_delivery => "sense_delivery",
        .interrupt => "interrupt",
        .typing => "typing",
        .timer => "timer",
        .emoji_reaction => "emoji_reaction",
    };
}

pub fn isIngestEligibleEventType(event_type: []const u8) bool {
    return std.mem.eql(u8, event_type, "stimulus_ingest");
}

test "inbox enqueue respects max and pending count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var inbox = Inbox.init(allocator, 2);
    defer inbox.deinit(allocator);
    try inbox.enqueue(allocator, .heard_speech, 100, 0.8, null, "hello");
    try inbox.enqueue(allocator, .typing, 101, 0.2, null, "typing");
    try std.testing.expectEqual(@as(usize, 2), inbox.pendingCount());
    try std.testing.expectEqualStrings("stimulus_1", inbox.entries.items[0].id);
    try std.testing.expectEqualStrings("stimulus_2", inbox.entries.items[1].id);
    try inbox.enqueue(allocator, .interrupt, 102, 0.9, null, "stop");
    try std.testing.expectEqual(@as(usize, 2), inbox.pendingCount());
    try std.testing.expectEqualStrings("stimulus_3", inbox.entries.items[1].id);
    try std.testing.expectEqualStrings("stop", inbox.entries.items[1].payload);
}
