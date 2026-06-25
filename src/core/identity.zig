const std = @import("std");

pub const MatchStatus = enum { none, known, unknown, uncertain, multiple };

pub const IdentityResult = struct {
    person_present: bool,
    match_status: MatchStatus,
    person_id: ?[]const u8 = null,
    confidence: f32 = 0,
    candidate_name: ?[]const u8 = null,
    people_count: u32 = 0,
};

pub const IdentityRecognizer = struct {
    ctx: *anyopaque,
    identifyFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!IdentityResult,

    pub fn identify(self: IdentityRecognizer, allocator: std.mem.Allocator, image_path: []const u8) !IdentityResult {
        return self.identifyFn(self.ctx, allocator, image_path);
    }
};

pub fn statusFromConfidence(person_present: bool, confidence: f32, known_threshold: f32, uncertain_threshold: f32) MatchStatus {
    if (!person_present) return .none;
    if (confidence >= known_threshold) return .known;
    if (confidence >= uncertain_threshold) return .uncertain;
    return .unknown;
}
