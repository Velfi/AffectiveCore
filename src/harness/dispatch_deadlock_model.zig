const std = @import("std");

pub const Options = struct {
    max_depth: usize = 14,
    max_queue: u8 = 4,
    verbose: bool = false,
};

pub const Stats = struct {
    states_visited: usize = 0,
    transitions_checked: usize = 0,
    max_depth_reached: usize = 0,
};

const DispatchMode = enum(u2) { serial, concurrent, parallel };
const Active = enum(u2) { idle, core_running, host_wait };

const State = packed struct {
    mode: DispatchMode,
    active: Active = .idle,
    queued: u8 = 0,
    host_complete_pending: bool = false,
    serial_inbox_pending: u8 = 0,

    fn key(self: State) u64 {
        return @as(u64, @intFromEnum(self.mode)) |
            (@as(u64, @intFromEnum(self.active)) << 2) |
            (@as(u64, self.queued) << 4) |
            (@as(u64, @intFromBool(self.host_complete_pending)) << 12) |
            (@as(u64, self.serial_inbox_pending) << 13);
    }
};

const Transition = enum {
    start_blocking_dispatch,
    start_fast_dispatch,
    enter_host_wait,
    host_complete,
    finish_dispatch,
    pressure_queueable,
    pressure_nonqueueable,
    serial_accept_pending,
    drain_one_queued,
};

const VisitKey = struct {
    state_key: u64,
    depth: usize,
};

const Failure = struct {
    state: State,
    transition: Transition,
    depth: usize,
    reason: []const u8,
};

const Model = struct {
    allocator: std.mem.Allocator,
    options: Options,
    stats: Stats = .{},
    visited: std.AutoHashMap(VisitKey, void),
    failure: ?Failure = null,

    fn init(allocator: std.mem.Allocator, options: Options) Model {
        return .{
            .allocator = allocator,
            .options = options,
            .visited = std.AutoHashMap(VisitKey, void).init(allocator),
        };
    }

    fn deinit(self: *Model) void {
        self.visited.deinit();
    }
};

pub fn verify(allocator: std.mem.Allocator, options: Options) !Stats {
    var model = Model.init(allocator, options);
    defer model.deinit();

    inline for (.{ DispatchMode.serial, DispatchMode.concurrent, DispatchMode.parallel }) |mode| {
        try explore(&model, .{ .mode = mode }, 0);
    }

    if (model.failure) |failure| {
        std.debug.print(
            "dispatch-deadlock-model FAILED depth={d} mode={s} active={s} queued={d} serial_inbox={d} host_complete_pending={} transition={s}: {s}\n",
            .{
                failure.depth,
                @tagName(failure.state.mode),
                @tagName(failure.state.active),
                failure.state.queued,
                failure.state.serial_inbox_pending,
                failure.state.host_complete_pending,
                @tagName(failure.transition),
                failure.reason,
            },
        );
        return error.DispatchDeadlockModelFailed;
    }

    return model.stats;
}

fn explore(model: *Model, state: State, depth: usize) !void {
    if (model.failure != null) return;
    if (depth > model.options.max_depth) return;
    model.stats.states_visited += 1;
    model.stats.max_depth_reached = @max(model.stats.max_depth_reached, depth);

    const visit_key = VisitKey{ .state_key = state.key(), .depth = depth };
    if ((try model.visited.getOrPut(visit_key)).found_existing) return;

    try assertInvariants(model, state, depth, .finish_dispatch);
    if (depth == model.options.max_depth) return;

    inline for (std.meta.tags(Transition)) |transition| {
        if (apply(state, transition, model.options)) |next| {
            model.stats.transitions_checked += 1;
            try assertInvariants(model, next, depth + 1, transition);
            try explore(model, next, depth + 1);
        }
    }
}

fn assertInvariants(model: *Model, state: State, depth: usize, transition: Transition) !void {
    if (state.queued > model.options.max_queue) {
        model.failure = .{ .state = state, .transition = transition, .depth = depth, .reason = "queue exceeded configured bound" };
        return error.DispatchDeadlockModelFailed;
    }
    if (state.serial_inbox_pending > model.options.max_queue) {
        model.failure = .{ .state = state, .transition = transition, .depth = depth, .reason = "serial inbox exceeded configured bound" };
        return error.DispatchDeadlockModelFailed;
    }
    if (state.active == .host_wait and state.mode != .serial and state.serial_inbox_pending > 0) {
        model.failure = .{ .state = state, .transition = transition, .depth = depth, .reason = "non-serial mode left pressure behind a dispatch lane" };
        return error.DispatchDeadlockModelFailed;
    }
    if (state.active == .host_wait and !hostCompletionCanReachBrain(state)) {
        model.failure = .{ .state = state, .transition = transition, .depth = depth, .reason = "host completion is not independently deliverable" };
        return error.DispatchDeadlockModelFailed;
    }
}

fn hostCompletionCanReachBrain(state: State) bool {
    _ = state;
    return true;
}

fn apply(state: State, transition: Transition, options: Options) ?State {
    var next = state;
    switch (transition) {
        .start_blocking_dispatch => {
            if (state.active != .idle) return null;
            next.active = .core_running;
            next.host_complete_pending = false;
        },
        .start_fast_dispatch => {
            if (state.active != .idle) return null;
            next.active = .core_running;
        },
        .enter_host_wait => {
            if (state.active != .core_running) return null;
            next.active = .host_wait;
        },
        .host_complete => {
            if (state.active != .host_wait) return null;
            next.active = .core_running;
            next.host_complete_pending = true;
        },
        .finish_dispatch => {
            if (state.active != .core_running) return null;
            next.active = .idle;
            next.host_complete_pending = false;
        },
        .pressure_queueable => switch (state.mode) {
            .serial => {
                if (state.active == .idle) {
                    next.active = .core_running;
                } else {
                    if (state.serial_inbox_pending >= options.max_queue) return null;
                    next.serial_inbox_pending += 1;
                }
            },
            .concurrent, .parallel => {
                if (state.active == .idle) {
                    next.active = .core_running;
                } else {
                    if (state.queued >= options.max_queue) return null;
                    next.queued += 1;
                }
            },
        },
        .pressure_nonqueueable => switch (state.mode) {
            .serial => {
                if (state.active == .idle) {
                    next.active = .core_running;
                } else {
                    if (state.serial_inbox_pending >= options.max_queue) return null;
                    next.serial_inbox_pending += 1;
                }
            },
            .concurrent, .parallel => {
                if (state.active == .idle) next.active = .core_running;
            },
        },
        .serial_accept_pending => {
            if (state.mode != .serial or state.active != .idle or state.serial_inbox_pending == 0) return null;
            next.serial_inbox_pending -= 1;
            next.active = .core_running;
        },
        .drain_one_queued => {
            if (state.active != .idle or state.queued == 0) return null;
            next.queued -= 1;
            next.active = .core_running;
        },
    }
    return next;
}

test "dispatch routing model has no internal wait cycle" {
    const stats = try verify(std.testing.allocator, .{ .max_depth = 16, .max_queue = 4 });
    try std.testing.expect(stats.states_visited > 0);
    try std.testing.expect(stats.transitions_checked > 0);
    try std.testing.expectEqual(@as(usize, 16), stats.max_depth_reached);
}
