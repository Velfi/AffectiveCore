const std = @import("std");
const brain_mod = @import("brain.zig");
const host_capability_activation = @import("host_capability_activation.zig");

const Brain = brain_mod.Brain;

pub const HostSensePullError = host_capability_activation.HostSensePullError;

pub const Request = struct {
    request_id: []const u8,
    sense: []const u8,
    purpose: []const u8,
    since_seconds: i64,
    timeout_ms: u32,
    bound_activity_id: ?[]const u8 = null,
    bound_user_text: ?[]const u8 = null,
    bound_goal: ?[]const u8 = null,
};

pub fn hostSensePullTimeoutMs(self: *Brain, sense: []const u8, purpose: []const u8) !u32 {
    return (try host_capability_activation.resolvePullTimeoutMs(self, sense, purpose)).timeout_ms;
}

fn freeBoundFields(self: *Brain, req: Request) void {
    if (req.bound_activity_id) |id| self.allocator.free(id);
    if (req.bound_user_text) |text| self.allocator.free(text);
    if (req.bound_goal) |goal| self.allocator.free(goal);
}

pub fn clear(self: *Brain) void {
    const req = self.awaited_host_request orelse return;
    self.allocator.free(req.request_id);
    self.allocator.free(req.sense);
    self.allocator.free(req.purpose);
    freeBoundFields(self, req);
    self.awaited_host_request = null;
}

pub fn set(self: *Brain, sense: []const u8, purpose: []const u8) !void {
    const decision = try host_capability_activation.resolvePullTimeoutMs(self, sense, purpose);
    clear(self);
    const request_id = if (self.current_dispatch_request_id) |id|
        try self.allocator.dupe(u8, id)
    else if (self.active_activity) |activity|
        try self.allocator.dupe(u8, activity.originating_request_id)
    else
        try std.fmt.allocPrint(self.allocator, "host_req_{d}", .{self.now_seconds});

    var bound_activity_id: ?[]const u8 = null;
    var bound_user_text: ?[]const u8 = null;
    var bound_goal: ?[]const u8 = null;
    if (self.active_activity) |activity| {
        bound_activity_id = try self.allocator.dupe(u8, activity.id);
        if (activity.kind == .conversation and activity.goal.len > 0) {
            bound_user_text = try self.allocator.dupe(u8, activity.goal);
        }
        bound_goal = try self.allocator.dupe(u8, activity.goal);
    }

    self.awaited_host_request = .{
        .request_id = request_id,
        .sense = try self.allocator.dupe(u8, sense),
        .purpose = try self.allocator.dupe(u8, purpose),
        .since_seconds = self.now_seconds,
        .timeout_ms = decision.timeout_ms,
        .bound_activity_id = bound_activity_id,
        .bound_user_text = bound_user_text,
        .bound_goal = bound_goal,
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

pub const BoundSnapshot = struct {
    request_id: []const u8,
    sense: []const u8,
    purpose: []const u8,
    bound_activity_id: ?[]const u8 = null,
    bound_user_text: ?[]const u8 = null,
    bound_goal: ?[]const u8 = null,

    pub fn capture(brain: *Brain) !?BoundSnapshot {
        const req = brain.awaited_host_request orelse return null;
        return .{
            .request_id = try brain.allocator.dupe(u8, req.request_id),
            .sense = try brain.allocator.dupe(u8, req.sense),
            .purpose = try brain.allocator.dupe(u8, req.purpose),
            .bound_activity_id = if (req.bound_activity_id) |id| try brain.allocator.dupe(u8, id) else null,
            .bound_user_text = if (req.bound_user_text) |text| try brain.allocator.dupe(u8, text) else null,
            .bound_goal = if (req.bound_goal) |goal| try brain.allocator.dupe(u8, goal) else null,
        };
    }

    pub fn deinit(self: BoundSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.sense);
        allocator.free(self.purpose);
        if (self.bound_activity_id) |id| allocator.free(id);
        if (self.bound_user_text) |text| allocator.free(text);
        if (self.bound_goal) |goal| allocator.free(goal);
    }
};

pub fn fulfillIfMatches(self: *Brain, sense: []const u8, purpose: []const u8) bool {
    if (!matches(self, sense, purpose)) return false;
    clear(self);
    return true;
}

pub fn pullRequestedObservation(self: *Brain, sense: []const u8, purpose: []const u8) ![]const u8 {
    const decision = try host_capability_activation.resolvePullTimeoutMs(self, sense, purpose);
    try set(self, sense, purpose);
    const request_id = self.awaited_host_request.?.request_id;
    return std.fmt.allocPrint(
        self.allocator,
        "host_sense_pull_requested:\n- sense: {s}\n- purpose: {s}\n- request_id: {s}\n- timeout_ms: {d}\n- host_id: {s}\n- capability: {s}\n- latency_basis_ms: {d}\n- history_basis_ms: {d}\n- host_reliability: {d:.2}\n- note: runtime may resume in a later pass when host_sense_delivered arrives.\n",
        .{
            sense,
            purpose,
            request_id,
            decision.timeout_ms,
            decision.host_id,
            decision.capability_id,
            decision.latency_basis_ms,
            decision.history_basis_ms,
            decision.reliability,
        },
    );
}
