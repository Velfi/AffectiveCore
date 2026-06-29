const std = @import("std");
const brain_mod = @import("brain.zig");
const belief_updates = @import("belief_updates.zig");
const capabilities = @import("capabilities.zig");
const capability_registry = @import("capability_registry.zig");
const experience_kinds = @import("experience_kinds.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;

pub const HostSensePullError = error{
    UnknownHostSensePull,
};

/// Brain cold-start wait when this host has no latency sample and no activation history yet.
pub const cold_start_pull_timeout_ms: u32 = 8_000;
pub const latency_timeout_multiplier: u32 = 4;
pub const history_timeout_multiplier: u32 = 2;
pub const max_pull_timeout_ms: u32 = 60_000;
pub const activation_history_window_seconds: i64 = 7 * 24 * 60 * 60;
pub const activation_history_max_samples: usize = 24;

pub const ActivationStats = struct {
    attempt_count: usize = 0,
    completed_count: usize = 0,
    failed_count: usize = 0,
    timed_out_count: usize = 0,
    max_duration_ms: u32 = 0,
    avg_duration_ms: u32 = 0,
    last_state: ?schema.CapabilityRequestState = null,
};

pub const PullTimeoutDecision = struct {
    timeout_ms: u32,
    capability_id: []const u8,
    host_id: []const u8,
    latency_basis_ms: u32,
    history_basis_ms: u32,
    reliability: f32,
};

pub fn capabilityIdForHostSensePull(sense: []const u8, purpose: []const u8) HostSensePullError![]const u8 {
    if (std.mem.eql(u8, sense, "camera") and std.mem.eql(u8, purpose, "recognize")) return "recognize";
    if (std.mem.eql(u8, sense, "camera") and std.mem.eql(u8, purpose, "take_picture")) return "take_picture";
    if (std.mem.eql(u8, sense, "camera") and std.mem.eql(u8, purpose, "describe_image")) return "describe_image";
    if (std.mem.eql(u8, sense, "orientation") and std.mem.eql(u8, purpose, "sample")) return "request_orientation";
    return error.UnknownHostSensePull;
}

pub fn activationStats(self: *Brain, host_id: []const u8, capability_id: []const u8) !ActivationStats {
    const canonical = capability_registry.canonicalId(capability_id);
    const requests = try self.deps.store.loadCapabilityRequests(self.allocator);
    const results = try self.deps.store.loadCapabilityResults(self.allocator);
    const cutoff_ms = self.now_seconds * 1000 - activation_history_window_seconds * 1000;

    var stats: ActivationStats = .{};
    var duration_total: u64 = 0;
    var duration_count: usize = 0;

    for (results) |result| {
        if (result.completed_at_ms < cutoff_ms) continue;
        if (!std.mem.eql(u8, result.host_id, host_id)) continue;
        if (!std.mem.eql(u8, capability_registry.canonicalId(result.capability_id), canonical)) continue;

        stats.attempt_count += 1;
        stats.last_state = result.state;
        switch (result.state) {
            .completed => stats.completed_count += 1,
            .failed, .unavailable, .refused => stats.failed_count += 1,
            else => {},
        }
        if (std.mem.indexOf(u8, result.error_message, "timed_out") != null or std.mem.indexOf(u8, result.output, "timed_out") != null) {
            stats.timed_out_count += 1;
        }

        const duration_ms = requestDurationMs(requests, result.request_id, result.completed_at_ms);
        if (duration_ms > 0) {
            stats.max_duration_ms = @max(stats.max_duration_ms, duration_ms);
            duration_total += duration_ms;
            duration_count += 1;
        }
    }
    if (duration_count > 0) {
        stats.avg_duration_ms = @intCast(@divTrunc(duration_total, duration_count));
    }
    return stats;
}

fn requestDurationMs(requests: []const schema.CapabilityRequest, request_id: []const u8, completed_at_ms: i64) u32 {
    for (requests) |request| {
        if (!std.mem.eql(u8, request.request_id, request_id)) continue;
        if (completed_at_ms <= request.created_at_ms) return 0;
        const delta = completed_at_ms - request.created_at_ms;
        if (delta <= 0) return 0;
        return @intCast(@min(delta, @as(i64, max_pull_timeout_ms)));
    }
    return 0;
}

pub fn resolvePullTimeoutMs(self: *Brain, sense: []const u8, purpose: []const u8) !PullTimeoutDecision {
    const capability_id = try capabilityIdForHostSensePull(sense, purpose);
    const host_id = self.currentHostId();
    const status = findCapabilityStatus(self, host_id, capability_id);
    const stats = try activationStats(self, host_id, capability_id);

    const reliability = status.reliability;
    const latency_basis_ms: u32 = if (status.latency_ms > 0)
        @min(status.latency_ms * latency_timeout_multiplier, max_pull_timeout_ms)
    else
        cold_start_pull_timeout_ms;

    const history_basis_ms: u32 = if (stats.max_duration_ms > 0)
        @min(stats.max_duration_ms * history_timeout_multiplier, max_pull_timeout_ms)
    else
        0;

    var timeout_ms = @max(latency_basis_ms, history_basis_ms);
    if (status.updated_at_ms > 0 and reliability > 0.0 and reliability < 0.50) {
        timeout_ms = @min(@as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(timeout_ms)) * 1.25))), max_pull_timeout_ms);
    }

    return .{
        .timeout_ms = timeout_ms,
        .capability_id = capability_id,
        .host_id = host_id,
        .latency_basis_ms = latency_basis_ms,
        .history_basis_ms = history_basis_ms,
        .reliability = reliability,
    };
}

