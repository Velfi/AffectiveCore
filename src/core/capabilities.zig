const std = @import("std");
const brain_mod = @import("brain.zig");
const belief_updates = @import("belief_updates.zig");
const capability_registry = @import("capability_registry.zig");
const experience_kinds = @import("experience_kinds.zig");
const learning = @import("learning.zig");
const ports = @import("ports.zig");
const schema = ports.schema;

const Brain = brain_mod.Brain;

pub const CapabilityRegistry = capability_registry;

const capability_quality_delta_threshold: f32 = 0.15;

pub fn recordCapabilityStatus(self: *Brain, status: schema.CapabilityStatus) !void {
    try self.ensureHostBinding(status.host_id);
    const prior = findCapabilityStatus(self, status.capability_id, status.host_id);
    try self.deps.store.upsertCapabilityStatus(status);
    const status_event = try self.recordSimpleExperienceEvent(experience_kinds.capability_status_updated, .host, status.capability_id);
    const source_event_ids = [_][]const u8{status_event.id};
    if (prior) |previous| {
        const quality_delta = @abs(status.quality - previous.quality);
        const reliability_delta = @abs(status.reliability - previous.reliability);
        if (quality_delta >= capability_quality_delta_threshold or reliability_delta >= capability_quality_delta_threshold) {
            _ = try self.recordSimpleExperienceEvent(experience_kinds.capability_quality_changed, .host, status.capability_id);
            try belief_updates.onHostCapabilityChange(self, status, previous, &source_event_ids);
        }
    } else {
        try belief_updates.onHostCapabilityChange(self, status, null, &source_event_ids);
    }
}

pub fn recordCapabilityRequest(self: *Brain, capability_id: []const u8, input: []const u8, parents: []const []const u8) !schema.CapabilityRequest {
    const canonical_id = capability_registry.canonicalId(capability_id);
    const host_id = try self.allocator.dupe(u8, self.currentHostId());
    try self.ensureHostBinding(host_id);
    const existing_events = self.deps.store.loadExperienceEvents(self.allocator) catch &.{};
    const request: schema.CapabilityRequest = .{
        .request_id = try std.fmt.allocPrint(self.allocator, "capreq_{d}_{d}_{s}", .{ self.now_seconds * 1000, existing_events.len, canonical_id }),
        .capability_id = canonical_id,
        .host_id = host_id,
        .state = .started,
        .input = input,
        .causal_parent_ids = try cloneParents(self.allocator, parents),
        .created_at_ms = self.now_seconds * 1000,
    };
    try self.deps.store.addCapabilityRequest(request);
    _ = try self.recordSimpleExperienceEvent(experience_kinds.capability_requested, .capability, canonical_id);
    _ = try self.recordSimpleExperienceEvent(experience_kinds.capability_started, .capability, canonical_id);
    return request;
}

pub fn markMailboxRead(self: *Brain, mailbox_id: []const u8) !schema.MailboxItem {
    const read_at_ms = self.now_seconds * 1000;
    const item = try self.deps.store.markMailboxItemRead(mailbox_id, read_at_ms);
    _ = try self.recordSimpleExperienceEvent(experience_kinds.mailbox_marked_read, .host, mailbox_id);
    return item;
}

pub fn recordManifestStatuses(self: *Brain, host_id: []const u8, capability_ids: []const []const u8) !void {
    for (capability_ids) |id| {
        const canonical = capability_registry.canonicalId(id);
        try self.recordCapabilityStatus(.{
            .capability_id = canonical,
            .host_id = host_id,
            .permission = .granted,
            .availability = .available,
            .quality = 0.70,
            .reliability = 0.70,
            .updated_at_ms = self.now_seconds * 1000,
        });
    }
}

pub fn recordCapabilityResult(self: *Brain, request: schema.CapabilityRequest, state: schema.CapabilityRequestState, output: []const u8, error_message: []const u8) !schema.CapabilityResult {
    const event_kind = switch (state) {
        .completed => experience_kinds.capability_completed,
        .failed => experience_kinds.capability_failed,
        .unavailable => experience_kinds.capability_unavailable,
        .refused => experience_kinds.capability_refused,
        else => experience_kinds.capability_outcome,
    };
    const terminal_event = try self.recordSimpleExperienceEvent(event_kind, .capability, if (output.len > 0) output else error_message);
    const outcome_payload = try std.fmt.allocPrint(
        self.allocator,
        "capability={s}\nstate={s}\nterminal_event={s}",
        .{ request.capability_id, @tagName(state), terminal_event.id },
    );
    const outcome_event = try self.recordSimpleExperienceEvent(experience_kinds.capability_outcome, .capability, outcome_payload);
    const matched_outcome = try learning.findOpenActionOutcomeForCapability(self, request.capability_id);
    const linked_pressure_id = if (matched_outcome) |outcome| blk: {
        if (outcome.pressure_id.len == 0) break :blk "";
        if (try learning.actionPressureExists(self, outcome.pressure_id)) break :blk outcome.pressure_id;
        break :blk "";
    } else "";
    const result: schema.CapabilityResult = .{
        .request_id = request.request_id,
        .capability_id = request.capability_id,
        .host_id = request.host_id,
        .state = state,
        .output = output,
        .error_message = error_message,
        .outcome_event_id = outcome_event.id,
        .pressure_id = linked_pressure_id,
        .outcome_id = if (matched_outcome) |outcome| outcome.outcome_id else "",
        .completed_at_ms = self.now_seconds * 1000,
    };
    try self.deps.store.addCapabilityResult(result);
    try self.publishRuntimeLearningCapabilityRecorded(.{
        .result = result,
        .source_event_ids = request.causal_parent_ids,
        .terminal_event_id = terminal_event.id,
    }, "capabilities.record_capability_result");
    return result;
}

fn findCapabilityStatus(self: *Brain, capability_id: []const u8, host_id: []const u8) ?schema.CapabilityStatus {
    const statuses = self.deps.store.loadCapabilityStatuses(self.allocator) catch return null;
    for (statuses) |status| {
        if (std.mem.eql(u8, status.capability_id, capability_id) and std.mem.eql(u8, status.host_id, host_id)) return status;
    }
    return null;
}

fn cloneParents(allocator: std.mem.Allocator, parents: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, parents.len);
    for (parents, 0..) |parent, i| out[i] = try allocator.dupe(u8, parent);
    return out;
}
