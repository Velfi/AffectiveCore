const std = @import("std");
const brain_mod = @import("../brain.zig");
const activity = @import("../activity.zig");
const brain_activity = @import("../brain_activity.zig");
const chat = @import("../port_chat.zig");
const brain_actor = @import("brain_actor.zig");

const Brain = brain_mod.Brain;

pub const ActivityActor = struct {
    allocator: std.mem.Allocator,
    sink: brain_actor.EventSink,

    pub fn init(allocator: std.mem.Allocator, sink: brain_actor.EventSink) ActivityActor {
        return .{ .allocator = allocator, .sink = sink };
    }

    pub fn ensureActive(
        self: *const ActivityActor,
        brain: *Brain,
        anchor: []const u8,
        originating_request_id: []const u8,
        orchestration: brain_activity.ActivityOrchestration,
    ) !void {
        try brain_activity.ensureActiveActivity(brain, anchor, originating_request_id, orchestration);
        try self.emitUpdated(brain);
    }

    pub fn appendTurn(
        self: *const ActivityActor,
        brain: *Brain,
        user_text: []const u8,
        spoken_text: []const u8,
        turn: ?chat.ChatTurn,
    ) !void {
        try brain_activity.appendTurnEvents(brain, user_text, spoken_text, turn);
        try self.emitUpdated(brain);
    }

    pub fn pauseForHostSense(self: *const ActivityActor, brain: *Brain, pause: brain_activity.PauseForHostSense) !void {
        try brain_activity.pauseForHostSense(brain, pause);
        try self.emitUpdated(brain);
    }

    pub fn resumeActivity(self: *const ActivityActor, brain: *Brain) !activity.Checkpoint {
        const checkpoint = try brain_activity.resumeActiveActivity(brain);
        try self.emitUpdated(brain);
        return checkpoint;
    }

    pub fn close(self: *const ActivityActor, brain: *Brain, status: activity.Status, reason: []const u8) !void {
        try brain_activity.closeActiveActivity(brain, status, reason);
        try self.emitUpdated(brain);
    }

    pub fn syncContext(self: *const ActivityActor, brain: *Brain) !void {
        try brain_activity.syncActivityContextFromBrain(brain);
        try self.emitUpdated(brain);
    }

    pub fn newActivityId(allocator: std.mem.Allocator, now_seconds: i64, kind_label: []const u8, salt: u64) ![]const u8 {
        return activity.newId(allocator, now_seconds, kind_label, salt);
    }

    fn emitUpdated(self: *const ActivityActor, brain: *Brain) !void {
        const Payload = struct {
            activity_id: ?[]const u8,
            status: ?[]const u8,
            kind_label: ?[]const u8,
            goal: ?[]const u8,
            awaiting: ?[]const u8,
        };

        const view = try brain_activity.activityView(brain, self.allocator);
        if (view) |v| {
            defer activity.freeViewExtras(self.allocator, v);
            try self.sink.emitStruct(self.allocator, "activity.updated", Payload{
                .activity_id = v.id,
                .status = activity.statusTag(v.status),
                .kind_label = v.kind_label,
                .goal = v.goal,
                .awaiting = v.awaiting,
            });
            return;
        }

        try self.sink.emitStruct(self.allocator, "activity.updated", Payload{
            .activity_id = null,
            .status = null,
            .kind_label = null,
            .goal = null,
            .awaiting = null,
        });
    }
};