pub fn recordCapabilityActivationOutcome(self: *Brain, result: schema.CapabilityResult) !void {
    const requests = try self.deps.store.loadCapabilityRequests(self.allocator);
    const duration_ms = requestDurationMs(requests, result.request_id, result.completed_at_ms);
    if (result.state == .completed and duration_ms > 0) {
        try maybeRefreshObservedLatency(self, result.host_id, result.capability_id, duration_ms);
    }
    if (result.state == .completed and !isHostPullCapability(result.capability_id)) return;
    try recordActivationOutcome(
        self,
        result.host_id,
        result.capability_id,
        result.state,
        duration_ms,
        if (result.output.len > 0) result.output else result.error_message,
        result.outcome_event_id,
    );
}

pub fn recordHostSensePullOutcome(
    self: *Brain,
    sense: []const u8,
    purpose: []const u8,
    status: []const u8,
    detail: []const u8,
    elapsed_ms: u32,
) !void {
    const capability_id = capabilityIdForHostSensePull(sense, purpose) catch return;
    const state: schema.CapabilityRequestState = if (std.mem.eql(u8, status, "timed_out"))
        .failed
    else if (std.mem.eql(u8, status, "available") or std.mem.eql(u8, status, "completed"))
        .completed
    else
        .failed;
    const event = try self.recordSimpleExperienceEvent(experience_kinds.capability_outcome, .host, detail);
    try recordActivationOutcome(self, self.currentHostId(), capability_id, state, elapsed_ms, detail, event.id);
}

