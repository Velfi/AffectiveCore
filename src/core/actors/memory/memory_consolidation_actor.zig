const std = @import("std");
const ports = @import("../../ports.zig");
const schema = ports.schema;
const ctx_mod = @import("context.zig");
const types = @import("types.zig");

pub const MemoryConsolidationActor = struct {
    pub fn consolidateActivity(
        context: *const ctx_mod.ActorContext,
        activity: schema.ActivityRecord,
        reason: []const u8,
    ) !types.MemoryCandidate {
        if (activity.status != .paused and activity.status != .complete and activity.status != .abandoned) {
            return error.ActivityNotPausedOrClosed;
        }
        const timeline_excerpt = if (activity.timeline.len == 0)
            "none"
        else
            activity.timeline[activity.timeline.len - 1].body;
        const summary = try std.fmt.allocPrint(
            context.allocator,
            "activity={s} status={s} goal={s} summary={s} close_reason={s} timeline_tail={s}",
            .{
                activity.id,
                @tagName(activity.status),
                activity.goal,
                activity.summary,
                if (reason.len > 0) reason else (activity.close_reason orelse ""),
                timeline_excerpt,
            },
        );
        const tags = try context.allocator.alloc([]const u8, 3);
        tags[0] = try context.allocator.dupe(u8, "activity");
        tags[1] = try context.allocator.dupe(u8, "episode_summary");
        tags[2] = try context.allocator.dupe(u8, @tagName(activity.status));
        const source_id = if (activity.id.len > 0) activity.id else return error.MissingActivityId;
        return .{
            .candidate_id = try std.fmt.allocPrint(context.allocator, "activity_episode_{s}_{d}", .{ source_id, context.now_seconds }),
            .key = try std.fmt.allocPrint(context.allocator, "activity.{s}", .{source_id}),
            .proposition = summary,
            .evidence = summary,
            .kind = .episode,
            .confidence = 0.72,
            .salience = 0.65,
            .status = .candidate,
            .source_event_ids = &.{},
            .tags = tags,
        };
    }
};
