const std = @import("std");

pub const StimulusKind = enum {
    face_memory,
    held_input,
    conversation,
};

pub const Stimulus = struct {
    kind: StimulusKind,
};

pub const Source = struct {
    ctx: *anyopaque,
    pollFn: *const fn (*anyopaque, std.mem.Allocator) anyerror!?Stimulus,

    pub fn poll(self: Source, allocator: std.mem.Allocator) !?Stimulus {
        return self.pollFn(self.ctx, allocator);
    }
};