pub fn appendActivationObservationIfChanged(self: *Brain, out: *std.ArrayList(u8)) !void {
    const host_id = self.currentHostId();
    if (host_id.len == 0) return;

    const results = try self.deps.store.loadCapabilityResults(self.allocator);
    const cutoff_ms = self.now_seconds * 1000 - activation_history_window_seconds * 1000;
    var digest = std.ArrayList(u8).empty;
    defer digest.deinit(self.allocator);

    var seen_capabilities = std.ArrayList([]const u8).empty;
    defer seen_capabilities.deinit(self.allocator);

    for (results) |result| {
        if (result.completed_at_ms < cutoff_ms) continue;
        if (!std.mem.eql(u8, result.host_id, host_id)) continue;
        const canonical = capability_registry.canonicalId(result.capability_id);
        var duplicate = false;
        for (seen_capabilities.items) |existing| {
            if (std.mem.eql(u8, existing, canonical)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        try seen_capabilities.append(self.allocator, canonical);
        const stats = try activationStats(self, host_id, canonical);
        const line = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{d}/{d} ok avg={d}ms max={d}ms timeouts={d} last={s};",
            .{
                canonical,
                stats.completed_count,
                stats.attempt_count,
                stats.avg_duration_ms,
                stats.max_duration_ms,
                stats.timed_out_count,
                if (stats.last_state) |state| @tagName(state) else "none",
            },
        );
        defer self.allocator.free(line);
        try digest.appendSlice(self.allocator, line);
    }

    const digest_text = try digest.toOwnedSlice(self.allocator);
    defer self.allocator.free(digest_text);
    if (digest_text.len == 0) return;

    if (self.last_host_activation_digest) |previous| {
        if (std.mem.eql(u8, previous, digest_text)) return;
        self.allocator.free(previous);
    }
    self.last_host_activation_digest = try self.allocator.dupe(u8, digest_text);

    try out.print(
        self.allocator,
        "host_capability_activations:\n- host_id: {s}\n- digest: {s}\n- note: keyed by host; surprises vs this history shape expectations.\n",
        .{ host_id, digest_text },
    );
}

fn recordActivationOutcome(
    self: *Brain,
    host_id: []const u8,
    capability_id: []const u8,
    state: schema.CapabilityRequestState,
    duration_ms: u32,
    detail: []const u8,
    source_event_id: []const u8,
) !void {
    const stats = try activationStats(self, host_id, capability_id);
    const source_event_ids = if (source_event_id.len > 0) &[_][]const u8{source_event_id} else &.{};
    try belief_updates.onHostCapabilityActivation(
        self,
        host_id,
        capability_id,
        state,
        duration_ms,
        stats,
        detail,
        source_event_ids,
    );
}

fn maybeRefreshObservedLatency(self: *Brain, host_id: []const u8, capability_id: []const u8, duration_ms: u32) !void {
    const status = findCapabilityStatus(self, host_id, capability_id);
    const updated_latency = if (status.latency_ms > 0)
        @divTrunc(status.latency_ms + duration_ms, 2)
    else
        duration_ms;
    if (updated_latency == status.latency_ms) return;
    try capabilities.recordCapabilityStatus(self, .{
        .capability_id = capability_id,
        .host_id = host_id,
        .permission = status.permission,
        .availability = status.availability,
        .quality = status.quality,
        .reliability = status.reliability,
        .cost = status.cost,
        .latency_ms = updated_latency,
        .risk = status.risk,
        .unavailable_reason = status.unavailable_reason,
        .updated_at_ms = self.now_seconds * 1000,
    });
}

fn findCapabilityStatus(self: *Brain, host_id: []const u8, capability_id: []const u8) schema.CapabilityStatus {
    const canonical = capability_registry.canonicalId(capability_id);
    const statuses = self.deps.store.loadCapabilityStatuses(self.allocator) catch return defaultCapabilityStatus(host_id, capability_id);
    for (statuses) |status| {
        if (std.mem.eql(u8, status.host_id, host_id) and std.mem.eql(u8, capability_registry.canonicalId(status.capability_id), canonical)) {
            return status;
        }
    }
    return defaultCapabilityStatus(host_id, capability_id);
}

fn isHostPullCapability(capability_id: []const u8) bool {
    const canonical = capability_registry.canonicalId(capability_id);
    return std.mem.eql(u8, canonical, "recognize")
        or std.mem.eql(u8, canonical, "take_picture")
        or std.mem.eql(u8, canonical, "request_orientation");
}

fn defaultCapabilityStatus(host_id: []const u8, capability_id: []const u8) schema.CapabilityStatus {
    return .{
        .capability_id = capability_id,
        .host_id = host_id,
        .permission = .unknown,
        .availability = .unavailable,
        .quality = 0.0,
        .reliability = 0.0,
        .latency_ms = 0,
        .updated_at_ms = 0,
    };
}

test "resolve pull timeout uses host latency when known" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var store = @import("brain_test_store.zig").TestStore.init(allocator);
    var desc = @import("ports.zig").openai.TestDescriptionService{};
    var brain = @import("brain_test_support.zig").makeBrain(allocator, "fixtures/visitors/known_01.jpg", &.{}, &store, &desc);
    const host_id = brain.currentHostId();
    try brain.recordCapabilityStatus(.{
        .capability_id = "recognize",
        .host_id = host_id,
        .permission = .granted,
        .availability = .available,
        .quality = 0.8,
        .reliability = 0.8,
        .latency_ms = 2_000,
        .updated_at_ms = brain.now_seconds * 1000,
    });
    const decision = try resolvePullTimeoutMs(&brain, "camera", "recognize");
    try std.testing.expectEqual(@as(u32, 8_000), decision.timeout_ms);
}
