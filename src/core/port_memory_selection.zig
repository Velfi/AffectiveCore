const std = @import("std");

pub const MemoryCandidate = struct {
    memory_id: []const u8,
    interpretation: []const u8,
    tags: []const []const u8,
    salience: f32,
    score: i32,
    scope: []const u8,
};

pub const SelectedMemory = struct {
    memory_id: []const u8,
    relevance: f32,
    reason: []const u8,
};

pub const MemorySelectionResult = struct {
    summary: []const u8,
    selected: []SelectedMemory,
};

pub const MemorySelectionService = struct {
    ctx: *anyopaque,
    selectFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const MemoryCandidate) anyerror!MemorySelectionResult,

    pub fn select(
        self: MemorySelectionService,
        allocator: std.mem.Allocator,
        user_utterance: []const u8,
        candidates: []const MemoryCandidate,
    ) !MemorySelectionResult {
        return self.selectFn(self.ctx, allocator, user_utterance, candidates);
    }
};

pub const ScriptedMemorySelectionService = struct {
    summary: []const u8 = "scripted memory selection summary",
    max_selected: usize = 3,
    /// When set, returned verbatim instead of deriving from candidates (for tests).
    selected_memory_ids: ?[]const []const u8 = null,
    fail: ?anyerror = null,
    calls: usize = 0,
    last_user_utterance: []const u8 = "",
    last_candidate_count: usize = 0,

    pub fn service(self: *ScriptedMemorySelectionService) MemorySelectionService {
        return .{ .ctx = self, .selectFn = select };
    }

    fn select(ctx: *anyopaque, allocator: std.mem.Allocator, user_utterance: []const u8, candidates: []const MemoryCandidate) !MemorySelectionResult {
        const self: *ScriptedMemorySelectionService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_user_utterance = user_utterance;
        self.last_candidate_count = candidates.len;
        if (self.fail) |err| return err;
        if (candidates.len == 0) {
            return .{
                .summary = try allocator.dupe(u8, "No candidate memories were available for this turn."),
                .selected = &.{},
            };
        }
        if (self.selected_memory_ids) |ids| {
            var out = try allocator.alloc(SelectedMemory, ids.len);
            for (ids, 0..) |id, index| {
                out[index] = .{
                    .memory_id = try allocator.dupe(u8, id),
                    .relevance = 0.85,
                    .reason = try std.fmt.allocPrint(allocator, "scripted override rank {d}", .{index + 1}),
                };
            }
            return .{
                .summary = try allocator.dupe(u8, self.summary),
                .selected = out,
            };
        }
        const take = @min(self.max_selected, candidates.len);
        var out = try allocator.alloc(SelectedMemory, take);
        for (candidates[0..take], 0..) |candidate, index| {
            out[index] = .{
                .memory_id = try allocator.dupe(u8, candidate.memory_id),
                .relevance = 0.85,
                .reason = try std.fmt.allocPrint(allocator, "scripted selection rank {d}", .{index + 1}),
            };
        }
        return .{
            .summary = try allocator.dupe(u8, self.summary),
            .selected = out,
        };
    }
};
