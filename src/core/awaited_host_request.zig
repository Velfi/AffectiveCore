const std = @import("std");
const brain_mod = @import("brain.zig");

const Brain = brain_mod.Brain;

pub const HostSensePullError = error{
    UnknownHostSensePull,
};

pub const camera_recognize_timeout_ms: u32 = 15_000;
pub const camera_take_picture_timeout_ms: u32 = 12_000;
pub const orientation_sample_timeout_ms: u32 = 5_000;

pub const Request = struct {
    request_id: []const u8,
    sense: []const u8,
    purpose: []const u8,
    since_seconds: i64,
    timeout_ms: u32,
};

pub fn hostSensePullTimeoutMs(sense: []const u8, purpose: []const u8) HostSensePullError!u32 {
    if (std.mem.eql(u8, sense, "camera") and std.mem.eql(u8, purpose, "recognize")) return camera_recognize_timeout_ms;
    if (std.mem.eql(u8, sense, "camera") and std.mem.eql(u8, purpose, "take_picture")) return camera_take_picture_timeout_ms;
    if (std.mem.eql(u8, sense, "orientation") and std.mem.eql(u8, purpose, "sample")) return orientation_sample_timeout_ms;
    return error.UnknownHostSensePull;
}

pub fn clear(self: *Brain) void {
    const req = self.awaited_host_request orelse return;
    self.allocator.free(req.request_id);
    self.allocator.free(req.sense);
    self.allocator.free(req.purpose);
    self.awaited_host_request = null;
}

pub fn set(self: *Brain, sense: []const u8, purpose: []const u8) !void {
    const timeout_ms = try hostSensePullTimeoutMs(sense, purpose);
    clear(self);
    const request_id = if (self.current_dispatch_request_id) |id|
        try self.allocator.dupe(u8, id)
    else if (self.active_activity) |activity|
        try self.allocator.dupe(u8, activity.originating_request_id)
    else
        try std.fmt.allocPrint(self.allocator, "host_req_{d}", .{self.now_seconds});
    self.awaited_host_request = .{
        .request_id = request_id,
        .sense = try self.allocator.dupe(u8, sense),
        .purpose = try self.allocator.dupe(u8, purpose),
        .since_seconds = self.now_seconds,
        .timeout_ms = timeout_ms,
    };
}

pub fn active(self: *const Brain) bool {
    return self.awaited_host_request != null;
}

pub fn matches(self: *const Brain, sense: []const u8, purpose: []const u8) bool {
    const req = self.awaited_host_request orelse return false;
    return std.mem.eql(u8, req.sense, sense) and std.mem.eql(u8, req.purpose, purpose);
}

pub fn awaitingSense(self: *const Brain, sense: []const u8) bool {
    const req = self.awaited_host_request orelse return false;
    return std.mem.eql(u8, req.sense, sense);
}

pub fn fulfillIfMatches(self: *Brain, sense: []const u8, purpose: []const u8) bool {
    if (!matches(self, sense, purpose)) return false;
    clear(self);
    return true;
}

pub fn pullRequestedObservation(self: *Brain, sense: []const u8, purpose: []const u8) ![]const u8 {
    try set(self, sense, purpose);
    const request_id = self.awaited_host_request.?.request_id;
    const timeout_ms = self.awaited_host_request.?.timeout_ms;
    return std.fmt.allocPrint(
        self.allocator,
        "host_sense_pull_requested:\n- sense: {s}\n- purpose: {s}\n- request_id: {s}\n- timeout_ms: {d}\n- note: wait to speak until host_sense_delivered; you'll continue in a later pass.\n",
        .{ sense, purpose, request_id, timeout_ms },
    );
}
