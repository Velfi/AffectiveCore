const std = @import("std");

pub const WantCandidate = struct {
    memory_id: []const u8,
    text: []const u8,
    interpretation: []const u8,
    salience: f32,
    score: i32,
};

pub const WantAchievementMatch = struct {
    memory_id: []const u8,
    confidence: f32,
    evidence: []const u8,
};

pub const WantAchievementResult = struct {
    matches: []const WantAchievementMatch,
};

pub const WantAchievementDetector = struct {
    ctx: *anyopaque,
    detectFn: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const WantCandidate) anyerror!WantAchievementResult,

    pub fn detect(self: WantAchievementDetector, allocator: std.mem.Allocator, event_text: []const u8, wants: []const WantCandidate) !WantAchievementResult {
        return self.detectFn(self.ctx, allocator, event_text, wants);
    }
};

pub const ScriptedWantAchievementDetector = struct {
    matches: []const WantAchievementMatch = &.{},
    fail: ?anyerror = null,
    calls: usize = 0,
    last_event_text: []const u8 = "",
    last_want_count: usize = 0,

    pub fn detector(self: *ScriptedWantAchievementDetector) WantAchievementDetector {
        return .{ .ctx = self, .detectFn = detect };
    }

    fn detect(ctx: *anyopaque, allocator: std.mem.Allocator, event_text: []const u8, wants: []const WantCandidate) !WantAchievementResult {
        _ = allocator;
        const self: *ScriptedWantAchievementDetector = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_event_text = event_text;
        self.last_want_count = wants.len;
        if (self.fail) |err| return err;
        return .{ .matches = self.matches };
    }
};
