const std = @import("std");
const brain_mod = @import("brain.zig");
const activity_mod = @import("activity.zig");

const Brain = brain_mod.Brain;

pub const max_cotext_events: usize = 6;

pub fn appendConversationCotextObservation(self: *Brain, out: *std.ArrayList(u8)) !void {
    const active = &(self.active_activity orelse {
        try out.appendSlice(self.allocator, "conversation_cotext: none\n");
        return;
    });
    if (active.kind != .conversation) {
        try out.appendSlice(self.allocator, "conversation_cotext: none\n");
        return;
    }

    try out.appendSlice(
        self.allocator,
        "conversation_cotext:\n- note: senses that arrived while this conversation was already active; associate with active_activity goal; not user speech; speaking is optional.\n",
    );

    var count: usize = 0;
    var index: isize = @intCast(active.timeline.len);
    while (index > 0 and count < max_cotext_events) {
        index -= 1;
        const event = active.timeline[@intCast(index)];
        if (event.kind != .stimulus) continue;
        const age_seconds = @max(@as(i64, 0), self.now_seconds - event.at_seconds);
        try out.print(
            self.allocator,
            "- ({d}s ago) {s}: {s}\n",
            .{ age_seconds, event.title, event.body },
        );
        count += 1;
    }

    if (count == 0) try out.appendSlice(self.allocator, "- none yet\n");
}
