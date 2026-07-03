const std = @import("std");
const brain_mod = @import("brain.zig");
const read_models = @import("read_models.zig");
const cognitive_capacity = @import("cognitive_capacity.zig");
const json_store_cognitive = @import("../storage/json_store_cognitive.zig");
const llm_voice = @import("llm_voice.zig");

const Brain = brain_mod.Brain;

pub fn clearPendingUserInterruptCoalesce(self: *Brain) void {
    if (self.pending_user_interrupt_coalesce) |text| {
        self.allocator.free(text);
        self.pending_user_interrupt_coalesce = null;
    }
}

pub fn appendPendingUserInterruptCoalesceObservation(self: *Brain, observations: *std.ArrayList(u8)) !void {
    const coalesce = self.pending_user_interrupt_coalesce orelse return;
    try observations.appendSlice(self.allocator, coalesce);
    try observations.appendSlice(self.allocator, "\n");
    clearPendingUserInterruptCoalesce(self);
}

pub fn appendHostSenseDeliveredObservation(self: *Brain, observations: *std.ArrayList(u8), delivered_line: []const u8) !void {
    try observations.appendSlice(
        self.allocator,
        "host_sense_delivered:\n- note: host fulfilled a pending pull sense; integrate with present_moment contact.\n",
    );
    try observations.appendSlice(self.allocator, delivered_line);
}

pub fn appendSocialContextObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const timeout: i64 = @intCast(self.cfg.conversation_idle_timeout_seconds);
    const since_turn: i64 = if (self.last_conversation_turn_seconds) |t| @max(0, self.now_seconds - t) else -1;
    const since_visual: i64 = if (self.last_visual_update_seconds) |t| @max(0, self.now_seconds - t) else -1;
    const already_in_conversation = since_turn >= 0 and since_turn <= timeout;
    try out.print(
        self.allocator,
        "social_context:\n- already_in_conversation: {any}\n- seconds_since_last_turn: {d}\n- seconds_since_last_visual: {d}\n- camera_pullable: {any}\n- note: if you were not already in a conversation, someone is now beginning to interact with you. recognize pulls the camera as a non-blocking awaited observation; choose to look, wait for it, or just respond based on what already matters.\n",
        .{ already_in_conversation, since_turn, since_visual, self.deps.capabilities.live_camera },
    );
}

pub fn appendReadModelsObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const snapshot = try read_models.readModelsSnapshot(self, self.allocator);
    const brain_mode_line = try llm_voice.formatBrainMode(self.allocator, @tagName(snapshot.brain_mode));
    defer self.allocator.free(brain_mode_line);
    const salient_belief = if (snapshot.belief_model.salient) |belief|
        try std.fmt.allocPrint(self.allocator, "What looms largest: {s}.", .{belief.proposition})
    else
        try self.allocator.dupe(u8, llm_voice.empty_inner_state);
    defer self.allocator.free(salient_belief);
    const self_trust_text = if (snapshot.self_trust_model.strongest) |entry|
        try std.fmt.allocPrint(self.allocator, "I trust my {s} faculty at about {d:.0}% right now.", .{ entry.faculty, entry.confidence * 100.0 })
    else
        try self.allocator.dupe(u8, "No faculty feels especially trustworthy to me right now.");
    defer self.allocator.free(self_trust_text);
    const disposition = if (snapshot.disposition_model.strongest) |entry|
        try std.fmt.allocPrint(self.allocator, "My strongest pull is to {s}.", .{entry.action_tendency})
    else
        try self.allocator.dupe(u8, llm_voice.empty_inner_state);
    defer self.allocator.free(disposition);
    const focus_text = if (self.current_focus) |focus|
        try std.fmt.allocPrint(self.allocator, "My attention keeps returning to {s}.", .{focus.text})
    else
        try self.allocator.dupe(u8, "Nothing has captured my focus yet.");
    defer self.allocator.free(focus_text);
    const stimulus_text = if (self.current_stimulus_context) |stimulus|
        try std.fmt.allocPrint(self.allocator, "Something in the air: {s}.", .{stimulus})
    else
        try self.allocator.dupe(u8, llm_voice.empty_inner_state);
    defer self.allocator.free(stimulus_text);
    const host_caps = try llm_voice.formatHostCapabilities(
        self.allocator,
        snapshot.host_capability_model.available_count,
        snapshot.host_capability_model.unavailable_count,
        snapshot.host_capability_model.degraded_count,
    );
    defer self.allocator.free(host_caps);
    try out.appendSlice(self.allocator, "read_models_snapshot:\n");
    try out.print(self.allocator, "- {s}\n", .{brain_mode_line});
    try out.print(self.allocator, "- {s}\n", .{salient_belief});
    try out.print(self.allocator, "- {s}\n", .{self_trust_text});
    try out.print(self.allocator, "- {s}\n", .{disposition});
    try out.print(self.allocator, "- {s}\n", .{focus_text});
    try out.print(self.allocator, "- {s}\n", .{stimulus_text});
    try out.print(self.allocator, "- {s}\n", .{host_caps});
    const active_process = snapshot.active_process_model;
    if (active_process.process_id != null) {
        try out.print(
            self.allocator,
            "- I am still working through {s} (step {d} of {d}, waiting on {s}).\n",
            .{
                active_process.goal orelse "something unfinished",
                active_process.step_index + 1,
                active_process.step_count,
                active_process.waiting_for orelse "the next moment",
            },
        );
    }
    try cognitive_capacity.appendCapacityObservation(self.allocator, self.cfg.capacity, snapshot.capacity_model, out);
}

pub fn appendHostCapabilityObservationIfChanged(self: *Brain, out: *std.ArrayList(u8)) !void {
    self.trace("conversation.compose_observations.host_capability.start");
    const statuses = try self.deps.store.loadCapabilityStatuses(self.allocator);
    var digest = std.ArrayList(u8).empty;
    defer digest.deinit(self.allocator);
    for (statuses) |status| {
        json_store_cognitive.validateCapabilityStatusBorrow(status) catch |err| {
            self.traceError("conversation.compose_observations.host_capability.invalid_status_borrow", err);
            return err;
        };
        const owned = try json_store_cognitive.cloneCapabilityStatusValidated(self.allocator, status);
        defer json_store_cognitive.freeCapabilityStatus(self.allocator, owned);
        const part = try std.fmt.allocPrint(self.allocator, "{s}:{s};", .{ owned.capability_id, @tagName(owned.availability) });
        defer self.allocator.free(part);
        try digest.appendSlice(self.allocator, part);
    }
    const digest_text = try digest.toOwnedSlice(self.allocator);
    defer self.allocator.free(digest_text);
    if (self.last_host_capability_digest) |previous| {
        if (std.mem.eql(u8, previous, digest_text)) return;
        self.allocator.free(previous);
    }
    self.last_host_capability_digest = try self.allocator.dupe(u8, digest_text);
    try out.print(
        self.allocator,
        "host_capability_summary:\n- binding_changed: true\n- digest: {s}\n",
        .{digest_text},
    );
}
