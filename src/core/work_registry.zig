const std = @import("std");
const brain_mod = @import("brain.zig");
const process_runtime_mod = @import("process_runtime.zig");

const Brain = brain_mod.Brain;
const ActiveProcess = process_runtime_mod.ActiveProcess;

pub const Registry = struct {
    secondary: std.ArrayList(ActiveProcess) = .empty,
    max_slots: usize = 0,

    pub fn init(max_slots: usize) Registry {
        return .{ .max_slots = max_slots };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.secondary.items) |*process| freeProcess(allocator, process);
        self.secondary.deinit(allocator);
    }

    pub fn slotAvailable(self: *const Registry) bool {
        return self.secondary.items.len < self.max_slots;
    }

    pub fn registerSecondary(self: *Registry, allocator: std.mem.Allocator, process: ActiveProcess) !void {
        if (!self.slotAvailable()) return error.WorkRegistryFull;
        try self.secondary.append(allocator, process);
    }

    pub fn activeCount(self: *const Registry, primary_active: bool) usize {
        return (if (primary_active) @as(usize, 1) else 0) + self.secondary.items.len;
    }
};

pub fn freeProcess(allocator: std.mem.Allocator, process: *ActiveProcess) void {
    allocator.free(process.id);
    allocator.free(process.goal);
    allocator.free(process.user_anchor);
    if (process.composition_reason) |reason| allocator.free(reason);
    if (process.wait_stimulus_signature) |signature| allocator.free(signature);
    for (process.steps) |step| process_runtime_mod.freeProcessStepFields(allocator, step);
    allocator.free(process.steps);
    for (process.step_ids) |step_id| allocator.free(step_id);
    allocator.free(process.step_ids);
}

pub fn tryStartProcess(
    self: *Brain,
    goal: []const u8,
    user_anchor: []const u8,
    origin: @import("port_chat.zig").ActionOrigin,
    composition_reason: ?[]const u8,
    steps: []process_runtime_mod.ProcessStep,
) !void {
    if (self.active_process == null) {
        try process_runtime_mod.startProcessUnchecked(self, goal, user_anchor, origin, composition_reason, steps);
        return;
    }
    if (!self.work_registry.slotAvailable()) return error.NestedProcessGoal;
    try process_runtime_mod.startSecondaryProcess(self, goal, user_anchor, origin, composition_reason, steps);
}
