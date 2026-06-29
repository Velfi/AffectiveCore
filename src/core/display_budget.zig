const std = @import("std");
const facial_expression = @import("port_facial_expression.zig");

pub const window_seconds: i64 = 5;
pub const max_budget_ms: u32 = facial_expression.max_duration_ms;

pub const State = struct {
    window_start_seconds: i64 = 0,
    used_ms: u32 = 0,
    active: bool = false,
};

pub fn tryConsume(state: *State, now_seconds: i64, duration_ms: u32) error{DisplayBudgetExceeded}!void {
    if (!state.active or now_seconds - state.window_start_seconds >= window_seconds) {
        state.window_start_seconds = now_seconds;
        state.used_ms = 0;
        state.active = true;
    }
    if (state.used_ms + duration_ms > max_budget_ms) return error.DisplayBudgetExceeded;
    state.used_ms += duration_ms;
}

test "display budget resets after window elapses" {
    var state = State{};
    try tryConsume(&state, 100, 3000);
    try std.testing.expectEqual(@as(u32, 3000), state.used_ms);
    try tryConsume(&state, 105, 2000);
    try std.testing.expectEqual(@as(u32, 2000), state.used_ms);
    try std.testing.expectEqual(@as(i64, 105), state.window_start_seconds);
}

test "display budget rejects when cap exceeded in window" {
    var state = State{};
    try tryConsume(&state, 10, 3000);
    try std.testing.expectError(error.DisplayBudgetExceeded, tryConsume(&state, 11, 3000));
}

test "display budget shares window across consumers" {
    var state = State{};
    try tryConsume(&state, 50, 4000);
    try std.testing.expectError(error.DisplayBudgetExceeded, tryConsume(&state, 51, 2000));
    try tryConsume(&state, 56, 5000);
    try std.testing.expectEqual(@as(u32, 5000), state.used_ms);
}

test "display budget keeps window at epoch zero" {
    var state = State{};
    try tryConsume(&state, 0, 5000);
    try std.testing.expectError(error.DisplayBudgetExceeded, tryConsume(&state, 0, 1000));
}
