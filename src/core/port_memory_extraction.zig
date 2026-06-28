const std = @import("std");

pub const CandidateKind = enum {
    belief,
    preference,
    relationship,
};

pub const ExtractionCandidate = struct {
    key: []const u8,
    proposition: []const u8,
    evidence: []const u8,
    kind: CandidateKind = .belief,
    confidence: f32 = 0.60,
    salience: f32 = 0.55,
    tags: []const []const u8 = &.{},
    source_references: []const []const u8 = &.{},
};

pub const MemoryExtractionService = struct {
    ctx: *anyopaque,
    extractFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]ExtractionCandidate,

    pub fn extract(self: MemoryExtractionService, allocator: std.mem.Allocator, episode_text: []const u8) ![]ExtractionCandidate {
        return self.extractFn(self.ctx, allocator, episode_text);
    }
};

pub const ScriptedMemoryExtractionService = struct {
    candidates: []const ExtractionCandidate = &.{},
    fail: ?anyerror = null,
    calls: usize = 0,
    last_episode_text: []const u8 = "",

    pub fn service(self: *ScriptedMemoryExtractionService) MemoryExtractionService {
        return .{ .ctx = self, .extractFn = extract };
    }

    fn extract(ctx: *anyopaque, _: std.mem.Allocator, episode_text: []const u8) ![]ExtractionCandidate {
        const self: *ScriptedMemoryExtractionService = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.last_episode_text = episode_text;
        if (self.fail) |err| return err;
        return @constCast(self.candidates);
    }
};
