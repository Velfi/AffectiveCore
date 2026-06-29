const std = @import("std");
const brain_mod = @import("brain.zig");
const read_models = @import("read_models.zig");
const cognitive_capacity = @import("cognitive_capacity.zig");

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
    const salient_belief = if (snapshot.belief_model.salient) |belief| belief.proposition else "none";
    const self_trust_text = if (snapshot.self_trust_model.strongest) |entry|
        try std.fmt.allocPrint(self.allocator, "{s}={d:.2}", .{ entry.faculty, entry.confidence })
    else
        try self.allocator.dupe(u8, "none");
    defer self.allocator.free(self_trust_text);
    const disposition = if (snapshot.disposition_model.strongest) |entry| entry.action_tendency else "none";
    const focus_text = if (self.current_focus) |focus|
        try std.fmt.allocPrint(self.allocator, "{s} ({s})", .{ focus.text, @tagName(focus.source) })
    else
        try self.allocator.dupe(u8, "none");
    defer self.allocator.free(focus_text);
    const stimulus_text = self.current_stimulus_context orelse "none";
    try out.print(
        self.allocator,
        "read_models_snapshot:\n- brain_mode: {s}\n- salient_belief: {s}\n- strongest_self_trust: {s}\n- winning_disposition: {s}\n- current_focus: {s}\n- current_stimulus: {s}\n- host_capabilities: available={d} unavailable={d} degraded={d}\n",
        .{
            @tagName(snapshot.brain_mode),
            salient_belief,
            self_trust_text,
            disposition,
            focus_text,
            stimulus_text,
            snapshot.host_capability_model.available_count,
            snapshot.host_capability_model.unavailable_count,
            snapshot.host_capability_model.degraded_count,
        },
    );
    const active_process = snapshot.active_process_model;
    if (active_process.process_id != null) {
        try out.print(
            self.allocator,
            "- active_process: goal={s} origin={s} state={s} step={d}/{d} kind={s} waiting={s}\n",
            .{
                active_process.goal orelse "unknown",
                active_process.origin orelse "unknown",
                active_process.state orelse "unknown",
                active_process.step_index + 1,
                active_process.step_count,
                active_process.current_step_kind orelse "none",
                active_process.waiting_for orelse "none",
            },
        );
    }
    try cognitive_capacity.appendCapacityObservation(self.allocator, self.cfg.capacity, snapshot.capacity_model, out);
}

pub fn appendHostCapabilityObservationIfChanged(self: *Brain, out: *std.ArrayList(u8)) !void {
    const statuses = try self.deps.store.loadCapabilityStatuses(self.allocator);
    var digest = std.ArrayList(u8).empty;
    defer digest.deinit(self.allocator);
    for (statuses) |status| {
        const part = try std.fmt.allocPrint(self.allocator, "{s}:{s};", .{ status.capability_id, @tagName(status.availability) });
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
