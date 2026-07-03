const std = @import("std");

pub const CompletionStatus = enum {
    complete,
    failed,
};

pub const Completion = struct {
    status: CompletionStatus,
    data: ?[]u8 = null,
    error_message: ?[]u8 = null,

    pub fn deinit(self: Completion, allocator: std.mem.Allocator) void {
        if (self.data) |data| allocator.free(data);
        if (self.error_message) |message| allocator.free(message);
    }
};

pub const Channel = struct {
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    entries: std.StringHashMap(*Entry),

    pub fn init(allocator: std.mem.Allocator) Channel {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(*Entry).init(allocator),
        };
    }

    pub fn deinit(self: *Channel, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn complete(self: *Channel, io: std.Io, request_id: []const u8, data: []const u8) !void {
        try self.store(io, request_id, .{
            .status = .complete,
            .data = try self.allocator.dupe(u8, data),
        });
    }

    pub fn fail(self: *Channel, io: std.Io, request_id: []const u8, message: []const u8) !void {
        try self.store(io, request_id, .{
            .status = .failed,
            .error_message = try self.allocator.dupe(u8, message),
        });
    }

    pub fn wait(self: *Channel, io: std.Io, request_id: []const u8, timeout: std.Io.Timeout) !Completion {
        try self.mutex.lock(io);
        const entry = try self.entryForLocked(request_id);
        self.mutex.unlock(io);

        try entry.event.waitTimeout(io, timeout);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const removed = self.entries.fetchRemove(request_id) orelse return error.MissingCompletionEntry;
        defer self.allocator.free(removed.key);
        defer self.allocator.destroy(removed.value);
        const completion = removed.value.completion orelse return error.MissingCompletionResult;
        removed.value.completion = null;
        return completion;
    }

    fn entryForLocked(self: *Channel, request_id: []const u8) !*Entry {
        const found = try self.entries.getOrPut(request_id);
        if (found.found_existing) return found.value_ptr.*;
        errdefer _ = self.entries.remove(request_id);
        const owned_key = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(owned_key);
        const entry = try self.allocator.create(Entry);
        entry.* = .{};
        found.key_ptr.* = owned_key;
        found.value_ptr.* = entry;
        return entry;
    }

    fn store(self: *Channel, io: std.Io, request_id: []const u8, completion: Completion) !void {
        errdefer completion.deinit(self.allocator);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const entry = try self.entryForLocked(request_id);
        if (entry.completion) |previous| {
            previous.deinit(self.allocator);
        }
        entry.completion = completion;
        entry.event.set(io);
    }
};

const Entry = struct {
    event: std.Io.Event = .unset,
    completion: ?Completion = null,

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.completion) |completion| completion.deinit(allocator);
        self.completion = null;
    }
};

fn testTimeout(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(ms), .clock = .awake } };
}

test "completion channel returns completed result by request id" {
    const allocator = std.testing.allocator;
    var io_threaded = std.Io.Threaded.init_single_threaded;
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var channel = Channel.init(allocator);
    defer channel.deinit(io);

    try channel.complete(io, "req-1", "{\"ok\":true}");
    const completion = try channel.wait(io, "req-1", testTimeout(10));
    defer completion.deinit(allocator);
    try std.testing.expectEqual(CompletionStatus.complete, completion.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", completion.data.?);
}

test "completion channel replaces duplicate request id loudly with latest result" {
    const allocator = std.testing.allocator;
    var io_threaded = std.Io.Threaded.init_single_threaded;
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var channel = Channel.init(allocator);
    defer channel.deinit(io);

    try channel.fail(io, "req-1", "first");
    try channel.complete(io, "req-1", "second");
    const completion = try channel.wait(io, "req-1", testTimeout(10));
    defer completion.deinit(allocator);
    try std.testing.expectEqual(CompletionStatus.complete, completion.status);
    try std.testing.expectEqualStrings("second", completion.data.?);
}

test "completion channel wait times out" {
    const allocator = std.testing.allocator;
    var io_threaded = std.Io.Threaded.init_single_threaded;
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var channel = Channel.init(allocator);
    defer channel.deinit(io);

    try std.testing.expectError(error.Timeout, channel.wait(io, "missing", testTimeout(1)));
}
